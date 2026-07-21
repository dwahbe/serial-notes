import Foundation

/// Computes the single text replacement that toggles an inline Markdown style
/// around a selection, Obsidian-style. Pure and stateless: detection consumes
/// `MarkdownInlineParser` spans (never a parallel grammar), and every wrap is
/// re-parsed to confirm the parser will actually render it — anything it
/// wouldn't (intraword `~~`/`==`, delimiter runs merging with neighbors, …)
/// becomes a no-op (`nil`) instead of literal marker noise.
enum MarkdownInlineToggle {
    enum Style: Equatable {
        case bold
        case italic
        case code
        case strikethrough
        case highlight
        case link
    }

    struct Edit: Equatable {
        let range: NSRange
        let replacement: String
        /// Selection in post-edit coordinates.
        let selectionAfter: NSRange
    }

    /// Nil means "no sensible toggle here" — the caller should treat the
    /// shortcut as consumed but make no edit.
    static func edit(for style: Style, selection: NSRange, in text: String) -> Edit? {
        let source = text as NSString
        let clamped = clamp(selection, to: source.length)

        // Inline rules never cross a newline, so the toggle works on the line
        // containing the selection start. A selection reaching only into that
        // line's terminator is tolerated (triple-click selects the newline
        // too); one reaching the next line's text is not.
        let line = source.lineRange(for: NSRange(location: clamped.location, length: 0))
        guard NSMaxRange(clamped) <= NSMaxRange(line) else { return nil }
        let lineContent = contentRange(ofLine: line, in: source)
        let selectionStart = min(clamped.location, NSMaxRange(lineContent))
        let selectionEnd = min(NSMaxRange(clamped), NSMaxRange(lineContent))
        let effective = NSRange(
            location: selectionStart,
            length: max(0, selectionEnd - selectionStart)
        )

        let spans = MarkdownInlineParser.flattenedSpans(in: text, range: lineContent)

        if let span = innermostSpan(carrying: style, containing: effective, in: spans) {
            return unwrapEdit(for: style, span: span, selection: effective, source: source)
        }
        if effective.length == 0 {
            return caretEdit(for: style, at: effective.location, source: source, lineContent: lineContent)
        }
        return wrapEdit(for: style, selection: effective, spans: spans, text: text, source: source)
    }

    // MARK: - Unwrap

    /// Removes (or, for boldItalic, shrinks) the enclosing span's markers,
    /// mapping the selection into the surviving content. Delimiter-agnostic:
    /// `__bold__` and `~~strike~~` unwrap through the same `syntaxRanges`.
    private static func unwrapEdit(
        for style: Style,
        span: MarkdownInlineParser.Span,
        selection: NSRange,
        source: NSString
    ) -> Edit? {
        let content = source.substring(with: span.contentRange)

        // Toggling one half of a boldItalic span shrinks the markers instead
        // of removing them: ***x*** + bold → *x*, + italic → **x**.
        if span.kind == .boldItalic, style == .bold || style == .italic {
            let keep = style == .bold ? 1 : 2
            let delimiter = source.substring(
                with: NSRange(location: span.syntaxRanges[0].location, length: 1)
            )
            let side = String(repeating: delimiter, count: keep)
            return Edit(
                range: span.range,
                replacement: side + content + side,
                selectionAfter: mapped(
                    selection,
                    from: span.contentRange,
                    toContentStart: span.range.location + keep
                )
            )
        }

        return Edit(
            range: span.range,
            replacement: content,
            selectionAfter: mapped(
                selection,
                from: span.contentRange,
                toContentStart: span.range.location
            )
        )
    }

    /// Shifts `selection` from the old content position to `newStart`,
    /// clamping endpoints that sat on the removed markers to the content edge.
    private static func mapped(
        _ selection: NSRange,
        from contentRange: NSRange,
        toContentStart newStart: Int
    ) -> NSRange {
        let start = min(max(selection.location, contentRange.location), NSMaxRange(contentRange))
        let end = min(max(NSMaxRange(selection), contentRange.location), NSMaxRange(contentRange))
        return NSRange(location: newStart + (start - contentRange.location), length: end - start)
    }

    // MARK: - Caret (empty selection)

    private static func caretEdit(
        for style: Style,
        at caret: Int,
        source: NSString,
        lineContent: NSRange
    ) -> Edit? {
        switch style {
        case .bold, .italic:
            return emphasisCaretEdit(for: style, at: caret, source: source, lineContent: lineContent)

        case .strikethrough, .highlight, .code:
            let marker = marker(for: style)
            let delimiter = (marker as NSString).character(at: 0)
            if let removal = exactPairRemoval(
                marker: marker,
                delimiter: delimiter,
                at: caret,
                source: source,
                lineContent: lineContent
            ) {
                return removal
            }
            // A fresh pair next to the same delimiter character would merge
            // runs into something unparseable — no-op instead.
            guard !adjacentCharacter(at: caret, in: source, within: lineContent, equals: delimiter)
            else { return nil }
            return Edit(
                range: NSRange(location: caret, length: 0),
                replacement: marker + marker,
                selectionAfter: NSRange(location: caret + (marker as NSString).length, length: 0)
            )

        case .link:
            // `[⎸]()` is the artifact the insertion below creates; toggle it
            // back off. (A filled-in link is a real span and unwraps above.)
            if caret - 1 >= lineContent.location,
               caret + 3 <= NSMaxRange(lineContent),
               source.substring(with: NSRange(location: caret - 1, length: 4)) == "[]()"
            {
                return Edit(
                    range: NSRange(location: caret - 1, length: 4),
                    replacement: "",
                    selectionAfter: NSRange(location: caret - 1, length: 0)
                )
            }
            return Edit(
                range: NSRange(location: caret, length: 0),
                replacement: "[]()",
                selectionAfter: NSRange(location: caret + 1, length: 0)
            )
        }
    }

    /// Bold/italic at a caret operate on the symmetric `*`/`_` run around it —
    /// the empty pairs this feature inserts are invisible to the parser (empty
    /// content never parses), so the run *is* the state: `⎸` + bold → `**⎸**`,
    /// `**⎸**` + italic → `***⎸***`, `***⎸***` + bold → `*⎸*`, and removal
    /// when the toggled style's marker count reaches zero.
    private static func emphasisCaretEdit(
        for style: Style,
        at caret: Int,
        source: NSString,
        lineContent: NSRange
    ) -> Edit? {
        let lineStart = lineContent.location
        let lineEnd = NSMaxRange(lineContent)

        var runCharacter: unichar = 0
        var beforeCount = 0
        if caret > lineStart {
            let character = source.character(at: caret - 1)
            if character == CharacterCode.asterisk || character == CharacterCode.underscore {
                runCharacter = character
                var index = caret
                while index > lineStart, source.character(at: index - 1) == character {
                    index -= 1
                    beforeCount += 1
                }
            }
        }

        if runCharacter == 0 {
            // No run before the caret; one immediately after would merge with
            // a fresh pair's markers — no-op instead of run soup.
            if caret < lineEnd {
                let character = source.character(at: caret)
                if character == CharacterCode.asterisk || character == CharacterCode.underscore {
                    return nil
                }
            }
            let marker = marker(for: style)
            return Edit(
                range: NSRange(location: caret, length: 0),
                replacement: marker + marker,
                selectionAfter: NSRange(location: caret + (marker as NSString).length, length: 0)
            )
        }

        var afterCount = 0
        var index = caret
        while index < lineEnd, source.character(at: index) == runCharacter {
            index += 1
            afterCount += 1
        }
        guard beforeCount == afterCount, (1...3).contains(beforeCount) else { return nil }

        let count = beforeCount
        let carriesBold = count >= 2
        let carriesItalic = count == 1 || count == 3
        let newCount: Int
        switch style {
        case .bold: newCount = carriesBold ? count - 2 : count + 2
        case .italic: newCount = carriesItalic ? count - 1 : count + 1
        default: return nil
        }
        // newCount stays in 0...3 for every count in 1...3 by construction.
        let side = String(repeating: source.substring(
            with: NSRange(location: caret - 1, length: 1)
        ), count: newCount)
        return Edit(
            range: NSRange(location: caret - count, length: 2 * count),
            replacement: side + side,
            selectionAfter: NSRange(location: caret - count + newCount, length: 0)
        )
    }

    /// Removes the exact empty `~~⎸~~` / `==⎸==` / `` `⎸` `` artifact, without
    /// biting into longer delimiter runs.
    private static func exactPairRemoval(
        marker: String,
        delimiter: unichar,
        at caret: Int,
        source: NSString,
        lineContent: NSRange
    ) -> Edit? {
        let length = (marker as NSString).length
        let start = caret - length
        let end = caret + length
        guard start >= lineContent.location,
              end <= NSMaxRange(lineContent),
              source.substring(with: NSRange(location: start, length: length)) == marker,
              source.substring(with: NSRange(location: caret, length: length)) == marker,
              start == lineContent.location || source.character(at: start - 1) != delimiter,
              end == NSMaxRange(lineContent) || source.character(at: end) != delimiter
        else { return nil }
        return Edit(
            range: NSRange(location: start, length: 2 * length),
            replacement: "",
            selectionAfter: NSRange(location: start, length: 0)
        )
    }

    // MARK: - Wrap

    private static func wrapEdit(
        for style: Style,
        selection: NSRange,
        spans: [MarkdownInlineParser.Span],
        text: String,
        source: NSString
    ) -> Edit? {
        // Wrapping across a link would either destroy its destination (if
        // absorbed) or nest brackets the parser rejects — no-op.
        if style == .link {
            let touchesLink = spans.contains {
                isLink($0.kind) && NSIntersectionRange($0.range, selection).length > 0
            }
            if touchesLink { return nil }
        }

        // Same-kind spans the selection overlaps or touches are absorbed into
        // the wrap ("**a**b" + bold over "b" → "**ab**"); leaving their
        // markers in place would merge delimiter runs into unparseable text.
        var union = selection
        var absorbed: [MarkdownInlineParser.Span] = []
        for span in spans where matchesExactly(span.kind, style) {
            let touches = NSIntersectionRange(span.range, selection).length > 0
                || NSMaxRange(span.range) == selection.location
                || NSMaxRange(selection) == span.range.location
            if touches {
                absorbed.append(span)
                union = NSUnionRange(union, span.range)
            }
        }

        // Markers must sit immediately against non-whitespace, so the wrap
        // excludes the selection's whitespace edges.
        var start = union.location
        var end = NSMaxRange(union)
        while start < end, isWhitespace(source.character(at: start)) { start += 1 }
        while end > start, isWhitespace(source.character(at: end - 1)) { end -= 1 }
        guard start < end else { return nil }

        let range = NSRange(location: start, length: end - start)
        let core = strippedContent(of: range, absorbing: absorbed, source: source)
        let coreSource = core as NSString
        let coreLength = coreSource.length

        switch style {
        case .bold, .italic, .strikethrough, .highlight:
            let marker = marker(for: style)
            let markerLength = (marker as NSString).length
            let edit = Edit(
                range: range,
                replacement: marker + core + marker,
                selectionAfter: NSRange(location: start + markerLength, length: coreLength)
            )
            return validated(edit, style: style, text: text)

        case .code:
            // The fence must be one longer than any backtick run inside the
            // content (capped at the grammar's 3), and content edges touching
            // a backtick would merge into the fence.
            guard coreLength > 0,
                  coreSource.character(at: 0) != CharacterCode.backtick,
                  coreSource.character(at: coreLength - 1) != CharacterCode.backtick
            else { return nil }
            let fence = maxRun(of: CharacterCode.backtick, in: coreSource) + 1
            guard fence <= 3 else { return nil }
            let fenceString = String(repeating: "`", count: fence)
            let edit = Edit(
                range: range,
                replacement: fenceString + core + fenceString,
                selectionAfter: NSRange(location: start + fence, length: coreLength)
            )
            return validated(edit, style: style, text: text)

        case .link:
            // `[core](⎸)` — caret lands in the destination. Not validated: an
            // empty destination deliberately stays literal until typed.
            guard coreSource.rangeOfCharacter(
                from: CharacterSet(charactersIn: "[]()")
            ).location == NSNotFound
            else { return nil }
            return Edit(
                range: range,
                replacement: "[" + core + "](" + ")",
                selectionAfter: NSRange(location: start + 1 + coreLength + 2, length: 0)
            )
        }
    }

    /// Rebuilds `range`'s text with the absorbed spans' markers dropped.
    private static func strippedContent(
        of range: NSRange,
        absorbing spans: [MarkdownInlineParser.Span],
        source: NSString
    ) -> String {
        let cuts = spans
            .flatMap(\.syntaxRanges)
            .filter { $0.location >= range.location && NSMaxRange($0) <= NSMaxRange(range) }
            .sorted { $0.location < $1.location }
        var result = ""
        var cursor = range.location
        for cut in cuts {
            if cut.location > cursor {
                result += source.substring(
                    with: NSRange(location: cursor, length: cut.location - cursor)
                )
            }
            cursor = max(cursor, NSMaxRange(cut))
        }
        if cursor < NSMaxRange(range) {
            result += source.substring(
                with: NSRange(location: cursor, length: NSMaxRange(range) - cursor)
            )
        }
        return result
    }

    /// Re-parses the edited line and requires a span carrying `style` whose
    /// content is exactly the wrapped selection — the parser is the only
    /// authority on whether inserted markers actually render.
    private static func validated(_ edit: Edit, style: Style, text: String) -> Edit? {
        let newText = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        let newSource = newText as NSString
        let anchor = min(edit.selectionAfter.location, newSource.length)
        let line = newSource.lineRange(for: NSRange(location: anchor, length: 0))
        let lineContent = contentRange(ofLine: line, in: newSource)
        let spans = MarkdownInlineParser.flattenedSpans(in: newText, range: lineContent)
        guard spans.contains(where: {
            carries($0.kind, style) && $0.contentRange == edit.selectionAfter
        })
        else { return nil }
        return edit
    }

    // MARK: - Span matching

    /// Whether a span of `kind` renders `style` (boldItalic carries both).
    private static func carries(_ kind: MarkdownInlineParser.Kind, _ style: Style) -> Bool {
        switch style {
        case .bold: kind == .bold || kind == .boldItalic
        case .italic: kind == .italic || kind == .boldItalic
        case .code: kind == .code
        case .strikethrough: kind == .strikethrough
        case .highlight: kind == .highlight
        case .link: isLink(kind)
        }
    }

    /// Exact-kind match used for merge-wrap absorption (a boldItalic span is
    /// never absorbed by a plain bold wrap — its italic half must survive).
    private static func matchesExactly(_ kind: MarkdownInlineParser.Kind, _ style: Style) -> Bool {
        switch style {
        case .bold: kind == .bold
        case .italic: kind == .italic
        case .code: kind == .code
        case .strikethrough: kind == .strikethrough
        case .highlight: kind == .highlight
        case .link: isLink(kind)
        }
    }

    private static func isLink(_ kind: MarkdownInlineParser.Kind) -> Bool {
        if case .link = kind { return true }
        return false
    }

    private static func innermostSpan(
        carrying style: Style,
        containing selection: NSRange,
        in spans: [MarkdownInlineParser.Span]
    ) -> MarkdownInlineParser.Span? {
        spans
            .filter { carries($0.kind, style) && contains($0.range, selection) }
            .min { $0.range.length < $1.range.length }
    }

    private static func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    // MARK: - Text utilities

    private static func marker(for style: Style) -> String {
        switch style {
        case .bold: "**"
        case .italic: "*"
        case .strikethrough: "~~"
        case .highlight: "=="
        case .code: "`"
        case .link: ""
        }
    }

    private static func contentRange(ofLine line: NSRange, in source: NSString) -> NSRange {
        var end = NSMaxRange(line)
        while end > line.location, isNewline(source.character(at: end - 1)) { end -= 1 }
        return NSRange(location: line.location, length: end - line.location)
    }

    private static func adjacentCharacter(
        at caret: Int,
        in source: NSString,
        within line: NSRange,
        equals character: unichar
    ) -> Bool {
        (caret > line.location && source.character(at: caret - 1) == character)
            || (caret < NSMaxRange(line) && source.character(at: caret) == character)
    }

    private static func maxRun(of character: unichar, in source: NSString) -> Int {
        var longest = 0
        var current = 0
        for index in 0..<source.length {
            if source.character(at: index) == character {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        return NSRange(location: location, length: min(max(range.length, 0), length - location))
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isNewline(_ character: unichar) -> Bool {
        character == 10 || character == 13 || character == 0x2028 || character == 0x2029
    }

    private enum CharacterCode {
        static let asterisk: unichar = 42
        static let underscore: unichar = 95
        static let backtick: unichar = 96
    }
}
