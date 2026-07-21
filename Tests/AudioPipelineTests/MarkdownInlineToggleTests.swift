import Foundation
import Testing

@testable import SerialNotes

@Suite("Markdown Inline Toggle")
struct MarkdownInlineToggleTests {
    /// Applies the computed edit so assertions read as before → after.
    private func toggled(
        _ style: MarkdownInlineToggle.Style,
        in text: String,
        selection: NSRange
    ) -> (text: String, selection: NSRange)? {
        guard let edit = MarkdownInlineToggle.edit(for: style, selection: selection, in: text)
        else { return nil }
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        return (result, edit.selectionAfter)
    }

    // MARK: - Wrapping a selection

    @Test("Wrapping a selection inserts markers and keeps the content selected")
    func wrapsSelection() throws {
        let bold = try #require(toggled(.bold, in: "make this bold", selection: NSRange(location: 10, length: 4)))
        #expect(bold.text == "make this **bold**")
        #expect(bold.selection == NSRange(location: 12, length: 4))

        let italic = try #require(toggled(.italic, in: "make this bold", selection: NSRange(location: 10, length: 4)))
        #expect(italic.text == "make this *bold*")
        #expect(italic.selection == NSRange(location: 11, length: 4))

        let strike = try #require(toggled(.strikethrough, in: "strike me", selection: NSRange(location: 0, length: 6)))
        #expect(strike.text == "~~strike~~ me")
        #expect(strike.selection == NSRange(location: 2, length: 6))

        let highlight = try #require(toggled(.highlight, in: "note this", selection: NSRange(location: 5, length: 4)))
        #expect(highlight.text == "note ==this==")
        #expect(highlight.selection == NSRange(location: 7, length: 4))
    }

    @Test("Whitespace at the selection edges stays outside the markers")
    func trimsWhitespaceEdges() throws {
        let result = try #require(toggled(.bold, in: "a word z", selection: NSRange(location: 1, length: 6)))
        #expect(result.text == "a **word** z")
        #expect(result.selection == NSRange(location: 4, length: 4))
    }

    @Test("A whitespace-only selection is a no-op")
    func whitespaceOnlySelectionIsNoOp() {
        #expect(toggled(.bold, in: "a   b", selection: NSRange(location: 1, length: 3)) == nil)
    }

    @Test("Intraword wraps follow the parser: * allowed, ~~/== refused")
    func intrawordWrapsFollowParserRules() throws {
        let bold = try #require(toggled(.bold, in: "word", selection: NSRange(location: 1, length: 2)))
        #expect(bold.text == "w**or**d")

        #expect(toggled(.strikethrough, in: "word", selection: NSRange(location: 1, length: 2)) == nil)
        #expect(toggled(.highlight, in: "word", selection: NSRange(location: 1, length: 2)) == nil)
    }

    @Test("A wrap the parser would not render is a no-op")
    func unparseableWrapIsNoOp() {
        // `*hello **world***` never parses — the sub-selection wrap must not
        // leave literal marker noise behind.
        #expect(toggled(.bold, in: "*hello world*", selection: NSRange(location: 7, length: 5)) == nil)
    }

    @Test("Wrapping absorbs same-kind spans the selection overlaps or touches")
    func wrapAbsorbsIntersectingSpans() throws {
        let full = try #require(toggled(.bold, in: "a **b** c", selection: NSRange(location: 0, length: 9)))
        #expect(full.text == "**a b c**")
        #expect(full.selection == NSRange(location: 2, length: 5))

        let straddle = try #require(toggled(.bold, in: "x **bold** more", selection: NSRange(location: 5, length: 10)))
        #expect(straddle.text == "x **bold more**")
        #expect(straddle.selection == NSRange(location: 4, length: 9))

        let adjacent = try #require(toggled(.bold, in: "**a**b", selection: NSRange(location: 5, length: 1)))
        #expect(adjacent.text == "**ab**")
        #expect(adjacent.selection == NSRange(location: 2, length: 2))
    }

    // MARK: - Unwrapping

    @Test("Any selection within a span unwraps it, wherever it sits")
    func unwrapFromEveryPosition() throws {
        let text = "**bold**"

        let fromContent = try #require(toggled(.bold, in: text, selection: NSRange(location: 4, length: 0)))
        #expect(fromContent.text == "bold")
        #expect(fromContent.selection == NSRange(location: 2, length: 0))

        let contentSelected = try #require(toggled(.bold, in: text, selection: NSRange(location: 2, length: 4)))
        #expect(contentSelected.text == "bold")
        #expect(contentSelected.selection == NSRange(location: 0, length: 4))

        let fullSelected = try #require(toggled(.bold, in: text, selection: NSRange(location: 0, length: 8)))
        #expect(fullSelected.text == "bold")
        #expect(fullSelected.selection == NSRange(location: 0, length: 4))

        let overMarker = try #require(toggled(.bold, in: text, selection: NSRange(location: 1, length: 3)))
        #expect(overMarker.text == "bold")
        #expect(overMarker.selection == NSRange(location: 0, length: 2))

        let atStart = try #require(toggled(.bold, in: text, selection: NSRange(location: 0, length: 0)))
        #expect(atStart.text == "bold")
        #expect(atStart.selection == NSRange(location: 0, length: 0))

        let atEnd = try #require(toggled(.bold, in: text, selection: NSRange(location: 8, length: 0)))
        #expect(atEnd.text == "bold")
        #expect(atEnd.selection == NSRange(location: 4, length: 0))
    }

    @Test("Underscore-delimited spans unwrap and keep their delimiter flavor")
    func underscoreFamilyUnwraps() throws {
        let bold = try #require(toggled(.bold, in: "__bold__", selection: NSRange(location: 4, length: 0)))
        #expect(bold.text == "bold")

        let italic = try #require(toggled(.italic, in: "_i_", selection: NSRange(location: 1, length: 0)))
        #expect(italic.text == "i")

        let shrink = try #require(toggled(.bold, in: "___x___", selection: NSRange(location: 4, length: 0)))
        #expect(shrink.text == "_x_")
    }

    @Test("Toggling one half of boldItalic shrinks the markers")
    func boldItalicShrinks() throws {
        let unbolded = try #require(toggled(.bold, in: "***x***", selection: NSRange(location: 4, length: 0)))
        #expect(unbolded.text == "*x*")
        #expect(unbolded.selection == NSRange(location: 2, length: 0))

        let unitalicized = try #require(toggled(.italic, in: "***x***", selection: NSRange(location: 4, length: 0)))
        #expect(unitalicized.text == "**x**")
        #expect(unitalicized.selection == NSRange(location: 3, length: 0))
    }

    @Test("Adding the other emphasis to a span grows it to boldItalic")
    func emphasisGrowsToBoldItalic() throws {
        let boldedItalic = try #require(toggled(.bold, in: "*x*", selection: NSRange(location: 1, length: 1)))
        #expect(boldedItalic.text == "***x***")
        #expect(boldedItalic.selection == NSRange(location: 3, length: 1))

        let italicizedBold = try #require(toggled(.italic, in: "**x**", selection: NSRange(location: 2, length: 1)))
        #expect(italicizedBold.text == "***x***")
        #expect(italicizedBold.selection == NSRange(location: 3, length: 1))
    }

    @Test("Nested spans: the innermost carrier of the style wins")
    func nestedSpansUnwrapInnermost() throws {
        let text = "**bold *it* end**"

        let italic = try #require(toggled(.italic, in: text, selection: NSRange(location: 9, length: 0)))
        #expect(italic.text == "**bold it end**")
        #expect(italic.selection == NSRange(location: 8, length: 0))

        let bold = try #require(toggled(.bold, in: text, selection: NSRange(location: 9, length: 0)))
        #expect(bold.text == "bold *it* end")
        #expect(bold.selection == NSRange(location: 7, length: 0))
    }

    // MARK: - Caret toggles (empty selection)

    @Test("A caret toggle inserts an empty pair with the caret centered")
    func caretInsertsEmptyPair() throws {
        let cases: [(MarkdownInlineToggle.Style, String, Int)] = [
            (.bold, "****", 2),
            (.italic, "**", 1),
            (.strikethrough, "~~~~", 2),
            (.highlight, "====", 2),
            (.code, "``", 1),
            (.link, "[]()", 1)
        ]
        for (style, expected, caret) in cases {
            let result = try #require(toggled(style, in: "", selection: NSRange(location: 0, length: 0)))
            #expect(result.text == expected)
            #expect(result.selection == NSRange(location: caret, length: 0))
        }

        let midWord = try #require(toggled(.bold, in: "word", selection: NSRange(location: 2, length: 0)))
        #expect(midWord.text == "wo****rd")
        #expect(midWord.selection == NSRange(location: 4, length: 0))
    }

    @Test("Toggling at the caret twice returns to the original text")
    func caretToggleRoundTrips() throws {
        for style in [MarkdownInlineToggle.Style.bold, .italic, .strikethrough, .highlight, .code, .link] {
            let on = try #require(toggled(style, in: "ab", selection: NSRange(location: 1, length: 0)))
            let off = try #require(toggled(style, in: on.text, selection: on.selection))
            #expect(off.text == "ab")
            #expect(off.selection == NSRange(location: 1, length: 0))
        }
    }

    @Test("Empty emphasis pairs use run arithmetic, preserving the delimiter")
    func emptyEmphasisRunArithmetic() throws {
        // ***⎸*** minus bold → *⎸*; minus italic → **⎸**.
        let unbolded = try #require(toggled(.bold, in: "******", selection: NSRange(location: 3, length: 0)))
        #expect(unbolded.text == "**")
        #expect(unbolded.selection == NSRange(location: 1, length: 0))

        let unitalicized = try #require(toggled(.italic, in: "******", selection: NSRange(location: 3, length: 0)))
        #expect(unitalicized.text == "****")
        #expect(unitalicized.selection == NSRange(location: 2, length: 0))

        // *⎸* plus bold → ***⎸***; **⎸** plus italic → ***⎸***.
        let bolded = try #require(toggled(.bold, in: "**", selection: NSRange(location: 1, length: 0)))
        #expect(bolded.text == "******")
        #expect(bolded.selection == NSRange(location: 3, length: 0))

        let italicized = try #require(toggled(.italic, in: "****", selection: NSRange(location: 2, length: 0)))
        #expect(italicized.text == "******")
        #expect(italicized.selection == NSRange(location: 3, length: 0))

        // The underscore flavor is preserved.
        let underscore = try #require(toggled(.bold, in: "______", selection: NSRange(location: 3, length: 0)))
        #expect(underscore.text == "__")
    }

    @Test("Asymmetric or oversized runs and adjacent delimiters are no-ops")
    func degenerateCaretPositionsAreNoOps() {
        // **⎸* — asymmetric.
        #expect(toggled(.bold, in: "***", selection: NSRange(location: 2, length: 0)) == nil)
        // ****⎸**** — beyond the grammar.
        #expect(toggled(.bold, in: "********", selection: NSRange(location: 4, length: 0)) == nil)
        // ⎸*ab — a fresh pair would merge with the run after the caret.
        #expect(toggled(.bold, in: "*ab", selection: NSRange(location: 0, length: 0)) == nil)
        // ~~~⎸~~~ — the exact-pair probe must not bite into longer runs.
        #expect(toggled(.strikethrough, in: "~~~~~~", selection: NSRange(location: 3, length: 0)) == nil)
    }

    // MARK: - Code

    @Test("Code wraps pick a fence longer than any run inside")
    func codeFenceEscalation() throws {
        let plain = try #require(toggled(.code, in: "run it now", selection: NSRange(location: 4, length: 2)))
        #expect(plain.text == "run `it` now")
        #expect(plain.selection == NSRange(location: 5, length: 2))

        let withTick = try #require(toggled(.code, in: "x`y", selection: NSRange(location: 0, length: 3)))
        #expect(withTick.text == "``x`y``")
        #expect(withTick.selection == NSRange(location: 2, length: 3))

        // Edge backtick would merge with the fence; a triple run overflows it.
        #expect(toggled(.code, in: "ab`", selection: NSRange(location: 0, length: 3)) == nil)
        #expect(toggled(.code, in: "a```b", selection: NSRange(location: 0, length: 5)) == nil)
    }

    @Test("A caret inside a code span unwraps it")
    func codeUnwraps() throws {
        let result = try #require(toggled(.code, in: "`code`", selection: NSRange(location: 3, length: 0)))
        #expect(result.text == "code")
        #expect(result.selection == NSRange(location: 2, length: 0))
    }

    // MARK: - Links

    @Test("Link wrap builds the construct with the caret in the destination")
    func linkWrapPlacesCaretInDestination() throws {
        let result = try #require(toggled(.link, in: "click here", selection: NSRange(location: 6, length: 4)))
        #expect(result.text == "click [here]()")
        #expect(result.selection == NSRange(location: 13, length: 0))
    }

    @Test("Any position inside a link unwraps it to its label")
    func linkUnwrapsFromAnyPosition() throws {
        let text = "[a](https://x.com)"

        let fromLabel = try #require(toggled(.link, in: text, selection: NSRange(location: 1, length: 0)))
        #expect(fromLabel.text == "a")
        #expect(fromLabel.selection == NSRange(location: 0, length: 0))

        let fromDestination = try #require(toggled(.link, in: text, selection: NSRange(location: 8, length: 0)))
        #expect(fromDestination.text == "a")
        #expect(fromDestination.selection == NSRange(location: 1, length: 0))
    }

    @Test("Link wraps refuse bracket characters and partial link overlap")
    func linkWrapRefusesInvalidShapes() {
        #expect(toggled(.link, in: "a]b", selection: NSRange(location: 0, length: 3)) == nil)
        // A selection reaching past the link would destroy its destination.
        #expect(toggled(.link, in: "[a](https://x.com) tail", selection: NSRange(location: 10, length: 10)) == nil)
    }

    // MARK: - Scope and bounds

    @Test("Selections spanning lines are no-ops; a trailing newline is tolerated")
    func lineScope() throws {
        #expect(toggled(.bold, in: "ab\ncd", selection: NSRange(location: 0, length: 5)) == nil)

        // Triple-click line selection includes the terminator.
        let fullLine = try #require(toggled(.bold, in: "ab\ncd", selection: NSRange(location: 0, length: 3)))
        #expect(fullLine.text == "**ab**\ncd")
        #expect(fullLine.selection == NSRange(location: 2, length: 2))

        let secondLine = try #require(toggled(.bold, in: "ab\ncd", selection: NSRange(location: 3, length: 2)))
        #expect(secondLine.text == "ab\n**cd**")
        #expect(secondLine.selection == NSRange(location: 5, length: 2))
    }

    @Test("Out-of-bounds selections clamp instead of crashing")
    func outOfBoundsSelectionClamps() throws {
        let result = try #require(toggled(.bold, in: "abc", selection: NSRange(location: 10, length: 5)))
        #expect(result.text == "abc****")
        #expect(result.selection == NSRange(location: 5, length: 0))
    }
}
