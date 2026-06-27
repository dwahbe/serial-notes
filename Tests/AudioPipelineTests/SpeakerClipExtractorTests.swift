import Foundation
import Testing

@testable import SerialNotes

@Suite("Speaker Clip Extractor")
struct SpeakerClipExtractorTests {
    // MARK: - mergedSegments

    @Test("Merges overlapping and near-adjacent segments, sorted")
    func mergesSegments() {
        // Out of order; (2.0–3.0) is within the 0.3s merge gap of (0–2).
        let input = [Segment(start: 2.1, end: 3.0), Segment(start: 0, end: 2.0)]
        let merged = SpeakerClipExtractor.mergedSegments(input)
        #expect(merged == [Segment(start: 0, end: 3.0)])
    }

    @Test("Keeps segments separated by more than the merge gap")
    func keepsDistantSegments() {
        let input = [Segment(start: 0, end: 2.0), Segment(start: 2.5, end: 3.0)]
        let merged = SpeakerClipExtractor.mergedSegments(input)
        #expect(merged == [Segment(start: 0, end: 2.0), Segment(start: 2.5, end: 3.0)])
    }

    @Test("Merges fully-overlapping segments")
    func mergesOverlap() {
        let input = [Segment(start: 0, end: 3.0), Segment(start: 1.0, end: 2.0)]
        let merged = SpeakerClipExtractor.mergedSegments(input)
        #expect(merged == [Segment(start: 0, end: 3.0)])
    }

    // MARK: - clipFrames

    @Test("Converts seconds to frames at 48 kHz")
    func framesAt48k() {
        let frames = SpeakerClipExtractor.clipFrames(
            forSegments: [Segment(start: 0, end: 5)],
            sampleRate: 48_000
        )
        #expect(frames.count == 1)
        #expect(frames[0].start == 0)
        #expect(frames[0].end == 240_000)
    }

    @Test("Converts seconds to frames at 44.1 kHz")
    func framesAt44k() {
        let frames = SpeakerClipExtractor.clipFrames(
            forSegments: [Segment(start: 0, end: 2)],
            sampleRate: 44_100
        )
        #expect(frames.count == 1)
        #expect(frames[0].start == 0)
        #expect(frames[0].end == 88_200)
    }

    @Test("Drops segments shorter than the minimum")
    func dropsShortSegments() {
        let frames = SpeakerClipExtractor.clipFrames(
            forSegments: [Segment(start: 0, end: 0.4)],
            sampleRate: 48_000,
            minSeconds: 0.6,
            maxSeconds: 12
        )
        #expect(frames.isEmpty)
    }

    @Test("Caps the total clip length")
    func capsTotalLength() {
        let frames = SpeakerClipExtractor.clipFrames(
            forSegments: [Segment(start: 0, end: 20)],
            sampleRate: 48_000,
            minSeconds: 0.6,
            maxSeconds: 12
        )
        #expect(frames.count == 1)
        #expect(frames[0].start == 0)
        #expect(frames[0].end == 12 * 48_000)
    }

    @Test("Accumulates chronologically and truncates the last segment at the cap")
    func accumulatesChronologically() {
        let frames = SpeakerClipExtractor.clipFrames(
            forSegments: [Segment(start: 10, end: 18), Segment(start: 0, end: 5)],
            sampleRate: 48_000,
            minSeconds: 0.6,
            maxSeconds: 12
        )
        #expect(frames.count == 2)
        #expect(frames[0].start == 0 && frames[0].end == 5 * 48_000)
        // Second segment contributes only the remaining 7s (10s → 17s).
        #expect(frames[1].start == 10 * 48_000 && frames[1].end == 17 * 48_000)
    }

    @Test("Returns nothing for a non-positive sample rate")
    func zeroSampleRate() {
        let frames = SpeakerClipExtractor.clipFrames(forSegments: [Segment(start: 0, end: 5)], sampleRate: 0)
        #expect(frames.isEmpty)
    }

    // MARK: - parseEntries (inline + block-form)

    @Test("Parses inline and block-form entries, ignoring non-headers")
    func parsesEntries() {
        let transcript = """
        ## Summary

        - Person 2 raised a point.

        - [ ] **Person 1** — follow up

        **Person 1** (00:00:05): Short inline.

        **Person 2** (00:00:09):

        This is the block-form body on the next line.
        """
        let entries = SpeakerClipExtractor.parseEntries(transcript)
        #expect(entries.count == 2)
        #expect(entries[0] == SpeakerClipExtractor.ParsedEntry(label: "Person 1", timestamp: 5, text: "Short inline."))
        #expect(entries[1] == SpeakerClipExtractor.ParsedEntry(
            label: "Person 2", timestamp: 9, text: "This is the block-form body on the next line."
        ))
    }

    @Test("sampleText returns the block-form body for long-only speakers")
    func sampleTextBlockForm() {
        let transcript = "**Person 2** (00:01:23):\n\nA long utterance that wraps onto its own line."
        let sample = SpeakerClipExtractor.sampleText(for: "Person 2", in: transcript)
        #expect(sample == "A long utterance that wraps onto its own line.")
    }

    @Test("Parses timestamps with 3-digit hours")
    func parsesLongTimestamps() throws {
        let line = "**Person 2** (100:00:05): Hi."
        let header = try #require(TranscriptFormatter.parseEntryHeader(line))
        #expect(header.label == "Person 2")
        #expect(header.timestamp == TimeInterval(360_005))
        #expect(SpeakerClipExtractor.entryTimestamps(for: "Person 2", in: line) == [TimeInterval(360_005)])
    }

    // MARK: - segmentsCovering (echo-aware)

    @Test("Keeps only segments near a surviving entry timestamp")
    func segmentsCoveringFiltersEcho() {
        // Speaker has three diarized segments; only the middle one has a surviving
        // transcript line (the others were dropped as echo).
        let segments = [
            Segment(start: 0, end: 4),    // no surviving line nearby → dropped
            Segment(start: 10, end: 14),  // surviving line at t=12 → kept
            Segment(start: 30, end: 34),  // no surviving line nearby → dropped
        ]
        let kept = SpeakerClipExtractor.segmentsCovering(segments, timestamps: [12], tolerance: 1.5)
        #expect(kept == [Segment(start: 10, end: 14)])
    }

    @Test("Returns nothing when no entries survived")
    func segmentsCoveringEmptyTimestamps() {
        let segments = [Segment(start: 0, end: 4)]
        #expect(SpeakerClipExtractor.segmentsCovering(segments, timestamps: []).isEmpty)
    }

    @Test("Only surviving system entries authorize an offline speaker clip")
    func survivingSystemEntriesExcludeMicAndFilteredEchoes() {
        let entries = [
            TranscriptEntry(source: .mic, speaker: "Person 1", text: "local bleed", timestamp: 3),
            TranscriptEntry(source: .system, speaker: "Person 2", text: "remote", timestamp: 8),
        ]
        #expect(SpeakerClipExtractor.survivingSystemEntries(for: "Person 1", in: entries).isEmpty)
        let remote = SpeakerClipExtractor.survivingSystemEntries(for: "Person 2", in: entries)
        #expect(remote.map(\.timestamp) == [8])
    }

    // MARK: - transcriptContainsSpeaker

    @Test("Detects a speaker header but not action-item owners")
    func detectsSpeakerHeader() {
        let transcript = """
        ## Action items

        - [ ] **Person 9** — do the thing

        **Person 2** (00:00:05): Hi.
        """
        #expect(SpeakerClipExtractor.transcriptContainsSpeaker(transcript, label: "Person 2"))
        #expect(!SpeakerClipExtractor.transcriptContainsSpeaker(transcript, label: "Person 9"))
        #expect(!SpeakerClipExtractor.transcriptContainsSpeaker(transcript, label: "Person 1"))
    }

    // MARK: - sampleText

    @Test("Returns the longest inline utterance, truncated")
    func sampleTextLongest() {
        let transcript = """
        **Person 2** (00:00:05): Hi.

        **Person 2** (00:00:09): This is a longer thing that I said in the meeting.
        """
        let sample = SpeakerClipExtractor.sampleText(for: "Person 2", in: transcript)
        #expect(sample == "This is a longer thing that I said in the meeting.")
    }

    @Test("Truncates overly long excerpts with an ellipsis")
    func sampleTextTruncates() {
        let long = String(repeating: "word ", count: 60).trimmingCharacters(in: .whitespaces)
        let transcript = "**Person 1** (00:00:01): \(long)"
        let sample = SpeakerClipExtractor.sampleText(for: "Person 1", in: transcript, maxLength: 40)
        #expect(sample.count <= 41) // 40 + ellipsis
        #expect(sample.hasSuffix("…"))
    }

    // MARK: - Sidecar round-trip

    @Test("Sidecar survives a write/load round-trip")
    func sidecarRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snclip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = SpeakerSidecar(
            version: SpeakerSidecar.currentVersion,
            sessionStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
            speakers: [
                DetectedSpeaker(
                    label: "Person 2",
                    speakerIndex: 2,
                    totalSpeechSeconds: 12.5,
                    sampleRate: 48_000,
                    segments: [Segment(start: 0, end: 5), Segment(start: 10, end: 17)],
                    sampleText: "Hello there",
                    clipFile: "speaker-2.wav",
                    state: .pending,
                    resolvedName: nil
                )
            ]
        )

        try SpeakerClipExtractor.writeSidecar(original, inSessionDirectory: dir)
        let loaded = SpeakerClipExtractor.loadSidecar(inSessionDirectory: dir)
        #expect(loaded == original)
    }
}
