import Foundation
import Testing

@testable import SerialNotes

@Suite("Transcript Formatter")
struct TranscriptFormatterTests {
    @Test("Short entries stay inline")
    func shortEntriesStayInline() {
        let entry = TranscriptFormatter.entry(
            speaker: "You",
            timestamp: 3,
            text: "Hello world."
        )

        #expect(entry == "**You** (00:00:03): Hello world.\n\n")
    }

    @Test("Long entries render as readable paragraphs")
    func longEntriesRenderAsParagraphs() {
        let text = """
        First sentence has enough context to make this transcript entry too long for a compact inline line. Second sentence continues the same speaker turn with more useful detail for the reader. Third sentence closes the first paragraph naturally. Fourth sentence starts a new paragraph instead of extending the wall of text.
        """
        let entry = TranscriptFormatter.entry(
            speaker: "Person 1",
            timestamp: 65,
            text: text
        )

        #expect(entry.hasPrefix("**Person 1** (00:01:05):\n\n"))
        #expect(entry.contains("Third sentence closes the first paragraph naturally.\n\nFourth sentence starts a new paragraph"))
    }

    @Test("Summary input excludes entries after cutoff")
    func summaryInputExcludesEntriesAfterCutoff() {
        let body = """
        **Person 1** (00:00:05): Call content.

        **You** (00:00:12): More call content.

        **You** (00:00:35): Post-call hallway chatter.

        """

        let filtered = TranscriptFormatter.summaryInput(from: body, cutoff: 20)

        #expect(filtered.contains("Call content."))
        #expect(filtered.contains("More call content."))
        #expect(!filtered.contains("Post-call hallway chatter."))
    }

    @Test("Summary input keeps full body without cutoff")
    func summaryInputKeepsFullBodyWithoutCutoff() {
        let body = """
        **Person 1** (00:00:05): Call content.

        **You** (00:00:35): Post-call hallway chatter.

        """

        #expect(TranscriptFormatter.summaryInput(from: body, cutoff: nil) == body)
    }

    @Test("Manual notes render under notes heading")
    func manualNotesRenderUnderHeading() {
        let notes = """
        - Follow up on pricing

        Keep legal in the loop.
        """

        let section = TranscriptFormatter.manualNotesSection(notes)

        let marker = TranscriptFormatter.manualNotesEndMarker
        #expect(section == "## Notes\n\n- Follow up on pricing\n\nKeep legal in the loop.\n\n\(marker)\n\n")
    }

    @Test("Empty manual notes render no section")
    func emptyManualNotesRenderNoSection() {
        #expect(TranscriptFormatter.manualNotesSection(nil) == "")
        #expect(TranscriptFormatter.manualNotesSection(" \n\t ") == "")
    }

    @Test("Manual notes precede generated top sections")
    func manualNotesPrecedeGeneratedSections() {
        let result = SummaryResult(
            summary: ["Discussed launch timing."],
            actionItems: [ActionItem(task: "Send the launch checklist", owner: "You")]
        )
        let top = TranscriptFormatter.topSections(
            manualNotes: "Customer asked about beta access.",
            summary: result
        )

        let notesRange = top.range(of: "## Notes")
        let summaryRange = top.range(of: "## Summary")
        let actionsRange = top.range(of: "## Action items")
        #expect(notesRange != nil)
        #expect(summaryRange != nil)
        #expect(actionsRange != nil)
        if let n = notesRange, let s = summaryRange, let a = actionsRange {
            #expect(n.lowerBound < s.lowerBound)
            #expect(s.lowerBound < a.lowerBound)
        }
    }

    @Test("Speaker parsing ignores manual notes")
    func speakerParsingIgnoresManualNotes() {
        let transcript = """
        ## Notes

        **Person 1** is the budget owner.

        **Person 1** (00:00:05): Actual transcript entry.
        """

        let parsed = SpeakerClipExtractor.parseEntries(transcript)

        #expect(parsed == [
            SpeakerClipExtractor.ParsedEntry(
                label: "Person 1",
                timestamp: 5,
                text: "Actual transcript entry."
            )
        ])
    }

    @Test("Pasted transcript quote inside notes is not parsed as an entry")
    func pastedQuoteInNotesIsNotAnEntry() {
        let transcript = """
        ## Notes

        **Person 1** (00:00:05): pasted quote from another meeting

        \(TranscriptFormatter.manualNotesEndMarker)

        ## Summary

        - Person 1 raised the budget question.

        **Person 1** (00:01:00): Real entry.
        """

        let parsed = SpeakerClipExtractor.parseEntries(transcript)

        #expect(parsed == [
            SpeakerClipExtractor.ParsedEntry(
                label: "Person 1",
                timestamp: 60,
                text: "Real entry."
            )
        ])
        #expect(SpeakerClipExtractor.entryTimestamps(for: "Person 1", in: transcript) == [60])
    }

    @Test("Notes line range requires the closing sentinel")
    func notesLineRangeRequiresSentinel() {
        let withoutMarker = ["## Notes", "", "text", ""]
        #expect(TranscriptFormatter.manualNotesLineRange(in: withoutMarker) == nil)

        let withMarker = ["## Notes", "", "text", TranscriptFormatter.manualNotesEndMarker, "body"]
        #expect(TranscriptFormatter.manualNotesLineRange(in: withMarker) == 0...3)
    }

    @Test("Exports strip the notes sentinel")
    func exportsStripNotesSentinel() {
        let body = "## Notes\n\nplan\n\n\(TranscriptFormatter.manualNotesEndMarker)\n\n**You** (00:00:01): hi"

        let stripped = MeetingExporter.strippingManualNotesMarker(body)
        #expect(!stripped.contains(TranscriptFormatter.manualNotesEndMarker))
        #expect(stripped.contains("plan"))
        #expect(!MeetingExporter.htmlBody(fromMarkdown: stripped).contains("serial-notes"))
    }

    @Test("Replaces only the shared entry-header label token")
    func replacesEntryHeaderLabel() {
        let line = "**Person 1** (00:00:05): Person 1 said hello."
        let rewritten = TranscriptFormatter.replacingEntryHeaderLabel(
            in: line, from: "Person 1", to: "Jake"
        )
        #expect(rewritten == "**Jake** (00:00:05): Person 1 said hello.")
        #expect(TranscriptFormatter.replacingEntryHeaderLabel(
            in: line, from: "Person 2", to: "Jake"
        ) == nil)
    }
}
