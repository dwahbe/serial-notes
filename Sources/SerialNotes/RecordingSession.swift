import Foundation

/// One recording's identity and capture-side state, alive from the moment its
/// capture starts until its finalization completes. Recordings can overlap a
/// predecessor's finalization (capture starts immediately; the transcription
/// session attaches once the previous finalization releases the actor), so
/// everything that used to be a single-slot field on `RecordingState` — session
/// dir, start date, pipeline, stats — lives here, keyed by `id`. Callbacks that
/// can fire late (capture errors, transcription errors, phase updates) carry
/// the `id` and are checked against the current session before touching UI state.
@MainActor
final class RecordingSession {
    let id = UUID()
    let directory: URL
    /// Capture start — the origin of the samples-fed timeline. Must be the date
    /// passed to `startSession` even though attach happens later.
    let startDate: Date
    let pipeline: AudioFeedPipeline

    /// Snapshotted at the stop press. The recording *ends* here: capture stops
    /// immediately and this date becomes `endedAt`/duration, no matter how long
    /// finalization takes afterwards. (The stop REASON lives on `StopContext`,
    /// the single authority — it is deliberately not duplicated here.)
    private(set) var stopDate: Date?
    /// Snapshotted by the capture-teardown step, right after `stopCapture()` —
    /// before any successor capture can reset the service's stats.
    var captureStats: AudioCaptureStats?
    /// The finalization of the session this one overlapped (nil when none) —
    /// the attach task waits it out, and the quit path awaits it separately so
    /// its (deliberately unbounded) wait isn't lumped into the bounded attach
    /// wait below.
    var predecessorFinalization: Task<Void, Never>?
    /// Phase 2 of `start()`: waits out the previous finalization, then starts
    /// the transcription session and attaches the pipeline. The session's
    /// finalization awaits this before deciding whether it may call `endSession`
    /// — unbounded normally, bounded on app quit (the attach may be parked in a
    /// model download, and quit must not hang behind the network).
    var attachTask: Task<Void, Never>?
    /// True once `startSession` succeeded — only then may finalization call
    /// `endSession` (an unattached session has no actor session to end).
    var attached = false
    /// True once the manual-notes store was bound to this session; gates both
    /// the stop-time notes snapshot and `completeSnapshotWrite`.
    var notesAttached = false

    init(directory: URL, startDate: Date, pipeline: AudioFeedPipeline) {
        self.directory = directory
        self.startDate = startDate
        self.pipeline = pipeline
    }

    var isStopRequested: Bool { stopDate != nil }

    func markStopped(at date: Date) {
        stopDate = date
    }
}
