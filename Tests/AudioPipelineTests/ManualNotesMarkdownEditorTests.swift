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
    // can blank it for the selected lines. Selection changes across lines whose
    // reveal state can't flip (bullets, plain text) must therefore be
    // mutation-free — a mouse drag lands here on every tracking event.
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
        let (textView, _) = makeEditor("* top\n\t* tab nested\n    * space nested")
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
        let content = "* top\n\t* tab nested\n    * space nested"
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
        let (textView, _) = makeEditor("1. first\n* bullet")
        // Only the `*` line gets a drawn bullet.
        #expect(textView.renderedBullets.count == 1)
        // The "1." marker stays at full size; the "*" marker is hidden.
        #expect(markerFontSize(at: 0, in: textView) == 15)
        let bulletLine = ("1. first\n" as NSString).length
        #expect(markerFontSize(at: bulletLine, in: textView) < 1)
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
        #expect(textView.renderedBullets.map(\.indentLevel) == [1])

        let handled = coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.insertBacktab(_:))
        )
        #expect(handled)
        #expect(textView.string == "* item")
        #expect(textView.renderedBullets.map(\.indentLevel) == [0])
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
