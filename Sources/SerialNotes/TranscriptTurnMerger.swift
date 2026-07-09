import Foundation

/// Collapses consecutive same-speaker entries into one conversational turn for
/// rendering, so a speaker's natural mid-thought pauses don't fragment the
/// transcript into staccato blocks.
///
/// Segmentation upstream stays deliberately fine-grained — short segments are
/// what keep midpoint speaker attribution accurate on the shared system channel
/// (`FinalTranscriptSegmenter`) — so this merge runs at render time only, after
/// attribution, echo filtering, and label normalization. The exact per-fragment
/// entries survive unmerged for offline re-attribution and clip extraction,
/// which depend on their sub-second timings.
enum TranscriptTurnMerger {
    /// A new block still starts after this much true silence (the gap between
    /// one entry's audio end and the next one's start), so timestamps stay
    /// useful as navigation anchors within a long recording.
    static let maxSilenceGap: TimeInterval = 30

    /// Merge consecutive same-speaker/same-source entries of a sorted list.
    ///
    /// `boundary` is a timestamp merging must never cross (the auto-stop summary
    /// cutoff): `TranscriptFormatter.summaryInput` includes or drops *whole*
    /// blocks by their header timestamp, so a block that started before the
    /// cutoff but absorbed post-cutoff fragments would smuggle post-call speech
    /// into the summary input. Breaking the run at the boundary keeps the
    /// cutoff's per-fragment precision.
    static func mergedTurns(
        _ entries: [TranscriptEntry],
        maxSilenceGap: TimeInterval = maxSilenceGap,
        boundary: TimeInterval? = nil
    ) -> [TranscriptEntry] {
        var merged: [TranscriptEntry] = []
        merged.reserveCapacity(entries.count)

        // The open run: text accumulates in place (amortized O(total text) —
        // rebuilding the merged entry per fragment would copy the accumulated
        // head once per fragment, quadratic over a long monologue).
        var runFirst: TranscriptEntry?
        var runText = ""
        var runEnd: TimeInterval = 0

        func closeRun() {
            guard let first = runFirst else { return }
            merged.append(TranscriptEntry(
                source: first.source,
                speaker: first.speaker,
                text: runText,
                timestamp: first.timestamp,
                end: runEnd
            ))
            runFirst = nil
        }

        for entry in entries {
            let continuesRun: Bool
            if let first = runFirst {
                continuesRun = first.speaker == entry.speaker
                    && first.source == entry.source
                    && entry.timestamp - runEnd <= maxSilenceGap
                    && !crossesBoundary(runStart: first.timestamp, next: entry.timestamp, boundary: boundary)
            } else {
                continuesRun = false
            }

            if continuesRun {
                appendFragment(entry.text, to: &runText)
                runEnd = max(runEnd, entry.end)
            } else {
                closeRun()
                runFirst = entry
                runText = entry.text
                runEnd = entry.end
            }
        }
        closeRun()
        return merged
    }

    private static func crossesBoundary(
        runStart: TimeInterval,
        next: TimeInterval,
        boundary: TimeInterval?
    ) -> Bool {
        guard let boundary else { return false }
        return runStart <= boundary && next > boundary
    }

    /// Appends with a space, except when the fragment opens with punctuation —
    /// an orphaned "." that survived segmentation lands flush against the
    /// accumulated text's last word. If that text *already* ends in punctuation,
    /// the fragment's leading mark is ASR noise: strip it instead of rendering
    /// a doubled "check.. Okay".
    private static func appendFragment(_ fragment: String, to text: inout String) {
        guard !fragment.isEmpty else { return }
        guard !text.isEmpty else {
            text = fragment
            return
        }

        let punctuation = TranscriptTextProcessing.leftBindingPunctuation
        guard let first = fragment.first, punctuation.contains(first) else {
            text += " "
            text += fragment
            return
        }

        if let last = text.last, punctuation.contains(last) {
            let stripped = fragment.drop { punctuation.contains($0) || $0.isWhitespace }
            guard !stripped.isEmpty else { return }
            text += " "
            text += stripped
        } else {
            text += fragment
        }
    }
}
