import Foundation
import Testing

@testable import SerialNotes

@Suite("Speaker Relabel + Name Sanitization")
struct SpeakerRelabelTests {
    // MARK: - relabelSpeaker

    @Test("Relabels only the matching speaker header")
    func relabelsMatchingHeader() {
        let transcript = """
        **Person 2** (00:00:05): Hello there.

        **Person 1** (00:00:09): Hi back.
        """
        let out = SpeakerClipExtractor.relabelSpeaker(in: transcript, from: "Person 2", to: "Alex")
        #expect(out.contains("**Alex** (00:00:05): Hello there."))
        #expect(out.contains("**Person 1** (00:00:09): Hi back."))
        #expect(!out.contains("**Person 2**"))
    }

    @Test("Person 2 does not match Person 20")
    func boundaryDoesNotMatchLongerLabel() {
        let transcript = """
        **Person 20** (00:00:05): I am twenty.

        **Person 2** (00:00:09): I am two.
        """
        let out = SpeakerClipExtractor.relabelSpeaker(in: transcript, from: "Person 2", to: "Bob")
        #expect(out.contains("**Person 20** (00:00:05): I am twenty."))
        #expect(out.contains("**Bob** (00:00:09): I am two."))
        #expect(!out.contains("**Person 2** ("))
    }

    @Test("Rewrites every occurrence of the speaker")
    func rewritesAllOccurrences() {
        let transcript = """
        **Person 3** (00:00:01): One.

        **Person 3** (00:01:02): Two.

        **Person 3** (01:00:03): Three.
        """
        let out = SpeakerClipExtractor.relabelSpeaker(in: transcript, from: "Person 3", to: "Casey")
        #expect(out.components(separatedBy: "**Casey** (").count == 4) // 3 headers → 3 splits + 1
        #expect(!out.contains("**Person 3**"))
    }

    @Test("Is idempotent — a second pass is a no-op")
    func idempotent() {
        let transcript = "**Person 2** (00:00:05): Hello."
        let once = SpeakerClipExtractor.relabelSpeaker(in: transcript, from: "Person 2", to: "Alex")
        let twice = SpeakerClipExtractor.relabelSpeaker(in: once, from: "Person 2", to: "Alex")
        #expect(once == twice)
    }

    @Test("Relabels summary prose and action-item owners above the first entry")
    func relabelsSummaryAndActionItems() {
        let transcript = """
        # Meeting — 2026-06-05 at 6:26 PM

        ## Summary

        - Person 2 raised the budget question.

        ## Action items

        - [ ] **Person 2** — send the report

        **Person 2** (00:00:05): I'll send it.
        """
        let out = SpeakerClipExtractor.relabelSpeaker(in: transcript, from: "Person 2", to: "Dana")
        // Header, summary bullet, and bold action-item owner all carry the new name.
        #expect(out.contains("**Dana** (00:00:05): I'll send it."))
        #expect(out.contains("- [ ] **Dana** — send the report"))
        #expect(out.contains("- Dana raised the budget question."))
        #expect(!out.contains("Person 2"))
    }

    @Test("A spoken label inside the transcript body is left untouched")
    func leavesSpokenLabelInBodyAlone() {
        let transcript = """
        ## Summary

        - Person 2 asked about Person 2's role.

        **Person 1** (00:00:05): I think Person 2 should lead this.

        **Person 2** (00:00:09): Sure.
        """
        let out = SpeakerClipExtractor.relabelSpeaker(in: transcript, from: "Person 2", to: "Dana")
        // Summary prose is rewritten…
        #expect(out.contains("- Dana asked about Dana's role."))
        // …but a quote that literally mentions the label in the body is preserved.
        #expect(out.contains("I think Person 2 should lead this."))
        // The body header for the named speaker still flips.
        #expect(out.contains("**Dana** (00:00:09): Sure."))
    }

    @Test("Summary 'Person 1' does not clobber 'Person 10'")
    func summaryBoundaryDoesNotMatchLongerLabel() {
        let transcript = """
        ## Summary

        - Person 1 and Person 10 disagreed.

        **Person 1** (00:00:05): Hi.
        """
        let out = SpeakerClipExtractor.relabelSpeaker(in: transcript, from: "Person 1", to: "Casey")
        #expect(out.contains("- Casey and Person 10 disagreed."))
        #expect(out.contains("**Casey** (00:00:05): Hi."))
    }

    @Test("Block-form headers (label on its own line) are relabeled")
    func blockFormHeader() {
        let transcript = "**Person 2** (00:00:05):\n\nA very long utterance body."
        let out = SpeakerClipExtractor.relabelSpeaker(in: transcript, from: "Person 2", to: "Eve")
        #expect(out.hasPrefix("**Eve** (00:00:05):"))
    }

    @Test("Relabels headers with 3-digit hours")
    func relabelsLongTimestamps() {
        let transcript = "**Person 2** (100:00:05): Marathon meeting."
        let out = SpeakerClipExtractor.relabelSpeaker(in: transcript, from: "Person 2", to: "Fin")
        #expect(out == "**Fin** (100:00:05): Marathon meeting.")
    }

    // MARK: - sanitizedName

    @Test("Strips Markdown metacharacters")
    func stripsMarkdown() {
        #expect(SpeakerClipExtractor.sanitizedName("**Bob**") == "Bob")
        #expect(SpeakerClipExtractor.sanitizedName("A`l`ex") == "Alex")
        #expect(SpeakerClipExtractor.sanitizedName("Bob (Sales)") == "Bob Sales")
        #expect(SpeakerClipExtractor.sanitizedName("#Lead [x]") == "Lead x")
    }

    @Test("Collapses newlines and whitespace to a single line")
    func collapsesWhitespace() {
        #expect(SpeakerClipExtractor.sanitizedName("Bob\nSmith") == "Bob Smith")
        #expect(SpeakerClipExtractor.sanitizedName("  Bob   Smith  ") == "Bob Smith")
        #expect(SpeakerClipExtractor.sanitizedName("Bob\tSmith") == "Bob Smith")
    }

    @Test("Returns nil when nothing usable remains")
    func nilWhenEmpty() {
        #expect(SpeakerClipExtractor.sanitizedName("") == nil)
        #expect(SpeakerClipExtractor.sanitizedName("   ") == nil)
        #expect(SpeakerClipExtractor.sanitizedName("**``[]**") == nil)
    }
}
