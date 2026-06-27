import Foundation
import Testing

@testable import SerialNotes

@Suite("Speaker re-attribution")
struct SpeakerReattributionTests {
    private func speaker(_ id: String, _ span: (Double, Double), _ decision: SpeakerIdentityMatcher.Decision) -> IdentifiedSpeaker {
        IdentifiedSpeaker(
            cluster: OfflineSpeakerCluster(id: id, embedding: [1, 0], segments: [.init(start: span.0, end: span.1)]),
            decision: decision)
    }

    @Test("Labels confirmed by name and anonymous as Person N")
    func labelsSpeakers() {
        let labeled = SpeakerReattribution.labelSpeakers([
            speaker("A", (0, 30), .confirmed(profileID: UUID(), name: "Jake", similarity: 0.9)),
            speaker("B", (50, 70), .anonymous),
            speaker("C", (80, 90), .suggested(profileID: UUID(), name: "Sam", similarity: 0.5)),
        ])
        #expect(labeled.map(\.label) == ["Jake", "Person 1", "Person 2"])
    }

    @Test("Picks the covering speaker, nearby gaps, and leaves long gaps alone")
    func picksSpeaker() {
        let labeled = SpeakerReattribution.labelSpeakers([
            speaker("A", (0, 30), .confirmed(profileID: UUID(), name: "Jake", similarity: 0.9)),
            speaker("B", (50, 70), .anonymous),
        ])
        #expect(SpeakerReattribution.speaker(at: 10, among: labeled)?.label == "Jake")       // covered
        #expect(SpeakerReattribution.speaker(at: 60, among: labeled)?.label == "Person 1")    // covered
        #expect(SpeakerReattribution.speaker(at: 31, among: labeled)?.label == "Jake")          // nearby gap
        #expect(SpeakerReattribution.speaker(at: 100, among: labeled) == nil)                    // do not force-label
    }

    @Test("Re-attributes system entries by time; leaves mic + summary alone")
    func reattributes() {
        // Streaming merged both remote people into "Person 1". Offline split them:
        // Jake speaks 0–30s, an anonymous guest 50–70s.
        let transcript = """
        ## Summary

        Person 1 discussed the launch.

        **You** (00:00:05): Hi everyone.

        **Person 1** (00:00:10): I'm Jake, glad to be here.

        **Person 1** (00:01:00): And I'm the other guest.
        """
        let speakers = [
            speaker("A", (0, 30), .confirmed(profileID: UUID(), name: "Jake", similarity: 0.96)),
            speaker("B", (50, 70), .anonymous),
        ]
        let out = SpeakerReattribution.reattribute(transcript: transcript, speakers: speakers, micLabels: ["You"])
        #expect(out.contains("**Jake** (00:00:10): I'm Jake"))      // 10s → Jake
        #expect(out.contains("**Person 1** (00:01:00): And I'm"))   // 60s → anonymous guest
        #expect(out.contains("**You** (00:00:05): Hi everyone."))   // mic untouched
        #expect(out.contains("Person 1 discussed the launch."))     // summary prose untouched
        #expect(!out.contains("**Person 1** (00:00:10)"))           // the 10s entry was relabeled
    }

    @Test("Re-attributes exact system timings without relabeling mic entries")
    func reattributesExactEntries() {
        // Markdown would truncate 10.9 to 10. The in-memory ASR timing must still
        // choose Sam, whose turn begins at 10.8.
        let speakers = [
            speaker("A", (0, 10.8), .confirmed(profileID: UUID(), name: "Jake", similarity: 0.96)),
            speaker("B", (10.8, 30), .confirmed(profileID: UUID(), name: "Sam", similarity: 0.96)),
        ]
        let entries = [
            TranscriptEntry(source: .system, speaker: "Person 1", text: "Late turn", timestamp: 10.9),
            TranscriptEntry(source: .mic, speaker: "You", text: "My turn", timestamp: 10.9),
        ]

        let out = SpeakerReattribution.reattribute(entries, speakers: speakers)
        #expect(out[0].speaker == "Sam")
        #expect(out[1].speaker == "You")
    }

    @Test("Uncovered system entries move into a disjoint leftover namespace")
    func uncoveredSystemEntriesUseLeftoverNamespace() {
        let speakers = [
            speaker("A", (0, 10), .anonymous),
        ]
        let entries = [
            TranscriptEntry(source: .system, speaker: "Person 1", text: "Covered", timestamp: 5),
            TranscriptEntry(source: .system, speaker: "Person 1", text: "Far gap one", timestamp: 30),
            TranscriptEntry(source: .system, speaker: "Person 1", text: "Far gap two", timestamp: 35),
            TranscriptEntry(source: .mic, speaker: "You", text: "Mic stays put", timestamp: 35),
        ]

        let result = SpeakerReattribution.reattributeEntries(entries, speakers: speakers)

        #expect(result.entries[0].speaker == "Person 1") // offline namespace
        #expect(result.entries[1].speaker == "Unknown speaker 1")
        #expect(result.entries[2].speaker == "Unknown speaker 1")
        #expect(result.entries[3].speaker == "You")
        #expect(result.leftoverLabelsByOriginalLabel == ["Person 1": "Unknown speaker 1"])
    }
}
