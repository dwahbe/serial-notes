import Foundation

/// The small inline-Markdown grammar shared by the live notepad and Apple Notes
/// export. It intentionally stops at the syntax useful in a meeting notepad:
/// emphasis, code, strike-through, highlights, links, and escaped punctuation.
/// Vault-oriented extensions (wiki links, embeds, tags, math, and footnotes) stay
/// literal text.
enum MarkdownInlineParser {
    enum Kind: Equatable {
        case bold
        case italic
        case boldItalic
        case strikethrough
        case highlight
        case code
        case link(destination: String)
        case escape
    }

    struct Span: Equatable {
        let kind: Kind
        let range: NSRange
        let contentRange: NSRange
        let syntaxRanges: [NSRange]
        let children: [Span]

        var flattened: [Span] {
            [self] + children.flatMap(\.flattened)
        }
    }

    static func spans(in text: String, range: NSRange? = nil) -> [Span] {
        let source = text as NSString
        let requested = range ?? NSRange(location: 0, length: source.length)
        let location = min(max(requested.location, 0), source.length)
        let length = min(requested.length, max(0, source.length - location))
        return Parser(source: source).parse(NSRange(location: location, length: length))
    }

    static func flattenedSpans(in text: String, range: NSRange? = nil) -> [Span] {
        spans(in: text, range: range).flatMap(\.flattened)
    }

    static func html(from text: String) -> String {
        let source = text as NSString
        let parser = Parser(source: source)
        let fullRange = NSRange(location: 0, length: source.length)
        return renderHTML(in: fullRange, spans: parser.parse(fullRange), source: source)
    }

    /// The canonical delimiter string for each delimiter-based kind — the one
    /// home of the marker table, consumed by `MarkdownInlineToggle` so the
    /// grammar and the shortcuts can't drift. Bracket syntaxes (link, escape)
    /// have no delimiter; reaching them here is caller error.
    static func marker(for kind: Kind) -> String {
        switch kind {
        case .bold: "**"
        case .italic: "*"
        case .boldItalic: "***"
        case .strikethrough: "~~"
        case .highlight: "=="
        case .code: "`"
        case .link, .escape: preconditionFailure("\(kind) is not a delimiter kind")
        }
    }

    /// Whether the character at `index` is backslash-escaped (an odd run of
    /// backslashes precedes it). Shared with the toggle's caret-run scans so
    /// an escaped delimiter is never mistaken for a live marker.
    static func isEscaped(at index: Int, in source: NSString) -> Bool {
        var slashCount = 0
        var cursor = index
        while cursor > 0, source.character(at: cursor - 1) == CharacterCode.backslash {
            slashCount += 1
            cursor -= 1
        }
        return slashCount.isMultiple(of: 2) == false
    }

    /// `line` minus its trailing line-break characters — the single notion of
    /// a line's content shared by the toggle and the live editor (both strip
    /// U+2028/U+2029 alongside \n and \r).
    static func contentRange(ofLine line: NSRange, in source: NSString) -> NSRange {
        var end = NSMaxRange(line)
        while end > line.location, CharacterCode.isNewline(source.character(at: end - 1)) {
            end -= 1
        }
        return NSRange(location: line.location, length: end - line.location)
    }

    private static func renderHTML(in range: NSRange, spans: [Span], source: NSString) -> String {
        var html = ""
        var cursor = range.location
        for span in spans where span.range.location >= range.location && NSMaxRange(span.range) <= NSMaxRange(range) {
            if span.range.location > cursor {
                html += escapeHTML(source.substring(with: NSRange(
                    location: cursor,
                    length: span.range.location - cursor
                )))
            }

            let content: String
            switch span.kind {
            case .escape:
                content = escapeHTML(source.substring(with: span.contentRange))
            case .code:
                content = "<code>\(escapeHTML(source.substring(with: span.contentRange)))</code>"
            case let .link(destination):
                let label = renderHTML(in: span.contentRange, spans: span.children, source: source)
                content = "<a href=\"\(escapeHTMLAttribute(destination))\">\(label)</a>"
            case .bold:
                content = "<b>\(renderHTML(in: span.contentRange, spans: span.children, source: source))</b>"
            case .italic:
                content = "<i>\(renderHTML(in: span.contentRange, spans: span.children, source: source))</i>"
            case .boldItalic:
                content = "<b><i>\(renderHTML(in: span.contentRange, spans: span.children, source: source))</i></b>"
            case .strikethrough:
                content = "<s>\(renderHTML(in: span.contentRange, spans: span.children, source: source))</s>"
            case .highlight:
                content = "<mark>\(renderHTML(in: span.contentRange, spans: span.children, source: source))</mark>"
            }
            html += content
            cursor = NSMaxRange(span.range)
        }
        if cursor < NSMaxRange(range) {
            html += escapeHTML(source.substring(with: NSRange(
                location: cursor,
                length: NSMaxRange(range) - cursor
            )))
        }
        return html
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeHTMLAttribute(_ text: String) -> String {
        escapeHTML(text).replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Only web and mail links become live; any other explicit scheme
    /// (javascript:, data:, …) keeps the whole bracket construct literal.
    /// Schemeless (relative) destinations are harmless and stay allowed.
    private static func isAllowedLinkDestination(_ destination: String) -> Bool {
        guard let colon = destination.firstIndex(of: ":") else { return true }
        let scheme = destination[..<colon]
        guard let first = scheme.first, first.isLetter,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." })
        else { return true }
        return ["http", "https", "mailto"].contains(scheme.lowercased())
    }

    private static func unescape(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let nextIndex = text.index(after: index)
            if character == "\\", nextIndex < text.endIndex {
                let next = text[nextIndex]
                if next.unicodeScalars.count == 1,
                   let scalar = next.unicodeScalars.first,
                   scalar.value <= UInt16.max,
                   CharacterCode.isEscapable(unichar(scalar.value))
                {
                    result.append(next)
                    index = text.index(after: nextIndex)
                    continue
                }
            }
            result.append(character)
            index = nextIndex
        }
        return result
    }

    private struct Parser {
        let source: NSString

        func parse(_ range: NSRange) -> [Span] {
            var spans: [Span] = []
            var index = range.location
            let end = NSMaxRange(range)

            while index < end {
                let character = source.character(at: index)
                if character == CharacterCode.backslash,
                   index + 1 < end,
                   CharacterCode.isEscapable(source.character(at: index + 1))
                {
                    spans.append(Span(
                        kind: .escape,
                        range: NSRange(location: index, length: 2),
                        contentRange: NSRange(location: index + 1, length: 1),
                        syntaxRanges: [NSRange(location: index, length: 1)],
                        children: []
                    ))
                    index += 2
                    continue
                }

                if character == CharacterCode.backtick,
                   let span = codeSpan(startingAt: index, before: end)
                {
                    spans.append(span)
                    index = NSMaxRange(span.range)
                    continue
                }

                // Images are intentionally outside the meeting-notepad feature
                // set. Skip a well-formed image as one literal unit so its `[alt]`
                // portion is not accidentally reinterpreted as a normal link.
                if character == CharacterCode.exclamation,
                   index + 1 < end,
                   source.character(at: index + 1) == CharacterCode.openBracket,
                   let imageLink = linkSpan(startingAt: index + 1, before: end)
                {
                    index = NSMaxRange(imageLink.range)
                    continue
                }

                if character == CharacterCode.openBracket,
                   let span = linkSpan(startingAt: index, before: end)
                {
                    spans.append(span)
                    index = NSMaxRange(span.range)
                    continue
                }

                if CharacterCode.isDelimiter(character) {
                    let run = runLength(of: character, from: index, before: end)
                    if let delimiter = delimiter(startingAt: index, before: end),
                       let span = delimitedSpan(delimiter, startingAt: index, before: end)
                    {
                        spans.append(span)
                        index = NSMaxRange(span.range)
                    } else {
                        // A failed marker run stays entirely literal. Skipping the
                        // run prevents the second star in a stray `**` from being
                        // reinterpreted as the start of an italic span.
                        index += run
                    }
                    continue
                }

                index += 1
            }
            return spans
        }

        private func codeSpan(startingAt start: Int, before end: Int) -> Span? {
            let length = runLength(of: CharacterCode.backtick, from: start, before: end)
            guard length <= 3 else { return nil }
            var candidate = start + length
            while candidate + length <= end {
                if CharacterCode.isNewline(source.character(at: candidate)) { return nil }
                if source.character(at: candidate) == CharacterCode.backtick,
                   !isEscaped(candidate),
                   runLength(of: CharacterCode.backtick, from: candidate, before: end) == length
                {
                    let contentRange = NSRange(location: start + length, length: candidate - start - length)
                    guard contentRange.length > 0 else { return nil }
                    return Span(
                        kind: .code,
                        range: NSRange(location: start, length: candidate + length - start),
                        contentRange: contentRange,
                        syntaxRanges: [
                            NSRange(location: start, length: length),
                            NSRange(location: candidate, length: length)
                        ],
                        children: []
                    )
                }
                candidate += max(1, runLength(of: CharacterCode.backtick, from: candidate, before: end))
            }
            return nil
        }

        private func linkSpan(startingAt start: Int, before end: Int) -> Span? {
            var closeBracket = start + 1
            while closeBracket < end {
                let character = source.character(at: closeBracket)
                if CharacterCode.isNewline(character) { return nil }
                if character == CharacterCode.closeBracket, !isEscaped(closeBracket) { break }
                closeBracket += 1
            }
            guard closeBracket > start + 1,
                  closeBracket + 1 < end,
                  source.character(at: closeBracket + 1) == CharacterCode.openParenthesis
            else { return nil }

            // Destinations may contain balanced parentheses (Wikipedia-style
            // "…/Swift_(programming_language)"), so only an unmatched `)`
            // closes the link.
            var closeParenthesis = closeBracket + 2
            var parenthesisDepth = 0
            while closeParenthesis < end {
                let character = source.character(at: closeParenthesis)
                if CharacterCode.isNewline(character) { return nil }
                if character == CharacterCode.openParenthesis, !isEscaped(closeParenthesis) {
                    parenthesisDepth += 1
                }
                if character == CharacterCode.closeParenthesis, !isEscaped(closeParenthesis) {
                    if parenthesisDepth == 0 { break }
                    parenthesisDepth -= 1
                }
                closeParenthesis += 1
            }
            guard closeParenthesis < end, closeParenthesis > closeBracket + 2 else { return nil }

            let contentRange = NSRange(location: start + 1, length: closeBracket - start - 1)
            let destinationRange = NSRange(
                location: closeBracket + 2,
                length: closeParenthesis - closeBracket - 2
            )
            // The stored destination is already unescaped — both consumers (the
            // notepad's .link attribute and the exporter's href) want the real
            // URL, and the scheme check below must see it post-unescape so an
            // escaped colon can't smuggle a script scheme past it.
            let destination = MarkdownInlineParser.unescape(source.substring(with: destinationRange))
            guard MarkdownInlineParser.isAllowedLinkDestination(destination) else { return nil }
            return Span(
                kind: .link(destination: destination),
                range: NSRange(location: start, length: closeParenthesis + 1 - start),
                contentRange: contentRange,
                syntaxRanges: [
                    NSRange(location: start, length: 1),
                    NSRange(location: closeBracket, length: closeParenthesis + 1 - closeBracket)
                ],
                children: parse(contentRange)
            )
        }

        private func delimitedSpan(
            _ delimiter: Delimiter,
            startingAt start: Int,
            before end: Int
        ) -> Span? {
            let contentStart = start + delimiter.length
            guard contentStart < end,
                  !CharacterCode.isWhitespace(source.character(at: contentStart)),
                  canOpen(delimiter, at: start, end: end)
            else { return nil }

            var candidate = contentStart
            while candidate + delimiter.length <= end {
                let character = source.character(at: candidate)
                if CharacterCode.isNewline(character) { return nil }
                if character == delimiter.character,
                   !isEscaped(candidate),
                   runLength(of: delimiter.character, from: candidate, before: end) == delimiter.length,
                   !CharacterCode.isWhitespace(source.character(at: candidate - 1)),
                   canClose(delimiter, at: candidate, end: end)
                {
                    let contentRange = NSRange(location: contentStart, length: candidate - contentStart)
                    return Span(
                        kind: delimiter.kind,
                        range: NSRange(location: start, length: candidate + delimiter.length - start),
                        contentRange: contentRange,
                        syntaxRanges: [
                            NSRange(location: start, length: delimiter.length),
                            NSRange(location: candidate, length: delimiter.length)
                        ],
                        children: parse(contentRange)
                    )
                }
                candidate += max(1, runLength(of: delimiter.character, from: candidate, before: end))
            }
            return nil
        }

        private func delimiter(startingAt index: Int, before end: Int) -> Delimiter? {
            let character = source.character(at: index)
            guard character == CharacterCode.asterisk
                    || character == CharacterCode.underscore
                    || character == CharacterCode.tilde
                    || character == CharacterCode.equals
            else { return nil }

            let run = runLength(of: character, from: index, before: end)
            switch character {
            case CharacterCode.asterisk, CharacterCode.underscore:
                guard run <= 3 else { return Delimiter(character: character, length: run, kind: .italic) }
                let kind: Kind = run == 3 ? .boldItalic : (run == 2 ? .bold : .italic)
                return Delimiter(character: character, length: run, kind: kind)
            case CharacterCode.tilde:
                return run == 2 ? Delimiter(character: character, length: 2, kind: .strikethrough) : nil
            case CharacterCode.equals:
                return run == 2 ? Delimiter(character: character, length: 2, kind: .highlight) : nil
            default:
                return nil
            }
        }

        private func canOpen(_ delimiter: Delimiter, at index: Int, end: Int) -> Bool {
            delimiter.length <= 3 && !isIntrawordRestricted(delimiter, at: index, end: end)
        }

        private func canClose(_ delimiter: Delimiter, at index: Int, end: Int) -> Bool {
            !isIntrawordRestricted(delimiter, at: index, end: end)
        }

        /// `_`, `~`, and `=` refuse to open or close inside a word, so
        /// snake_case, `flag==true==done`, and `x~~y~~z` stay literal. Only `*`
        /// supports intraword emphasis, matching Obsidian.
        private func isIntrawordRestricted(_ delimiter: Delimiter, at index: Int, end: Int) -> Bool {
            guard delimiter.character != CharacterCode.asterisk else { return false }
            return index > 0
                && index + delimiter.length < end
                && CharacterCode.isAlphanumeric(source.character(at: index - 1))
                && CharacterCode.isAlphanumeric(source.character(at: index + delimiter.length))
        }

        private func runLength(of character: unichar, from start: Int, before end: Int) -> Int {
            var index = start
            while index < end, source.character(at: index) == character { index += 1 }
            return index - start
        }

        private func isEscaped(_ index: Int) -> Bool {
            MarkdownInlineParser.isEscaped(at: index, in: source)
        }
    }

    private struct Delimiter {
        let character: unichar
        let length: Int
        let kind: Kind
    }

    enum CharacterCode {
        static let backslash: unichar = 92
        static let asterisk: unichar = 42
        static let underscore: unichar = 95
        static let tilde: unichar = 126
        static let equals: unichar = 61
        static let backtick: unichar = 96
        static let exclamation: unichar = 33
        static let openBracket: unichar = 91
        static let closeBracket: unichar = 93
        static let openParenthesis: unichar = 40
        static let closeParenthesis: unichar = 41

        static func isWhitespace(_ character: unichar) -> Bool {
            guard let scalar = UnicodeScalar(character) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }

        static func isAlphanumeric(_ character: unichar) -> Bool {
            guard let scalar = UnicodeScalar(character) else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }

        static func isNewline(_ character: unichar) -> Bool {
            character == 10 || character == 13 || character == 0x2028 || character == 0x2029
        }

        static func isEscapable(_ character: unichar) -> Bool {
            switch character {
            case 33...47, 58...64, 91...96, 123...126:
                true
            default:
                false
            }
        }

        static func isDelimiter(_ character: unichar) -> Bool {
            character == asterisk || character == underscore || character == tilde || character == equals
        }
    }
}
