import AVFoundation
import Foundation
import os

/// How much of one side's captured audio made it through the streaming feed by
/// the time the session finalized. The final render uses this to decide whether
/// the streaming transcript / diarizer timeline can be trusted: `.partial` and
/// `.missed` mean the WAV holds audio the streaming pipeline never saw.
enum StreamingCoverage: Equatable, Sendable {
    /// Every buffer the capture yielded was fed to the streaming pipeline
    /// (including the vacuous case where the side captured nothing).
    case complete
    /// The feed was cut short — streaming state only covers audio up to this
    /// many seconds into the side's timeline.
    case partial(throughSeconds: TimeInterval)
    /// Audio was captured but none of it reached the streaming pipeline.
    /// (Named `missed`, not `none`, so it can never be confused with
    /// `Optional.none` in dictionary lookups and equality checks.)
    case missed

    /// The point on the side's timeline up to which streaming state is valid.
    /// `nil` means unbounded (complete coverage).
    var validThroughSeconds: TimeInterval? {
        switch self {
        case .complete: nil
        case .partial(let seconds): seconds
        case .missed: 0
        }
    }

    var isComplete: Bool { self == .complete }
}

/// Await `operation`'s value, giving up at `timeout` (returns nil) — in which
/// case the operation keeps running detached (its work must be safe to outlive
/// the wait; see callers). First-resume-wins by design: a task group is NOT
/// usable here because the group would join a child that is itself blocked
/// awaiting a non-cancellable `Task.value`, defeating the timeout. This is the
/// ONE audited resume-once race in the codebase — extend it rather than
/// hand-rolling another continuation gate.
func awaitOrTimeout<T: Sendable>(_ timeout: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            if !resumed.withLock({ let was = $0; $0 = true; return was }) {
                continuation.resume(returning: nil)
            }
        }
        Task {
            let value = await operation()
            if !resumed.withLock({ let was = $0; $0 = true; return was }) {
                // Don't leave the watchdog sleeping out its full timeout after
                // every ordinary completion.
                watchdog.cancel()
                continuation.resume(returning: value)
            }
        }
    }
}

/// Void convenience: true when the operation finished in time, false on timeout.
func awaitOrTimeout(_ timeout: Duration, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
    let outcome: Void? = await awaitOrTimeout(timeout) { await operation() }
    return outcome != nil
}

/// Per-session conveyor between `AudioCaptureService`'s real-time callbacks and
/// the `TranscriptionService` actor. Capture threads `yield` buffers into
/// per-side unbounded `AsyncStream`s; one consumer task per side feeds them to
/// the actor **in order** once `attach` runs. Before attach the streams simply
/// buffer — this is what lets a new recording capture immediately while the
/// previous recording's finalization still owns the transcription actor.
///
/// Ordering is load-bearing: entry timestamps are a pure function of cumulative
/// samples fed per side, so buffers must reach the actor per-side FIFO with no
/// drops. That's why the backlog cap *abandons the whole feed* instead of
/// shedding oldest buffers — a gap would silently skew every later timestamp
/// and misattribute speakers, whereas a clean abandon is reported as coverage
/// the final render can act on (the WAVs always hold the full audio).
final class AudioFeedPipeline: Sendable {
    private struct SideBook {
        var sampleRate: Double = 0
        var yieldedSamples = 0
        var consumedSamples = 0
    }

    private struct State {
        // Stored per side (not a dictionary): `yield` runs ~12×/sec/side on the
        // capture queues while holding the lock — no hashing on that path.
        var micBook = SideBook()
        var systemBook = SideBook()
        /// Bytes yielded but not yet consumed — the in-memory backlog.
        var backlogBytes = 0
        var finished = false
        var abandoned = false
        var attached = false
        var consumers: [Task<Void, Never>] = []

        func book(for side: AudioSide) -> SideBook {
            switch side {
            case .mic: micBook
            case .system: systemBook
            }
        }

        mutating func withBook(for side: AudioSide, _ body: (inout SideBook) -> Void) {
            switch side {
            case .mic: body(&micBook)
            case .system: body(&systemBook)
            }
        }
    }

    /// Yields arrive on the IOProc / mic-tap / SCK queues while control runs on
    /// the main actor, so every mutable field lives behind this lock. Yield and
    /// its bookkeeping happen under one lock hold so an accepted buffer can
    /// never race a concurrent finish/abandon into a false-partial coverage.
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let micStream: AsyncStream<CapturedAudioBuffer>
    private let systemStream: AsyncStream<CapturedAudioBuffer>
    private let micContinuation: AsyncStream<CapturedAudioBuffer>.Continuation
    private let systemContinuation: AsyncStream<CapturedAudioBuffer>.Continuation
    private let maxBacklogBytes: Int

    /// ~4 minutes of mono float32 at 48 kHz on both sides. Finalization of the
    /// previous meeting should be well under this; blowing through it means
    /// something is wedged, and the second-pass ASR still covers the WAVs.
    static let defaultMaxBacklogBytes = 96 * 1024 * 1024

    init(maxBacklogBytes: Int = AudioFeedPipeline.defaultMaxBacklogBytes) {
        self.maxBacklogBytes = maxBacklogBytes
        // Explicitly unbounded: any bounded policy sheds buffers, and a shed
        // buffer corrupts the samples-fed timeline (see type comment).
        (micStream, micContinuation) = AsyncStream<CapturedAudioBuffer>.makeStream(bufferingPolicy: .unbounded)
        (systemStream, systemContinuation) = AsyncStream<CapturedAudioBuffer>.makeStream(bufferingPolicy: .unbounded)
    }

    var isAbandoned: Bool {
        state.withLock { $0.abandoned }
    }

    private func stream(for side: AudioSide) -> AsyncStream<CapturedAudioBuffer> {
        switch side {
        case .mic: micStream
        case .system: systemStream
        }
    }

    private func continuation(for side: AudioSide) -> AsyncStream<CapturedAudioBuffer>.Continuation {
        switch side {
        case .mic: micContinuation
        case .system: systemContinuation
        }
    }

    // MARK: - Producer side (capture queues)

    func yield(_ captured: CapturedAudioBuffer, side: AudioSide) {
        let frames = Int(captured.buffer.frameLength)
        guard frames > 0 else { return }
        let bytes = captured.byteCount
        let sampleRate = captured.buffer.format.sampleRate
        let continuation = continuation(for: side)

        let overflowed: Bool = state.withLock { s in
            // abandon() always sets finished too, so one flag check suffices.
            guard !s.finished else { return false }
            s.withBook(for: side) { book in
                book.yieldedSamples += frames
                if book.sampleRate == 0 {
                    book.sampleRate = sampleRate
                }
            }
            s.backlogBytes += bytes
            // Yield under the same lock hold as the bookkeeping — see `state` doc.
            continuation.yield(captured)
            return s.backlogBytes > maxBacklogBytes
        }
        if overflowed {
            NSLog("[SerialNotes/FeedPipeline] backlog exceeded %d bytes — abandoning streaming feed (WAVs unaffected)", maxBacklogBytes)
            abandon()
        }
    }

    // MARK: - Lifecycle

    /// No more input — the feed is now finite. Already-buffered audio remains
    /// drainable (this is a stop, not an abandon).
    func finishFeed() {
        let shouldFinish: Bool = state.withLock { s in
            guard !s.finished else { return false }
            s.finished = true
            return true
        }
        if shouldFinish {
            micContinuation.finish()
            systemContinuation.finish()
        }
    }

    /// Drop the feed entirely: no further input **and** the buffered backlog is
    /// never delivered (`AsyncStream.finish()` alone would still drain it —
    /// consumers and `attach` check the flag instead). Used by app quit, the
    /// backlog cap, drain timeout, and attach failure.
    func abandon() {
        let toCancel: [Task<Void, Never>]? = state.withLock { s in
            guard !s.abandoned else { return nil }
            s.abandoned = true
            s.finished = true
            return s.consumers
        }
        guard let toCancel else { return }
        micContinuation.finish()
        systemContinuation.finish()
        for task in toCancel { task.cancel() }
    }

    // MARK: - Consumer side

    /// Start one consumer task per side, feeding buffered + live audio through
    /// `processBuffer` strictly in order. No-ops if already attached or
    /// abandoned. `processBuffer` is the only path by which pipeline audio may
    /// reach the transcription actor.
    func attach(processBuffer: @escaping @Sendable (AudioSide, CapturedAudioBuffer) async -> Void) {
        let shouldStart: Bool = state.withLock { s in
            guard !s.attached, !s.abandoned else { return false }
            s.attached = true
            return true
        }
        guard shouldStart else { return }

        let tasks: [Task<Void, Never>] = AudioSide.allCases.map { side in
            let stream = stream(for: side)
            return Task { [state] in
                for await captured in stream {
                    if Task.isCancelled { break }
                    if state.withLock({ $0.abandoned }) { break }
                    await processBuffer(side, captured)
                    let frames = Int(captured.buffer.frameLength)
                    let bytes = captured.byteCount
                    state.withLock { s in
                        s.withBook(for: side) { $0.consumedSamples += frames }
                        s.backlogBytes = max(0, s.backlogBytes - bytes)
                    }
                }
            }
        }

        let abandonedMeanwhile: Bool = state.withLock { s in
            s.consumers = tasks
            return s.abandoned
        }
        if abandonedMeanwhile {
            for task in tasks { task.cancel() }
        }
    }

    /// Finish the feed and wait for the consumers to drain the (now finite)
    /// backlog into the actor — **bounded hard**: at `timeout` the feed is
    /// abandoned and this returns immediately with the coverage achieved so
    /// far, even if a consumer is wedged inside an inference call. Such a
    /// consumer self-terminates after that call returns, and anything it would
    /// still send is dropped by the transcription actor's ingest gate
    /// (`acceptingStreamingAudio`), so callers may proceed to `endSession` at
    /// once. Returns the per-side coverage.
    func drain(timeout: Duration) async -> [AudioSide: StreamingCoverage] {
        finishFeed()
        let consumers = state.withLock { $0.consumers }
        guard !consumers.isEmpty else { return coverage() }

        let drained = await awaitOrTimeout(timeout) {
            for task in consumers { await task.value }
        }
        if !drained {
            NSLog("[SerialNotes/FeedPipeline] drain timed out — abandoning remaining backlog")
            abandon()
        }
        return coverage()
    }

    /// Per-side coverage snapshot. `.complete` when everything yielded was
    /// consumed (including sides that never captured audio at all).
    func coverage() -> [AudioSide: StreamingCoverage] {
        state.withLock { s in
            var result: [AudioSide: StreamingCoverage] = [:]
            for side in AudioSide.allCases {
                let book = s.book(for: side)
                if book.consumedSamples >= book.yieldedSamples {
                    result[side] = .complete
                } else if book.consumedSamples == 0 {
                    result[side] = .missed
                } else {
                    let rate = book.sampleRate > 0 ? book.sampleRate : 48000
                    result[side] = .partial(throughSeconds: Double(book.consumedSamples) / rate)
                }
            }
            return result
        }
    }
}
