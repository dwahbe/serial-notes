import AVFoundation
import Foundation
import Testing
import os

@testable import SerialNotes

@Suite("Audio Feed Pipeline")
struct AudioFeedPipelineTests {
    /// Thread-safe recorder of what reached the consumer, in per-side order.
    private final class Collector: Sendable {
        private let entries = OSAllocatedUnfairLock(initialState: [AudioSide: [Int]]())

        func record(side: AudioSide, frames: Int) {
            entries.withLock { $0[side, default: []].append(frames) }
        }

        func frames(for side: AudioSide) -> [Int] {
            entries.withLock { $0[side] ?? [] }
        }

        var totalCount: Int {
            entries.withLock { $0.values.reduce(0) { $0 + $1.count } }
        }
    }

    /// Mono float32 buffer whose frame length doubles as a sequence marker.
    private func makeBuffer(frames: Int, sampleRate: Double = 48000) -> CapturedAudioBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        return CapturedAudioBuffer(buffer: buffer)
    }

    @Test("Buffers yielded before attach are delivered in order once attached")
    func preAttachBacklogReplaysInOrder() async {
        let pipeline = AudioFeedPipeline()
        let collector = Collector()

        for frames in [100, 200, 300, 400, 500] {
            pipeline.yield(makeBuffer(frames: frames), side: .mic)
        }
        pipeline.attach { side, captured in
            collector.record(side: side, frames: Int(captured.buffer.frameLength))
        }

        let coverage = await pipeline.drain(timeout: .seconds(5))
        #expect(collector.frames(for: .mic) == [100, 200, 300, 400, 500])
        #expect(coverage[.mic] == .complete)
        #expect(coverage[.system] == .complete)  // vacuously: nothing captured
    }

    @Test("Per-side FIFO holds with interleaved live yields across the attach boundary")
    func perSideOrderingAcrossAttach() async {
        let pipeline = AudioFeedPipeline()
        let collector = Collector()

        pipeline.yield(makeBuffer(frames: 10), side: .mic)
        pipeline.yield(makeBuffer(frames: 11), side: .system)
        pipeline.yield(makeBuffer(frames: 20), side: .mic)

        pipeline.attach { side, captured in
            collector.record(side: side, frames: Int(captured.buffer.frameLength))
        }

        // "Live" yields after attach continue the same streams.
        pipeline.yield(makeBuffer(frames: 30), side: .mic)
        pipeline.yield(makeBuffer(frames: 21), side: .system)

        let coverage = await pipeline.drain(timeout: .seconds(5))
        #expect(collector.frames(for: .mic) == [10, 20, 30])
        #expect(collector.frames(for: .system) == [11, 21])
        #expect(coverage[.mic] == .complete)
        #expect(coverage[.system] == .complete)
    }

    @Test("Drain timeout abandons the remainder mid-backlog and reports partial coverage")
    func drainTimeoutReportsPartial() async throws {
        let pipeline = AudioFeedPipeline()
        let collector = Collector()
        let permits = AsyncPermitGate()

        // 10 buffers, each 4800 frames = 0.1 s of audio. The consumer parks on
        // a permit per buffer, so exactly how far it drains is deterministic —
        // no wall-clock coupling for a saturated CI executor to flake on.
        for _ in 0..<10 {
            pipeline.yield(makeBuffer(frames: 4800), side: .mic)
        }
        pipeline.attach { side, captured in
            collector.record(side: side, frames: Int(captured.buffer.frameLength))
            await permits.wait()
        }

        // Two buffers fully consumed; the third is recorded but held inside
        // processBuffer — a consumer wedged mid-inference, in miniature.
        permits.permit(2)
        #expect(await waitUntil { collector.totalCount == 3 })

        let coverage = await pipeline.drain(timeout: .milliseconds(200))
        #expect(pipeline.isAbandoned)
        #expect(collector.totalCount == 3)

        // Drain returned at the deadline without awaiting the wedged consumer;
        // coverage counts the two COMPLETED buffers (the in-flight one hasn't
        // finished processing, so it isn't claimed as covered).
        guard case .partial(let through)? = coverage[.mic] else {
            Issue.record("expected partial coverage, got \(String(describing: coverage[.mic]))")
            return
        }
        #expect(abs(through - 0.2) < 0.001)

        // Un-wedge the consumer: it must exit on the abandoned flag and deliver
        // nothing further from the dropped backlog.
        permits.permit(100)
        #expect(await waitUntil { collector.totalCount == 3 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(collector.totalCount == 3)
    }

    @Test("Abandon with a buffered backlog delivers nothing — attach afterwards is a no-op")
    func abandonDropsBacklog() async {
        let pipeline = AudioFeedPipeline()
        let collector = Collector()

        pipeline.yield(makeBuffer(frames: 100), side: .mic)
        pipeline.yield(makeBuffer(frames: 200), side: .system)
        pipeline.abandon()

        // AsyncStream.finish() alone would still hand consumers the buffered
        // elements — the abandoned flag must make attach decline entirely.
        pipeline.attach { side, captured in
            collector.record(side: side, frames: Int(captured.buffer.frameLength))
        }

        let coverage = await pipeline.drain(timeout: .seconds(1))
        #expect(collector.totalCount == 0)
        #expect(coverage[.mic] == .missed)
        #expect(coverage[.system] == .missed)
    }

    @Test("Abandon after attach stops delivery after the in-flight buffer")
    func abandonAfterAttachStopsDelivery() async throws {
        let pipeline = AudioFeedPipeline()
        let collector = Collector()
        let gate = OSAllocatedUnfairLock(initialState: false)

        for frames in [100, 200, 300] {
            pipeline.yield(makeBuffer(frames: frames), side: .mic)
        }
        pipeline.attach { side, captured in
            collector.record(side: side, frames: Int(captured.buffer.frameLength))
            // Park until the test abandons, so at most one buffer is in flight.
            while !gate.withLock({ $0 }) {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        try await Task.sleep(for: .milliseconds(50))  // let the first buffer enter
        pipeline.abandon()
        gate.withLock { $0 = true }

        _ = await pipeline.drain(timeout: .seconds(2))
        #expect(collector.frames(for: .mic).count <= 1)
    }

    @Test("Backlog cap abandons the whole feed instead of shedding buffers")
    func backlogCapAbandons() async {
        // Cap below two buffers' bytes: 4800 frames * 4 bytes = 19200 each.
        let pipeline = AudioFeedPipeline(maxBacklogBytes: 30_000)
        let collector = Collector()

        pipeline.yield(makeBuffer(frames: 4800), side: .mic)
        #expect(!pipeline.isAbandoned)
        pipeline.yield(makeBuffer(frames: 4800), side: .mic)
        #expect(pipeline.isAbandoned)

        pipeline.attach { side, captured in
            collector.record(side: side, frames: Int(captured.buffer.frameLength))
        }
        let coverage = await pipeline.drain(timeout: .seconds(1))
        #expect(collector.totalCount == 0)
        #expect(coverage[.mic] == .missed)
    }

    @Test("Yields after finishFeed are dropped and don't distort coverage")
    func postFinishYieldsDropped() async {
        let pipeline = AudioFeedPipeline()
        let collector = Collector()

        pipeline.yield(makeBuffer(frames: 100), side: .mic)
        pipeline.finishFeed()
        pipeline.yield(makeBuffer(frames: 999), side: .mic)  // straggler after stop

        pipeline.attach { side, captured in
            collector.record(side: side, frames: Int(captured.buffer.frameLength))
        }
        let coverage = await pipeline.drain(timeout: .seconds(5))
        #expect(collector.frames(for: .mic) == [100])
        #expect(coverage[.mic] == .complete)
    }

    @Test("StreamingCoverage maps to the attribution bound")
    func coverageValidThrough() {
        #expect(StreamingCoverage.complete.validThroughSeconds == nil)
        #expect(StreamingCoverage.partial(throughSeconds: 12.5).validThroughSeconds == 12.5)
        #expect(StreamingCoverage.missed.validThroughSeconds == 0)
        #expect(StreamingCoverage.complete.isComplete)
        #expect(!StreamingCoverage.partial(throughSeconds: 1).isComplete)
        #expect(!StreamingCoverage.missed.isComplete)
    }
}

@Suite("Final render coverage rules")
struct StreamingCoverageRenderRuleTests {
    private func decide(
        streamingEntries: Int = 10,
        streamingSources: Set<AudioSide> = [.mic, .system],
        renderedEntries: Int = 10,
        renderedSources: Set<AudioSide> = [.mic, .system],
        coverage: [AudioSide: StreamingCoverage]
    ) -> Bool {
        TranscriptionService.shouldReplaceStreamingTranscript(
            streamingEntryCount: streamingEntries,
            streamingSources: streamingSources,
            renderedEntryCount: renderedEntries,
            renderedSources: renderedSources,
            coverage: coverage
        )
    }

    @Test("Complete coverage keeps today's rule: never lose a source the final pass missed")
    func completeCoverageKeepsSourceRule() {
        let full: [AudioSide: StreamingCoverage] = [.mic: .complete, .system: .complete]
        #expect(decide(coverage: full))
        // Final pass missed the mic → keep the (complete) streaming transcript.
        #expect(!decide(renderedSources: [.system], coverage: full))
    }

    @Test("Partial coverage prefers the final render even when it missed a source")
    func partialCoveragePrefersFinalRender() {
        let partial: [AudioSide: StreamingCoverage] = [
            .mic: .partial(throughSeconds: 30), .system: .complete
        ]
        // A partially-drained streaming transcript must never masquerade as
        // complete — the final pass read the full WAVs.
        #expect(decide(renderedSources: [.system], coverage: partial))
    }

    @Test("Incomplete streaming stands only when the final pass produced nothing")
    func incompleteStreamingOnlyStandsWhenFinalPassEmpty() {
        let missed: [AudioSide: StreamingCoverage] = [.mic: .missed, .system: .missed]
        #expect(!decide(renderedEntries: 0, renderedSources: [], coverage: missed))
        #expect(decide(renderedEntries: 1, renderedSources: [.mic], coverage: missed))
    }

    @Test("No streaming entries always replaces, regardless of coverage")
    func emptyStreamingAlwaysReplaces() {
        #expect(decide(streamingEntries: 0, streamingSources: [], coverage: [:]))
        #expect(decide(
            streamingEntries: 0,
            streamingSources: [],
            coverage: [.mic: .missed, .system: .missed]
        ))
    }

    @Test("Interruption note applies exactly when streaming-sourced content is missing its tail")
    func interruptionNoteDecision() {
        // Fallback render (no final ASR output): any incomplete side marks it.
        #expect(TranscriptionService.interruptionNoteApplies(
            mergedStreamingSides: [],
            usedFallbackStreamingRender: true,
            coverage: [.mic: .partial(throughSeconds: 30), .system: .complete]
        ))
        #expect(!TranscriptionService.interruptionNoteApplies(
            mergedStreamingSides: [],
            usedFallbackStreamingRender: true,
            coverage: [.mic: .complete, .system: .complete]
        ))

        // High-accuracy render: the note keys on the MERGED sides' coverage —
        // a fully WAV-regenerated transcript is complete even if streaming was
        // partial, and a merged side with complete streaming needs no note.
        #expect(!TranscriptionService.interruptionNoteApplies(
            mergedStreamingSides: [],
            usedFallbackStreamingRender: false,
            coverage: [.mic: .partial(throughSeconds: 5), .system: .missed]
        ))
        #expect(TranscriptionService.interruptionNoteApplies(
            mergedStreamingSides: [.mic],
            usedFallbackStreamingRender: false,
            coverage: [.mic: .partial(throughSeconds: 5), .system: .complete]
        ))
        #expect(!TranscriptionService.interruptionNoteApplies(
            mergedStreamingSides: [.mic],
            usedFallbackStreamingRender: false,
            coverage: [.mic: .complete, .system: .partial(throughSeconds: 5)]
        ))
    }

    @Test("Transcription ingest gate starts closed and drops buffers outside a session")
    func ingestGateClosedOutsideSession() async {
        let service = TranscriptionService()
        #expect(await !service.isAcceptingStreamingAudio)
        // Without a session (and without models) this must be a silent no-op —
        // the gate guard runs before any per-side state is touched.
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        await service.processMicAudio(CapturedAudioBuffer(buffer: buffer))
        #expect(await !service.isAcceptingStreamingAudio)
    }
}
