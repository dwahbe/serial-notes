import Foundation

@MainActor @Observable
final class RecordingState {
    var isRecording = false
    /// True from `start()` entry until the session is fully spun up — the window
    /// before `isRecording` flips, during which `start()` awaits model prep +
    /// session priming. The meeting detector reads this (via
    /// `isRecordingSessionActive`) to suppress its start prompt across the whole
    /// lifecycle. Not observed by any view.
    @ObservationIgnored private(set) var isStarting = false
    /// True for the whole finalization window — set synchronously in `beginStop`
    /// (before notifying the detector) and cleared after `finishStop`. Keeps the
    /// meeting detector's start monitor paused through finalization without
    /// depending on `finalizationTask`'s assignment timing.
    @ObservationIgnored private var isFinalizing = false
    var elapsedTime: TimeInterval = 0
    var errorMessage: String?

    @ObservationIgnored var onRecordingChange: (@MainActor () -> Void)?
    /// Fired after a recording finalizes when it detected ≥1 unrecognized system
    /// speaker, so the app can offer to name them. Carries the session directory and
    /// the pending-speaker count. Suppressed on `.appQuit`.
    @ObservationIgnored var onUnnamedSpeakers: (@MainActor (URL, Int) -> Void)?
    @ObservationIgnored weak var voiceProfileStore: VoiceProfileStore?
    @ObservationIgnored weak var summarySettings: SummarySettings?
    @ObservationIgnored weak var storageSettings: StorageSettings?
    @ObservationIgnored weak var identitySettings: IdentitySettings?

    private var timer: Timer?
    private var startDate: Date?
    private var currentSessionDir: URL?
    @ObservationIgnored private var finalizationTask: Task<Void, Never>?
    @ObservationIgnored private var pendingMeetingDiagnostics: MeetingSessionDiagnostics?
    private let captureService = AudioCaptureService()
    let transcriptionService = TranscriptionService()

    var formattedElapsedTime: String {
        let minutes = Int(elapsedTime) / 60
        let seconds = Int(elapsedTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var hasActiveOrFinalizingSession: Bool {
        isRecording || finalizationTask != nil
    }

    /// Whether a recording session occupies any phase — spinning up, actively
    /// recording, or finalizing. The meeting detector keys its start-prompt
    /// suppression on this rather than bare `isRecording`: `start()` runs
    /// `await`-heavy setup (model prep + session priming) before `isRecording`
    /// flips, and if the mic is already active in that window (e.g. a meeting app
    /// warm-holding the input) attributing it would fire a phantom "meeting
    /// detected" prompt over the user's own just-started recording.
    var isRecordingSessionActive: Bool {
        isStarting || isRecording || isFinalizing
    }

    func start(storageDirectory: URL) async {
        if hasActiveOrFinalizingSession {
            await stopAndWait(reason: .manual)
        }
        await stopCapture()

        // Mark the session in flight before the await-heavy setup below. Notifying
        // now lets the meeting detector clear any "meeting detected" prompt the
        // instant the user hits Record and stay quiet for the whole start window —
        // otherwise an already-active mic (e.g. an idle meeting app warm-holding
        // the input) could be attributed and prompt before `isRecording` flips.
        isStarting = true
        onRecordingChange?()

        do {
            // Idempotent — if models are already loaded this returns immediately.
            // If a download kicked off at app launch is still in flight, the
            // actor serializes us behind it so we don't race to re-download.
            try await transcriptionService.downloadModelsIfNeeded()

            let sessionDir = storageDirectory.appendingPathComponent(Self.sessionDirectoryName())
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

            // Wire transcription error callback.
            await transcriptionService.setCallbacks(
                onError: { [weak self] error in
                    Task { @MainActor in
                        self?.errorMessage = TranscriptionError.userFacingDescription(for: error)
                    }
                }
            )

            // Start the transcription session before capture so the actor's
            // per-side ASR/diarizer state is reset and `activeSessionID` is set
            // before any audio buffer can arrive. Otherwise buffers fired
            // between startCapture's return and startSession's completion would
            // bleed into stale state.
            let now = Date()
            // The preferred name (or "You" when unset) labels the user's mic
            // voice everywhere: the streaming default label, the `.you` diarizer
            // enrollment, and the final-render collapse target.
            let micDisplayName = identitySettings?.micDisplayName ?? "You"
            let enrollments = loadEnrollments(micDisplayName: micDisplayName)
            // Pass the start-time snapshot so the summarizer can prewarm during
            // the recording. If the user toggles summary on later, the splice
            // step falls back to lazy construction.
            let summarySnapshot = summarySettings?.snapshot() ?? .disabled
            try await transcriptionService.startSession(
                sessionDirectory: sessionDir,
                sessionStart: now,
                enrollments: enrollments,
                summarySettings: summarySnapshot,
                micPrimaryName: micDisplayName
            )

            // Wire audio buffer callbacks for transcription.
            let transcriber = transcriptionService
            captureService.onSystemAudioBuffer = { buffer in
                Task { await transcriber.processSystemAudio(buffer) }
            }
            captureService.onMicAudioBuffer = { buffer in
                Task { await transcriber.processMicAudio(buffer) }
            }

            try await captureService.startCapture(sessionDir: sessionDir) { [weak self] error in
                Task { @MainActor in
                    self?.errorMessage = error.localizedDescription
                    await self?.stopCapture()
                }
            }

            isStarting = false
            isRecording = true
            errorMessage = nil
            startDate = now
            currentSessionDir = sessionDir
            elapsedTime = 0
            onRecordingChange?()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let startDate = self.startDate else { return }
                    self.elapsedTime = Date().timeIntervalSince(startDate)
                }
            }
        } catch {
            // Start failed — clear the in-flight flag and re-notify so the detector
            // resumes normal evaluation (it suppressed itself on the entry ping).
            isStarting = false
            errorMessage = error.localizedDescription
            onRecordingChange?()
        }
    }

    func stop(reason: RecordingStopReason = .manual) {
        Task { await stopAndWait(reason: reason) }
    }

    func stopAndWait(reason: RecordingStopReason = .manual) async {
        if let finalizationTask {
            // Preserve the reason that started finalization. If app quit races
            // with an already-fired auto-stop, quit should wait for the save
            // rather than relabel the session after teardown has begun.
            await finalizationTask.value
            return
        }
        guard let context = beginStop(reason: reason) else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.finishStop(context)
        }
        finalizationTask = task
        await task.value
        finalizationTask = nil
        // Session fully clear — drop the finalizing flag and notify so the detector
        // re-baselines and resumes its start monitor.
        isFinalizing = false
        onRecordingChange?()
    }

    private func beginStop(reason: RecordingStopReason) -> StopContext? {
        guard isRecording else { return nil }

        isRecording = false
        timer?.invalidate()
        timer = nil
        let sessionStart = startDate
        let sessionDir = currentSessionDir
        let summaryCutoff = Self.summaryCutoff(for: reason, sessionStart: sessionStart)
        startDate = nil
        currentSessionDir = nil
        // Mark finalizing *before* notifying, so the detector both (a) keeps its
        // start monitor paused for the whole finalization window (isFinalizing keeps
        // isRecordingSessionActive true regardless of finalizationTask timing) and
        // (b) ends call-end monitoring now — which flushes its diagnostics into
        // pendingMeetingDiagnostics that we read just below.
        isFinalizing = true
        onRecordingChange?()
        let summarySnapshot = summarySettings?.snapshot() ?? .disabled
        let keepAudioFiles = storageSettings?.saveAudioFiles ?? true
        var diagnostics = pendingMeetingDiagnostics
        diagnostics?.stopReason = reason.diagnosticsValue
        pendingMeetingDiagnostics = nil
        return StopContext(
            sessionDir: sessionDir,
            sessionStart: sessionStart,
            stopReason: reason,
            summarySettings: summarySnapshot,
            keepAudioFiles: keepAudioFiles,
            summaryCutoff: summaryCutoff,
            meetingDiagnostics: diagnostics
        )
    }

    private func finishStop(_ context: StopContext) async {
        await stopCapture()
        let stats = captureService.currentStats()
        let pendingSpeakers = await transcriptionService.endSession(
            summarySettings: context.summarySettings,
            keepAudioFiles: context.keepAudioFiles,
            summaryCutoff: context.summaryCutoff,
            // On app quit the prompt is suppressed anyway — skip clip extraction so
            // termination isn't delayed by writing WAVs the user won't see.
            extractSpeakers: !context.stopReason.isAppQuit
        )
        finalizeSession(
            context: context,
            stats: stats
        )
        notifyUnnamedSpeakersIfNeeded(context: context, count: pendingSpeakers)
    }

    private func notifyUnnamedSpeakersIfNeeded(context: StopContext, count: Int) {
        guard count > 0, let sessionDir = context.sessionDir else { return }
        // App quit tears the UI down — don't try to surface a naming prompt then.
        // The speakers.json sidecar still persists, so the user can name them later
        // from Settings → Meetings.
        if case .appQuit = context.stopReason { return }
        onUnnamedSpeakers?(sessionDir, count)
    }

    private func finalizeSession(
        context: StopContext,
        stats: AudioCaptureStats
    ) {
        let sessionDir = context.sessionDir
        let sessionStart = context.sessionStart
        guard let sessionDir, let sessionStart else { return }

        writeSessionJSON(
            sessionDir: sessionDir,
            sessionStart: sessionStart,
            stats: stats,
            context: context
        )
        writeMeetingAudioDiagnosticsIfNeeded(sessionDir: sessionDir, diagnostics: context.meetingDiagnostics)

        // Only warn when zero buffers arrived for a recording long enough that
        // we'd have expected the tap to fire (~12 buffers/sec). Short test
        // recordings or genuinely silent system output (e.g. a Zoom call with
        // no other participants) can legitimately produce zero buffers and
        // shouldn't trigger a permission alarm.
        let duration = Date().timeIntervalSince(sessionStart)
        let zeroBufferThreshold: TimeInterval = 15
        if stats.path == .processTap,
           stats.system.bufferCount == 0,
           duration >= zeroBufferThreshold {
            errorMessage = "System audio wasn't captured. If other participants were speaking, check System Settings → Privacy & Security → System Audio Recording Only."
        }
    }

    private func writeSessionJSON(
        sessionDir: URL,
        sessionStart: Date,
        stats: AudioCaptureStats,
        context: StopContext
    ) {
        let payload = SessionDiagnostics(
            startedAt: sessionStart,
            endedAt: Date(),
            stopReason: context.stopReason.diagnosticsValue,
            summaryCutoffSeconds: context.summaryCutoff,
            capturePath: stats.path?.rawValue ?? "unknown",
            mic: stats.mic,
            system: stats.system,
            enrolledProfiles: voiceProfileStore?.profiles.map { $0.name } ?? [],
            meeting: context.meetingDiagnostics
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = sessionDir.appendingPathComponent("session.json")
        do {
            let data = try encoder.encode(payload)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Diagnostics-only — don't surface in UI, but log so debugging
            // a missing session.json doesn't look like nothing happened.
            NSLog("[SerialNotes/RecordingState] failed to write session.json: %@",
                  error.localizedDescription)
        }
    }

    func attachMeetingDiagnosticsForCurrentStop(_ diagnostics: MeetingSessionDiagnostics?) {
        pendingMeetingDiagnostics = diagnostics
    }

    private func writeMeetingAudioDiagnosticsIfNeeded(
        sessionDir: URL,
        diagnostics: MeetingSessionDiagnostics?
    ) {
        guard let diagnostics, diagnostics.shouldWriteSidecar else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = sessionDir.appendingPathComponent("meeting-audio-diagnostics.json")
        do {
            let data = try encoder.encode(diagnostics)
            try data.write(to: url, options: [.atomic])
        } catch {
            NSLog("[SerialNotes/RecordingState] failed to write meeting-audio-diagnostics.json: %@",
                  error.localizedDescription)
        }
    }

    private func stopCapture() async {
        await captureService.stopCapture()
    }

    private func loadEnrollments(micDisplayName: String) -> [EnrollmentClip] {
        guard let store = voiceProfileStore else { return [] }
        return store.profiles.compactMap { profile -> EnrollmentClip? in
            guard let clip = store.loadClipSamples(for: profile) else { return nil }
            let side: AudioSide = profile.kind == .you ? .mic : .system
            // Label the user's own voice with their current preferred name rather
            // than the name baked into the profile at enrollment time — the name
            // can be changed in Settings after recording without re-enrolling.
            let name = profile.kind == .you ? micDisplayName : profile.name
            return EnrollmentClip(
                name: name,
                side: side,
                samples: clip.samples,
                sampleRate: clip.sampleRate
            )
        }
    }

    private static func sessionDirectoryName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    private static func summaryCutoff(
        for reason: RecordingStopReason,
        sessionStart: Date?
    ) -> TimeInterval? {
        guard let sessionStart,
              let cutoffDate = reason.summaryCutoffDate else {
            return nil
        }
        return max(0, cutoffDate.timeIntervalSince(sessionStart))
    }
}

/// Written as `session.json` alongside the WAVs so we can tell — after the
/// fact — which capture path was used, how much audio each stream got, and
/// which voice profiles were primed.
private struct SessionDiagnostics: Codable {
    let startedAt: Date
    let endedAt: Date
    let stopReason: String
    let summaryCutoffSeconds: TimeInterval?
    let capturePath: String
    let mic: AudioStreamStats
    let system: AudioStreamStats
    let enrolledProfiles: [String]
    let meeting: MeetingSessionDiagnostics?
}

private struct StopContext: Sendable {
    let sessionDir: URL?
    let sessionStart: Date?
    let stopReason: RecordingStopReason
    let summarySettings: SummarySettings.Snapshot
    let keepAudioFiles: Bool
    let summaryCutoff: TimeInterval?
    let meetingDiagnostics: MeetingSessionDiagnostics?
}
