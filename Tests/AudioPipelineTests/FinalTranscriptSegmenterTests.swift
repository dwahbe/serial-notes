import FluidAudio
import Foundation
import Testing

@testable import SerialNotes

@Suite("Final Transcript Segmenter")
struct FinalTranscriptSegmenterTests {
    @Test("Falls back to result text when token timings are missing")
    func fallbackWithoutTimings() {
        let result = ASRResult(
            text: "Hello world.",
            confidence: 1,
            duration: 4,
            processingTime: 0.1
        )

        let segments = FinalTranscriptSegmenter.segments(from: result)

        #expect(segments.count == 1)
        #expect(segments.first?.text == "Hello world.")
        #expect(segments.first?.start == 0)
        #expect(segments.first?.end == 4)
    }

    @Test("Breaks on timing gaps")
    func breaksOnTimingGaps() {
        let result = ASRResult(
            text: "",
            confidence: 1,
            duration: 8,
            processingTime: 0.1,
            tokenTimings: [
                token(" Hello", start: 0.0, end: 0.2),
                token(" world", start: 0.2, end: 0.4),
                token(".", start: 0.4, end: 0.5),
                token(" Next", start: 2.0, end: 2.2),
                token(" thought", start: 2.2, end: 2.4),
                token(".", start: 2.4, end: 2.5)
            ]
        )

        let segments = FinalTranscriptSegmenter.segments(from: result)

        #expect(segments.map(\.text) == ["Hello world.", "Next thought."])
        #expect(segments.map(\.start) == [0.0, 2.0])
    }

    @Test("Glues orphaned punctuation after a pause to the segment it closes")
    func gluesOrphanPunctuationToPreviousSegment() {
        let result = ASRResult(
            text: "",
            confidence: 1,
            duration: 6,
            processingTime: 0.1,
            tokenTimings: [
                token(" Hello", start: 0.0, end: 0.2),
                token(" .", start: 2.0, end: 2.1),
                token(" I", start: 2.3, end: 2.4),
                token(" am", start: 2.4, end: 2.5),
                token(" tired", start: 2.5, end: 2.8)
            ]
        )

        let segments = FinalTranscriptSegmenter.segments(from: result)

        #expect(segments.map(\.text) == ["Hello.", "I am tired"])
        // The punctuation's own timing is dropped: the closed segment still ends
        // on its last spoken word, and the next segment starts on real speech.
        #expect(segments.map(\.end) == [0.2, 2.8])
        #expect(segments.map(\.start) == [0.0, 2.3])
    }

    @Test("Consecutive orphan punctuation neither doubles nor leads a segment")
    func consecutiveOrphanPunctuation() {
        let result = ASRResult(
            text: "",
            confidence: 1,
            duration: 6,
            processingTime: 0.1,
            tokenTimings: [
                token(" Hello", start: 0.0, end: 0.2),
                token(" .", start: 2.0, end: 2.1),
                token(" ?", start: 2.2, end: 2.3),
                token(" I", start: 2.5, end: 2.6),
                token(" am", start: 2.6, end: 2.8)
            ]
        )

        let segments = FinalTranscriptSegmenter.segments(from: result)

        // The first orphan closes "Hello."; the second is redundant noise and
        // is dropped — it must not double up ("Hello.?") or open the next
        // segment ("? I am").
        #expect(segments.map(\.text) == ["Hello.", "I am"])
        #expect(segments.map(\.start) == [0.0, 2.5])
    }

    @Test("Stream-initial punctuation is dropped, not rendered as a leading mark")
    func streamInitialPunctuationDropped() {
        let result = ASRResult(
            text: "",
            confidence: 1,
            duration: 3,
            processingTime: 0.1,
            tokenTimings: [
                token(" .", start: 0.0, end: 0.1),
                token(" Hello", start: 0.4, end: 0.6),
                token(" there", start: 0.6, end: 0.9)
            ]
        )

        let segments = FinalTranscriptSegmenter.segments(from: result)

        #expect(segments.map(\.text) == ["Hello there"])
        #expect(segments.map(\.start) == [0.4])
    }

    @Test("A redundant orphan mark after an already-punctuated word is dropped")
    func redundantOrphanPunctuationDropped() {
        let result = ASRResult(
            text: "",
            confidence: 1,
            duration: 5,
            processingTime: 0.1,
            tokenTimings: [
                token(" long", start: 0.0, end: 0.3),
                token(" day.", start: 0.3, end: 0.6),
                token(" .", start: 2.0, end: 2.1),
                token(" Next", start: 2.4, end: 2.7)
            ]
        )

        let segments = FinalTranscriptSegmenter.segments(from: result)

        #expect(segments.map(\.text) == ["long day.", "Next"])
    }

    @Test("Normalizes spaces before punctuation")
    func normalizesPunctuationSpacing() {
        let result = ASRResult(
            text: "",
            confidence: 1,
            duration: 2,
            processingTime: 0.1,
            tokenTimings: [
                token(" Hello", start: 0.0, end: 0.1),
                token(" world", start: 0.1, end: 0.2),
                token(" ,", start: 0.2, end: 0.3),
                token(" again", start: 0.3, end: 0.4),
                token(" !", start: 0.4, end: 0.5)
            ]
        )

        let segments = FinalTranscriptSegmenter.segments(from: result)

        #expect(segments.first?.text == "Hello world, again!")
    }

    private func token(_ text: String, start: TimeInterval, end: TimeInterval) -> TokenTiming {
        TokenTiming(
            token: text,
            tokenId: 0,
            startTime: start,
            endTime: end,
            confidence: 1
        )
    }
}
