import AppKit
import SwiftUI
import Testing

@testable import SerialNotes

/// Counts text-storage edits so tests can assert a code path is mutation-free.
private final class StorageEditSpy: NSObject, NSTextStorageDelegate {
    private(set) var editCount = 0

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        editCount += 1
    }
}

@Suite("Manual Notes Markdown Editor")
@MainActor
struct ManualNotesMarkdownEditorTests {
    /// Mirrors the wiring `makeNSView` does, minus the scroll view and the
    /// system text checking (spell checking would edit attributes on its own
    /// schedule and make the mutation-count assertions racy).
    private func makeEditor(
        _ content: String
    ) -> (textView: ManualNotesTextView, coordinator: ManualNotesMarkdownEditor.Coordinator) {
        let coordinator = ManualNotesMarkdownEditor.Coordinator(text: .constant(content))
        let textView = ManualNotesTextView()
        textView.delegate = coordinator
        textView.layoutManager?.delegate = coordinator
        textView.isRichText = false
        textView.string = content
        coordinator.textView = textView
        coordinator.applyMarkdownStyling()
        return (textView, coordinator)
    }

    private func changeSelection(
        to range: NSRange,
        in textView: ManualNotesTextView,
        _ coordinator: ManualNotesMarkdownEditor.Coordinator
    ) {
        textView.setSelectedRange(range)
        coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
        )
    }

    /// Lets the deferred (next-run-loop-turn) selection restyle land.
    private func drainMainQueue() async {
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func markerFontSize(at location: Int, in textView: NSTextView) -> CGFloat {
        let font = textView.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        return font?.pointSize ?? -1
    }

    // On macOS 26 the text view renders through a window-server-managed content
    // layer, and storage edits made from inside a selection-change notification
    // can blank it for the selected lines. Bullet/task markers render live and
    // never flip with the selection, so selection changes across list or plain
    // lines must not touch the storage at all — a mouse drag lands here on every
    // tracking event.
    @Test("Selection changes over bullet lines never edit the storage")
    func bulletSelectionIsMutationFree() async throws {
        let (textView, coordinator) = makeEditor("* awda\n* awd\n* adw\n* ")
        let length = (textView.string as NSString).length

        let spy = StorageEditSpy()
        textView.textStorage?.delegate = spy

        // Caret parked at the end, then a drag growing backwards to select all,
        // like real mouse tracking reports it.
        changeSelection(to: NSRange(location: length, length: 0), in: textView, coordinator)
        for extent in stride(from: 1, through: length, by: 3) {
            changeSelection(
                to: NSRange(location: length - extent, length: extent),
                in: textView,
                coordinator
            )
        }
        await drainMainQueue()

        #expect(spy.editCount == 0)
    }

    @Test("Caret entering a heading reveals its marker on the next turn")
    func headingRevealIsDeferred() async throws {
        let content = "# Title\nbody text"
        let (textView, coordinator) = makeEditor(content)
        let bodyLocation = (content as NSString).length

        // Park the caret in the body so the initial full pass hides the marker.
        changeSelection(to: NSRange(location: bodyLocation, length: 0), in: textView, coordinator)
        await drainMainQueue()
        #expect(markerFontSize(at: 0, in: textView) < 1)

        changeSelection(to: NSRange(location: 2, length: 0), in: textView, coordinator)
        // The restyle is deferred out of the selection-change transaction.
        #expect(markerFontSize(at: 0, in: textView) < 1)
        await drainMainQueue()
        #expect(markerFontSize(at: 0, in: textView) >= 1)

        // Leaving the heading hides the marker again.
        changeSelection(to: NSRange(location: bodyLocation, length: 0), in: textView, coordinator)
        await drainMainQueue()
        #expect(markerFontSize(at: 0, in: textView) < 1)
    }

    @Test("A hash without following whitespace is ordinary text")
    func headingRequiresWhitespace() throws {
        let (textView, _) = makeEditor("#123 is an issue\nplain")
        let font = try #require(textView.textStorage?.attribute(
            .font, at: 0, effectiveRange: nil
        ) as? NSFont)
        #expect(font.pointSize == 15)
        #expect(markerFontSize(at: 0, in: textView) == 15)
    }

    @Test("Selecting across a bold span reveals its markers")
    func boldRevealAcrossSelection() async throws {
        let content = "plain\n**bold** words"
        let (textView, coordinator) = makeEditor(content)
        let source = content as NSString
        let boldStart = source.range(of: "**").location

        changeSelection(to: NSRange(location: 0, length: 0), in: textView, coordinator)
        await drainMainQueue()
        #expect(markerFontSize(at: boldStart, in: textView) < 1)

        changeSelection(to: NSRange(location: 0, length: source.length), in: textView, coordinator)
        await drainMainQueue()
        #expect(markerFontSize(at: boldStart, in: textView) >= 1)
    }

    // MARK: - Lists

    @Test("Nested bullets indent per level and carry the level to the drawn bullet")
    func nestedBulletIndentation() throws {
        let (textView, _) = makeEditor("* top\n\t* tab nested\n    * space nested\nplain")
        let step = ManualNotesMarkdownEditor.Coordinator.listIndentStep

        let bullets = textView.renderedBullets
        #expect(bullets.map(\.indentLevel) == [0, 1, 2])

        let storage = try #require(textView.textStorage)
        for bullet in bullets {
            let style = storage.attribute(
                .paragraphStyle, at: bullet.lineRange.location, effectiveRange: nil
            ) as? NSParagraphStyle
            let expected = CGFloat(bullet.indentLevel + 1) * step
            #expect(style?.firstLineHeadIndent == expected)
            #expect(style?.headIndent == expected)
        }
    }

    @Test("Nested text starts exactly one indent step deeper per level")
    func nestedTextGeometry() throws {
        // Attribute checks aren't enough here: a tab's rendered width comes from
        // tab stops, not its (hidden 0.1pt) font, so a leading "\t" once shoved
        // nested text a 28pt tab stop deeper than its bullet. Measure where the
        // first content glyph actually lands.
        let content = "* top\n\t* tab nested\n    * space nested\nplain"
        let (textView, _) = makeEditor(content)
        textView.textContainer?.containerSize = NSSize(width: 400, height: 1000)
        let layoutManager = try #require(textView.layoutManager)
        let container = try #require(textView.textContainer)
        layoutManager.ensureLayout(for: container)

        let source = content as NSString
        func contentX(of word: String) -> CGFloat {
            let glyph = layoutManager.glyphIndexForCharacter(at: source.range(of: word).location)
            return layoutManager.location(forGlyphAt: glyph).x
        }

        let top = contentX(of: "top")
        let tabNested = contentX(of: "tab nested")
        let spaceNested = contentX(of: "space nested")
        let step = ManualNotesMarkdownEditor.Coordinator.listIndentStep

        // One step deeper per level, regardless of whether the indent was typed
        // as a tab or as spaces (±1pt for hidden-glyph residue).
        #expect(abs(tabNested - top - step) < 1)
        #expect(abs(spaceNested - top - 2 * step) < 1)
    }

    @Test("Ordered items keep their number visible and draw no bullet")
    func orderedItemsShowNumbers() throws {
        let (textView, _) = makeEditor("1. first\n* bullet\nplain")
        // Only the `*` line gets a drawn bullet.
        #expect(textView.renderedBullets.count == 1)
        // The "1." marker stays at full size; the "*" marker is hidden.
        #expect(markerFontSize(at: 0, in: textView) == 15)
        let bulletLine = ("1. first\n" as NSString).length
        #expect(markerFontSize(at: bulletLine, in: textView) < 1)
    }

    @Test("Ordered numbers sit on the drawn-bullet axis, per level")
    func orderedMarkerSharesBulletAxis() throws {
        let content = "1. first\n\t2. nested\n* bullet"
        let (textView, _) = makeEditor(content)
        textView.textContainer?.containerSize = NSSize(width: 400, height: 1000)
        let layoutManager = try #require(textView.layoutManager)
        let container = try #require(textView.textContainer)
        layoutManager.ensureLayout(for: container)

        let source = content as NSString
        func markerX(of text: String) -> CGFloat {
            let glyph = layoutManager.glyphIndexForCharacter(at: source.range(of: text).location)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return layoutManager.location(forGlyphAt: glyph).x - lineRect.minX
        }

        let step = ManualNotesMarkdownEditor.Coordinator.listIndentStep
        let inset = ManualNotesMarkdownEditor.Coordinator.listMarkerGutterInset
        let padding = container.lineFragmentPadding
        // drawRenderedBullets places each bullet at `padding + level * step +
        // inset` within its line fragment; the visible numbers must land on the
        // same axis (±1pt for hidden-glyph residue).
        #expect(abs(markerX(of: "1.") - (padding + inset)) < 1)
        #expect(abs(markerX(of: "2.") - (padding + step + inset)) < 1)
    }

    @Test("Enter on an ordered item continues with the next number")
    func orderedContinuationIncrements() throws {
        let content = "3. third"
        let (textView, coordinator) = makeEditor(content)
        let end = (content as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))

        let allowed = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: end, length: 0),
            replacementString: "\n"
        )
        #expect(!allowed)
        #expect(textView.string == "3. third\n4. ")
    }

    @Test("Typing space after a bullet marker restarts an adjacent bullet list")
    func bulletMarkerRestartsList() throws {
        for marker in ["*", "-", "+"] {
            let content = "* first\n\(marker)"
            let (textView, coordinator) = makeEditor(content)
            let end = (content as NSString).length

            let allowed = coordinator.textView(
                textView,
                shouldChangeTextIn: NSRange(location: end, length: 0),
                replacementString: " "
            )

            #expect(!allowed)
            #expect(textView.string == "* first\n\(marker) ")
            // The committed bullet renders live, while the caret is still on its
            // line — the raw marker hides immediately, Obsidian-style.
            #expect(textView.renderedBullets.count == 2)
            #expect(markerFontSize(at: end - 1, in: textView) < 1)
        }
    }

    @Test("Typing an ordered marker resumes an adjacent ordered list")
    func orderedMarkerResumesList() throws {
        let content = "1. first\n2. second\n1."
        let (textView, coordinator) = makeEditor(content)
        let end = (content as NSString).length

        let allowed = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: end, length: 0),
            replacementString: " "
        )

        #expect(!allowed)
        #expect(textView.string == "1. first\n2. second\n3. ")
    }

    @Test("Parenthesized ordered markers resume and continue with the same delimiter")
    func parenthesizedOrderedLists() throws {
        let content = "1) first\n1)"
        let (textView, coordinator) = makeEditor(content)
        let end = (content as NSString).length

        let committed = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: end, length: 0),
            replacementString: " "
        )
        #expect(!committed)
        #expect(textView.string == "1) first\n2) ")

        let continuationLocation = (textView.string as NSString).length
        textView.insertText("second", replacementRange: NSRange(location: continuationLocation, length: 0))
        let afterText = (textView.string as NSString).length
        let continued = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: afterText, length: 0),
            replacementString: "\n"
        )
        #expect(!continued)
        #expect(textView.string == "1) first\n2) second\n3) ")
    }

    @Test("Inserting an ordered item renumbers sequential following siblings")
    func orderedInsertionRenumbersFollowingItems() throws {
        let content = "1. first\n2. second\n3. third\nafter"
        let (textView, coordinator) = makeEditor(content)
        let insertion = ("1. first" as NSString).length
        textView.setSelectedRange(NSRange(location: insertion, length: 0))

        let allowed = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: insertion, length: 0),
            replacementString: "\n"
        )

        #expect(!allowed)
        #expect(textView.string == "1. first\n2. \n3. second\n4. third\nafter")
        #expect(textView.selectedRange().location == ("1. first\n2. " as NSString).length)
    }

    @Test("Committing an ordered marker mid-list renumbers the followers")
    func orderedMarkerCommitRenumbersFollowers() throws {
        // The space-commit path must agree with the Enter path: resuming "2."
        // above an existing "2. b" shifts the follower instead of duplicating.
        let content = "1. a\n2.\n2. b"
        let (textView, coordinator) = makeEditor(content)
        let commitAt = ("1. a\n2." as NSString).length

        let allowed = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: commitAt, length: 0),
            replacementString: " "
        )

        #expect(!allowed)
        #expect(textView.string == "1. a\n2. \n3. b")
        #expect(textView.selectedRange().location == ("1. a\n2. " as NSString).length)
    }

    @Test("An Int.max ordered marker never traps — continuation repeats it")
    func hugeOrderedMarkerDoesNotOverflow() throws {
        let content = "9223372036854775807. x"
        let (textView, coordinator) = makeEditor(content)
        let end = (content as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))

        let allowed = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: end, length: 0),
            replacementString: "\n"
        )

        #expect(!allowed)
        #expect(textView.string == "9223372036854775807. x\n9223372036854775807. ")
    }

    @Test("Digit markers too large to parse still show their number")
    func unparseableOrderedMarkerKeepsNumberVisible() throws {
        let (textView, _) = makeEditor("99999999999999999999. item\nplain")
        // Ordered by shape: the number stays visible and no bullet is drawn.
        #expect(markerFontSize(at: 0, in: textView) == 15)
        #expect(textView.renderedBullets.isEmpty)
    }

    @Test("Non-ASCII digit markers stay ordinary text")
    func unicodeDigitMarkerStaysLiteral() throws {
        let (textView, _) = makeEditor("٣. item\nplain")
        // Int() can't parse "٣", so the grammar doesn't admit it as a list
        // line at all — the typed number must never vanish behind a bullet.
        #expect(markerFontSize(at: 0, in: textView) == 15)
        #expect(textView.renderedBullets.isEmpty)
    }

    @Test("Enter on an ordered line with task syntax keeps the box literal")
    func orderedTaskSyntaxDoesNotContinue() throws {
        let content = "1. [ ] todo"
        let (textView, coordinator) = makeEditor(content)
        let end = (content as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))

        let allowed = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: end, length: 0),
            replacementString: "\n"
        )

        #expect(!allowed)
        #expect(textView.string == "1. [ ] todo\n2. ")
    }

    @Test("Task items continue unchecked and use task glyphs off the active line")
    func taskContinuation() throws {
        let content = "- [x] done"
        let (textView, coordinator) = makeEditor(content)
        let end = (content as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))

        let allowed = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: end, length: 0),
            replacementString: "\n"
        )

        #expect(!allowed)
        #expect(textView.string == "- [x] done\n- [ ] ")
        // Both lines draw task glyphs — the new empty task renders live even
        // though the caret sits on it.
        #expect(textView.renderedBullets.map(\.kind) == [.checkedTask, .uncheckedTask])
    }

    @Test("A blank line starts a new ordered list instead of resuming the old one")
    func orderedMarkerAfterBlankLineStartsNewList() throws {
        let content = "1. first\n2. second\n\n1."
        let (textView, coordinator) = makeEditor(content)
        let end = (content as NSString).length

        let allowed = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: end, length: 0),
            replacementString: " "
        )

        #expect(!allowed)
        #expect(textView.string == "1. first\n2. second\n\n1. ")
    }

    @Test("Tab indents a list item; Shift-Tab outdents it")
    func tabIndentsListItems() throws {
        let content = "* item"
        let (textView, coordinator) = makeEditor(content)
        textView.setSelectedRange(NSRange(location: 3, length: 0))

        let allowed = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: 3, length: 0),
            replacementString: "\t"
        )
        #expect(!allowed)
        #expect(textView.string == "\t* item")
        let nestedStyle = textView.textStorage?.attribute(
            .paragraphStyle, at: 0, effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(nestedStyle?.firstLineHeadIndent == 2 * ManualNotesMarkdownEditor.Coordinator.listIndentStep)

        let handled = coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.insertBacktab(_:))
        )
        #expect(handled)
        #expect(textView.string == "* item")
        let topStyle = textView.textStorage?.attribute(
            .paragraphStyle, at: 0, effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(topStyle?.firstLineHeadIndent == ManualNotesMarkdownEditor.Coordinator.listIndentStep)
    }

    @Test("Backspace at list content removes structure; nested items outdent first")
    func smartListBackspace() throws {
        let (topTextView, topCoordinator) = makeEditor("- [ ] task")
        topTextView.setSelectedRange(NSRange(location: 6, length: 0))
        #expect(topCoordinator.textView(
            topTextView,
            doCommandBy: #selector(NSResponder.deleteBackward(_:))
        ))
        #expect(topTextView.string == "task")

        let (nestedTextView, nestedCoordinator) = makeEditor("\t* nested")
        nestedTextView.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(nestedCoordinator.textView(
            nestedTextView,
            doCommandBy: #selector(NSResponder.deleteBackward(_:))
        ))
        #expect(nestedTextView.string == "* nested")

        // The marker region's glyphs are hidden, so a caret parked mid-marker
        // must delete structurally too — never a single invisible character.
        let (midTextView, midCoordinator) = makeEditor("- [ ] task")
        midTextView.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(midCoordinator.textView(
            midTextView,
            doCommandBy: #selector(NSResponder.deleteBackward(_:))
        ))
        #expect(midTextView.string == "task")
    }

    @Test("Tab outside a list stays a literal tab")
    func tabOutsideListIsLiteral() throws {
        let (textView, coordinator) = makeEditor("plain")
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        let allowed = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: 2, length: 0),
            replacementString: "\t"
        )
        #expect(allowed)
        let handled = coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.insertBacktab(_:))
        )
        #expect(!handled)
    }

    // MARK: - Emphasis

    @Test("Practical inline Markdown styles and hides through one shared grammar")
    func practicalInlineStyles() throws {
        let content = "plain\n__bold__ _italic_ ~~done~~ ==key== `code` [site](https://example.com)"
        let (textView, coordinator) = makeEditor(content)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applyMarkdownStyling()
        let source = content as NSString
        let storage = try #require(textView.textStorage)

        let boldLocation = source.range(of: "bold").location
        let boldFont = try #require(storage.attribute(.font, at: boldLocation, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))

        let italicLocation = source.range(of: "italic").location
        let italicFont = try #require(storage.attribute(.font, at: italicLocation, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: italicFont).contains(.italicFontMask))

        let strikeLocation = source.range(of: "done").location
        #expect((storage.attribute(.strikethroughStyle, at: strikeLocation, effectiveRange: nil) as? Int) == 1)
        let highlightLocation = source.range(of: "key").location
        #expect(storage.attribute(.backgroundColor, at: highlightLocation, effectiveRange: nil) != nil)

        let codeLocation = source.range(of: "code").location
        let codeFont = try #require(storage.attribute(.font, at: codeLocation, effectiveRange: nil) as? NSFont)
        #expect(codeFont.fontName.lowercased().contains("mono"))

        let linkLocation = source.range(of: "site").location
        #expect(storage.attribute(.foregroundColor, at: linkLocation, effectiveRange: nil) as? NSColor == .linkColor)

        for marker in ["__", "_italic_", "~~", "==", "`", "[site]"] {
            #expect(markerFontSize(at: source.range(of: marker).location, in: textView) < 1)
        }
    }

    @Test("Escaped emphasis markers stay literal while the escape slash hides")
    func escapedMarkersStayLiteral() throws {
        let content = "plain\n\\*literal\\*"
        let (textView, coordinator) = makeEditor(content)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applyMarkdownStyling()
        let source = content as NSString
        let firstSlash = source.range(of: "\\").location
        let literal = source.range(of: "literal").location

        #expect(markerFontSize(at: firstSlash, in: textView) < 1)
        let font = try #require(textView.textStorage?.attribute(.font, at: literal, effectiveRange: nil) as? NSFont)
        let traits = NSFontManager.shared.traits(of: font)
        #expect(!traits.contains(.italicFontMask))
    }

    @Test("Inline code inside emphasis keeps the emphasis traits")
    func codeInsideBoldKeepsBold() throws {
        let content = "plain\n**check `flag` now**"
        let (textView, coordinator) = makeEditor(content)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applyMarkdownStyling()
        let source = content as NSString
        let storage = try #require(textView.textStorage)

        // The exporter nests <code> inside <b>; the notepad must match: mono
        // AND bold, not mono-regular clobbering the parent span's weight.
        let font = try #require(storage.attribute(
            .font, at: source.range(of: "flag").location, effectiveRange: nil
        ) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }

    @Test("Caret reveals each emphasis fence within the same paragraph")
    func caretRevealsInlineEmphasisInSameParagraph() async throws {
        let cases: [(content: String, fence: String, word: String)] = [
            ("left **bold** right", "**", "bold"),
            ("left *italic* right", "*", "italic"),
            ("left ***both*** right", "***", "both")
        ]

        for testCase in cases {
            let (textView, coordinator) = makeEditor(testCase.content)
            let source = testCase.content as NSString
            let fenceStart = source.range(of: testCase.fence).location
            let contentLocation = source.range(of: testCase.word).location

            // Both positions are in one paragraph. The plain-text position keeps
            // the fence hidden; moving into the styled span reveals its raw syntax.
            changeSelection(to: NSRange(location: 0, length: 0), in: textView, coordinator)
            await drainMainQueue()
            #expect(markerFontSize(at: fenceStart, in: textView) < 1)

            changeSelection(
                to: NSRange(location: contentLocation, length: 0),
                in: textView,
                coordinator
            )
            await drainMainQueue()
            #expect(markerFontSize(at: fenceStart, in: textView) >= 1)

            // Leaving the span on the same line hides the fence again.
            changeSelection(to: NSRange(location: source.length, length: 0), in: textView, coordinator)
            await drainMainQueue()
            #expect(markerFontSize(at: fenceStart, in: textView) < 1)
        }
    }

    @Test("Triple-star renders bold-italic with no stray literal asterisks")
    func tripleStarBoldItalic() throws {
        let content = "***word*** after"
        let (textView, _) = makeEditor(content)
        let storage = try #require(textView.textStorage)

        // All three opening and closing markers are hidden.
        #expect(markerFontSize(at: 0, in: textView) < 1)
        #expect(markerFontSize(at: 1, in: textView) < 1)
        #expect(markerFontSize(at: 2, in: textView) < 1)
        #expect(markerFontSize(at: 7, in: textView) < 1)
        #expect(markerFontSize(at: 9, in: textView) < 1)

        // The content carries both traits.
        let font = try #require(storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
        let traits = NSFontManager.shared.traits(of: font)
        #expect(traits.contains(.boldFontMask))
        #expect(traits.contains(.italicFontMask))

        // " after" stays plain — nothing leaked past the fence.
        let plainFont = try #require(storage.attribute(.font, at: 12, effectiveRange: nil) as? NSFont)
        #expect(plainFont.pointSize == 15)
        #expect(!NSFontManager.shared.traits(of: plainFont).contains(.boldFontMask))
    }

    @Test("Selecting across a triple-star span reveals its markers")
    func tripleStarRevealAcrossSelection() async throws {
        let content = "plain\n***word***"
        let (textView, coordinator) = makeEditor(content)
        let source = content as NSString
        let fenceStart = source.range(of: "***").location

        changeSelection(to: NSRange(location: 0, length: 0), in: textView, coordinator)
        await drainMainQueue()
        #expect(markerFontSize(at: fenceStart, in: textView) < 1)

        changeSelection(to: NSRange(location: 0, length: source.length), in: textView, coordinator)
        await drainMainQueue()
        #expect(markerFontSize(at: fenceStart, in: textView) >= 1)
    }
}
