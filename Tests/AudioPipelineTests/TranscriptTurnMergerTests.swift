import Foundation
import Testing

@testable import SerialNotes

@Suite("Transcript Turn Merger")
struct TranscriptTurnMergerTests {
    @Test("Merges consecutive same-speaker fragments into one turn")
    func mergesConsecutiveFragments() {
        let entries = [
            entry("Pat", "long day yesterday and started some new", at: 74, end: 78),
            entry("Pat", "Medication for acid reflux and things, which", at: 79, end: 83),
            entry("Pat", "is", at: 84, end: 85)
        ]

        let merged = TranscriptTurnMerger.mergedTurns(entries)

        #expect(merged.count == 1)
        #expect(merged.first?.text == "long day yesterday and started some new Medication for acid reflux and things, which is")
        #expect(merged.first?.timestamp == 74)
        #expect(merged.first?.end == 85)
    }

    @Test("Keeps blocks separate across a speaker change")
    func keepsSpeakerChangesSeparate() {
        let entries = [
            entry("Pat", "Hello", at: 59, end: 60),
            entry("You", "Hello, how are you doing?", at: 62, end: 64, source: .mic),
            entry("Pat", "I am very tired", at: 65, end: 67)
        ]

        let merged = TranscriptTurnMerger.mergedTurns(entries)

        #expect(merged.map(\.text) == ["Hello", "Hello, how are you doing?", "I am very tired"])
    }

    @Test("Starts a new block after a long silence")
    func splitsOnLongSilence() {
        let entries = [
            entry("Pat", "Talk to you later.", at: 100, end: 102),
            entry("Pat", "Anyway, as I was saying.", at: 140, end: 143)
        ]

        let merged = TranscriptTurnMerger.mergedTurns(entries)

        #expect(merged.count == 2)
        #expect(merged.map(\.timestamp) == [100, 140])
    }

    @Test("Merges across a pause within the silence threshold")
    func mergesWithinSilenceThreshold() {
        let entries = [
            entry("Pat", "Let me pull that up.", at: 100, end: 102),
            entry("Pat", "Okay, here it is.", at: 125, end: 127)
        ]

        let merged = TranscriptTurnMerger.mergedTurns(entries)

        #expect(merged.count == 1)
        #expect(merged.first?.text == "Let me pull that up. Okay, here it is.")
    }

    @Test("Does not merge the same label across channels")
    func keepsSourcesSeparate() {
        let entries = [
            entry("Sam", "in the room", at: 10, end: 12, source: .mic),
            entry("Sam", "on the call", at: 13, end: 15, source: .system)
        ]

        let merged = TranscriptTurnMerger.mergedTurns(entries)

        #expect(merged.count == 2)
    }

    @Test("Joins an orphaned leading punctuation fragment without a space")
    func joinsLeadingPunctuationFlush() {
        let entries = [
            entry("Pat", "Hello", at: 59, end: 60),
            entry("Pat", ". I am very tired", at: 65, end: 67)
        ]

        let merged = TranscriptTurnMerger.mergedTurns(entries)

        #expect(merged.count == 1)
        #expect(merged.first?.text == "Hello. I am very tired")
    }

    @Test("Gap is measured from the previous entry's end, not its start")
    func gapUsesEndTiming() {
        // Start-to-start distance is 40s (> threshold) but the first utterance
        // runs 30s, so true silence is only 10s — the end-based gap must merge.
        // Pins the exact behavior TranscriptEntry.end exists to enable; a
        // regression to start-to-start measurement fails here and nowhere else.
        let entries = [
            entry("Pat", "a rather long uninterrupted thought", at: 100, end: 130),
            entry("Pat", "with a short pause before the coda", at: 140, end: 145)
        ]

        let merged = TranscriptTurnMerger.mergedTurns(entries)

        #expect(merged.count == 1)
        #expect(merged.first?.end == 145)
    }

    @Test("Never merges across the summary-cutoff boundary")
    func boundaryBreaksRun() {
        let entries = [
            entry("You", "Alright, talk soon. Bye.", at: 100, end: 102),
            entry("You", "God, that was painful.", at: 106, end: 108)
        ]

        let merged = TranscriptTurnMerger.mergedTurns(entries, boundary: 104)

        #expect(merged.count == 2)
        #expect(merged.map(\.timestamp) == [100, 106])
    }

    @Test("Entries on the same side of the boundary still merge")
    func boundaryOnlyBreaksStraddlingRuns() {
        let entries = [
            entry("You", "before one", at: 90, end: 92),
            entry("You", "before two", at: 95, end: 97),
            entry("You", "after one", at: 106, end: 108),
            entry("You", "after two", at: 111, end: 113)
        ]

        let merged = TranscriptTurnMerger.mergedTurns(entries, boundary: 100)

        #expect(merged.map(\.text) == ["before one before two", "after one after two"])
    }

    @Test("Strips a redundant leading mark instead of doubling punctuation")
    func stripsRedundantLeadingPunctuation() {
        let entries = [
            entry("Pat", "Let me check.", at: 10, end: 12),
            entry("Pat", ". Okay here it is", at: 14, end: 16)
        ]

        let merged = TranscriptTurnMerger.mergedTurns(entries)

        #expect(merged.first?.text == "Let me check. Okay here it is")
    }

    @Test("A pure-punctuation fragment vanishes into an already-punctuated turn")
    func dropsPurePunctuationFragment() {
        let entries = [
            entry("Pat", "Hello.", at: 10, end: 11),
            entry("Pat", ".", at: 13, end: 14),
            entry("Pat", "How are you?", at: 15, end: 17)
        ]

        let merged = TranscriptTurnMerger.mergedTurns(entries)

        #expect(merged.count == 1)
        #expect(merged.first?.text == "Hello. How are you?")
        #expect(merged.first?.end == 17)
    }

    @Test("Entries without end timings fall back to conservative start-to-start gaps")
    func unknownEndTimingsStayConservative() {
        // Default end == timestamp, so the measured gap includes the first
        // entry's speech and overestimates the silence — 40s apart must not merge.
        let entries = [
            entry("Pat", "First thought", at: 100),
            entry("Pat", "Second thought", at: 140)
        ]

        let merged = TranscriptTurnMerger.mergedTurns(entries)

        #expect(merged.count == 2)
    }

    private func entry(
        _ speaker: String,
        _ text: String,
        at timestamp: TimeInterval,
        end: TimeInterval? = nil,
        source: AudioSide = .system
    ) -> TranscriptEntry {
        TranscriptEntry(source: source, speaker: speaker, text: text, timestamp: timestamp, end: end)
    }
}
