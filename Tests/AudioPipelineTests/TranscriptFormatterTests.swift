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
