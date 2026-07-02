import Foundation
import Testing

@testable import SerialNotes

@Suite("Meeting Exporter — Markdown rendering")
struct MeetingExporterTests {
    /// A transcript shaped exactly like what TranscriptFormatter writes to disk:
    /// YAML front-matter, the `# Meeting — …` H1, optional summary/action sections,
    /// then inline and block-form speaker entries.
    static let sampleTranscript = """
    ---
    date: 2026-06-09
    duration: 01h02m03s
    ---

    # Meeting — 2026-06-09 at 3:04 PM


    ## Summary

    - We discussed the roadmap.

    ## Action items

    - [ ] **Dylan** — Ship Phase 2
    - [x] Review notes

    **You** (00:00:05): Hello <there> & welcome.

    **Person 2** (00:01:10):

    This is a longer block-form turn.

    """

    // MARK: - Front matter

    @Test("Strips the YAML front-matter, keeping the H1 first")
    func stripsFrontMatter() {
        let stripped = MeetingExporter.strippingFrontMatter(Self.sampleTranscript)
        #expect(stripped.hasPrefix("# Meeting — 2026-06-09 at 3:04 PM"))
        #expect(!stripped.contains("date:"))
        #expect(!stripped.contains("duration:"))
        #expect(!stripped.contains("---"))
    }

    @Test("Leaves content without front-matter unchanged")
    func noFrontMatterUnchanged() {
        let input = "# Title\n\nbody"
        #expect(MeetingExporter.strippingFrontMatter(input) == input)
    }

    @Test("Returns input unchanged when the closing fence is missing")
    func unterminatedFrontMatter() {
        let input = "---\ndate: 2026-06-09\n# Meeting"
        #expect(MeetingExporter.strippingFrontMatter(input) == input)
    }

    // MARK: - HTML body

    @Test("Renders headings, lists, task items and speaker turns to single-line HTML")
    func rendersHTML() {
        let body = MeetingExporter.strippingFrontMatter(Self.sampleTranscript)
        let html = MeetingExporter.htmlBody(fromMarkdown: body)

        // Apple Notes' body literal is embedded in AppleScript — it must be one line.
        #expect(!html.contains("\n"))

        #expect(html.contains("<h1>Meeting — 2026-06-09 at 3:04 PM</h1>"))
        #expect(html.contains("<h2>Summary</h2>"))
        #expect(html.contains("<li>We discussed the roadmap.</li>"))
        #expect(html.contains("<h2>Action items</h2>"))
        // Unchecked task item with the bold owner.
        #expect(html.contains("<li>\u{2610} <b>Dylan</b> — Ship Phase 2</li>"))
        // Checked task item — assert the glyph too, not just the text.
        #expect(html.contains("<li>\u{2611}\u{FE0E} Review notes</li>"))
        // Inline speaker turn with the label bolded and HTML escaped.
        #expect(html.contains("<p><b>You</b> (00:00:05): Hello &lt;there&gt; &amp; welcome.</p>"))
        // Block-form turn: header line and body line each become a paragraph.
        #expect(html.contains("<p><b>Person 2</b> (00:01:10):</p>"))
        #expect(html.contains("<p>This is a longer block-form turn.</p>"))
    }

    @Test("Bullet lists are wrapped in a single <ul> and closed on a blank line")
    func bulletListGrouping() {
        let html = MeetingExporter.htmlBody(fromMarkdown: "- one\n- two\n\nafter")
        #expect(html == "<ul><li>one</li><li>two</li></ul><p>after</p>")
    }

    @Test("Nested bullets emit child lists inside the parent item")
    func nestedBulletLists() {
        // Tabs and space pairs both mean one level (TranscriptFormatter rule).
        let html = MeetingExporter.htmlBody(fromMarkdown: "* top\n\t* nested tab\n  * nested spaces\n* top again")
        #expect(html == "<ul><li>top<ul><li>nested tab</li><li>nested spaces</li></ul></li><li>top again</li></ul>")
    }

    @Test("Ordered lists render as <ol> and nest under bullets")
    func orderedLists() {
        let html = MeetingExporter.htmlBody(fromMarkdown: "1. first\n2. second\n\n* parent\n\t1. step")
        #expect(html == "<ol><li>first</li><li>second</li></ol><ul><li>parent<ol><li>step</li></ol></li></ul>")
    }

    @Test("A list-type switch at the same level closes the previous list")
    func listTypeSwitch() {
        let html = MeetingExporter.htmlBody(fromMarkdown: "* bullet\n1. number")
        #expect(html == "<ul><li>bullet</li></ul><ol><li>number</li></ol>")
    }

    @Test("A multi-level outdent closes every intermediate list")
    func multiLevelOutdent() {
        let html = MeetingExporter.htmlBody(fromMarkdown: "* a\n\t* b\n\t\t* c\n* d")
        #expect(html == "<ul><li>a<ul><li>b<ul><li>c</li></ul></li></ul></li><li>d</li></ul>")
    }

    // MARK: - Inline conversion

    @Test("Escapes HTML special characters")
    func escapesHTML() {
        #expect(MeetingExporter.inlineHTML("a < b & c > d") == "a &lt; b &amp; c &gt; d")
    }

    @Test("Converts balanced bold and italic markers")
    func convertsEmphasis() {
        #expect(MeetingExporter.inlineHTML("**bold** and *italic*") == "<b>bold</b> and <i>italic</i>")
    }

    @Test("Leaves an unbalanced single marker as literal text")
    func leavesUnbalancedMarker() {
        #expect(MeetingExporter.inlineHTML("5 * 3 = 15") == "5 * 3 = 15")
    }

    @Test("A stray ** in body text does not corrupt the bold speaker label")
    func strayDoubleStarKeepsLabel() {
        // The exact regression: "**You** … C++ uses ** for pointers" used to render
        // the label as <i></i>You<i></i>. The label must stay bold, the stray ** stays literal.
        let html = MeetingExporter.inlineHTML("**You** (00:00:05): C++ uses ** for pointers")
        #expect(html.contains("<b>You</b>"))
        #expect(!html.contains("<i>"))
        #expect(html.contains("C++ uses ** for pointers"))
    }

    @Test("A stray ** after a bold owner does not spill emphasis into the body")
    func strayDoubleStarAfterOwner() {
        let html = MeetingExporter.inlineHTML("**Alex** — migrate to React 18** then 19")
        #expect(html.contains("<b>Alex</b>"))
        #expect(!html.contains("<i>"))
    }

    @Test("Space-flanked literal asterisks are not turned into italics")
    func spaceFlankedAsterisksStayLiteral() {
        #expect(MeetingExporter.inlineHTML("the *.txt and *.md files") == "the *.txt and *.md files")
    }

    @Test("Bold can contain a nested italic span")
    func nestedEmphasis() {
        #expect(MeetingExporter.inlineHTML("**bold *and italic* here**") == "<b>bold <i>and italic</i> here</b>")
    }

    @Test("Triple-star renders bold-italic; straddling markers still never cross tags")
    func emphasisNeverCrossesTags() {
        // `***x***` is a first-class bold-italic span (mirrors the notepad editor).
        #expect(MeetingExporter.inlineHTML("***triple***") == "<b><i>triple</i></b>")
        // A single `*` straddling a `**` boundary still degrades to literal
        // asterisks rather than overlapping tags like <b><i>one</b></i>.
        #expect(MeetingExporter.inlineHTML("**one *two** three*") == "<b>one *two</b> three*")
    }

    @Test("Non-LF line separators still collapse to a single line of HTML")
    func nonLFSeparators() {
        // transcript.md is user-editable, so it may arrive with CR / CRLF / U+2028.
        let body = "# Title\r\n\r\nfirst\u{2028}second\rthird"
        let html = MeetingExporter.htmlBody(fromMarkdown: body)
        #expect(html.rangeOfCharacter(from: .newlines) == nil)
        #expect(html.contains("<h1>Title</h1>"))
    }
}

@Suite("Export settings")
@MainActor
struct ExportSettingsTests {
    @Test("activeTargets reflects the enabled toggles")
    func activeTargetsMapping() {
        // ExportSettings persists to UserDefaults.standard, so set explicit values
        // up front rather than relying on the persisted state.
        let settings = ExportSettings()
        settings.sendToAppleNotes = false
        settings.sendToBear = false
        #expect(settings.activeTargets.isEmpty)

        settings.setEnabled(.appleNotes, true)
        #expect(settings.activeTargets == [.appleNotes])

        settings.setEnabled(.bear, true)
        #expect(settings.activeTargets == [.appleNotes, .bear])

        settings.setEnabled(.appleNotes, false)
        #expect(settings.activeTargets == [.bear])
    }
}

@Suite("AppleScript literal escaping")
struct AppleScriptStringTests {
    @Test("Escapes backslash then quote so the value is a safe \"…\" literal")
    func escapesBackslashAndQuote() {
        #expect(AppleScriptString.escapingLiteral("plain") == "plain")
        #expect(AppleScriptString.escapingLiteral(#"a "q" b"#) == #"a \"q\" b"#)
        #expect(AppleScriptString.escapingLiteral(#"c:\path"#) == #"c:\\path"#)
        // Backslash is escaped before the quote, so a literal \" becomes \\\".
        #expect(AppleScriptString.escapingLiteral(#"\""#) == #"\\\""#)
    }
}
