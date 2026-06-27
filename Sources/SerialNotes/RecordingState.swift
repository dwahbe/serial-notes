import Foundation

@MainActor @Observable
final class RecordingState {
    var isRecording = false
    /// True from `start()` entry until the session is fully spun up — the window
    /// before `isRecording` flips, during which `start()` awaits model prep +
    /// session priming. The meeting detector reads this (via
    /// `isRecordingSessionActive`) to suppress its start prompt across the whole
    /// lifecycle.
    @ObservationIgnored private(set) var isStarting = false
    /// True for the whole finalization window — set synchronously in `beginStop`
    /// (before notifying the detector) and cleared after `finishStop`. Keeps the
    /// meeting detector's start monitor paused through finalization without
    /// depending on `finalizationTask`'s assignment timing. Observable because
    /// Settings disables setup-guide re-entry while finalization is active.
    private(set) var isFinalizing = false
    /// Current milestone of the post-meeting pipeline while `isFinalizing`, driving
    /// the popover's processing card. `nil` outside finalization.
    private(set) var finalizationPhase: FinalizationPhase?
    var elapsedTime: TimeInterval = 0
    var errorMessage: String?

    @ObservationIgnored var onRecordingChange: (@MainActor () -> Void)?
    /// Fired after a recording finalizes when it detected ≥1 unrecognized system
    /// speaker, so the app can offer to name them. Carries the session directory and
    /// the pending-speaker count. Suppressed on `.appQuit`.
    @ObservationIgnored var onUnnamedSpeakers: (@MainActor (URL, Int) -> Void)?
    @ObservationIgnored weak var voiceProfileStore: VoiceProfileStore?

    /// Shared offline speaker identifier — owns the post-meeting re-diarization +
    /// embedding models (downloaded once, reused across meetings).
    @ObservationIgnored private let offlineIdentifier = OfflineSpeakerIdentifier()
    @ObservationIgnored weak var summarySettings: SummarySettings?
    @ObservationIgnored weak var storageSettings: StorageSettings?
    @ObservationIgnored weak var identitySettings: IdentitySettings?
    @ObservationIgnored weak var exportSettings: ExportSettings?

    private var timer: Timer?
    private var startDate: Date?
    private var currentSessionDir: URL?
    @ObservationIgnored private var finalizationTask: Task<Void, Never>?
    @ObservationIgnored private var pendingMeetingDiagnostics: MeetingSessionDiagnostics?
    /// Candidate embeddings are prepared during the recording, rather than serially
    /// after Stop. Finalization only waits here when a very short session ends before
    /// the preparation task can finish.
    @ObservationIgnored private var speakerCandidatePreparationTask: Task<Void, Never>?
    @ObservationIgnored private var preparedSpeakerCandidates: [SpeakerIdentityMatcher.Candidate] = []
    private static let appQuitOfflineIdentityTimeout: Duration = .seconds(6)
    private let captureService = AudioCaptureService()
    let transcriptionService = TranscriptionService()

    var formattedElapsedTime: String {
        let minutes = Int(elapsedTime) / 60
        let seconds = Int(elapsedTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var hasActiveOrFinalizingSession: Bool {
        isRecording || isFinalizing
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

            prepareSpeakerCandidatesForCurrentSession()

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
        finalizationPhase = nil
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
        // Seed the first phase synchronously so the popover never shows an empty
        // processing card before endSession's first callback lands.
        finalizationPhase = .finishingTranscript
        onRecordingChange?()
        let summarySnapshot = summarySettings?.snapshot() ?? .disabled
        let keepAudioFiles = storageSettings?.saveAudioFiles ?? true
        // Freeze the enabled export targets at stop time so a mid-finalization
        // toggle can't change what gets pushed.
        let exportTargets = exportSettings?.activeTargets ?? []
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
            exportTargets: exportTargets,
            meetingDiagnostics: diagnostics
        )
    }

    private func finishStop(_ context: StopContext) async {
        await stopCapture()
        let stats = captureService.currentStats()
        // Candidate embeddings normally finish during recording. Both stop paths
        // await any remaining work before the identity pass. Quit uses only the
        // already-prepared snapshot so a first-use enrollment embedding cannot block
        // termination behind an uncancellable offline diarization.
        let isAppQuit = context.stopReason.isAppQuit
        let candidates = await speakerCandidatesForStop(isAppQuit: isAppQuit)
        let pendingSpeakers = await transcriptionService.endSession(
            summarySettings: context.summarySettings,
            keepAudioFiles: context.keepAudioFiles,
            summaryCutoff: context.summaryCutoff,
            // App quit still applies known identities when models/candidates are
            // available, but continues to skip clip extraction and naming UI.
            extractSpeakers: !isAppQuit,
            performOfflineIdentity: true,
            speakerCandidates: candidates,
            offlineIdentifier: offlineIdentifier,
            offlineIdentityTimeout: isAppQuit ? Self.appQuitOfflineIdentityTimeout : nil,
            requirePreparedOfflineModels: isAppQuit,
            onPhase: { [weak self] phase in
                Task { @MainActor in self?.finalizationPhase = phase }
            }
        )
        finalizeSession(
            context: context,
            stats: stats
        )
        notifyUnnamedSpeakersIfNeeded(context: context, count: pendingSpeakers)
        exportIfNeeded(context)
        speakerCandidatePreparationTask?.cancel()
        speakerCandidatePreparationTask = nil
        preparedSpeakerCandidates = []
    }

    /// Push the finalized transcript into any enabled notes apps (Apple Notes /
    /// Bear). Fire-and-forget so it can't delay finalization or the detector
    /// resuming — the first Apple Notes send blocks on a TCC prompt. Skipped on app
    /// quit (the target app may be quitting too, and we don't delay termination);
    /// the on-disk transcript is unaffected either way.
    private func exportIfNeeded(_ context: StopContext) {
        guard !context.exportTargets.isEmpty,
              !context.stopReason.isAppQuit,
              let sessionDir = context.sessionDir else { return }
        let transcriptURL = sessionDir.appendingPathComponent("transcript.md")
        let targets = context.exportTargets
        Task.detached(priority: .utility) {
            await MeetingExporter.export(targets: targets, transcriptURL: transcriptURL)
        }
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
        // Only the user's own voice (`.you`) is primed into the *live* diarizer.
        // Other people's profiles are matched after the meeting by the offline
        // identity pass, which has a cosine score + rejection threshold — the live
        // LS-EEND diarizer has neither (it tracks speakers by fixed neural slots),
        // so priming a name here can route a brand-new voice into an enrolled slot
        // and mislabel a stranger as a known participant. The mic voice is labelled
        // with the *current* preferred name, not the one baked in at enrollment, so
        // it can be changed in Settings without re-enrolling.
        return store.profiles.compactMap { profile -> EnrollmentClip? in
            guard profile.kind == .you else { return nil }
            guard let clip = store.loadClipSamples(for: profile) else { return nil }
            return EnrollmentClip(
                name: micDisplayName,
                side: .mic,
                samples: clip.samples,
                sampleRate: clip.sampleRate
            )
        }
    }

    /// Begin computing any missing profile embeddings while the meeting is in
    /// progress. Cached embeddings are immediately available; only first-use clips
    /// incur diarization work, and that work is shared with offline model preloading.
    private func prepareSpeakerCandidatesForCurrentSession() {
        speakerCandidatePreparationTask?.cancel()
        preparedSpeakerCandidates = cachedSpeakerCandidates()
        speakerCandidatePreparationTask = Task { [weak self] in
            guard let self else { return }
            let candidates = await self.buildSpeakerCandidates()
            guard !Task.isCancelled else { return }
            self.preparedSpeakerCandidates = candidates
        }
    }

    /// Resolve candidates for the current stop. This normally returns immediately
    /// because preparation began at session start. App quit is deliberately bounded:
    /// use the snapshot already prepared and cancel any first-use embedding work.
    private func speakerCandidatesForStop(isAppQuit: Bool) async -> [SpeakerIdentityMatcher.Candidate] {
        if isAppQuit {
            speakerCandidatePreparationTask?.cancel()
            return preparedSpeakerCandidates
        }
        await speakerCandidatePreparationTask?.value
        return preparedSpeakerCandidates
    }

    private func cachedSpeakerCandidates() -> [SpeakerIdentityMatcher.Candidate] {
        guard let store = voiceProfileStore else { return [] }
        return store.otherProfiles.compactMap { profile in
            guard let embedding = store.embedding(for: profile) else { return nil }
            return .init(profileID: profile.id, name: profile.name, embedding: embedding)
        }
    }

    /// Warm the offline model bundle at launch. Failure is logged and retried later
    /// under the identifier's shared cooldown; it must never block normal recording.
    func prepareOfflineIdentityModels() async {
        do {
            try await offlineIdentifier.prepareModels()
        } catch {
            NSLog("[SerialNotes/Speakers] offline model preload failed: %@", error.localizedDescription)
        }
    }

    /// Build identity-match candidates from saved `.other` voice profiles, computing
    /// (and caching) each one's speaker embedding from its enrollment clip on first use.
    /// The embedding work runs off the main actor via the offline identifier.
    private func buildSpeakerCandidates() async -> [SpeakerIdentityMatcher.Candidate] {
        guard let store = voiceProfileStore else { return [] }
        let others = store.otherProfiles
        guard !others.isEmpty else { return [] }

        var candidates: [SpeakerIdentityMatcher.Candidate] = []
        for profile in others {
            let embedding: [Float]
            if let cached = store.embedding(for: profile) {
                embedding = cached
            } else {
                do {
                    guard let computed = try await offlineIdentifier.enrollmentEmbedding(forClipAt: store.clipURL(for: profile)) else {
                        NSLog("[SerialNotes/Speakers] no usable enrollment speech for %@", profile.name)
                        continue
                    }
                    store.saveEmbedding(computed, for: profile)
                    embedding = computed
                } catch {
                    NSLog("[SerialNotes/Speakers] failed to build enrollment embedding for %@: %@",
                          profile.name, error.localizedDescription)
                    continue
                }
            }
            candidates.append(.init(profileID: profile.id, name: profile.name, embedding: embedding))
        }
        return candidates
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
    let exportTargets: Set<ExportTarget>
    let meetingDiagnostics: MeetingSessionDiagnostics?
}
