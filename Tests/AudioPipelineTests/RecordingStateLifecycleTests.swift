import Foundation
import Testing
import os

@testable import SerialNotes

// MARK: - Test doubles
// (AsyncPermitGate + waitUntil live in TestSupport.swift — shared with the
// pipeline suite.)

private struct TestCaptureError: Error {}

/// Scriptable transcription seam: records every lifecycle call in order,
/// optionally holding `downloadModelsIfNeeded` / `endSession` open on gates.
/// `overlapViolations` counts any second `startSession` before the previous
/// session ended — the core "one actor session at a time" invariant.
private actor FakeTranscription: TranscriptionSessionManaging {
    enum Event: Equatable, Sendable {
        case download
        case startSession(URL)
        case endSession(URL?)
    }

    private(set) var events: [Event] = []
    private(set) var endSessionEnds: [Date?] = []
    private(set) var overlapViolations = 0
    private var currentDir: URL?
    private var pendingSpeakersPerEnd: [Int]
    private let downloadGate: AsyncPermitGate?
    private let downloadError: Error?
    private let endSessionGate: AsyncPermitGate?

    init(
        downloadGate: AsyncPermitGate? = nil,
        downloadError: Error? = nil,
        endSessionGate: AsyncPermitGate? = nil,
        pendingSpeakersPerEnd: [Int] = []
    ) {
        self.downloadGate = downloadGate
        self.downloadError = downloadError
        self.endSessionGate = endSessionGate
        self.pendingSpeakersPerEnd = pendingSpeakersPerEnd
    }

    var startedSessionDirectories: [URL] {
        events.compactMap {
            if case .startSession(let dir) = $0 { dir } else { nil }
        }
    }

    var endSessionCount: Int {
        events.count { if case .endSession = $0 { true } else { false } }
    }

    func downloadModelsIfNeeded() async throws {
        events.append(.download)
        if let downloadGate { await downloadGate.wait() }
        if let downloadError { throw downloadError }
    }

    func setCallbacks(onError: (@Sendable (Error) -> Void)?) {}

    func startSession(
        sessionDirectory: URL,
        sessionStart: Date,
        enrollments: [EnrollmentClip],
        summarySettings: SummarySettings.Snapshot,
        micPrimaryName: String
    ) async throws {
        if currentDir != nil { overlapViolations += 1 }
        currentDir = sessionDirectory
        events.append(.startSession(sessionDirectory))
    }

    func endSession(
        summarySettings: SummarySettings.Snapshot,
        keepAudioFiles: Bool,
        sessionEnd: Date?,
        summaryCutoff: TimeInterval?,
        streamingCoverage: [AudioSide: StreamingCoverage],
        manualNotesMarkdown: String?,
        extractSpeakers: Bool,
        performOfflineIdentity: Bool,
        speakerCandidates: [SpeakerIdentityMatcher.Candidate],
        offlineIdentifier: OfflineSpeakerIdentifier?,
        offlineIdentityTimeout: Duration?,
        requirePreparedOfflineModels: Bool,
        onPhase: (@Sendable (FinalizationPhase) -> Void)?
    ) async -> FinalizedSessionResult {
        if let endSessionGate { await endSessionGate.wait() }
        events.append(.endSession(currentDir))
        endSessionEnds.append(sessionEnd)
        currentDir = nil
        let speakers = pendingSpeakersPerEnd.isEmpty ? 0 : pendingSpeakersPerEnd.removeFirst()
        return FinalizedSessionResult(pendingSpeakerCount: speakers, manualNotesCommitted: true)
    }

    func processMicAudio(_ captured: CapturedAudioBuffer) async {}
    func processSystemAudio(_ captured: CapturedAudioBuffer) async {}
}

/// Scriptable capture seam: records start/stop order, hands back the callbacks
/// for error injection, and counts `violations` — a startCapture entered while
/// a previous capture was still active (the teardown-serialization invariant).
private final class FakeCapture: AudioCapturing, @unchecked Sendable {
    enum Event: Equatable, Sendable { case start, stop }
    enum StartBehavior {
        case succeed
        case gated(AsyncPermitGate)
        case fail(Error)
        case gatedFail(AsyncPermitGate, Error)
    }

    private let state = OSAllocatedUnfairLock(
        initialState: (
            events: [Event](), callbacks: [AudioCaptureCallbacks](),
            active: false, violations: 0, behaviors: [StartBehavior]()
        )
    )

    init(startBehaviors: [StartBehavior] = []) {
        state.withLock { $0.behaviors = startBehaviors }
    }

    var events: [Event] { state.withLock { $0.events } }
    var violations: Int { state.withLock { $0.violations } }

    func startCapture(sessionDir: URL, callbacks: AudioCaptureCallbacks) async throws {
        let behavior: StartBehavior = state.withLock { s in
            s.behaviors.isEmpty ? .succeed : s.behaviors.removeFirst()
        }
        switch behavior {
        case .succeed:
            break
        case .gated(let gate):
            await gate.wait()
        case .fail(let error):
            throw error
        case .gatedFail(let gate, let error):
            await gate.wait()
            throw error
        }
        state.withLock { s in
            if s.active { s.violations += 1 }
            s.active = true
            s.events.append(.start)
            s.callbacks.append(callbacks)
        }
    }

    func stopCapture() async {
        state.withLock { s in
            s.active = false
            s.events.append(.stop)
        }
    }

    func currentStats() -> AudioCaptureStats { AudioCaptureStats() }

    func emitErrorOnLatestCapture(_ error: Error) {
        let callbacks = state.withLock { $0.callbacks.last }
        callbacks?.onError(error)
    }
}

/// MainActor box for recording UI-side callback invocations.
@MainActor
private final class BannerRecorder {
    private(set) var directories: [URL] = []
    func record(_ dir: URL) { directories.append(dir) }
}

// MARK: - Suite

@Suite("Recording State Lifecycle", .serialized)
@MainActor
struct RecordingStateLifecycleTests {
    private func makeState(
        capture: FakeCapture,
        transcription: FakeTranscription,
        quitTimeout: Duration = .milliseconds(400)
    ) throws -> (RecordingState, URL) {
        let state = RecordingState(
            captureService: capture,
            transcription: transcription,
            quitAttachTimeout: quitTimeout
        )
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (state, dir)
    }

    private func sessionStopReasons(in storageDir: URL) throws -> [String] {
        let subdirs = try FileManager.default.contentsOfDirectory(at: storageDir, includingPropertiesForKeys: nil)
        return try subdirs.compactMap { dir in
            let url = dir.appendingPathComponent("session.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            return json?["stopReason"] as? String
        }
    }

    @Test("Stop before attach: endSession runs only after startSession, with the stop-press end date")
    func stopBeforeAttach() async throws {
        let downloadGate = AsyncPermitGate()
        let transcription = FakeTranscription(downloadGate: downloadGate)
        let capture = FakeCapture()
        let (state, dir) = try makeState(capture: capture, transcription: transcription)
        defer { try? FileManager.default.removeItem(at: dir) }

        await state.start(storageDirectory: dir)
        #expect(state.isRecording)
        #expect(state.isAwaitingTranscription)

        let beforeStop = Date()
        state.stop()
        let afterStop = Date()
        #expect(!state.isRecording)
        #expect(state.isFinalizing)
        // Capture stopped at the press, not at attach.
        #expect(await waitUntil { capture.events == [.start, .stop] })

        downloadGate.permit()
        #expect(await waitUntil { !state.isFinalizing })

        #expect(await transcription.overlapViolations == 0)
        #expect(await transcription.endSessionCount == 1)
        let started = await transcription.startedSessionDirectories
        #expect(started.count == 1)
        let ends = await transcription.endSessionEnds
        if let end = ends.first ?? nil {
            #expect(end >= beforeStop && end <= afterStop)
        } else {
            Issue.record("endSession received no sessionEnd")
        }
    }

    @Test("Notepad global shortcut is claimed while recording and released at the stop press")
    func notepadShortcutFollowsRecording() async throws {
        let transcription = FakeTranscription()
        let capture = FakeCapture()
        let (state, dir) = try makeState(capture: capture, transcription: transcription)
        defer { try? FileManager.default.removeItem(at: dir) }

        let notesStore = ManualNotesStore()
        let notesWindow = ManualNotesWindowController()
        notesWindow.notesStore = notesStore
        state.manualNotesStore = notesStore
        state.manualNotesWindowController = notesWindow

        #expect(!notesWindow.isGlobalShortcutActive)
        await state.start(storageDirectory: dir)
        #expect(state.isRecording)
        #expect(notesWindow.isGlobalShortcutActive)

        // The stop press releases the combo synchronously — it must not stay
        // claimed through finalization, which can outlive the meeting by minutes.
        state.stop()
        #expect(!notesWindow.isGlobalShortcutActive)
        #expect(await waitUntil { !state.isFinalizing })
    }

    @Test("Capture error stops and finalizes the session as captureFailed — no zombie recording")
    func captureErrorStopsAndFinalizes() async throws {
        let transcription = FakeTranscription()
        let capture = FakeCapture()
        let (state, dir) = try makeState(capture: capture, transcription: transcription)
        defer { try? FileManager.default.removeItem(at: dir) }

        await state.start(storageDirectory: dir)
        #expect(await waitUntil { !state.isAwaitingTranscription })

        capture.emitErrorOnLatestCapture(TestCaptureError())
        #expect(await waitUntil { !state.isRecording })
        #expect(state.errorMessage != nil)
        #expect(await waitUntil { !state.isFinalizing })

        #expect(await transcription.endSessionCount == 1)
        #expect(try sessionStopReasons(in: dir) == ["captureFailed"])
    }

    @Test("Restart after a capture error: teardown is serialized, never concurrent with the new capture")
    func captureErrorThenRestart() async throws {
        let transcription = FakeTranscription()
        let capture = FakeCapture()
        let (state, dir) = try makeState(capture: capture, transcription: transcription)
        defer { try? FileManager.default.removeItem(at: dir) }

        await state.start(storageDirectory: dir)
        #expect(await waitUntil { !state.isAwaitingTranscription })
        capture.emitErrorOnLatestCapture(TestCaptureError())
        #expect(await waitUntil { !state.isFinalizing })

        await state.start(storageDirectory: dir)
        #expect(await waitUntil { state.isRecording })
        #expect(capture.events == [.start, .stop, .start])
        #expect(capture.violations == 0)

        await state.stopAndWait()
        #expect(await transcription.overlapViolations == 0)
    }

    @Test("A→B→C chaining: sessions never overlap on the actor; capture teardown stays ordered")
    func chainedSessionsSerialize() async throws {
        let endGate = AsyncPermitGate()
        let transcription = FakeTranscription(endSessionGate: endGate)
        let capture = FakeCapture()
        let (state, dir) = try makeState(capture: capture, transcription: transcription)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A records and stops; its endSession is held open.
        await state.start(storageDirectory: dir)
        #expect(await waitUntil { !state.isAwaitingTranscription })
        state.stop()

        // B starts while A finalizes — recording and finalizing coexist.
        await state.start(storageDirectory: dir)
        #expect(state.isRecording)
        #expect(state.isFinalizing)
        #expect(state.isAwaitingTranscription)

        endGate.permit()  // A's endSession completes → B attaches
        #expect(await waitUntil { !state.isAwaitingTranscription })
        state.stop()

        // C starts while B finalizes.
        await state.start(storageDirectory: dir)
        endGate.permit()  // B's endSession
        #expect(await waitUntil { !state.isAwaitingTranscription })
        state.stop()
        endGate.permit()  // C's endSession
        #expect(await waitUntil { !state.isFinalizing })

        #expect(await transcription.overlapViolations == 0)
        #expect(capture.violations == 0)
        let started = await transcription.startedSessionDirectories
        #expect(started.count == 3)
        #expect(Set(started).count == 3)
        #expect(await transcription.endSessionCount == 3)
        #expect(capture.events == [.start, .stop, .start, .stop, .start, .stop])
    }

    @Test("Quit during overlap: deferred actions are dropped; both sessions finalize with their own reasons")
    func quitDuringOverlapDropsDeferredActions() async throws {
        let endGate = AsyncPermitGate()
        let transcription = FakeTranscription(endSessionGate: endGate, pendingSpeakersPerEnd: [1, 0])
        let capture = FakeCapture()
        let (state, dir) = try makeState(capture: capture, transcription: transcription)
        defer { try? FileManager.default.removeItem(at: dir) }

        let banners = BannerRecorder()
        state.onUnnamedSpeakers = { dir, _ in banners.record(dir) }

        await state.start(storageDirectory: dir)
        #expect(await waitUntil { !state.isAwaitingTranscription })
        state.stop()  // A finalizing, endSession gated

        await state.start(storageDirectory: dir)  // B records during A's finalization

        // Release both endSessions shortly after quit begins draining.
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            endGate.permit(2)
        }
        await state.stopAndWait(reason: .appQuit)

        // A's naming banner was deferred (B was recording) and then dropped at quit.
        #expect(banners.directories.isEmpty)
        #expect(await transcription.endSessionCount == 2)
        let reasons = try sessionStopReasons(in: dir).sorted()
        #expect(reasons == ["appQuit", "manual"])
    }

    @Test("Deferred post-meeting actions flush FIFO after the successor ends")
    func deferredActionsFlushFIFO() async throws {
        let endGate = AsyncPermitGate()
        let transcription = FakeTranscription(endSessionGate: endGate, pendingSpeakersPerEnd: [1, 1])
        let capture = FakeCapture()
        let (state, dir) = try makeState(capture: capture, transcription: transcription)
        defer { try? FileManager.default.removeItem(at: dir) }

        let banners = BannerRecorder()
        state.onUnnamedSpeakers = { dir, _ in banners.record(dir) }

        await state.start(storageDirectory: dir)
        #expect(await waitUntil { !state.isAwaitingTranscription })
        state.stop()

        await state.start(storageDirectory: dir)  // B records
        endGate.permit()  // A finalizes under B → A's banner deferred
        #expect(await waitUntil { !state.isFinalizing })
        #expect(banners.directories.isEmpty)

        state.stop()
        endGate.permit()  // B finalizes with nothing newer active
        #expect(await waitUntil { !state.isFinalizing })

        // FIFO: A's banner first (it was queued first), then B's.
        let started = await transcription.startedSessionDirectories
        #expect(await waitUntil { banners.directories.count == 2 })
        #expect(banners.directories == started)
    }

    @Test("Deferred actions stranded behind a failing start are flushed by the start's failure path")
    func strandedActionsFlushAfterFailedStart() async throws {
        let endGate = AsyncPermitGate()
        let startGateC = AsyncPermitGate()
        let transcription = FakeTranscription(endSessionGate: endGate, pendingSpeakersPerEnd: [1, 0])
        let capture = FakeCapture(startBehaviors: [
            .succeed, .succeed, .gatedFail(startGateC, TestCaptureError())
        ])
        let (state, dir) = try makeState(capture: capture, transcription: transcription)
        defer { try? FileManager.default.removeItem(at: dir) }

        let banners = BannerRecorder()
        state.onUnnamedSpeakers = { dir, _ in banners.record(dir) }

        // A records, stops; B records; A finalizes under B → banner deferred.
        await state.start(storageDirectory: dir)
        #expect(await waitUntil { !state.isAwaitingTranscription })
        state.stop()
        await state.start(storageDirectory: dir)
        endGate.permit()
        #expect(await waitUntil { !state.isFinalizing })
        #expect(banners.directories.isEmpty)

        // B stops (endSession gated); C's start blocks inside startCapture.
        state.stop()
        let startC = Task { await state.start(storageDirectory: dir) }
        #expect(await waitUntil { state.isStarting })

        // B's epilogue runs while C is still starting → flush is skipped.
        endGate.permit()
        #expect(await waitUntil { !state.isFinalizing })
        #expect(banners.directories.isEmpty)

        // C's start fails → its failure path drains the stranded queue.
        startGateC.permit()
        await startC.value
        #expect(state.errorMessage != nil)
        #expect(await waitUntil { banners.directories.count == 1 })
    }

    @Test("Attach failure recovers typed notes: pointer set, draft re-activated, session finalized unattached")
    func attachFailureRecoversNotes() async throws {
        let defaultsName = "lifecycle-notes-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let downloadGate = AsyncPermitGate()
        let transcription = FakeTranscription(downloadGate: downloadGate, downloadError: TestCaptureError())
        let capture = FakeCapture()
        let (state, dir) = try makeState(capture: capture, transcription: transcription)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ManualNotesStore(userDefaults: defaults)
        state.manualNotesStore = store

        await state.start(storageDirectory: dir)
        #expect(store.isEditable)  // notes bind at capture start, before attach
        store.updateText("crucial notes")

        downloadGate.permit()  // download resumes and throws → attach fails → auto-stop
        #expect(await waitUntil { !state.isRecording })
        #expect(await waitUntil { !state.isFinalizing })

        // No actor session was ever started or ended; the session finalized
        // unattached under the .manual stop the attach-failure path issues.
        #expect(await transcription.endSessionCount == 0)
        #expect(await transcription.startedSessionDirectories.isEmpty)
        #expect(try sessionStopReasons(in: dir) == ["manual"])

        // The notes got the full recovery treatment instead of being stranded.
        await store.drainDiskChain()
        #expect(store.text == "crucial notes")
        #expect(store.isEditable)
        let pointers = defaults.stringArray(forKey: ManualNotesStore.recoveryPathsKey) ?? []
        #expect(pointers.count == 1)
        if let pointer = pointers.first {
            let saved = try String(contentsOf: URL(fileURLWithPath: pointer), encoding: .utf8)
            #expect(saved == "crucial notes")
        }
    }

    @Test("Quit is bounded even when the parked session was stopped BEFORE the quit (non-quit reason)")
    func preQuitStopStillBoundsQuit() async throws {
        let downloadGate = AsyncPermitGate()  // never permitted — a wedged download
        let transcription = FakeTranscription(downloadGate: downloadGate)
        let capture = FakeCapture()
        let (state, dir) = try makeState(
            capture: capture,
            transcription: transcription,
            quitTimeout: .milliseconds(300)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        await state.start(storageDirectory: dir)
        state.stop()  // .manual — its finalization parks awaiting the attach
        #expect(state.isFinalizing)

        let began = ContinuousClock.now
        await state.stopAndWait(reason: .appQuit)
        let elapsed = ContinuousClock.now - began
        // The bounded quit path must engage even though this finalization was
        // created by a manual stop (the frozen-isQuit hang).
        #expect(elapsed < .seconds(3))
        #expect(await transcription.endSessionCount == 0)
        #expect(try sessionStopReasons(in: dir) == ["manual"])
    }

    @Test("Quit during an in-flight start abandons and removes the just-created session dir")
    func quitDuringStartRemovesOrphanDir() async throws {
        let startGate = AsyncPermitGate()
        let transcription = FakeTranscription()
        let capture = FakeCapture(startBehaviors: [.gated(startGate)])
        let (state, dir) = try makeState(capture: capture, transcription: transcription)
        defer { try? FileManager.default.removeItem(at: dir) }

        let startTask = Task { await state.start(storageDirectory: dir) }
        #expect(await waitUntil { state.isStarting })

        let quitTask = Task { await state.stopAndWait(reason: .appQuit) }
        try await Task.sleep(for: .milliseconds(50))  // let quitRequested land
        startGate.permit()  // startCapture returns into the quit-bail

        await startTask.value
        await quitTask.value
        #expect(!state.isRecording)
        // The bail removed the orphan dir — no header-only WAVs left behind.
        let subdirs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(subdirs.isEmpty)
    }

    @Test("Quit while attach is parked in the model download is bounded; audio session is preserved unattached")
    func quitBoundedWhileAttachParked() async throws {
        let downloadGate = AsyncPermitGate()  // never permitted — a wedged download
        let transcription = FakeTranscription(downloadGate: downloadGate)
        let capture = FakeCapture()
        let (state, dir) = try makeState(
            capture: capture,
            transcription: transcription,
            quitTimeout: .milliseconds(300)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        await state.start(storageDirectory: dir)
        #expect(state.isRecording)

        let began = ContinuousClock.now
        await state.stopAndWait(reason: .appQuit)
        let elapsed = ContinuousClock.now - began
        #expect(elapsed < .seconds(3))

        // Never attached → endSession must not run; the session dir still gets
        // its diagnostics (the WAVs would be the only record of the meeting).
        #expect(await transcription.endSessionCount == 0)
        #expect(try sessionStopReasons(in: dir) == ["appQuit"])
    }
}
