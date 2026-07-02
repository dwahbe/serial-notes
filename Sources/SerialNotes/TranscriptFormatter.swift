import Foundation

enum TranscriptFormatter {
    private static let inlineEntryLimit = 180
    private static let paragraphCharacterLimit = 420
    private static let paragraphSentenceLimit = 3

    /// Produces a fixed-width header so it can be rewritten in place at end-of-session
    /// via `seek(toOffset: 0)`. Duration is always formatted `HHhMMmSSs`.
    static func header(date: Date, duration: TimeInterval) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        let dateString = dateFormatter.string(from: date)
        let durationString = formatDuration(duration)

        return """
        ---
        date: \(dateString)
        duration: \(durationString)
        ---

        # \(meetingTitle(date: date))


        """
    }

    static func meetingTitle(date: Date) -> String {
        let titleFormatter = DateFormatter()
        titleFormatter.dateFormat = "yyyy-MM-dd 'at' h:mm a"
        titleFormatter.locale = Locale(identifier: "en_US_POSIX")
        return "Meeting — \(titleFormatter.string(from: date))"
    }

    /// Invisible sentinel closing the `## Notes` section. Markdown renderers hide
    /// HTML comments, but it gives every entry-grammar consumer an unambiguous
    /// "this region is user prose" boundary — a transcript-style line pasted into
    /// the notes must never masquerade as a real speaker entry (phantom speakers,
    /// truncated relabel region). `MeetingExporter` strips it from exports.
    static let manualNotesEndMarker = "<!-- serial-notes: end notes -->"

    /// Renders user-authored Markdown notes above generated sections. Internal
    /// Markdown is preserved exactly; only outer whitespace is trimmed so empty
    /// drafts don't create a blank section.
    static func manualNotesSection(_ notes: String?) -> String {
        guard let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return ""
        }
        return "## Notes\n\n\(trimmed)\n\n\(manualNotesEndMarker)\n\n"
    }

    /// The line-index range of the manual `## Notes` section — heading through
    /// closing sentinel — in a transcript already split on newlines. Nil when
    /// either bound is missing (no notes, a pre-sentinel transcript, or the user
    /// deleted the marker), in which case callers keep plain grammar scanning.
    static func manualNotesLineRange(in lines: [String]) -> ClosedRange<Int>? {
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "## Notes"
        }) else { return nil }
        guard let end = ((start + 1)..<lines.count).first(where: {
            lines[$0].trimmingCharacters(in: .whitespaces) == manualNotesEndMarker
        }) else { return nil }
        return start...end
    }

    /// Nesting depth of a Markdown list item from its leading whitespace: one
    /// level per tab, one per pair of spaces (a lone trailing space adds none).
    /// The single source of truth for list nesting — `ManualNotesMarkdownEditor`
    /// renders indents/bullets from it and `MeetingExporter` nests `<ul>`/`<ol>`
    /// from it, so what looks nested in the notepad exports nested to Notes.
    static func listIndentLevel(of leadingWhitespace: some StringProtocol) -> Int {
        var level = 0
        var pendingSpaces = 0
        for character in leadingWhitespace {
            if character == "\t" {
                level += 1
                pendingSpaces = 0
            } else if character == " " {
                pendingSpaces += 1
                if pendingSpaces == 2 {
                    level += 1
                    pendingSpaces = 0
                }
            }
        }
        return level
    }

    static func topSections(manualNotes: String?, summary: SummaryResult) -> String {
        manualNotesSection(manualNotes) + summarySections(summary)
    }

    /// Renders the summary + action items sections that go between the header
    /// and the first speaker entry. Returns an empty string when both sections
    /// are empty so callers can splice unconditionally.
    static func summarySections(_ result: SummaryResult) -> String {
        var out = ""
        if !result.summary.isEmpty {
            out += "## Summary\n\n"
            for bullet in result.summary {
                out += "- \(bullet)\n"
            }
            out += "\n"
        }
        if !result.actionItems.isEmpty {
            out += "## Action items\n\n"
            for item in result.actionItems {
                if let owner = item.owner, !owner.isEmpty {
                    out += "- [ ] **\(owner)** — \(item.task)\n"
                } else {
                    out += "- [ ] \(item.task)\n"
                }
            }
            out += "\n"
        }
        return out
    }

    static func entry(speaker: String, timestamp: TimeInterval, text: String) -> String {
        let body = readableBody(text)
        let prefix = "**\(speaker)** (\(formatTimestamp(timestamp)))"
        if body.count <= inlineEntryLimit && !body.contains("\n") {
            return "\(prefix): \(body)\n\n"
        }
        return "\(prefix):\n\n\(body)\n\n"
    }

    static func summaryInput(from body: String, cutoff: TimeInterval?) -> String {
        guard let cutoff else { return body }

        let lines = body.components(separatedBy: "\n")
        var included: [String] = []
        var current: [String] = []
        var currentTimestamp: TimeInterval?

        func flushCurrent() {
            guard !current.isEmpty else { return }
            if let timestamp = currentTimestamp {
                if timestamp <= cutoff {
                    included.append(contentsOf: current)
                }
            } else {
                included.append(contentsOf: current)
            }
            current.removeAll(keepingCapacity: true)
            currentTimestamp = nil
        }

        for line in lines {
            if let timestamp = timestampFromEntryHeader(line) {
                flushCurrent()
                currentTimestamp = timestamp
            }
            current.append(line)
        }
        flushCurrent()

        return included.joined(separator: "\n")
    }

    static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    /// Always 9 characters — `HHhMMmSSs`.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        return String(format: "%02dh%02dm%02ds", hours, minutes, secs)
    }

    private static func readableBody(_ text: String) -> String {
        let normalized = text
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > inlineEntryLimit else { return normalized }

        let sentences = splitSentences(normalized)
        guard sentences.count > 1 else {
            return wordParagraphs(normalized, maxWords: 80).joined(separator: "\n\n")
        }

        var paragraphs: [String] = []
        var current: [String] = []
        var currentCharacters = 0

        for sentence in sentences {
            current.append(sentence)
            currentCharacters += sentence.count

            if current.count >= paragraphSentenceLimit || currentCharacters >= paragraphCharacterLimit {
                paragraphs.append(current.joined(separator: " "))
                current.removeAll(keepingCapacity: true)
                currentCharacters = 0
            }
        }

        if !current.isEmpty {
            paragraphs.append(current.joined(separator: " "))
        }

        return paragraphs.joined(separator: "\n\n")
    }

    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.bySentences, .localized]
        ) { substring, _, _, _ in
            guard let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sentence.isEmpty else {
                return
            }
            sentences.append(sentence)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return sentences.isEmpty && !trimmed.isEmpty ? [trimmed] : sentences
    }

    private static func wordParagraphs(_ text: String, maxWords: Int) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }

        var paragraphs: [String] = []
        var current: [String] = []
        current.reserveCapacity(maxWords)

        for word in words {
            current.append(word)
            if current.count >= maxWords {
                paragraphs.append(current.joined(separator: " "))
                current.removeAll(keepingCapacity: true)
            }
        }

        if !current.isEmpty {
            paragraphs.append(current.joined(separator: " "))
        }
        return paragraphs
    }

    private static func timestampFromEntryHeader(_ line: String) -> TimeInterval? {
        parseEntryHeader(line)?.timestamp
    }

    /// Single source of truth for the transcript entry-header grammar
    /// `**Label** (HH:MM:SS): body`. Returns the speaker label, the timestamp, and the
    /// inline body (empty for block-form headers whose body lives on the following
    /// lines). Returns nil for any line that is not a speaker-entry header — summary
    /// prose, action-item owners (`- [ ] **x** — …`), headings, blank lines. The hour
    /// field may exceed two digits (it is parsed up to the first `):`).
    static func parseEntryHeader(_ line: some StringProtocol) -> (label: String, timestamp: TimeInterval, inlineBody: String)? {
        guard line.hasPrefix("**") else { return nil }
        let afterOpen = line.dropFirst(2)
        guard let boldClose = afterOpen.range(of: "** (") else { return nil }
        let label = String(afterOpen[afterOpen.startIndex..<boldClose.lowerBound])
        guard !label.isEmpty else { return nil }

        let afterParen = afterOpen[boldClose.upperBound...] // "HH:MM:SS): body" or "HH:MM:SS):"
        guard let close = afterParen.range(of: "):") else { return nil }
        let raw = afterParen[afterParen.startIndex..<close.lowerBound] // "HH:MM:SS"
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let hours = Int(parts[0]), let minutes = Int(parts[1]), let seconds = Int(parts[2]) else {
            return nil
        }
        let timestamp = TimeInterval(hours * 3600 + minutes * 60 + seconds)
        let body = afterParen[close.upperBound...].drop(while: { $0 == " " })
        return (label, timestamp, String(body))
    }

    /// Replace only the label token of a speaker-entry header while preserving its
    /// timestamp and body. Keeping this beside `parseEntryHeader` makes the header
    /// grammar a single shared contract for both post-processing paths.
    static func replacingEntryHeaderLabel(
        in line: String,
        from oldLabel: String,
        to newLabel: String
    ) -> String? {
        guard parseEntryHeader(line)?.label == oldLabel else { return nil }
        let oldPrefix = "**\(oldLabel)** ("
        guard line.hasPrefix(oldPrefix) else { return nil }
        return "**\(newLabel)** (" + line.dropFirst(oldPrefix.count)
    }
}
