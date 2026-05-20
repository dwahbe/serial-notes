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

        let titleFormatter = DateFormatter()
        titleFormatter.dateFormat = "yyyy-MM-dd 'at' h:mm a"
        titleFormatter.locale = Locale(identifier: "en_US_POSIX")

        let dateString = dateFormatter.string(from: date)
        let titleString = titleFormatter.string(from: date)
        let durationString = formatDuration(duration)

        return """
        ---
        date: \(dateString)
        duration: \(durationString)
        ---

        # Meeting — \(titleString)


        """
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
        guard line.hasPrefix("**"),
              let open = line.range(of: " ("),
              let close = line.range(of: "):", range: open.upperBound..<line.endIndex) else {
            return nil
        }
        let raw = String(line[open.upperBound..<close.lowerBound])
        let parts = raw.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
    }
}
