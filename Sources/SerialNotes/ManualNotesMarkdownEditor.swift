import AppKit
import SwiftUI

final class ManualNotesTextView: NSTextView {
    struct RenderedBullet: Equatable {
        enum Kind: Equatable {
            case bullet
            case uncheckedTask
            case checkedTask

            var glyph: String {
                switch self {
                case .bullet: "•"
                case .uncheckedTask: "☐"
                case .checkedTask: "☑︎"
                }
            }
        }

        let lineRange: NSRange
        let indentLevel: Int
        let kind: Kind
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
        let origin = textContainerOrigin
        let indentStep = ManualNotesMarkdownEditor.Coordinator.listIndentStep

        for rendered in renderedBullets where rendered.lineRange.location < string.utf16.count {
            let bullet = rendered.kind.glyph as NSString
            let bulletSize = bullet.size(withAttributes: attributes)
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
        /// The paragraph range used by the most recent selection-aware style pass.
        /// Inline syntax can reveal while the caret moves within that paragraph,
        /// so this only identifies the paragraph that may need re-hiding; it must
        /// not be used to skip same-paragraph selection changes.
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
            // stay a literal asterisk so it can also begin italic (`*word*`). The
            // trailing space commits a marker as a list item, matching Obsidian /
            // Google Docs / Word.

            if replacementString == " ",
               let startEdit = Self.listStartEdit(
                   at: affectedCharRange.location,
                   in: textView.string
               )
            {
                replaceText(
                    in: startEdit.range,
                    with: startEdit.replacement,
                    textView: textView,
                    selectionAfter: startEdit.selectionAfter
                )
                return false
            }

            if replacementString == "\n",
               let continuation = Self.listContinuation(at: affectedCharRange.location, in: textView.string)
            {
                replaceText(
                    in: continuation.range,
                    with: continuation.replacement,
                    textView: textView,
                    selectionAfter: continuation.selectionAfter
                )
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
            if commandSelector == #selector(NSResponder.insertBacktab(_:)),
               let indentEdit = Self.listIndentEdit(
                      at: textView.selectedRange().location,
                      in: textView.string,
                      outdent: true
               )
            {
                replaceText(in: indentEdit.range, with: indentEdit.replacement, textView: textView)
                return true
            }
            if commandSelector == #selector(NSResponder.deleteBackward(_:)),
               let deletion = Self.listBackspaceEdit(
                   at: textView.selectedRange(),
                   in: textView.string
               )
            {
                replaceText(in: deletion.range, with: deletion.replacement, textView: textView)
                return true
            }
            return false
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

        /// Backspace anywhere inside a list item's marker region (up to and
        /// including the start of its content) removes structural Markdown
        /// instead of eating hidden marker glyphs one character at a time.
        /// Nested items outdent by one level first; top-level bullets, tasks, and
        /// ordered items become ordinary text.
        private static func listBackspaceEdit(
            at selection: NSRange,
            in text: String
        ) -> (range: NSRange, replacement: String)? {
            guard selection.length == 0 else { return nil }
            let source = text as NSString
            let safeLocation = min(max(selection.location, 0), source.length)
            let lineRange = contentLineRange(containing: safeLocation, in: source)
            let line = source.substring(with: lineRange)
            let lineSource = line as NSString
            guard let match = listRegex.firstMatch(
                in: line,
                range: NSRange(location: 0, length: lineSource.length)
            ) else { return nil }

            // Ordered "tasks" aren't part of the grammar — the notepad renders
            // their brackets literally — so the box counts as content there.
            let marker = lineSource.substring(with: match.range(at: 2))
            let contentStart = match.range(at: 4).location == NSNotFound || isOrderedMarkerShape(marker)
                ? NSMaxRange(match.range(at: 3))
                : NSMaxRange(match.range(at: 5))
            // Fire from anywhere within the marker region: the glyphs there are
            // hidden (or drawn as a custom bullet), so single-character deletion
            // would silently corrupt structure the user can't see.
            guard safeLocation > lineRange.location,
                  safeLocation <= lineRange.location + contentStart
            else { return nil }

            let indent = lineSource.substring(with: match.range(at: 1))
            if !indent.isEmpty {
                return listIndentEdit(at: safeLocation, in: text, outdent: true)
            }
            return (NSRange(location: lineRange.location, length: contentStart), "")
        }

        /// Commits a marker-only line when its trailing space is typed. Bullets
        /// simply enter list mode. An ordered marker immediately following an
        /// ordered item at the same nesting depth resumes that list's numbering;
        /// a blank line or a different list type/depth starts a new list instead.
        /// Followers that continued the resumed number shift up by one, exactly
        /// as the Enter path does — the two insertion gestures must agree.
        private static func listStartEdit(
            at location: Int,
            in text: String
        ) -> (range: NSRange, replacement: String, selectionAfter: NSRange?)? {
            let source = text as NSString
            let safeLocation = min(max(location, 0), source.length)
            let lineRange = contentLineRange(containing: safeLocation, in: source)
            guard safeLocation == NSMaxRange(lineRange) else { return nil }

            let line = source.substring(with: lineRange)
            let localRange = NSRange(location: 0, length: (line as NSString).length)
            guard let match = listMarkerOnlyRegex.firstMatch(in: line, range: localRange)
            else { return nil }

            let lineSource = line as NSString
            let indent = lineSource.substring(with: match.range(at: 1))
            let typedMarker = lineSource.substring(with: match.range(at: 2))
            var resolvedMarker = typedMarker

            if let typed = OrderedMarker(typedMarker),
               lineRange.location > 0
            {
                let previousRange = contentLineRange(
                    containing: lineRange.location - 1,
                    in: source
                )
                let previousLine = source.substring(with: previousRange)
                let previousSource = previousLine as NSString
                let previousLocalRange = NSRange(location: 0, length: previousSource.length)
                if let previousMatch = listRegex.firstMatch(
                    in: previousLine,
                    range: previousLocalRange
                ) {
                    let previousIndent = previousSource.substring(with: previousMatch.range(at: 1))
                    let previousMarker = previousSource.substring(with: previousMatch.range(at: 2))
                    if let previous = OrderedMarker(previousMarker),
                       previous.delimiter == typed.delimiter,
                       TranscriptFormatter.listIndentLevel(of: previousIndent)
                        == TranscriptFormatter.listIndentLevel(of: indent),
                       let resumed = previous.next
                    {
                        resolvedMarker = resumed.text
                    }
                }
            }

            let committed = "\(indent)\(resolvedMarker) "
            if let resolved = OrderedMarker(resolvedMarker),
               let shifted = shiftedFollowerRun(
                   source: source,
                   fromFullLineEnd: NSMaxRange(source.lineRange(for: lineRange)),
                   depth: TranscriptFormatter.listIndentLevel(of: indent),
                   first: resolved
               )
            {
                // Between this line's content and the follower run sits only the
                // line terminator — carry it through the single replacement.
                let terminator = source.substring(with: NSRange(
                    location: NSMaxRange(lineRange),
                    length: shifted.range.location - NSMaxRange(lineRange)
                ))
                let range = NSRange(
                    location: lineRange.location,
                    length: NSMaxRange(shifted.range) - lineRange.location
                )
                let selection = NSRange(
                    location: lineRange.location + (committed as NSString).length,
                    length: 0
                )
                return (range, committed + terminator + shifted.rewritten, selection)
            }
            return (lineRange, committed, nil)
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
            let previous = styledSelectionParagraph
            styledSelectionParagraph = para
            // Only the line(s) the caret entered/left flip syntax reveal — restyle
            // those paragraphs instead of reparsing the whole document on every
            // arrow key or click. Plain and list lines skip storage work entirely
            // (bullet/task markers render live regardless of selection); headings
            // and inline spans reveal their raw syntax while the selection touches
            // them.
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
            // Coalesce: a burst of selection changes within one run-loop turn
            // (fast drags, key repeat) merges into a single deferred restyle
            // instead of stacking one block per event.
            let alreadyScheduled = !deferredRestyleRanges.isEmpty
            deferredRestyleRanges.append(contentsOf: staleRanges)
            guard !alreadyScheduled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let ranges = Self.mergedRanges(self.deferredRestyleRanges)
                self.deferredRestyleRanges = []
                // Skip while IME composition is live — a restyle would clobber the
                // marked-text underline mid-composition; the next caret move after
                // the composition confirms will re-run this.
                guard let textView = self.textView, !textView.hasMarkedText()
                else { return }
                for range in ranges { self.restyleParagraphs(intersecting: range) }
            }
        }

        /// Pending deferred-restyle ranges; non-empty exactly while a flush block
        /// is queued on the main queue.
        private var deferredRestyleRanges: [NSRange] = []

        /// Overlapping or touching ranges merged into one, so a coalesced flush
        /// restyles each paragraph once.
        private static func mergedRanges(_ ranges: [NSRange]) -> [NSRange] {
            var merged: [NSRange] = []
            for range in ranges.sorted(by: { $0.location < $1.location }) {
                if let last = merged.last, NSMaxRange(last) >= range.location {
                    merged[merged.count - 1] = NSUnionRange(last, range)
                } else {
                    merged.append(range)
                }
            }
            return merged
        }

        /// Whether any hidden-syntax run in `range`'s paragraphs must flip between
        /// hidden and revealed for the current selection. Mirrors the reveal policy
        /// in `applyBlockStyle` (headings reveal per line; list markers never
        /// reveal) and `applyInlineStyle` — keep them in lockstep.
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

            // Most prose paragraphs contain no inline syntax at all — skip the
            // parse (and its span-tree allocation) unless a trigger character
            // is present. Keep this set in lockstep with the parser's grammar.
            guard source.rangeOfCharacter(
                from: Self.inlineSyntaxTriggers,
                options: [],
                range: paraRange
            ).location != NSNotFound else { return false }

            for span in MarkdownInlineParser.flattenedSpans(in: source as String, range: paraRange) {
                guard let syntaxRange = span.syntaxRanges.first else { continue }
                let shouldHide = !Self.selectionIntersects(span.range, in: textView)
                if Self.isSyntaxHidden(syntaxRange, in: storage) != shouldHide {
                    return true
                }
            }
            return false
        }

        /// Every character that can begin an inline span (emphasis, strike,
        /// highlight, code, link, escape) — the cheap pre-filter for the parse.
        private static let inlineSyntaxTriggers = CharacterSet(charactersIn: "*_~=`[\\")

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
        /// the document untouched. Inline rules never cross a newline. The custom
        /// bullet/task entries for these lines are recomputed too (the scoped
        /// `setAttributes` wipes their block styling), merged with the untouched
        /// lines' existing entries.
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
            var renderedBullets: [ManualNotesTextView.RenderedBullet] = []
            source.enumerateSubstrings(
                in: paraRange,
                options: [.byLines, .substringNotRequired]
            ) { _, lineRange, _, _ in
                if let rendered = self.applyBlockStyle(
                    in: lineRange,
                    source: source,
                    storage: storage,
                    textView: textView
                ) {
                    renderedBullets.append(rendered)
                }
            }
            if let notesTextView = textView as? ManualNotesTextView {
                let untouched = notesTextView.renderedBullets.filter {
                    NSIntersectionRange($0.lineRange, paraRange).length == 0
                }
                notesTextView.renderedBullets = (untouched + renderedBullets).sorted {
                    $0.lineRange.location < $1.lineRange.location
                }
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
            // selection change skips re-hiding a revealed marker. It also
            // supersedes any pending scoped restyles.
            styledSelectionParagraph = currentSelectionParagraph(in: textView)
            deferredRestyleRanges = []

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
                if let rendered = self.applyBlockStyle(
                    in: lineRange,
                    source: source,
                    storage: storage,
                    textView: textView
                ) {
                    renderedBullets.append(rendered)
                }
            }
            (textView as? ManualNotesTextView)?.renderedBullets = renderedBullets
            applyInlineStyle(in: fullRange, source: source, storage: storage, textView: textView)
        }

        /// Returns a custom bullet/task glyph to draw, or nil when the line gets no
        /// drawn marker (headings, plain text, and ordered items — whose number
        /// stays visible as its own marker).
        private func applyBlockStyle(
            in lineRange: NSRange,
            source: NSString,
            storage: NSTextStorage,
            textView: NSTextView
        ) -> ManualNotesTextView.RenderedBullet? {
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
                    if Self.isOrderedMarkerShape(marker) {
                        // Ordered item: the number itself is the visible marker.
                        return nil
                    }

                    // The marker hides unconditionally — even on the caret's line —
                    // so a committed bullet renders live while the user types on it
                    // (Obsidian parity). One delimiter space remains full-size so an
                    // empty item retains a normal-height caret.
                    Self.hideSyntax(markerRange, storage: storage)

                    var kind = ManualNotesTextView.RenderedBullet.Kind.bullet
                    if listMatch.range(at: 4).location != NSNotFound {
                        let markerSpacingRange = Self.absoluteRange(listMatch.range(at: 3), in: lineRange)
                        let taskRange = Self.absoluteRange(listMatch.range(at: 4), in: lineRange)
                        let task = lineSource.substring(with: listMatch.range(at: 4))
                        // A task has whitespace on both sides of `[ ]`. Collapse
                        // the first one with the hidden marker so task content
                        // starts in the same column as an ordinary bullet; the
                        // second stays full-size to keep an empty task's caret tall.
                        Self.hideSyntax(markerSpacingRange, storage: storage)
                        Self.hideSyntax(taskRange, storage: storage)
                        kind = task.lowercased() == "[x]" ? .checkedTask : .uncheckedTask
                    }
                    return .init(lineRange: lineRange, indentLevel: level, kind: kind)
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

        private func applyInlineStyle(in range: NSRange, source: NSString, storage: NSTextStorage, textView: NSTextView) {
            for span in MarkdownInlineParser.flattenedSpans(in: source as String, range: range) {
                switch span.kind {
                case .bold:
                    Self.addFontTraits(.boldFontMask, to: span.contentRange, storage: storage)
                case .italic:
                    Self.addFontTraits(.italicFontMask, to: span.contentRange, storage: storage)
                case .boldItalic:
                    Self.addFontTraits([.boldFontMask, .italicFontMask], to: span.contentRange, storage: storage)
                case .strikethrough:
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.contentRange)
                case .highlight:
                    storage.addAttribute(
                        .backgroundColor,
                        value: NSColor.systemYellow.withAlphaComponent(0.28),
                        range: span.contentRange
                    )
                case .code:
                    Self.applyCodeFont(to: span.contentRange, storage: storage)
                    storage.addAttribute(
                        .backgroundColor,
                        value: NSColor.quaternaryLabelColor.withAlphaComponent(0.18),
                        range: span.contentRange
                    )
                case let .link(destination):
                    storage.addAttributes(
                        [
                            .foregroundColor: NSColor.linkColor,
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                            .link: destination
                        ],
                        range: span.contentRange
                    )
                case .escape:
                    break
                }

                if !Self.selectionIntersects(span.range, in: textView) {
                    for syntaxRange in span.syntaxRanges {
                        Self.hideSyntax(syntaxRange, storage: storage)
                    }
                }
            }
        }

        private func replaceText(
            in range: NSRange,
            with replacement: String,
            textView: NSTextView,
            selectionAfter: NSRange? = nil
        ) {
            applyingAutomaticEdit = true
            defer {
                applyingAutomaticEdit = false
                text.wrappedValue = textView.string
                applyMarkdownStyling()
            }
            textView.insertText(replacement, replacementRange: range)
            if let selectionAfter {
                textView.setSelectedRange(selectionAfter)
            }
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

        /// Swap each run to the monospaced system font while preserving the size
        /// and bold/italic that enclosing spans (emphasis, headings) already
        /// applied — the exporter nests `<code>` inside `<b>`/`<i>`, so the
        /// notepad must render the same combination.
        private static func applyCodeFont(to range: NSRange, storage: NSTextStorage) {
            guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
            storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                let current = value as? NSFont ?? bodyFont
                let traits = NSFontManager.shared.traits(of: current)
                var mono = NSFont.monospacedSystemFont(
                    ofSize: current.pointSize,
                    weight: traits.contains(.boldFontMask) ? .bold : .regular
                )
                if traits.contains(.italicFontMask) {
                    mono = NSFontManager.shared.convert(mono, toHaveTrait: .italicFontMask)
                }
                storage.addAttribute(.font, value: mono, range: subrange)
            }
        }

        private static func addFontTraits(
            _ traits: NSFontTraitMask,
            to range: NSRange,
            storage: NSTextStorage
        ) {
            guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
            storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                let current = value as? NSFont ?? bodyFont
                storage.addAttribute(
                    .font,
                    value: NSFontManager.shared.convert(current, toHaveTrait: traits),
                    range: subrange
                )
            }
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

        private static func listContinuation(
            at location: Int,
            in text: String
        ) -> (range: NSRange, replacement: String, selectionAfter: NSRange?)? {
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
            let taskRange = match.range(at: 4)
            let taskSpacingRange = match.range(at: 5)
            let marker = lineSource.substring(with: match.range(at: 2))
            // Ordered "tasks" aren't part of the grammar — the notepad renders
            // their brackets literally, so the box counts as content and Enter
            // must not propagate it.
            let taskMatched = taskRange.location != NSNotFound && !isOrderedMarkerShape(marker)
            let contentStart: Int
            if taskMatched {
                contentStart = NSMaxRange(taskSpacingRange)
            } else {
                contentStart = NSMaxRange(match.range(at: 3))
            }
            let contentRange = NSRange(location: contentStart, length: max(0, lineSource.length - contentStart))
            let content = lineSource.substring(with: contentRange)
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                return (lineRange, "", nil)
            }

            let indent = lineSource.substring(with: match.range(at: 1))
            let ordered = OrderedMarker(marker)
            let nextMarker = ordered?.next?.text ?? marker
            let taskPrefix = taskMatched ? "[ ] " : ""
            let insertion = "\n\(indent)\(nextMarker) \(taskPrefix)"
            if let next = ordered?.next,
               let shifted = shiftedFollowerRun(
                   source: source,
                   fromFullLineEnd: NSMaxRange(source.lineRange(for: lineRange)),
                   depth: TranscriptFormatter.listIndentLevel(of: indent),
                   first: next
               )
            {
                // Between the caret (end of content) and the follower run sits
                // only this line's terminator — carry it through unchanged so
                // the whole insertion + renumber stays a single replacement.
                let terminator = source.substring(with: NSRange(
                    location: safeLocation,
                    length: shifted.range.location - safeLocation
                ))
                let range = NSRange(
                    location: safeLocation,
                    length: NSMaxRange(shifted.range) - safeLocation
                )
                let selection = NSRange(
                    location: safeLocation + (insertion as NSString).length,
                    length: 0
                )
                return (range, insertion + terminator + shifted.rewritten, selection)
            }
            return (NSRange(location: safeLocation, length: 0), insertion, nil)
        }

        /// The sequential same-depth ordered run starting directly below
        /// `fromFullLineEnd`, rewritten with every number shifted up by one —
        /// what makes room for an item numbered `first` inserted above it.
        /// Nil when no follower continues `first`'s sequence: deliberately
        /// numbered or broken sequences are left alone, and a blank line ends
        /// the list. Nested children are traversed but keep their own numbering.
        private static func shiftedFollowerRun(
            source: NSString,
            fromFullLineEnd: Int,
            depth: Int,
            first: OrderedMarker
        ) -> (range: NSRange, rewritten: String)? {
            var cursor = fromFullLineEnd
            guard cursor < source.length else { return nil }

            var expected = first
            var replacements: [(range: NSRange, marker: String)] = []
            var scanEnd = fromFullLineEnd

            while cursor < source.length {
                let contentRange = contentLineRange(containing: cursor, in: source)
                guard contentRange.length > 0 else { break }
                let line = source.substring(with: contentRange)
                let lineSource = line as NSString
                guard let match = listRegex.firstMatch(
                    in: line,
                    range: NSRange(location: 0, length: lineSource.length)
                ) else { break }

                let lineIndent = lineSource.substring(with: match.range(at: 1))
                let lineDepth = TranscriptFormatter.listIndentLevel(of: lineIndent)
                if lineDepth < depth { break }
                if lineDepth == depth {
                    let marker = lineSource.substring(with: match.range(at: 2))
                    guard let ordered = OrderedMarker(marker),
                          ordered.delimiter == expected.delimiter,
                          ordered.number == expected.number,
                          let shifted = ordered.next
                    else { break }
                    replacements.append((
                        absoluteRange(match.range(at: 2), in: contentRange),
                        shifted.text
                    ))
                    expected = shifted
                }

                let fullLine = source.lineRange(for: contentRange)
                scanEnd = NSMaxRange(fullLine)
                guard scanEnd > cursor else { break }
                cursor = scanEnd
            }

            guard !replacements.isEmpty, scanEnd > fromFullLineEnd else { return nil }
            let tailRange = NSRange(
                location: fromFullLineEnd,
                length: scanEnd - fromFullLineEnd
            )
            let tail = NSMutableString(string: source.substring(with: tailRange))
            for replacement in replacements.reversed() {
                tail.replaceCharacters(
                    in: NSRange(
                        location: replacement.range.location - fromFullLineEnd,
                        length: replacement.range.length
                    ),
                    with: replacement.marker
                )
            }
            return (tailRange, tail as String)
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

        // ATX headings require a space after the fence (or an empty heading), so a
        // meeting note such as `#123` remains ordinary text.
        private static let headingRegex = try! NSRegularExpression(pattern: "^(#{1,6})([ \\t]+|$)")
        // Keep block/list grammar aligned with MeetingExporter: three unordered
        // markers, both ordered delimiters, and optional task syntax. Digits are
        // ASCII-only ([0-9], not \d) so everything the grammar admits as ordered
        // is also something `OrderedMarker` can classify — ICU \d matches Unicode
        // digits that Int() can't parse, which used to hide the typed number
        // behind a drawn bullet.
        private static let listRegex = try! NSRegularExpression(
            pattern: "^(\\s*)([-+*]|[0-9]+[.)])(\\s+)(?:(\\[[ xX]\\])(\\s+))?"
        )
        private static let listMarkerOnlyRegex = try! NSRegularExpression(
            pattern: "^(\\s*)([-+*]|[0-9]+[.)])$"
        )

        /// Whether a listRegex marker is digit-shaped ("3." / "3)") as opposed to
        /// a bullet ("-", "+", "*"). Rendering routes on the shape; arithmetic
        /// (resume, continuation, renumbering) additionally needs the number to
        /// parse — that's `OrderedMarker`.
        private static func isOrderedMarkerShape(_ marker: String) -> Bool {
            marker.last == "." || marker.last == ")"
        }

        /// A parsed ordered-list marker. The single home of the number/delimiter
        /// grammar and the +1 rule shared by marker resume, Enter continuation,
        /// and follower renumbering — and the overflow guard that keeps a
        /// pathological `9223372036854775807.` marker from trapping `+ 1`.
        private struct OrderedMarker {
            let number: Int
            let delimiter: Character

            init?(_ marker: String) {
                guard let last = marker.last, last == "." || last == ")",
                      let number = Int(marker.dropLast())
                else { return nil }
                self.number = number
                self.delimiter = last
            }

            private init(number: Int, delimiter: Character) {
                self.number = number
                self.delimiter = delimiter
            }

            /// The marker one past this one, or nil when the number would
            /// overflow Int — callers fall back to repeating the marker or
            /// ending the renumber run, never crash.
            var next: OrderedMarker? {
                let (value, overflow) = number.addingReportingOverflow(1)
                return overflow ? nil : OrderedMarker(number: value, delimiter: delimiter)
            }

            var text: String { "\(number)\(delimiter)" }
        }
    }
}
