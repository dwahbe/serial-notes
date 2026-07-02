import AppKit
import SwiftUI

final class ManualNotesTextView: NSTextView {
    struct RenderedBullet: Equatable {
        let lineRange: NSRange
        let indentLevel: Int
    }

    var renderedBullets: [RenderedBullet] = [] {
        didSet {
            if renderedBullets != oldValue {
                needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawRenderedBullets()
    }

    private func drawRenderedBullets() {
        guard !renderedBullets.isEmpty,
              let layoutManager
        else {
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
        let bullet = "•" as NSString
        let bulletSize = bullet.size(withAttributes: attributes)
        let origin = textContainerOrigin
        let indentStep = ManualNotesMarkdownEditor.Coordinator.listIndentStep

        for rendered in renderedBullets where rendered.lineRange.location < string.utf16.count {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: rendered.lineRange,
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else { continue }

            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
            // Each bullet sits inside its own level's gutter, just left of where
            // that level's text begins.
            let point = NSPoint(
                x: origin.x + lineRect.minX + CGFloat(rendered.indentLevel) * indentStep + 2,
                y: origin.y + lineRect.minY + max(0, (lineRect.height - bulletSize.height) / 2) - 1
            )
            bullet.draw(at: point, withAttributes: attributes)
        }
    }
}

struct ManualNotesMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = ManualNotesTextView()
        textView.delegate = context.coordinator
        // Drives uniform line heights (see the delegate method). Touching
        // `layoutManager` also keeps the view on TextKit 1, which the custom bullet
        // drawing already relies on.
        textView.layoutManager?.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        Self.configureNativeTextChecking(on: textView)
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.string = text
        textView.isEditable = isEditable
        textView.isSelectable = true
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.applyMarkdownStyling()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        Self.configureNativeTextChecking(on: textView)
        textView.isEditable = isEditable
        // Restyle only when the string is replaced from outside (store resets,
        // draft carry-forward). On the typing path this update is the echo of
        // textDidChange's own binding write, which already restyled.
        if textView.string != text {
            textView.string = text
            context.coordinator.applyMarkdownStyling()
        }
    }

    private static func configureNativeTextChecking(on textView: NSTextView) {
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = false
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?
        private var applyingStyle = false
        private var applyingAutomaticEdit = false
        /// The paragraph range last styled for the caret position, so a selection
        /// change that stays within the same paragraph skips re-styling entirely.
        private var styledSelectionParagraph: NSRange?

        init(text: Binding<String>) {
            self.text = text
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard !applyingAutomaticEdit,
                  affectedCharRange.length == 0,
                  let replacementString
            else {
                return true
            }

            // Deliberately no auto-conversion when the user types a bare "*": it must
            // stay a literal asterisk so it can also begin italic (`*word*`). A line
            // becomes a bullet only once the user types the space in "* " — handled by
            // the list regex during styling — matching Obsidian / Google Docs / Word.

            if replacementString == "\n",
               let continuation = Self.listContinuation(at: affectedCharRange.location, in: textView.string)
            {
                replaceText(in: continuation.range, with: continuation.replacement, textView: textView)
                return false
            }

            if replacementString == "\t",
               let indentEdit = Self.listIndentEdit(
                   at: affectedCharRange.location,
                   in: textView.string,
                   outdent: false
               )
            {
                replaceText(in: indentEdit.range, with: indentEdit.replacement, textView: textView)
                return false
            }

            return true
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertBacktab(_:)),
                  let indentEdit = Self.listIndentEdit(
                      at: textView.selectedRange().location,
                      in: textView.string,
                      outdent: true
                  )
            else { return false }
            replaceText(in: indentEdit.range, with: indentEdit.replacement, textView: textView)
            return true
        }

        /// Tab / Shift-Tab with the caret on a list line indents or outdents the
        /// whole item (Notes/Bear/Obsidian muscle memory) instead of inserting a
        /// literal tab. Nil when the caret isn't on a list line — the tab stays an
        /// ordinary character — or when outdenting an item that's already at the
        /// top level.
        private static func listIndentEdit(
            at location: Int,
            in text: String,
            outdent: Bool
        ) -> (range: NSRange, replacement: String)? {
            let source = text as NSString
            let safeLocation = min(max(location, 0), source.length)
            let lineRange = contentLineRange(containing: safeLocation, in: source)
            let line = source.substring(with: lineRange)
            guard listRegex.firstMatch(
                in: line,
                range: NSRange(location: 0, length: (line as NSString).length)
            ) != nil else {
                return nil
            }
            if !outdent {
                return (NSRange(location: lineRange.location, length: 0), "\t")
            }
            if line.hasPrefix("\t") {
                return (NSRange(location: lineRange.location, length: 1), "")
            }
            if line.hasPrefix("  ") {
                return (NSRange(location: lineRange.location, length: 2), "")
            }
            return nil
        }

        func textDidChange(_ notification: Notification) {
            // applyingAutomaticEdit: list continuation goes through replaceText,
            // whose defer does this exact write+restyle once the edit is whole.
            guard !applyingStyle, !applyingAutomaticEdit, let textView else { return }
            text.wrappedValue = textView.string
            // A text change can add/remove list lines, so re-run the full pass that
            // rebuilds the document-wide bullet list (it also refreshes the styled-
            // selection bookkeeping). Notes are short, so this is bounded;
            // selection-only changes take the scoped path below.
            applyMarkdownStyling()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applyingStyle, let textView, let storage = textView.textStorage, storage.length > 0
            else { return }
            let para = currentSelectionParagraph(in: textView)
            guard styledSelectionParagraph != para else { return }
            let previous = styledSelectionParagraph
            styledSelectionParagraph = para
            // Only the line(s) the caret entered/left flip syntax reveal — restyle
            // those paragraphs instead of re-regexing the whole document on every
            // arrow key or click. And only when a reveal actually flips: bullet
            // markers are hidden regardless of selection, so dragging across list
            // or plain lines must not touch the storage at all.
            //
            // The mutation is also deferred out of this notification. On macOS 26
            // the text view's glyphs, selection highlight, and spell underlines
            // render through a window-server-managed content layer, and editing
            // storage attributes from inside the selection-change transaction can
            // blank that layer for the selected lines (text invisible while
            // highlighted) — every selection change during a mouse drag lands
            // here, so this path must stay mutation-free.
            var staleRanges: [NSRange] = []
            if let para, revealStateNeedsUpdate(in: para) { staleRanges.append(para) }
            if let previous, previous != para, revealStateNeedsUpdate(in: previous) {
                staleRanges.append(previous)
            }
            guard !staleRanges.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                // Skip while IME composition is live — a restyle would clobber the
                // marked-text underline mid-composition; the next caret move after
                // the composition confirms will re-run this.
                guard let self, let textView = self.textView, !textView.hasMarkedText()
                else { return }
                for range in staleRanges { self.restyleParagraphs(intersecting: range) }
            }
        }

        /// Whether any hidden-syntax run in `range`'s paragraphs must flip between
        /// hidden and revealed for the current selection. Mirrors the reveal policy
        /// in `applyBlockStyle` (headings reveal per line) and `applyInlineStyle`
        /// (bold/italic reveal per match) — keep them in lockstep.
        private func revealStateNeedsUpdate(in range: NSRange) -> Bool {
            guard let textView, let storage = textView.textStorage, storage.length > 0 else { return false }
            let source = storage.string as NSString
            let location = min(max(range.location, 0), source.length)
            let length = min(range.length, max(0, source.length - location))
            let paraRange = source.paragraphRange(for: NSRange(location: location, length: length))
            guard paraRange.length > 0 else { return false }

            var headingNeedsUpdate = false
            source.enumerateSubstrings(
                in: paraRange,
                options: [.byLines, .substringNotRequired]
            ) { _, lineRange, _, stop in
                let line = source.substring(with: lineRange)
                guard let match = Self.headingRegex.firstMatch(
                    in: line,
                    range: NSRange(location: 0, length: (line as NSString).length)
                ) else { return }
                let markerRange = Self.absoluteRange(match.range(at: 1), in: lineRange)
                let shouldHide = !Self.selectionIntersects(lineRange, in: textView)
                if Self.isSyntaxHidden(markerRange, in: storage) != shouldHide {
                    headingNeedsUpdate = true
                    stop.pointee = true
                }
            }
            if headingNeedsUpdate { return true }

            for match in Self.inlineSyntaxMatches(in: paraRange, source: source) {
                let shouldHide = !Self.selectionIntersects(match.matchRange, in: textView)
                if Self.isSyntaxHidden(match.openingRange, in: storage) != shouldHide {
                    return true
                }
            }
            return false
        }

        private static func isSyntaxHidden(_ range: NSRange, in storage: NSTextStorage) -> Bool {
            guard range.length > 0, NSMaxRange(range) <= storage.length else { return false }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            return (font?.pointSize ?? bodyFont.pointSize) < 1
        }

        // MARK: - Uniform line height
        //
        // Paragraph-style `minimumLineHeight`/`maximumLineHeight` is unreliable in
        // TextKit (see Christian Tietze's writeups and the "Neat" library): lines with
        // mixed font sizes size inconsistently. This editor hides list markers / syntax
        // by shrinking them to a 0.1pt font, which made an empty bullet's row shorter
        // than a filled one — so the row (and the bullets above) shifted the moment you
        // typed. Forcing the fragment height here from the line's largest *visible* font
        // (ignoring the 0.1pt hidden glyphs) makes every body/list/empty row identical
        // while still letting headings size to their larger font.
        nonisolated func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
            lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
            baselineOffset: UnsafeMutablePointer<CGFloat>,
            in textContainer: NSTextContainer,
            forGlyphRange glyphRange: NSRange
        ) -> Bool {
            let font = Self.lineFont(for: glyphRange, layoutManager: layoutManager)
            let fontLineHeight = layoutManager.defaultLineHeight(for: font)
            let lineHeight = fontLineHeight + Self.interLineSpacing
            let baselineNudge = (lineHeight - fontLineHeight) * 0.6

            var rect = lineFragmentRect.pointee
            rect.size.height = lineHeight
            var usedRect = lineFragmentUsedRect.pointee
            usedRect.size.height = max(lineHeight, usedRect.size.height)

            lineFragmentRect.pointee = rect
            lineFragmentUsedRect.pointee = usedRect
            baselineOffset.pointee += baselineNudge
            return true
        }

        /// The largest font on the line that isn't a hidden-syntax glyph (we shrink
        /// those to 0.1pt). Falls back to the body font for an otherwise-empty line.
        nonisolated private static func lineFont(for glyphRange: NSRange, layoutManager: NSLayoutManager) -> NSFont {
            guard let storage = layoutManager.textStorage else { return bodyFont }
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard charRange.length > 0, NSMaxRange(charRange) <= storage.length else { return bodyFont }
            var maxFont = bodyFont
            storage.enumerateAttribute(.font, in: charRange, options: []) { value, _, _ in
                if let font = value as? NSFont, font.pointSize >= 1, font.pointSize > maxFont.pointSize {
                    maxFont = font
                }
            }
            return maxFont
        }

        private func currentSelectionParagraph(in textView: NSTextView) -> NSRange? {
            guard let storage = textView.textStorage, storage.length > 0 else { return nil }
            let source = storage.string as NSString
            let sel = textView.selectedRange()
            let location = min(max(sel.location, 0), source.length)
            let length = min(sel.length, max(0, source.length - location))
            return source.paragraphRange(for: NSRange(location: location, length: length))
        }

        /// Restyle only the paragraph(s) intersecting `range`, leaving the rest of
        /// the document — and the document-wide bullet list — untouched. Correct for
        /// selection changes because all of this editor's syntax rules are line-scoped
        /// (`[^*\n]` inline regexes never cross a newline) and bullet glyph positions
        /// don't move when only the selection changes.
        private func restyleParagraphs(intersecting range: NSRange) {
            guard let textView, let storage = textView.textStorage, storage.length > 0 else { return }
            let source = storage.string as NSString
            let location = min(max(range.location, 0), source.length)
            let length = min(range.length, max(0, source.length - location))
            let paraRange = source.paragraphRange(for: NSRange(location: location, length: length))
            guard paraRange.length > 0 else { return }

            applyingStyle = true
            defer { applyingStyle = false }
            storage.beginEditing()
            defer { storage.endEditing() }

            storage.setAttributes(Self.defaultAttributes(), range: paraRange)
            source.enumerateSubstrings(
                in: paraRange,
                options: [.byLines, .substringNotRequired]
            ) { _, lineRange, _, _ in
                _ = self.applyBlockStyle(in: lineRange, source: source, storage: storage, textView: textView)
            }
            applyInlineStyle(in: paraRange, source: source, storage: storage, textView: textView)
        }

        func applyMarkdownStyling() {
            guard let textView, let storage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: storage.length)
            guard fullRange.length >= 0 else { return }

            // The full pass bakes reveal state for the *current* selection, so
            // record which paragraph that was — every caller, not just
            // textDidChange, must leave the bookkeeping consistent or a later
            // selection change skips re-hiding a revealed marker.
            styledSelectionParagraph = currentSelectionParagraph(in: textView)

            applyingStyle = true
            defer { applyingStyle = false }

            storage.beginEditing()
            defer { storage.endEditing() }

            let base = Self.defaultAttributes()
            storage.setAttributes(base, range: fullRange)
            guard storage.length > 0 else {
                textView.typingAttributes = base
                (textView as? ManualNotesTextView)?.renderedBullets = []
                return
            }

            textView.typingAttributes = base

            let source = storage.string as NSString
            var renderedBullets: [ManualNotesTextView.RenderedBullet] = []
            source.enumerateSubstrings(
                in: NSRange(location: 0, length: source.length),
                options: [.byLines, .substringNotRequired]
            ) { _, lineRange, _, _ in
                if let level = self.applyBlockStyle(in: lineRange, source: source, storage: storage, textView: textView) {
                    renderedBullets.append(.init(lineRange: lineRange, indentLevel: level))
                }
            }
            (textView as? ManualNotesTextView)?.renderedBullets = renderedBullets
            applyInlineStyle(in: fullRange, source: source, storage: storage, textView: textView)
        }

        /// Returns the indent level to draw a custom "•" at, or nil when the line
        /// gets no drawn bullet (headings, plain text, and ordered items — whose
        /// number stays visible as its own marker).
        private func applyBlockStyle(
            in lineRange: NSRange,
            source: NSString,
            storage: NSTextStorage,
            textView: NSTextView
        ) -> Int? {
            guard lineRange.length > 0 else { return nil }
            let line = source.substring(with: lineRange)
            guard let match = Self.headingRegex.firstMatch(
                in: line,
                range: NSRange(location: 0, length: (line as NSString).length)
            ) else {
                if let listMatch = Self.listRegex.firstMatch(
                    in: line,
                    range: NSRange(location: 0, length: (line as NSString).length)
                ) {
                    let lineSource = line as NSString
                    let indentRange = Self.absoluteRange(listMatch.range(at: 1), in: lineRange)
                    let markerRange = Self.absoluteRange(listMatch.range(at: 2), in: lineRange)
                    let marker = lineSource.substring(with: listMatch.range(at: 2))
                    let level = TranscriptFormatter.listIndentLevel(
                        of: lineSource.substring(with: listMatch.range(at: 1))
                    )
                    storage.addAttributes(
                        [
                            .font: NSFont.systemFont(ofSize: 15),
                            .paragraphStyle: Self.listParagraphStyle(indentLevel: level)
                        ],
                        range: lineRange
                    )
                    // Nesting depth renders as paragraph indent, so the raw indent
                    // glyphs are hidden with the marker (visible tabs would jump to
                    // unrelated tab stops and break the per-level columns).
                    Self.hideSyntax(indentRange, storage: storage)
                    if marker.hasSuffix(".") {
                        // Ordered item: the number itself is the visible marker.
                        return nil
                    }
                    // Hide only the marker glyph (the "•" is custom-drawn in its place)
                    // and leave the trailing space at full size. On an empty bullet that
                    // space is the only glyph on the line, so keeping it at 15pt is what
                    // gives the insertion point a full-height, visible caret — hiding it
                    // too would collapse the caret to the 0.1pt hidden font.
                    Self.hideSyntax(markerRange, storage: storage)
                    return level
                }
                return nil
            }

            let markerRange = Self.absoluteRange(match.range(at: 1), in: lineRange)
            let spacingRange = Self.absoluteRange(match.range(at: 2), in: lineRange)
            let markerAndSpacingRange = NSRange(
                location: markerRange.location,
                length: markerRange.length + spacingRange.length
            )
            let level = min(6, markerRange.length)

            storage.addAttributes(
                [
                    .font: Self.headingFont(for: level),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: Self.paragraphStyle(spacingAfter: level <= 2 ? 10 : 8)
                ],
                range: lineRange
            )

            if !Self.selectionIntersects(lineRange, in: textView) {
                Self.hideSyntax(markerAndSpacingRange, storage: storage)
            }
            return nil
        }

        private struct InlineSyntaxMatch {
            let matchRange: NSRange
            let openingRange: NSRange
            let contentRange: NSRange
            let closingRange: NSRange
            let traits: NSFontTraitMask
        }

        /// All emphasis spans in `range`, strongest fence first: `***` before `**`
        /// before `*`, with later passes skipping anything a stronger match already
        /// consumed — otherwise the bold pass eats the inside of a `***` fence and
        /// strands literal asterisks. Shared by `applyInlineStyle` and
        /// `revealStateNeedsUpdate` so reveal decisions can't drift from rendering.
        private static func inlineSyntaxMatches(in range: NSRange, source: NSString) -> [InlineSyntaxMatch] {
            let passes: [(regex: NSRegularExpression, traits: NSFontTraitMask)] = [
                (boldItalicRegex, [.boldFontMask, .italicFontMask]),
                (boldRegex, .boldFontMask),
                (italicRegex, .italicFontMask)
            ]
            var consumed: [NSRange] = []
            var matches: [InlineSyntaxMatch] = []
            for pass in passes {
                for match in pass.regex.matches(in: source as String, range: range) {
                    guard match.numberOfRanges >= 4 else { continue }
                    let matchRange = match.range(at: 0)
                    guard !consumed.contains(where: { NSIntersectionRange($0, matchRange).length > 0 })
                    else { continue }
                    consumed.append(matchRange)
                    matches.append(InlineSyntaxMatch(
                        matchRange: matchRange,
                        openingRange: match.range(at: 1),
                        contentRange: match.range(at: 2),
                        closingRange: match.range(at: 3),
                        traits: pass.traits
                    ))
                }
            }
            return matches
        }

        private func applyInlineStyle(in range: NSRange, source: NSString, storage: NSTextStorage, textView: NSTextView) {
            for match in Self.inlineSyntaxMatches(in: range, source: source) {
                storage.addAttributes(
                    [.font: Self.font(in: storage, at: match.contentRange, adding: match.traits)],
                    range: match.contentRange
                )
                if !Self.selectionIntersects(match.matchRange, in: textView) {
                    Self.hideSyntax(match.openingRange, storage: storage)
                    Self.hideSyntax(match.closingRange, storage: storage)
                }
            }
        }

        private func replaceText(in range: NSRange, with replacement: String, textView: NSTextView) {
            applyingAutomaticEdit = true
            defer {
                applyingAutomaticEdit = false
                text.wrappedValue = textView.string
                applyMarkdownStyling()
            }
            textView.insertText(replacement, replacementRange: range)
        }

        nonisolated static var bodyFont: NSFont { .systemFont(ofSize: 15) }
        /// Extra space added below each line, baked into the fragment height by the
        /// layout-manager delegate so it applies uniformly to every line.
        nonisolated static let interLineSpacing: CGFloat = 3

        private static func defaultAttributes() -> [NSAttributedString.Key: Any] {
            [
                .font: bodyFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle(spacingAfter: 6)
            ]
        }

        private static func paragraphStyle(
            spacingAfter: CGFloat,
            firstLineIndent: CGFloat = 0,
            headIndent: CGFloat = 0
        ) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = spacingAfter
            style.firstLineHeadIndent = firstLineIndent
            style.headIndent = headIndent
            return style
        }

        /// Horizontal advance per list nesting level. Text at level N starts at
        /// `(N + 1) * step`; that level's bullet is drawn inside the `N * step`
        /// gutter (see `drawRenderedBullets`).
        nonisolated static let listIndentStep: CGFloat = 18

        private static func listParagraphStyle(indentLevel: Int) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 6
            let indent = CGFloat(indentLevel + 1) * listIndentStep
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            // A tab's width comes from tab stops, not its font — a leading "\t"
            // hidden at 0.1pt would still jump to the next 28pt default stop and
            // shove the text a level deeper than its bullet. List geometry comes
            // entirely from the indents above, so collapse tab advances to ~0.
            style.tabStops = []
            style.defaultTabInterval = 0.1
            return style
        }

        private static func headingFont(for level: Int) -> NSFont {
            switch level {
            case 1:
                NSFont.systemFont(ofSize: 28, weight: .bold)
            case 2:
                NSFont.systemFont(ofSize: 23, weight: .bold)
            case 3:
                NSFont.systemFont(ofSize: 20, weight: .bold)
            case 4:
                NSFont.systemFont(ofSize: 18, weight: .semibold)
            case 5:
                NSFont.systemFont(ofSize: 16, weight: .semibold)
            default:
                NSFont.systemFont(ofSize: 15, weight: .semibold)
            }
        }

        private static func font(
            in storage: NSTextStorage,
            at range: NSRange,
            adding trait: NSFontTraitMask
        ) -> NSFont {
            let location = min(max(range.location, 0), max(storage.length - 1, 0))
            let current = storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
                ?? NSFont.systemFont(ofSize: 15)
            return NSFontManager.shared.convert(current, toHaveTrait: trait)
        }

        private static func hideSyntax(_ range: NSRange, storage: NSTextStorage) {
            guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
            storage.addAttributes(
                [
                    .font: NSFont.systemFont(ofSize: 0.1),
                    .foregroundColor: NSColor.clear
                ],
                range: range
            )
        }

        private static func selectionIntersects(_ range: NSRange, in textView: NSTextView) -> Bool {
            for value in textView.selectedRanges {
                let selection = value.rangeValue
                if selection.length == 0 {
                    if selection.location >= range.location && selection.location <= NSMaxRange(range) {
                        return true
                    }
                } else if NSIntersectionRange(selection, range).length > 0 {
                    return true
                }
            }
            return false
        }

        private static func absoluteRange(_ localRange: NSRange, in lineRange: NSRange) -> NSRange {
            NSRange(location: lineRange.location + localRange.location, length: localRange.length)
        }

        private static func listContinuation(at location: Int, in text: String) -> (range: NSRange, replacement: String)? {
            let source = text as NSString
            let safeLocation = min(max(location, 0), source.length)
            let lineRange = contentLineRange(containing: safeLocation, in: source)
            guard safeLocation == NSMaxRange(lineRange) else { return nil }

            let line = source.substring(with: lineRange)
            guard let match = listRegex.firstMatch(
                in: line,
                range: NSRange(location: 0, length: (line as NSString).length)
            ) else {
                return nil
            }

            let lineSource = line as NSString
            let contentStart = match.range(at: 3).location + match.range(at: 3).length
            let contentRange = NSRange(location: contentStart, length: max(0, lineSource.length - contentStart))
            let content = lineSource.substring(with: contentRange)
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                return (lineRange, "")
            }

            let indent = lineSource.substring(with: match.range(at: 1))
            let marker = lineSource.substring(with: match.range(at: 2))
            let nextMarker: String
            if marker.hasSuffix("."), let number = Int(marker.dropLast()) {
                nextMarker = "\(number + 1)."
            } else {
                nextMarker = marker
            }
            return (NSRange(location: safeLocation, length: 0), "\n\(indent)\(nextMarker) ")
        }

        private static func contentLineRange(containing location: Int, in source: NSString) -> NSRange {
            let safeLocation = min(max(location, 0), source.length)
            var range = source.lineRange(for: NSRange(location: safeLocation, length: 0))
            while range.length > 0 {
                let lastIndex = NSMaxRange(range) - 1
                let character = source.character(at: lastIndex)
                if character == 10 || character == 13 {
                    range.length -= 1
                } else {
                    break
                }
            }
            return range
        }

        private static let headingRegex = try! NSRegularExpression(pattern: "^(#{1,6})(\\s*)")
        private static let listRegex = try! NSRegularExpression(pattern: "^(\\s*)([-*]|\\d+[.])(\\s+)")
        // Emphasis must flank non-whitespace (CommonMark-style), mirroring
        // MeetingExporter's bold-italic/bold/italic grammar — keep the two in
        // lockstep so what styles as bold here exports as bold to Apple Notes/Bear.
        // `***` is matched before `**` (see `inlineSyntaxMatches`) so a bold-italic
        // fence isn't half-eaten by the bold pass.
        private static let boldItalicRegex = try! NSRegularExpression(pattern: "(\\*\\*\\*)(?=\\S)([^*\\n]+?)(?<=\\S)(\\*\\*\\*)")
        private static let boldRegex = try! NSRegularExpression(pattern: "(\\*\\*)(?=\\S)([^*\\n]+?)(?<=\\S)(\\*\\*)")
        private static let italicRegex = try! NSRegularExpression(pattern: "(?<!\\*)(\\*)(?=\\S)([^*\\n]+?)(?<=\\S)(\\*)(?!\\*)")
    }
}
