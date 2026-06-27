import Foundation
import Testing

@testable import SerialNotes

@Suite("Speaker Identity Matcher")
struct SpeakerIdentityMatcherTests {
    // Fixed thresholds so recalibrating the shipped defaults can't break these
    // logic tests. auto = 0.6, suggest = 0.5, margin = 0.03.
    private let thresholds = SpeakerIdentityMatcher.Thresholds(auto: 0.6, suggest: 0.5, margin: 0.03)

    private func matcher() -> SpeakerIdentityMatcher {
        var m = SpeakerIdentityMatcher()
        m.thresholds = thresholds
        return m
    }

    /// A 2-D unit vector whose cosine similarity with the query `[1, 0]` is
    /// exactly `s`. Lets each test name the similarity it's exercising.
    private func unit(at s: Float) -> [Float] {
        [s, (1 - s * s).squareRoot()]
    }

    private let query: [Float] = [1, 0]

    private func candidate(name: String, similarity: Float) -> SpeakerIdentityMatcher.Candidate {
        SpeakerIdentityMatcher.Candidate(profileID: UUID(), name: name, embedding: unit(at: similarity))
    }

    // MARK: - Tiers

    @Test("No candidates ⇒ anonymous")
    func noCandidates() {
        #expect(matcher().match(query, against: []) == .anonymous)
    }

    @Test("Below the suggest floor ⇒ anonymous")
    func belowSuggest() {
        let decision = matcher().match(query, against: [candidate(name: "Jake", similarity: 0.3)])
        #expect(decision == .anonymous)
    }

    @Test("Between suggest and auto ⇒ suggested")
    func midBandSuggests() {
        let decision = matcher().match(query, against: [candidate(name: "Jake", similarity: 0.55)])
        guard case let .suggested(_, name, _) = decision else {
            Issue.record("expected .suggested, got \(decision)")
            return
        }
        #expect(name == "Jake")
    }

    @Test("Single strong candidate ⇒ suggested until single-candidate calibration is enabled")
    func singleStrongSuggests() {
        let decision = matcher().match(query, against: [candidate(name: "Jake", similarity: 0.9)])
        guard case let .suggested(_, name, sim) = decision else {
            Issue.record("expected .suggested, got \(decision)")
            return
        }
        #expect(name == "Jake")
        #expect(abs(sim - 0.9) < 1e-3)
    }

    @Test("A calibrated policy can explicitly permit one-candidate confirmation")
    func singleStrongCanConfirmWhenEnabled() {
        var thresholds = thresholds
        thresholds.requireRunnerUpForAutomaticConfirmation = false
        var calibratedMatcher = SpeakerIdentityMatcher()
        calibratedMatcher.thresholds = thresholds
        let decision = calibratedMatcher.match(query, against: [candidate(name: "Jake", similarity: 0.9)])
        guard case .confirmed = decision else {
            Issue.record("expected .confirmed when the policy explicitly permits it")
            return
        }
    }

    @Test("Strong, clearly-separated winner ⇒ confirmed")
    func clearWinnerConfirms() {
        let decision = matcher().match(query, against: [
            candidate(name: "Jake", similarity: 0.9),
            candidate(name: "Sam", similarity: 0.4),
        ])
        guard case let .confirmed(_, name, _) = decision else {
            Issue.record("expected .confirmed, got \(decision)")
            return
        }
        #expect(name == "Jake")
    }

    // MARK: - The mislabel guard

    @Test("Strong but ambiguous (near-tie) ⇒ demoted to suggested, never auto-applied")
    func ambiguousNearTieDemotes() {
        // Both clear `auto` (0.6) but are within `margin` (0.03) of each other.
        // This is the "new voice sits between two known people" case that used to
        // mislabel a stranger as a known participant.
        let decision = matcher().match(query, against: [
            candidate(name: "Jake", similarity: 0.90),
            candidate(name: "Sam", similarity: 0.88),
        ])
        guard case let .suggested(_, name, _) = decision else {
            Issue.record("expected .suggested (ambiguous), got \(decision)")
            return
        }
        #expect(name == "Jake") // still surfaces the best guess, just doesn't auto-apply
    }

    @Test("Margin is measured against the runner-up, not the floor")
    func marginUsesRunnerUp() {
        // Best 0.95 vs runner-up 0.95 → diff 0 < margin → suggested even though
        // the best is very high-confidence on its own.
        let decision = matcher().match(query, against: [
            candidate(name: "Jake", similarity: 0.95),
            candidate(name: "Sam", similarity: 0.95),
        ])
        if case .confirmed = decision {
            Issue.record("near-identical candidates must not auto-confirm")
        }
    }

    // MARK: - cosineSimilarity

    @Test("Cosine: identical = 1, orthogonal = 0, opposite = -1")
    func cosineExtremes() {
        #expect(abs(SpeakerIdentityMatcher.cosineSimilarity([1, 0], [1, 0]) - 1) < 1e-6)
        #expect(abs(SpeakerIdentityMatcher.cosineSimilarity([1, 0], [0, 1]) - 0) < 1e-6)
        #expect(abs(SpeakerIdentityMatcher.cosineSimilarity([1, 0], [-1, 0]) + 1) < 1e-6)
    }

    @Test("Cosine normalizes un-normalized inputs (scale-invariant)")
    func cosineScaleInvariant() {
        let a: [Float] = [3, 4] // not unit length
        let b: [Float] = [6, 8] // same direction, scaled
        #expect(abs(SpeakerIdentityMatcher.cosineSimilarity(a, b) - 1) < 1e-6)
    }

    @Test("Cosine: length mismatch or empty ⇒ 0")
    func cosineGuards() {
        #expect(SpeakerIdentityMatcher.cosineSimilarity([], []) == 0)
        #expect(SpeakerIdentityMatcher.cosineSimilarity([1, 0], [1, 0, 0]) == 0)
    }
}
