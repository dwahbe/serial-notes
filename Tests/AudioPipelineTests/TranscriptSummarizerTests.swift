import Foundation
import Testing

@testable import SerialNotes

@Suite("Transcript Summarizer")
struct TranscriptSummarizerTests {
    @Test("Formatter: renders summary bullets")
    func formatterSummaryBullets() {
        let result = SummaryResult(
            summary: ["Discussed the roadmap.", "Decided to ship in Q3."],
            actionItems: []
        )
        let out = TranscriptFormatter.summarySections(result)

        #expect(out.contains("## Summary"))
        #expect(out.contains("- Discussed the roadmap."))
        #expect(out.contains("- Decided to ship in Q3."))
        #expect(!out.contains("## Action items"))
    }

    @Test("Formatter: renders action items with and without owner")
    func formatterActionItems() {
        let result = SummaryResult(
            summary: [],
            actionItems: [
                ActionItem(task: "Send the design doc by Friday", owner: "Dylan"),
                ActionItem(task: "Schedule a follow-up with platform", owner: nil)
            ]
        )
        let out = TranscriptFormatter.summarySections(result)

        #expect(out.contains("## Action items"))
        #expect(out.contains("- [ ] **Dylan** — Send the design doc by Friday"))
        #expect(out.contains("- [ ] Schedule a follow-up with platform"))
        #expect(!out.contains("## Summary"))
    }

    @Test("Formatter: empty result yields empty string")
    func formatterEmpty() {
        #expect(TranscriptFormatter.summarySections(.empty) == "")
    }

    @Test("Formatter: renders both sections in order")
    func formatterBothSections() {
        let result = SummaryResult(
            summary: ["A topic."],
            actionItems: [ActionItem(task: "Do a thing", owner: nil)]
        )
        let out = TranscriptFormatter.summarySections(result)

        let summaryRange = out.range(of: "## Summary")
        let actionsRange = out.range(of: "## Action items")
        #expect(summaryRange != nil)
        #expect(actionsRange != nil)
        if let s = summaryRange, let a = actionsRange {
            #expect(s.lowerBound < a.lowerBound, "Summary should come before action items")
        }
    }

    @Test("Minimum input gate: background-noise transcript falls below the threshold")
    func minimumInputGateRejectsNoise() {
        // Real-world fixture: a recording that caught only stray background
        // audio. Summarizing this made the model fabricate a full meeting.
        let noise = """
            **Voice 2** (00:00:04): Um

            **Voice 2** (00:01:17): Don're gonna let your

            **Voice 2** (00:01:21): map

            **Voice 2** (00:01:24): .
            """
        #expect(SummarizerTextProcessing.wordCount(noise) < SummarizerTextProcessing.minSummaryInputWords)
    }

    @Test("Minimum input gate: a brief real exchange clears the threshold")
    func minimumInputGateAcceptsShortMeeting() {
        let meeting = """
            **You** (00:00:02): Quick sync on the launch. The build is green and \
            the release notes are drafted, so I think we can tag tomorrow morning.

            **Person 2** (00:00:14): Sounds good. I'll finish the QA pass on the \
            installer tonight and send you the results before you tag.

            **You** (00:00:25): Great, and I'll update the website download link \
            once the release is published. Let's check in after lunch tomorrow.
            """
        #expect(SummarizerTextProcessing.wordCount(meeting) >= SummarizerTextProcessing.minSummaryInputWords)
    }

    @Test("Chunking: short transcript stays single chunk")
    func chunkingShortTranscript() {
        let text = "**You** (00:00:01): hello there\n\n**You** (00:00:05): how are you"
        let chunks = SummarizerTextProcessing.speakerTurnChunks(text, maxWords: 100)
        #expect(chunks.count == 1)
    }

    @Test("Chunking: splits on speaker turns when over word budget")
    func chunkingSplitsByTurn() {
        let turn1 = "**You** (00:00:01): " + Array(repeating: "alpha", count: 60).joined(separator: " ")
        let turn2 = "**Person 2** (00:00:30): " + Array(repeating: "beta", count: 60).joined(separator: " ")
        let turn3 = "**You** (00:01:00): " + Array(repeating: "gamma", count: 60).joined(separator: " ")
        let text = [turn1, turn2, turn3].joined(separator: "\n\n")

        let chunks = SummarizerTextProcessing.speakerTurnChunks(text, maxWords: 100)
        #expect(chunks.count >= 2, "Expected at least 2 chunks, got \(chunks.count)")
        for chunk in chunks {
            #expect(SummarizerTextProcessing.wordCount(chunk) > 0)
        }
    }

    @Test("Token-derived chunk words: scales budget by measured word density")
    func tokenDerivedChunkWordsScaling() {
        // 6000 words measured at 9000 tokens → 1.5 tokens/word. A 3072-token
        // budget at 0.9 safety should cap chunks at 3072 / 1.5 * 0.9 = 1843.
        let words = SummarizerTextProcessing.tokenDerivedChunkWords(
            bodyTokens: 9000,
            wordCount: 6000,
            inputTokenBudget: 3072,
            safetyFactor: 0.9,
            minWords: 200
        )
        #expect(words == 1843)
    }

    @Test("Token-derived chunk words: clamps to the minimum")
    func tokenDerivedChunkWordsMinimum() {
        let words = SummarizerTextProcessing.tokenDerivedChunkWords(
            bodyTokens: 10000,
            wordCount: 1000,
            inputTokenBudget: 500,
            safetyFactor: 0.9,
            minWords: 200
        )
        #expect(words == 200)
    }

    @Test("Token-derived chunk words: degenerate inputs return the minimum")
    func tokenDerivedChunkWordsDegenerate() {
        for (tokens, count, budget) in [(0, 100, 3072), (100, 0, 3072), (100, 100, 0)] {
            let words = SummarizerTextProcessing.tokenDerivedChunkWords(
                bodyTokens: tokens,
                wordCount: count,
                inputTokenBudget: budget,
                safetyFactor: 0.9,
                minWords: 200
            )
            #expect(words == 200)
        }
    }

    @Test("Action item sanitizer strips bullets, deduplicates with owner, and caps output")
    func actionItemSanitizer() {
        let items = [
            GeneratedActionItem(task: "- Send the website homework by Sunday", owner: " Dylan "),
            GeneratedActionItem(task: "Send the website homework by Sunday", owner: "Dylan"),
            GeneratedActionItem(task: "Work on copy", owner: "John Paul, Lily, and Bella"),
            GeneratedActionItem(task: "x", owner: "Jack"),
        ]

        let out = ActionItemPostProcessing.sanitize(items, maxItems: 2, minCharacters: 3)

        #expect(out == [
            ActionItem(task: "Send the website homework by Sunday", owner: "Dylan"),
            ActionItem(task: "Work on copy", owner: "John Paul, Lily, and Bella"),
        ])
    }

    @Test("Fake summarizer: respects per-section flags")
    func fakeSummarizerFlags() async {
        let summarizer = FakeSummarizer(
            summary: ["only summary"],
            actionItems: [ActionItem(task: "only action", owner: nil)]
        )

        let onlySummary = await summarizer.summarize(
            transcript: "x",
            generateSummary: true,
            generateActionItems: false
        )
        #expect(onlySummary.summary == ["only summary"])
        #expect(onlySummary.actionItems.isEmpty)

        let onlyActions = await summarizer.summarize(
            transcript: "x",
            generateSummary: false,
            generateActionItems: true
        )
        #expect(onlyActions.summary.isEmpty)
        #expect(onlyActions.actionItems.count == 1)

        let neither = await summarizer.summarize(
            transcript: "x",
            generateSummary: false,
            generateActionItems: false
        )
        #expect(neither.isEmpty)
    }

    /// FM smoke test gated by SERIAL_FM_TEST=1, mirroring the rewriter test.
    @Test(
        "FoundationModels summarizer smoke test (gated by SERIAL_FM_TEST)",
        .enabled(if: ProcessInfo.processInfo.environment["SERIAL_FM_TEST"] == "1")
    )
    func foundationModelsSmokeTest() async {
        let summarizer = FoundationModelsSummarizer()
        let transcript = """
            **You** (00:00:01): We need to review the launch checklist before Friday.
            **Person 2** (00:00:15): I will write up the rollout plan and share it tomorrow.
            **You** (00:00:30): Great, and I will sync with marketing.
            """
        let result = await summarizer.summarize(
            transcript: transcript,
            generateSummary: true,
            generateActionItems: true
        )

        #expect(!result.summary.isEmpty || !result.actionItems.isEmpty,
                "Expected at least one section populated, got empty result")
    }
}

private struct FakeSummarizer: TranscriptSummarizer {
    let summary: [String]
    let actionItems: [ActionItem]

    func summarize(
        transcript: String,
        generateSummary: Bool,
        generateActionItems: Bool
    ) async -> SummaryResult {
        SummaryResult(
            summary: generateSummary ? summary : [],
            actionItems: generateActionItems ? actionItems : []
        )
    }
}
