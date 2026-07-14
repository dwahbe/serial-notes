import Foundation
import os

@MainActor @Observable
final class RecordingState {
    var isRecording = false
    /// True from `start()` entry until phase 1 completes (capture running) or
    /// fails — the window before `isRecording` flips. Observable so the record
    /// button can show immediate feedback, and folded into
    /// `isRecordingSessionActive` so the meeting detector stays quiet and the
    /// quit gate holds across the whole start window.
    private(set) var isStarting = false
    /// True while a recording is capturing but its transcription session hasn't
    /// attached yet (the previous meeting's finalization still owns the actor).
    /// Audio is fully captured — WAVs write from the first buffer — and notes
    /// are already bound; only the live transcript lags. No UI reads this today:
    /// it stays observable as the lifecycle tests' attach barrier.
    private(set) var isAwaitingTranscription = false
    /// True from a stop press until the *last* queued finalization completes.
    /// Finalizations are strictly serialized, so a single flag suffices even
    /// when a stopped session is still finalizing while its successor records.
    private(set) var isFinalizing = false
    /// Current milestone of the post-meeting pipeline while `isFinalizing`,
    /// driving the popover's processing card. Owned by whichever finalization is
    /// currently *executing* (`displayedFinalizationGeneration`), so a queued
    /// successor can't stomp the running one's progress. `nil` outside finalization.
    private(set) var finalizationPhase: FinalizationPhase?
    /// How many finalizations the current back-to-back batch holds, and how many
    /// have completed — drives the processing card's "meeting X of N". A batch
    /// starts at the first stop after idle and grows with each stop while any
    /// finalization is still queued; both reset when the last one finishes.
    private(set) var finalizationBatchSize = 0
    private(set) var finalizationBatchCompleted = 0
    var elapsedTime: TimeInterval = 0
    var errorMessage: String?

    @ObservationIgnored var onRecordingChange: (@MainActor () -> Void)?
    /// Fired after a recording finalizes when it detected ≥1 unrecognized system
    /// speaker, so the app can offer to name them. Carries the session directory and
    /// the pending-speaker count. Suppressed on `.appQuit`, and deferred while a
    /// newer recording is active (a banner mid-meeting is disruptive).
    @ObservationIgnored var onUnnamedSpeakers: (@MainActor (URL, Int) -> Void)?
    @ObservationIgnored weak var voiceProfileStore: VoiceProfileStore?

    /// Shared offline speaker identifier — owns the post-meeting re-diarization +
    /// embedding models (downloaded once, reused across meetings).
    @ObservationIgnored private let offlineIdentifier = OfflineSpeakerIdentifier()
    @ObservationIgnored weak var summarySettings: SummarySettings?
    @ObservationIgnored weak var storageSettings: StorageSettings?
    @ObservationIgnored weak var identitySettings: IdentitySettings?
    @ObservationIgnored weak var exportSettings: ExportSettings?
    @ObservationIgnored weak var manualNotesSettings: ManualNotesSettings?
    @ObservationIgnored weak var manualNotesStore: ManualNotesStore?
    @ObservationIgnored weak var manualNotesWindowController: ManualNotesWindowController?

    private var timer: Timer?
    /// The recording currently capturing (or awaiting attach). Cleared at the
    /// stop press — from then on the session lives inside its finalization task.
    @ObservationIgnored private var activeSession: RecordingSession?
    /// Stops capture + snapshots stats for the most recent stop. `start()`
    /// awaits it before `startCapture`: the capture service is single-instance,
    /// so a successor may not start until the predecessor's teardown completed
    /// (and the predecessor's stats are safely snapshotted).
    @ObservationIgnored private var captureTeardownTask: Task<Void, Never>?
    /// The most recently queued finalization. Finalizations are serialized —
    /// each new session's attach awaits its predecessor's finalization — so one
    /// handle suffices; the generation counter tells an epilogue whether it is
    /// still the last one and may clear the shared flags.
    @ObservationIgnored private var finalizationTask: Task<Void, Never>?
    @ObservationIgnored private var finalizationGeneration = 0
    /// Which finalization currently owns `finalizationPhase` (see that doc).
    @ObservationIgnored private var displayedFinalizationGeneration: Int?
    /// Post-meeting side effects (speaker-naming prompt, notes-app exports)
    /// queued because a newer recording was active when their meeting finished.
    /// Flushed by the finalization epilogue once no session is active.
    @ObservationIgnored private var deferredPostMeetingActions: [@MainActor () -> Void] = []
    /// One-way flag set when app quit begins draining: an in-flight `start()`
    /// checks it after its awaits and abandons the new session instead of
    /// racing termination.
    @ObservationIgnored private var quitRequested = false
    /// Waiters parked by in-flight finalizations racing their attach wait
    /// against a future quit (see `awaitAttachOrQuitBegins`); fired and cleared
    /// the moment quit begins draining, so a finalization created by a NON-quit
    /// stop still switches to the bounded quit-attach path instead of hanging
    /// termination behind an uncancellable model download.
    @ObservationIgnored private var quitBeganWaiters: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var pendingMeetingDiagnostics: MeetingSessionDiagnostics?
    /// Candidate embeddings are prepared during the recording, rather than serially
    /// after Stop. Finalization only waits here when a very short session ends before
    /// the preparation task can finish.
    @ObservationIgnored private var speakerCandidatePreparationTask: Task<Void, Never>?
    @ObservationIgnored private var preparedSpeakerCandidates: [SpeakerIdentityMatcher.Candidate] = []
    private static let appQuitOfflineIdentityTimeout: Duration = .seconds(6)
    /// Default quit-time bound on a session's own attach work (model download +
    /// startSession) — NOT on the predecessor-finalization wait, which stays
    /// unbounded by design. Past this, the session finalizes unattached.
    static let defaultAppQuitAttachTimeout: Duration = .seconds(5)
    /// How long a stop will wait for an in-flight `start()` before proceeding —
    /// the start may be suspended behind an interactive permission prompt.
    private static let startWaitLimitOnStop: Duration = .seconds(30)
    /// Bound on draining a stopped session's buffered feed into the streaming
    /// pipeline. Past it the remainder is abandoned and reported as partial
    /// coverage — the second-pass ASR regenerates the text from the WAVs.
    private static let feedDrainTimeout: Duration = .seconds(15)

    @ObservationIgnored private let captureService: any AudioCapturing
    /// The seam every session-lifecycle call goes through (lifecycle tests
    /// inject a fake here).
    @ObservationIgnored private let transcription: any TranscriptionSessionManaging
    /// The concrete production actor — the app shell wires `ModelDownloadState`
    /// to it. Identical to `transcription` in production.
    let transcriptionService: TranscriptionService
    @ObservationIgnored private let appQuitAttachTimeout: Duration

    init(
        captureService: any AudioCapturing = AudioCaptureService(),
        transcription: (any TranscriptionSessionManaging)? = nil,
        quitAttachTimeout: Duration = RecordingState.defaultAppQuitAttachTimeout
    ) {
        let concrete = TranscriptionService()
        self.transcriptionService = concrete
        self.transcription = transcription ?? concrete
        self.captureService = captureService
        self.appQuitAttachTimeout = quitAttachTimeout
    }

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
    /// suppression on this, and app quit gates on it (all phases have work that
    /// must drain before termination).
    var isRecordingSessionActive: Bool {
        isStarting || isRecording || isFinalizing
    }

    // MARK: - Start

    func start(storageDirectory: URL) async {
        guard !isStarting else { return }
        // Mark the start in flight before any await. Notifying now lets the
        // meeting detector clear any "meeting detected" prompt the instant the
        // user hits Record and stay quiet for the whole start window.
        isStarting = true
        onRecordingChange?()

        // A still-capturing session stops at this press — synchronously, so its
        // audio ends here. Its finalization proceeds concurrently with the new
        // session's capture; we deliberately do NOT wait for it. If the user had
        // the notepad open for it, remember that: the stop dismisses the panel,
        // and the new session should bring it right back.
        let notepadWasVisible = manualNotesWindowController?.isNotepadVisible ?? false
        if let current = activeSession, !current.isStopRequested {
            requestStop(reason: .manual)
        }

        do {
            // Serialize behind the predecessor's capture teardown: the capture
            // service is single-instance, and its stats snapshot must complete
            // before a new capture resets them. This await is bounded (stop +
            // stats + finishing the feed) — never the predecessor's finalization.
            await captureTeardownTask?.value

            let sessionDir = try Self.makeSessionDirectory(in: storageDirectory)
            let pipeline = AudioFeedPipeline()
            let session = RecordingSession(directory: sessionDir, startDate: Date(), pipeline: pipeline)
            let sessionID = session.id

            // Buffer callbacks feed the session's own pipeline; the error
            // callback carries the session id so a straggler from a torn-down
            // capture can't surface into a successor's UI (see AudioCaptureCallbacks).
            let callbacks = AudioCaptureCallbacks(
                onSystemAudioBuffer: { pipeline.yield($0, side: .system) },
                onMicAudioBuffer: { pipeline.yield($0, side: .mic) },
                onError: { [weak self] error in
                    Task { @MainActor in
                        self?.handleCaptureError(error, sessionID: sessionID)
                    }
                }
            )
            try await captureService.startCapture(sessionDir: sessionDir, callbacks: callbacks)

            // startCapture can suspend for a long time (TCC permission prompt);
            // if quit began in the meantime, abandon the new session rather
            // than racing termination with a fresh recording.
            if quitRequested {
                NSLog("[SerialNotes/RecordingState] quit requested during start — abandoning the new session")
                pipeline.abandon()
                await captureService.stopCapture()
                // Capture ran for at most an instant — remove the just-created
                // session dir rather than leaving header-only WAVs with no
                // diagnostics in the user's storage folder.
                try? FileManager.default.removeItem(at: sessionDir)
                isStarting = false
                onRecordingChange?()
                return
            }

            activeSession = session
            isRecording = true
            isAwaitingTranscription = true
            errorMessage = nil
            elapsedTime = 0
            startTimer(from: session.startDate)
            onRecordingChange?()

            // Notes bind at capture start, not at attach: the store's active
            // draft is decoupled from any predecessor's still-pending splice
            // (see ManualNotesSnapshot), so note-taking is available the moment
            // the recording is.
            if let manualNotesStore {
                manualNotesStore.beginSession(sessionDir: session.directory)
                session.notesAttached = true
                // The global ⌃⌘N toggle lives exactly as long as the notepad's
                // session binding — outside it the combo passes through to
                // whatever app is frontmost.
                manualNotesWindowController?.activateGlobalShortcut()
                if manualNotesSettings?.openNotepadWhenRecordingStarts == true || notepadWasVisible {
                    manualNotesWindowController?.present()
                }
            }

            // Phase 2: attach transcription once the previous finalization (if
            // any) releases the actor. Capture the predecessor's task NOW —
            // reading `finalizationTask` later could see this session's own
            // finalization (stop-before-attach) and deadlock against it.
            session.predecessorFinalization = finalizationTask
            session.attachTask = Task { [weak self] in
                await session.predecessorFinalization?.value
                await self?.attachTranscription(to: session)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isStarting = false
        onRecordingChange?()
        // A finalization that completed while this start was in flight skipped
        // its flush (isStarting held the guard); if the start failed there may
        // be no later finalization to retry it — drain the queue now. No-op
        // when a session is active or the queue is empty.
        flushDeferredPostMeetingActionsIfIdle()
    }

    /// Phase 2 of `start()`: bind the transcription actor, the manual-notes
    /// store, and speaker-candidate prep to the session. Runs after the previous
    /// finalization completed, so the actor and the notes store are free.
    private func attachTranscription(to session: RecordingSession) async {
        do {
            // Idempotent — if models are already loaded this returns immediately.
            try await transcription.downloadModelsIfNeeded()

            let sessionID = session.id
            await transcription.setCallbacks(
                onError: { [weak self] error in
                    Task { @MainActor in
                        self?.handleTranscriptionError(error, sessionID: sessionID)
                    }
                }
            )

            // The preferred name (or "You" when unset) labels the user's mic
            // voice everywhere: the streaming default label, the `.you` diarizer
            // enrollment, and the final-render collapse target.
            let micDisplayName = identitySettings?.micDisplayName ?? "You"
            let enrollments = loadEnrollments(micDisplayName: micDisplayName)
            let summarySnapshot = summarySettings?.snapshot() ?? .disabled
            try await transcription.startSession(
                sessionDirectory: session.directory,
                // The capture start, NOT "now": entry timestamps count samples
                // from the first buffer, and header date/duration/summary-cutoff
                // math must share that origin.
                sessionStart: session.startDate,
                enrollments: enrollments,
                summarySettings: summarySnapshot,
                micPrimaryName: micDisplayName
            )
            session.attached = true

            let transcriber = transcription
            session.pipeline.attach { side, captured in
                switch side {
                case .mic: await transcriber.processMicAudio(captured)
                case .system: await transcriber.processSystemAudio(captured)
                }
            }

            // Candidate prep serves this session's own finalization (which
            // awaits this attach task), so it runs even when the session was
            // stopped while waiting to attach — cached embeddings make it cheap.
            prepareSpeakerCandidatesForCurrentSession()
        } catch {
            // No transcription for this session. Keep the WAVs (capture keeps
            // writing them independently), surface the failure, and stop the
            // recording — its finalization takes the unattached branch.
            session.pipeline.abandon()
            NSLog("[SerialNotes/RecordingState] transcription attach failed: %@", error.localizedDescription)
            if activeSession?.id == session.id {
                errorMessage = "Transcription couldn't start — audio is being saved to “\(session.directory.lastPathComponent)”."
            }
            if !session.isStopRequested {
                requestStop(reason: .manual)
            }
        }
        if activeSession?.id == session.id {
            isAwaitingTranscription = false
        }
    }

    // MARK: - Stop

    func stop(reason: RecordingStopReason = .manual) {
        requestStop(reason: reason)
    }

    func stopAndWait(reason: RecordingStopReason = .manual) async {
        if reason.isAppQuit {
            beginQuitDrain()
        }
        // A start may be mid-flight (quit gates on isStarting too). Wait it out
        // so the session it produces gets stopped and drained rather than
        // orphaned by an early return — but bounded: the start may be suspended
        // behind an interactive permission prompt, and an unanswered prompt
        // must not block quit forever (proceeding matches the old behavior of
        // terminating past an in-flight start, as the worst-case fallback).
        var waited: Duration = .zero
        while isStarting, waited < Self.startWaitLimitOnStop {
            try? await Task.sleep(for: .milliseconds(50))
            waited += .milliseconds(50)
        }
        if isStarting {
            NSLog("[SerialNotes/RecordingState] proceeding with stop while a start is still blocked (permission prompt?)")
        }
        // If nothing is actively capturing, an in-flight finalization keeps its
        // original reason — quit racing an already-fired auto-stop must wait for
        // the save, not relabel it.
        if let session = activeSession, !session.isStopRequested {
            requestStop(reason: reason)
        }
        await finalizationTask?.value
    }

    private func beginQuitDrain() {
        quitRequested = true
        let waiters = quitBeganWaiters
        quitBeganWaiters = [:]
        for waiter in waiters.values { waiter() }
    }

    /// Await the session's attach, returning early (false) when app quit begins
    /// first — the caller then applies the bounded quit-attach path. First
    /// resume wins; the attach-side task removes its quit waiter so waiters
    /// can't accumulate across meetings.
    private func awaitAttachOrQuitBegins(_ attach: Task<Void, Never>) async -> Bool {
        if quitRequested { return false }
        let latch = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let waiterID = UUID()
            quitBeganWaiters[waiterID] = {
                if !latch.withLock({ let was = $0; $0 = true; return was }) {
                    continuation.resume(returning: false)
                }
            }
            Task { [weak self] in
                await attach.value
                if !latch.withLock({ let was = $0; $0 = true; return was }) {
                    self?.quitBeganWaiters[waiterID] = nil
                    continuation.resume(returning: true)
                }
            }
        }
    }

    /// The synchronous stop front-half. Runs entirely without suspension up to
    /// (and including) the teardown/finalization task assignments, so the quit
    /// gate and re-entry guards can never observe a half-stopped state. Capture
    /// stops immediately — the recording ends at this press even when the
    /// transcription session hasn't attached yet.
    private func requestStop(reason: RecordingStopReason) {
        guard let session = activeSession, !session.isStopRequested else { return }

        let stopDate = Date()
        session.markStopped(at: stopDate)
        activeSession = nil
        isRecording = false
        isAwaitingTranscription = false
        timer?.invalidate()
        timer = nil
        // Mark finalizing *before* notifying, so the detector (a) keeps its
        // start monitor paused and (b) ends call-end monitoring now — which
        // synchronously flushes its diagnostics into pendingMeetingDiagnostics,
        // read just below. Seed the phase only when no earlier finalization is
        // executing (the card belongs to the one doing the work; this
        // finalization claims it when its own work begins).
        isFinalizing = true
        if finalizationBatchSize == 0 {
            finalizationBatchCompleted = 0
        }
        finalizationBatchSize += 1
        if displayedFinalizationGeneration == nil {
            finalizationPhase = .finishingTranscript
        }
        onRecordingChange?()

        let summarySnapshot = summarySettings?.snapshot() ?? .disabled
        let keepAudioFiles = storageSettings?.saveAudioFiles ?? true
        // Freeze the enabled export targets at stop time so a mid-finalization
        // toggle can't change what gets pushed.
        let exportTargets = exportSettings?.activeTargets ?? []
        var diagnostics = pendingMeetingDiagnostics
        diagnostics?.stopReason = reason.diagnosticsValue
        pendingMeetingDiagnostics = nil

        // The snapshot token travels with THIS session's finalization; the
        // store's active-draft slot is free again for the next recording.
        let notesSnapshot: ManualNotesSnapshot?
        if session.notesAttached {
            notesSnapshot = manualNotesStore?.snapshotAndEndSession()
            manualNotesWindowController?.deactivateGlobalShortcut()
            manualNotesWindowController?.dismiss()
        } else {
            notesSnapshot = nil
        }

        let context = StopContext(
            stopReason: reason,
            stopDate: stopDate,
            summarySettings: summarySnapshot,
            keepAudioFiles: keepAudioFiles,
            summaryCutoff: Self.summaryCutoff(for: reason, sessionStart: session.startDate),
            notesSnapshot: notesSnapshot,
            exportTargets: exportTargets,
            meetingDiagnostics: diagnostics
        )

        // Capture ends now. On quit the buffered feed is abandoned outright —
        // draining it at inference speed would hold termination hostage; the
        // second-pass ASR covers the WAVs. Teardowns chain behind their
        // predecessor (like finalizations) so two stopCapture calls can never
        // overlap each other or a successor's startCapture.
        let isQuit = reason.isAppQuit
        let capture = captureService
        let previousTeardown = captureTeardownTask
        let teardown = Task {
            await previousTeardown?.value
            await capture.stopCapture()
            session.captureStats = capture.currentStats()
            if isQuit {
                session.pipeline.abandon()
            } else {
                session.pipeline.finishFeed()
            }
        }
        captureTeardownTask = teardown

        finalizationGeneration += 1
        let generation = finalizationGeneration
        let quitAttachTimeout = appQuitAttachTimeout
        let task = Task { [weak self] in
            await teardown.value
            guard let self else { return }
            // The attach task ends by either marking the session attached or
            // abandoning its pipeline — and it internally awaits the previous
            // finalization, which serializes all endSession calls. Normal stops
            // wait for it unbounded, but RACING a quit that begins mid-wait:
            // whichever stop reason created this task, termination must never
            // hang behind an attach parked in an uncancellable model download.
            // The quit-drain path first waits out the predecessor (unbounded by
            // design — quitting mid-finalization always drained the save), then
            // bounds only this session's OWN attach work. No log here on
            // timeout: the attach can still complete during the drain below, and
            // the unattached branch speaks for itself when actually taken.
            var quitDraining = isQuit
            if !quitDraining, let attach = session.attachTask {
                quitDraining = !(await self.awaitAttachOrQuitBegins(attach))
            }
            if quitDraining {
                await session.predecessorFinalization?.value
                if let attach = session.attachTask {
                    let attached = await awaitOrTimeout(quitAttachTimeout) { await attach.value }
                    if !attached {
                        session.pipeline.abandon()
                    }
                }
            }
            let coverage = await session.pipeline.drain(timeout: Self.feedDrainTimeout)
            // This finalization now owns the processing card. Reset the phase
            // unconditionally: a superseded predecessor's epilogue deliberately
            // leaves its last phase behind (generation guard), and showing that
            // stale value for this session would be wrong.
            self.displayedFinalizationGeneration = generation
            self.finalizationPhase = .finishingTranscript
            if session.attached {
                await self.finishStop(session: session, context: context, coverage: coverage, generation: generation)
            } else {
                await self.finalizeUnattachedSession(session: session, context: context)
            }
            self.finalizationBatchCompleted += 1
            self.completeFinalization(generation: generation, isAppQuit: isQuit)
        }
        finalizationTask = task
    }

    private func finishStop(
        session: RecordingSession,
        context: StopContext,
        coverage: [AudioSide: StreamingCoverage],
        generation: Int
    ) async {
        // Candidate embeddings normally finish during recording. Both stop paths
        // await any remaining work before the identity pass. Quit uses only the
        // already-prepared snapshot so a first-use enrollment embedding cannot block
        // termination behind an uncancellable offline diarization.
        let isAppQuit = context.stopReason.isAppQuit
        let candidates = await speakerCandidatesForStop(isAppQuit: isAppQuit)
        let finalization = await transcription.endSession(
            summarySettings: context.summarySettings,
            keepAudioFiles: context.keepAudioFiles,
            // The stop press, not "now" — finalization may run while a successor
            // records, and the transcript duration must not absorb that time.
            sessionEnd: context.stopDate,
            summaryCutoff: context.summaryCutoff,
            streamingCoverage: coverage,
            manualNotesMarkdown: context.notesSnapshot?.text,
            // App quit still applies known identities when models/candidates are
            // available, but continues to skip clip extraction and naming UI.
            extractSpeakers: !isAppQuit,
            performOfflineIdentity: true,
            speakerCandidates: candidates,
            offlineIdentifier: offlineIdentifier,
            offlineIdentityTimeout: isAppQuit ? Self.appQuitOfflineIdentityTimeout : nil,
            requirePreparedOfflineModels: isAppQuit,
            onPhase: { [weak self] phase in
                Task { @MainActor in
                    guard let self, self.displayedFinalizationGeneration == generation else { return }
                    self.finalizationPhase = phase
                }
            }
        )
        if let snapshot = context.notesSnapshot, let manualNotesStore {
            let failureMessage = await manualNotesStore.completeSnapshotWrite(
                snapshot, succeeded: finalization.manualNotesCommitted
            )
            surfaceNotesFailure(failureMessage, isAppQuit: isAppQuit)
        }
        finalizeSession(session: session, context: context)
        runOrDeferPostMeetingActions(session: session, context: context, pendingSpeakerCount: finalization.pendingSpeakerCount)
        speakerCandidatePreparationTask?.cancel()
        speakerCandidatePreparationTask = nil
        preparedSpeakerCandidates = []
    }

    /// Finalization for a session whose transcription never attached (attach
    /// threw, or quit gave up waiting). There is no actor session to end; keep
    /// the WAVs — regardless of the keep-audio setting, they're the only record
    /// of the meeting — and write diagnostics so the session dir explains itself.
    private func finalizeUnattachedSession(session: RecordingSession, context: StopContext) async {
        // The splice never ran, so any typed notes must get the full recovery
        // treatment (sidecar re-verified, launch pointer, surfaced failure) —
        // without this they'd survive only as an unreferenced hidden sidecar.
        if let snapshot = context.notesSnapshot, let manualNotesStore {
            let failureMessage = await manualNotesStore.completeSnapshotWrite(snapshot, succeeded: false)
            surfaceNotesFailure(failureMessage, isAppQuit: context.stopReason.isAppQuit)
        }
        finalizeSession(session: session, context: context)
        NSLog("[SerialNotes/RecordingState] session finalized without transcription — audio kept at %@",
              session.directory.path)
    }

    /// Surface a notes-splice failure in the right place: re-present the notepad
    /// when it's free (the store re-activated the failed draft into it), defer
    /// an attributed message otherwise (a successor's live notepad must not show
    /// a predecessor's failure), and stay silent at quit — the recovery pointer
    /// restores the notes at next launch.
    private func surfaceNotesFailure(_ message: String?, isAppQuit: Bool) {
        guard let message, !isAppQuit else { return }
        if activeSession == nil {
            manualNotesWindowController?.present()
        } else {
            presentOrDeferPostMeetingMessage(message)
        }
    }

    /// Shared post-`endSession` epilogue: clears the finalization flags iff this
    /// generation is still the newest, then flushes any deferred side effects —
    /// except at quit, where the queue is dropped: a naming banner or notes-app
    /// export firing into a terminating app is exactly what the quit path
    /// suppresses everywhere else (exports were always quit-skipped).
    private func completeFinalization(generation: Int, isAppQuit: Bool) {
        guard finalizationGeneration == generation else { return }
        finalizationTask = nil
        captureTeardownTask = nil
        isFinalizing = false
        finalizationPhase = nil
        displayedFinalizationGeneration = nil
        finalizationBatchSize = 0
        finalizationBatchCompleted = 0
        // Session fully clear — notify so the detector re-baselines and resumes
        // its start monitor (unless a successor recording keeps it paused).
        onRecordingChange?()
        // `quitRequested` covers the case where quit drains an already-running
        // finalization whose own reason isn't .appQuit.
        if isAppQuit || quitRequested {
            if !deferredPostMeetingActions.isEmpty {
                NSLog("[SerialNotes/RecordingState] dropping %d deferred post-meeting action(s) at quit",
                      deferredPostMeetingActions.count)
                deferredPostMeetingActions = []
            }
        } else {
            flushDeferredPostMeetingActionsIfIdle()
        }
    }

    // MARK: - Post-meeting side effects

    /// The speaker-naming prompt and notes-app exports are disruptive while a
    /// successor meeting records (the Bear export activates Bear; the banner
    /// floats over the call), so they queue until no session is active.
    private func runOrDeferPostMeetingActions(
        session: RecordingSession,
        context: StopContext,
        pendingSpeakerCount: Int
    ) {
        var actions: [@MainActor () -> Void] = []
        if pendingSpeakerCount > 0, !context.stopReason.isAppQuit {
            let directory = session.directory
            actions.append { [weak self] in
                self?.onUnnamedSpeakers?(directory, pendingSpeakerCount)
            }
        }
        if !context.exportTargets.isEmpty, !context.stopReason.isAppQuit {
            let transcriptURL = session.directory.appendingPathComponent("transcript.md")
            let targets = context.exportTargets
            actions.append {
                // Fire-and-forget so it can't delay anything — the first Apple
                // Notes send blocks on a TCC prompt. The on-disk transcript is
                // the source of truth either way.
                Task.detached(priority: .utility) {
                    await MeetingExporter.export(targets: targets, transcriptURL: transcriptURL)
                }
            }
        }
        guard !actions.isEmpty else { return }

        // Once quit begins draining, no post-meeting UI or export may fire at
        // all — not even from a predecessor finalizing with a non-quit reason
        // (its successor was already quit-stopped, so `activeSession` is nil
        // and the immediate branch would otherwise run these mid-termination).
        if quitRequested {
            NSLog("[SerialNotes/RecordingState] dropping %d post-meeting action(s): app is quitting", actions.count)
            return
        }

        // Also defer when the queue is non-empty: running these immediately
        // would jump ahead of an earlier meeting's queued actions, and the
        // older meeting's naming banner would then replace this one's when the
        // queue flushes. Enqueue-and-flush keeps strict FIFO.
        if activeSession == nil, !isStarting, deferredPostMeetingActions.isEmpty {
            for action in actions { action() }
        } else {
            NSLog("[SerialNotes/RecordingState] deferring %d post-meeting action(s) until the current recording ends", actions.count)
            deferredPostMeetingActions.append(contentsOf: actions)
        }
    }

    private func flushDeferredPostMeetingActionsIfIdle() {
        guard activeSession == nil, !isStarting, !deferredPostMeetingActions.isEmpty else { return }
        let actions = deferredPostMeetingActions
        deferredPostMeetingActions = []
        for action in actions { action() }
    }

    /// Surface a message about a *finished* meeting: immediately when nothing
    /// newer is active, otherwise deferred with the other post-meeting actions —
    /// it must neither masquerade as the live recording's failure nor be
    /// silently dropped (it may be the only signal of a permission problem).
    private func presentOrDeferPostMeetingMessage(_ message: String) {
        if quitRequested {
            NSLog("[SerialNotes/RecordingState] %@", message)
            return
        }
        if activeSession == nil, !isStarting, deferredPostMeetingActions.isEmpty {
            errorMessage = message
        } else {
            deferredPostMeetingActions.append { [weak self] in
                self?.errorMessage = message
            }
        }
    }

    // MARK: - Error routing

    /// Capture errors are session-scoped: a straggler from a torn-down capture
    /// must not surface into (or stop) a successor's recording.
    private func handleCaptureError(_ error: Error, sessionID: UUID) {
        guard let session = activeSession, session.id == sessionID else {
            NSLog("[SerialNotes/RecordingState] stale capture error ignored: %@", error.localizedDescription)
            return
        }
        // Capture is dead — end the session through the normal stop path: the
        // teardown stays tracked (so a restart serializes behind it instead of
        // racing a stray stopCapture), the timer and flags clear instead of
        // showing a zombie "recording", and whatever audio made it to disk gets
        // finalized rather than sitting in limbo until a manual stop.
        errorMessage = error.localizedDescription
        requestStop(reason: .captureFailed)
    }

    /// Transcription errors surface only when they belong to the session the
    /// user is looking at: the active recording, or — when nothing records — the
    /// meeting currently finalizing. A predecessor's late error while a new
    /// meeting records is logged, not shown as the new meeting's failure.
    private func handleTranscriptionError(_ error: Error, sessionID: UUID) {
        if let active = activeSession, active.id != sessionID {
            NSLog("[SerialNotes/RecordingState] transcription error from previous session suppressed: %@",
                  error.localizedDescription)
            return
        }
        errorMessage = TranscriptionError.userFacingDescription(for: error)
    }

    // MARK: - Session bookkeeping

    private func startTimer(from startDate: Date) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsedTime = Date().timeIntervalSince(startDate)
            }
        }
    }

    private func finalizeSession(session: RecordingSession, context: StopContext) {
        let stats = session.captureStats ?? AudioCaptureStats()

        writeSessionJSON(session: session, stats: stats, context: context)
        writeMeetingAudioDiagnosticsIfNeeded(sessionDir: session.directory, diagnostics: context.meetingDiagnostics)

        // Only warn when zero buffers arrived for a recording long enough that
        // we'd have expected the tap to fire (~12 buffers/sec). Short test
        // recordings or genuinely silent system output (e.g. a Zoom call with
        // no other participants) can legitimately produce zero buffers and
        // shouldn't trigger a permission alarm.
        let duration = context.stopDate.timeIntervalSince(session.startDate)
        let zeroBufferThreshold: TimeInterval = 15
        if stats.path == .processTap,
           stats.system.bufferCount == 0,
           duration >= zeroBufferThreshold {
            // Likely a permission problem that will hit every later meeting.
            // Deferred (not dropped) when a successor is recording — and
            // attributed to its meeting, because by the time it surfaces a
            // different, possibly healthy meeting may have just ended and an
            // unattributed permission alarm would read as a false one.
            let meetingTime = Self.meetingTimeFormatter.string(from: session.startDate)
            presentOrDeferPostMeetingMessage(
                "System audio wasn't captured in your \(meetingTime) meeting. If other participants were speaking, check System Settings → Privacy & Security → System Audio Recording Only."
            )
        }
    }

    private static let meetingTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private func writeSessionJSON(
        session: RecordingSession,
        stats: AudioCaptureStats,
        context: StopContext
    ) {
        let payload = SessionDiagnostics(
            startedAt: session.startDate,
            // The stop press — finalization may complete much later.
            endedAt: context.stopDate,
            stopReason: context.stopReason.diagnosticsValue,
            summaryCutoffSeconds: context.summaryCutoff,
            capturePath: stats.path?.rawValue ?? "unknown",
            inferenceComputeUnits: ModelComputePolicy.diagnosticsLabel,
            mic: stats.mic,
            system: stats.system,
            enrolledProfiles: voiceProfileStore?.profiles.map { $0.name } ?? [],
            meeting: context.meetingDiagnostics
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = session.directory.appendingPathComponent("session.json")
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

    /// Timestamped session dir, made collision-proof with a numeric suffix —
    /// the base name has one-second precision, and `createDirectory` would
    /// silently merge two sessions that collide.
    private static func makeSessionDirectory(in storageDirectory: URL) throws -> URL {
        let base = sessionDirectoryName()
        var url = storageDirectory.appendingPathComponent(base)
        var attempt = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = storageDirectory.appendingPathComponent("\(base) (\(attempt))")
            attempt += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func sessionDirectoryName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    private static func summaryCutoff(
        for reason: RecordingStopReason,
        sessionStart: Date
    ) -> TimeInterval? {
        guard let cutoffDate = reason.summaryCutoffDate else {
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
    /// Which compute units the CoreML models loaded with (ModelComputePolicy)
    /// — lets a future GPU-fault storm be correlated post-hoc.
    let inferenceComputeUnits: String
    let mic: AudioStreamStats
    let system: AudioStreamStats
    let enrolledProfiles: [String]
    let meeting: MeetingSessionDiagnostics?
}

/// The finalization inputs frozen at the stop press. The session itself (dir,
/// dates, pipeline, stats) travels alongside as a `RecordingSession`.
private struct StopContext: Sendable {
    let stopReason: RecordingStopReason
    let stopDate: Date
    let summarySettings: SummarySettings.Snapshot
    let keepAudioFiles: Bool
    let summaryCutoff: TimeInterval?
    let notesSnapshot: ManualNotesSnapshot?
    let exportTargets: Set<ExportTarget>
    let meetingDiagnostics: MeetingSessionDiagnostics?
}
