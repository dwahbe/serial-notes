import FluidAudio
import Foundation

struct FinalTranscriptSegment {
    let text: String
    let start: TimeInterval
    let end: TimeInterval

    var midpoint: TimeInterval {
        (start + end) / 2
    }
}

enum FinalTranscriptSegmenter {
    private static let segmentGapThreshold: TimeInterval = 1.2
    private static let maxSegmentDuration: TimeInterval = 30
    private static let maxSegmentWords = 80
    private static let minWordsForSentenceBreak = 14

    static func segments(from result: ASRResult) -> [FinalTranscriptSegment] {
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            let text = normalizedText(result.text)
            guard !text.isEmpty else { return [] }
            return [FinalTranscriptSegment(text: text, start: 0, end: result.duration)]
        }

        var segments: [FinalTranscriptSegment] = []
        var current: [TokenTiming] = []
        var currentWordCount = 0

        for timing in timings {
            if let previous = current.last {
                if shouldBreak(
                    before: timing,
                    after: previous,
                    segmentStart: current[0].startTime,
                    wordCount: currentWordCount
                ) {
                    // A pure-punctuation token at a break closes the utterance
                    // being flushed; carrying it into the next segment would
                    // render a leading ". I am very tired". Its timing is
                    // dropped so the closed segment's end (and attribution
                    // midpoint) stays on the last spoken word rather than
                    // stretching across the pause. A redundant mark — the
                    // segment already ends punctuated — is ASR noise and is
                    // dropped rather than rendered as "day.." or "word.,".
                    if isOrphanPunctuation(timing.token) {
                        let trailing = endsWithBindingPunctuation(previous.token) ? "" : timing.token
                        appendSegment(current, trailing: trailing, to: &segments)
                        current.removeAll(keepingCapacity: true)
                        currentWordCount = 0
                        continue
                    }
                    appendSegment(current, to: &segments)
                    current.removeAll(keepingCapacity: true)
                    currentWordCount = 0
                }
            } else if isOrphanPunctuation(timing.token) {
                // A pure-punctuation token must never open a segment. `current`
                // is only empty here at stream start or right after an orphan
                // glue (consecutive punctuation tokens) — bind the mark to the
                // previous segment's text, or drop it when there is nothing to
                // bind to.
                glueTrailingPunctuation(timing.token, onto: &segments)
                continue
            }

            current.append(timing)
            currentWordCount += wordCount(in: timing.token)
        }

        appendSegment(current, to: &segments)
        return segments
    }

    private static func shouldBreak(
        before token: TokenTiming,
        after previous: TokenTiming,
        segmentStart: TimeInterval,
        wordCount: Int
    ) -> Bool {
        let gap = token.startTime - previous.endTime
        if gap >= segmentGapThreshold { return true }

        let duration = previous.endTime - segmentStart
        if duration >= maxSegmentDuration { return true }
        if wordCount >= maxSegmentWords { return true }

        return TranscriptTextProcessing.hasTerminalPunctuation(previous.token) && wordCount >= minWordsForSentenceBreak
    }

    private static func appendSegment(
        _ timings: [TokenTiming],
        trailing: String = "",
        to segments: inout [FinalTranscriptSegment]
    ) {
        guard let first = timings.first, let last = timings.last else { return }
        let text = normalizedText(timings.map(\.token).joined() + trailing)
        guard !text.isEmpty else { return }

        segments.append(FinalTranscriptSegment(
            text: text,
            start: first.startTime,
            end: max(last.endTime, first.startTime)
        ))
    }

    private static func normalizedText(_ text: String) -> String {
        var collapsed = ""
        var previousWasWhitespace = false

        for character in text {
            if character.isWhitespace {
                if !collapsed.isEmpty && !previousWasWhitespace {
                    collapsed.append(" ")
                    previousWasWhitespace = true
                }
            } else {
                if isPunctuation(character), collapsed.last == " " {
                    collapsed.removeLast()
                }
                collapsed.append(character)
                previousWasWhitespace = false
            }
        }

        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func wordCount(in text: String) -> Int {
        // Counts words within a single token, e.g. "Q&A" -> 2; do not unify with whitespace word counts.
        text.split { character in
            !character.isLetter && !character.isNumber
        }.count
    }

    private static func isOrphanPunctuation(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.allSatisfy(isPunctuation)
    }

    private static func endsWithBindingPunctuation(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return isPunctuation(last)
    }

    /// Bind an orphan punctuation token to the most recently emitted segment.
    /// Dropped when there is no previous segment (stream-initial punctuation has
    /// no words to bind to) or the segment already ends punctuated (redundant).
    /// The segment's timing is left untouched for the same reason the break-glue
    /// drops it: attribution midpoints must stay on real speech.
    private static func glueTrailingPunctuation(
        _ token: String,
        onto segments: inout [FinalTranscriptSegment]
    ) {
        guard let last = segments.last, !endsWithBindingPunctuation(last.text) else { return }
        let text = normalizedText(last.text + token)
        guard !text.isEmpty else { return }
        segments[segments.count - 1] = FinalTranscriptSegment(
            text: text,
            start: last.start,
            end: last.end
        )
    }

    private static func isPunctuation(_ character: Character) -> Bool {
        TranscriptTextProcessing.leftBindingPunctuation.contains(character)
    }
}
