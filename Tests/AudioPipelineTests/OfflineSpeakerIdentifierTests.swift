import FluidAudio
import Foundation
import Testing

@testable import SerialNotes

@Suite("Offline Speaker Identifier — clustering")
struct OfflineSpeakerIdentifierTests {
    private func segment(
        _ speakerId: String,
        _ start: Float,
        _ end: Float,
        embedding: [Float] = [1, 0]
    ) -> TimedSpeakerSegment {
        TimedSpeakerSegment(
            speakerId: speakerId,
            embedding: embedding,
            startTimeSeconds: start,
            endTimeSeconds: end,
            qualityScore: 1
        )
    }

    @Test("Groups segments by speaker, sorted by id")
    func groupsBySpeaker() {
        let result = DiarizationResult(
            segments: [
                segment("1", 5, 7),
                segment("0", 0, 2),
                segment("1", 9, 12),
                segment("0", 3, 4),
            ],
            speakerDatabase: ["0": [1, 0], "1": [0, 1]]
        )
        let clusters = OfflineSpeakerIdentifier.clusters(from: result)
        #expect(clusters.map(\.id) == ["0", "1"])
        #expect(clusters[0].segments.count == 2)
        #expect(clusters[1].segments.count == 2)
    }

    @Test("Spans are sorted and total speech time is summed")
    func sortsSpansAndSumsDuration() {
        let result = DiarizationResult(
            segments: [segment("0", 9, 12), segment("0", 0, 2)],
            speakerDatabase: ["0": [1, 0]]
        )
        let cluster = OfflineSpeakerIdentifier.clusters(from: result)[0]
        #expect(cluster.segments.first?.start == 0)
        #expect(cluster.segments.last?.start == 9)
        #expect(abs(cluster.totalSpeechSeconds - 5) < 1e-6) // (2-0) + (12-9)
    }

    @Test("Prefers the speakerDatabase centroid over the per-segment embedding")
    func prefersCentroid() {
        let result = DiarizationResult(
            segments: [segment("0", 0, 2, embedding: [9, 9])],
            speakerDatabase: ["0": [1, 0]]
        )
        let cluster = OfflineSpeakerIdentifier.clusters(from: result)[0]
        #expect(cluster.embedding == [1, 0])
    }

    @Test("Falls back to the first segment embedding when no centroid is published")
    func fallsBackToSegmentEmbedding() {
        let result = DiarizationResult(
            segments: [segment("0", 0, 2, embedding: [0, 1])],
            speakerDatabase: nil
        )
        let cluster = OfflineSpeakerIdentifier.clusters(from: result)[0]
        #expect(cluster.embedding == [0, 1])
    }

    // MARK: - merge (over-segment → merge strategy)

    private func cluster(_ id: String, _ embedding: [Float], speechSeconds: Double) -> OfflineSpeakerCluster {
        OfflineSpeakerCluster(id: id, embedding: embedding, segments: [.init(start: 0, end: speechSeconds)])
    }

    @Test("merge collapses same-speaker fragments, keeps distinct speakers")
    func mergeCollapsesFragments() {
        // a + a2 share a direction (cosine 1) → merge; b is orthogonal → stays.
        let merged = OfflineSpeakerIdentifier.merge(
            [cluster("a", [1, 0], speechSeconds: 100),
             cluster("a2", [1, 0], speechSeconds: 50),
             cluster("b", [0, 1], speechSeconds: 80)],
            threshold: 0.5)
        #expect(merged.count == 2)
        let biggest = merged.max(by: { $0.totalSpeechSeconds < $1.totalSpeechSeconds })!
        #expect(abs(biggest.totalSpeechSeconds - 150) < 1e-6) // 100 + 50 combined
    }

    @Test("merge keeps distinct speakers separate")
    func mergeKeepsDistinct() {
        let merged = OfflineSpeakerIdentifier.merge(
            [cluster("a", [1, 0], speechSeconds: 30),
             cluster("b", [0, 1], speechSeconds: 30),
             cluster("c", [-1, 0], speechSeconds: 30)],
            threshold: 0.5)
        #expect(merged.count == 3)
    }

    @Test("merged cluster unions and time-sorts segments")
    func mergeCombinesSegments() {
        let a = OfflineSpeakerCluster(id: "a", embedding: [1, 0], segments: [.init(start: 10, end: 20)])
        let b = OfflineSpeakerCluster(id: "b", embedding: [1, 0], segments: [.init(start: 0, end: 5)])
        let merged = OfflineSpeakerIdentifier.merge([a, b], threshold: 0.5)
        #expect(merged.count == 1)
        #expect(merged[0].segments.map(\.start) == [0, 10])
    }

    @Test("merge threshold is inclusive")
    func mergeThresholdIsInclusive() {
        let merged = OfflineSpeakerIdentifier.merge(
            [cluster("a", [1, 0], speechSeconds: 30),
             cluster("b", [0.5, 0.8660254], speechSeconds: 30)],
            threshold: 0.5)
        #expect(merged.count == 1)
    }

    @Test("mergeAndFilter retains a speaker split into individually short fragments")
    func mergeBeforeDurationFilter() {
        let retained = OfflineSpeakerIdentifier.mergeAndFilter(
            [cluster("a", [1, 0], speechSeconds: 12),
             cluster("a2", [1, 0], speechSeconds: 12),
             cluster("noise", [0, 1], speechSeconds: 4)],
            threshold: 0.5,
            minSpeechSeconds: 20)
        #expect(retained.count == 1)
        #expect(abs(retained[0].totalSpeechSeconds - 24) < 1e-6)
    }
}
