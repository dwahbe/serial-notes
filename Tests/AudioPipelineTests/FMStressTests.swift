import Foundation
import Testing

@testable import SerialNotes

/// Before/after benchmark for the Foundation Models call sites. Gated behind
/// SERIAL_FM_STRESS=1 — hits the real on-device model many times, so it is
/// never part of a normal `swift test` run. Run the same file against two
/// checkouts to compare implementations.
@Suite("FM Stress Comparison", .serialized)
struct FMStressTests {
    @Test(
        "Rewriter stress: sequential meeting utterances",
        .enabled(if: ProcessInfo.processInfo.environment["SERIAL_FM_STRESS"] == "1")
    )
    func rewriterStress() async {
        let rewriter = FoundationModelsRewriter()
        let heuristic = HeuristicRewriter()

        var fmRewrites = 0
        var verbatimEchoes = 0
        var heuristicFallbacks = 0
        var samples: [String] = []

        let start = ContinuousClock.now
        for (index, raw) in StressData.utterances.enumerated() {
            let out = await rewriter.rewrite(raw)
            let heur = await heuristic.rewrite(raw)
            if out == raw {
                verbatimEchoes += 1
            } else if out == heur {
                heuristicFallbacks += 1
            } else {
                fmRewrites += 1
            }
            if index < 4 || index >= StressData.utterances.count - 4 {
                samples.append("  [\(index)] IN : \(raw)\n  [\(index)] OUT: \(out)")
            }
        }
        let elapsed = start.duration(to: .now)

        print(
            """
            === REWRITER STRESS (\(StressData.utterances.count) utterances) ===
            genuine FM rewrites : \(fmRewrites)
            verbatim echoes     : \(verbatimEchoes)   <- silent failure: raw text passed through
            heuristic fallbacks : \(heuristicFallbacks)
            elapsed             : \(elapsed)
            --- first/last samples ---
            \(samples.joined(separator: "\n"))
            === END REWRITER STRESS ===
            """
        )
    }

    @Test(
        "Summarizer stress: long multi-topic transcript",
        .enabled(if: ProcessInfo.processInfo.environment["SERIAL_FM_STRESS"] == "1")
    )
    func summarizerStress() async {
        let summarizer = FoundationModelsSummarizer()
        let transcript = StressData.longTranscript()
        let words = transcript.split(whereSeparator: { $0.isWhitespace }).count

        let start = ContinuousClock.now
        let result = await summarizer.summarize(
            transcript: transcript,
            generateSummary: true,
            generateActionItems: true
        )
        let elapsed = start.duration(to: .now)

        let summaryText = result.summary.joined(separator: " ").lowercased()
        let coveredTopics = StressData.topicKeywords.filter { keywords in
            keywords.contains { summaryText.contains($0) }
        }.count

        let actionText = result.actionItems
            .map { "\($0.owner ?? "") \($0.task)" }
            .joined(separator: " ")
            .lowercased()
        let capturedActions = StressData.actionKeywords.filter { keywords in
            keywords.allSatisfy { actionText.contains($0) }
        }.count

        print(
            """
            === SUMMARIZER STRESS (\(words)-word transcript, 4 planted topics + 4 owned action items) ===
            summary bullets   : \(result.summary.count)
            topics covered    : \(coveredTopics)/4
            action items      : \(result.actionItems.count) returned, \(capturedActions)/4 planted ones captured with owner
            elapsed           : \(elapsed)
            --- summary ---
            \(result.summary.map { "  • \($0)" }.joined(separator: "\n"))
            --- action items ---
            \(result.actionItems.map { "  • [\($0.owner ?? "—")] \($0.task)" }.joined(separator: "\n"))
            === END SUMMARIZER STRESS ===
            """
        )
    }
}

/// Deterministic synthetic meeting data — identical on both sides of the A/B.
private enum StressData {
    /// 30 ASR-shaped utterances (lowercase, unpunctuated), mixing statements,
    /// questions, and longer rambles like a real meeting.
    static let utterances: [String] = [
        "okay so the main thing on the agenda today is the rollout plan for the new onboarding flow",
        "yeah i think we should ship it behind a flag first and watch the metrics for a week",
        "do you know if the analytics events are already wired up for the new screens",
        "they are mostly wired up but the completion event is still missing on the last step",
        "i talked to the design team yesterday and they want one more pass on the empty states",
        "that seems reasonable as long as it doesn't push us past the end of the month",
        "what happens to users who are halfway through the old flow when we flip the flag",
        "good question we should keep the old flow alive for existing sessions and only route new signups",
        "the database migration finished on staging last night and the row counts all match production",
        "nice did anyone check the p ninety five latency on the new query path",
        "it's about twelve milliseconds slower which is within the budget we agreed on",
        "i'm a little worried about the retry storm we saw in the logs on tuesday",
        "that was the misconfigured backoff in the sync client and the fix is already merged",
        "can we add an alert for that class of failure so we don't find it in the logs again",
        "sure i'll wire it into the existing pager rotation with a conservative threshold",
        "switching topics for a second has anyone heard back from legal about the data retention policy",
        "they approved the ninety day window but want the export tool documented before launch",
        "okay i can own the documentation if someone else takes the screenshots",
        "i'll do the screenshots after the design pass lands so they're not immediately stale",
        "the support team also asked for a way to look up a user's deletion status",
        "that already exists in the admin panel under the privacy tab it's just not labeled well",
        "let's rename it then a one line change saves them a ticket every week",
        "how confident are we in the load test numbers from last week",
        "fairly confident we ran it three times at twice the expected peak and nothing fell over",
        "remind me what the rollback plan is if error rates spike after the flag flip",
        "we flip the flag back and the old flow takes over within a minute no deploy needed",
        "perfect then i think we're in good shape to commit to the date with the marketing team",
        "before we wrap does anyone have concerns about the pricing page changes going out the same day",
        "only that we should stagger them by a few hours so we can attribute any traffic changes",
        "agreed let's do the flag flip in the morning and the pricing page after lunch",
    ]

    /// Per-topic keyword alternatives for coverage checks (any match counts).
    static let topicKeywords: [[String]] = [
        ["pricing"],
        ["crash", "stability"],
        ["sso", "single sign"],
        ["offsite", "off-site"],
    ]

    /// Planted action items: all keywords must appear in the owner+task text.
    static let actionKeywords: [[String]] = [
        ["maya", "pricing"],
        ["ben", "crash"],
        ["priya", "sso"],
        ["sam", "offsite"],
    ]

    /// ~6000-word transcript in the app's markdown format, four sections with
    /// distinct topics, each ending in one explicitly owned action item.
    static func longTranscript() -> String {
        struct Section {
            let topic: String
            let opener: String
            let filler: [String]
            let action: String
            let actionOwner: String
        }

        let sections = [
            Section(
                topic: "pricing",
                opener:
                    "Let's start with the pricing page redesign. The current tiers confuse trial users and the comparison table hides the annual discount.",
                filler: [
                    "The funnel data shows most drop-off happens right where the tier comparison loads, so the redesign has to simplify that table before anything else.",
                    "We tested three layouts with the research panel and the single-column version with expandable details beat the others on comprehension by a wide margin.",
                    "Finance signed off on keeping the same price points, so this is purely a presentation change and we don't need a billing migration.",
                    "The enterprise tier stays gated behind the contact form for now, although sales would prefer a self-serve quote calculator next quarter.",
                    "We should keep the FAQ anchor links because support sends those to confused customers several times a week.",
                ],
                action:
                    "I will draft the new pricing page copy and have it ready for review by Thursday.",
                actionOwner: "Maya"
            ),
            Section(
                topic: "crash",
                opener:
                    "Next up is the iOS crash spike from the last release. Crash-free sessions dropped from ninety-nine point eight to ninety-eight point nine.",
                filler: [
                    "The crash reporter points at the photo picker flow but the stack traces are truncated, so we only see the dispatch queue and not the originating call site.",
                    "It reproduces on older devices under memory pressure, which suggests the new thumbnail cache is holding decoded images longer than it should.",
                    "We shipped a similar regression two years ago and the fix then was to downsample before caching, so there's a known pattern to check first.",
                    "If the bisect takes more than a couple of days we should ship a mitigation that disables the cache behind a remote flag.",
                    "App review turnaround is about a day right now, so a hotfix release this week is realistic if we get a fix validated.",
                ],
                action: "Ben will bisect the crash to a commit and report findings tomorrow morning.",
                actionOwner: "Ben"
            ),
            Section(
                topic: "sso",
                opener:
                    "Third topic: the enterprise SSO pilot. Two design partners are ready to start as soon as we enable SAML on their tenants.",
                filler: [
                    "The identity provider metadata exchange worked cleanly in staging with both Okta and Azure AD, including the attribute mapping for display names.",
                    "Session lifetime needs a decision because their security team wants eight hours while our default is thirty days, and we currently have no per-tenant override.",
                    "Provisioning is manual for the pilot, which is fine for two customers, but the long-term plan needs SCIM and that's a separate quarter of work.",
                    "The audit log already records login events with the provider identifier, so compliance reporting mostly falls out for free.",
                    "We agreed the pilot success criteria are zero authentication-related support tickets and a signed expansion for at least one of the two partners.",
                ],
                action:
                    "Priya will enable the SSO pilot for both design partners and schedule their kickoff calls this week.",
                actionOwner: "Priya"
            ),
            Section(
                topic: "offsite",
                opener:
                    "Last item, the team offsite in September. We need to lock the venue this month or we lose the group rate.",
                filler: [
                    "The two candidate venues are the lakeside lodge from last year and the new conference center downtown, and the lodge is cheaper but harder to reach.",
                    "Most of the agenda should be working sessions rather than presentations, based on the feedback survey from the spring offsite.",
                    "We want the roadmap workshop on day one while everyone is fresh, with the team dinners and the unstructured afternoon on day two.",
                    "Travel booking needs three weeks of lead time for the folks flying in, so the venue decision really is the long pole.",
                    "Budget per person is the same as last year and finance asked us to keep ground transport inside it this time.",
                ],
                action: "Sam will book the offsite venue and send the calendar holds by Friday.",
                actionOwner: "Sam"
            ),
        ]

        let speakers = ["You", "Maya", "Ben", "Priya", "Sam"]
        var lines: [String] = []
        var seconds = 5

        func stamp() -> String {
            let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
            return String(format: "%02d:%02d:%02d", h, m, s)
        }

        for (sectionIndex, section) in sections.enumerated() {
            lines.append("**You** (\(stamp())): \(section.opener)")
            seconds += 45
            // ~45 filler turns per section (~1300 words), cycling speakers and
            // filler text, so the whole transcript forces map-reduce on both
            // the old word-count and new token-count thresholds.
            for turn in 0..<45 {
                let speaker = speakers[(sectionIndex + turn + 1) % speakers.count]
                let text = section.filler[turn % section.filler.count]
                lines.append("**\(speaker)** (\(stamp())): \(text)")
                seconds += 40
            }
            lines.append("**\(section.actionOwner)** (\(stamp())): \(section.action)")
            seconds += 60
        }

        return lines.joined(separator: "\n\n")
    }
}
