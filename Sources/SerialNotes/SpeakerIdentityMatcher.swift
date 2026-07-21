import Accelerate
import Foundation

/// Decides whether a detected speaker's voice embedding belongs to a known
/// (enrolled) person, using a three-tier confidence gate with an ambiguity
/// margin.
///
/// This is the rejection threshold the live diarizer lacks. `LSEENDDiarizer`
/// tracks speakers by fixed neural slots and exposes no similarity score, so
/// priming an enrolled name into it can route a brand-new voice into that slot
/// and mislabel a stranger as a known participant. Naming instead happens after
/// the meeting, against per-speaker embeddings, where we *can* say "this voice
/// is only weakly — or ambiguously — similar to a known profile, so leave it
/// anonymous."
///
/// The margin guard is the load-bearing idea (borrowed from OpenWhispr's
/// shipped `MATCH_MARGIN`): a name is auto-applied only when the best candidate
/// both clears `auto` *and* beats the runner-up by `margin`. A new voice that
/// sits near-equidistant between two known people is demoted to a suggestion
/// rather than guessed at.
///
/// Thresholds are specific to the embedding model that produced the vectors
/// (FluidAudio's 256-dim, L2-normalized WeSpeaker embeddings) and must be
/// calibrated against real recordings — see ``Thresholds/provisional``.
struct SpeakerIdentityMatcher {
    /// An enrolled person to match against. `embedding` is the profile's
    /// representative voice vector, expected L2-normalized.
    struct Candidate: Equatable, Sendable {
        let profileID: UUID
        let name: String
        let embedding: [Float]
    }

    /// Confidence cut-offs, in cosine-similarity units (1 = identical voice).
    struct Thresholds: Equatable, Sendable {
        /// Minimum similarity to apply a name automatically.
        var auto: Float
        /// Minimum similarity to *suggest* a name for one-tap confirmation.
        var suggest: Float
        /// The best candidate must beat the runner-up by at least this much to
        /// be auto-applied; otherwise it is demoted to a suggestion. Guards the
        /// "new voice near two known people" mislabel.
        var margin: Float
        /// Until capture-condition calibration is complete, a single enrolled
        /// candidate never auto-applies. It can still be suggested for a one-tap
        /// user confirmation, which is safer than silently naming a stranger.
        var requireRunnerUpForAutomaticConfirmation: Bool = true
        /// Sub-floor fragment adoption (`OfflineSpeakerIdentifier.adopt`): the
        /// minimum similarity for a short fragment to join a surviving speaker.
        /// Call-start audio (codec ramp-up, a Bluetooth headset switching into
        /// call mode) often embeds far enough from the same speaker's main
        /// cluster to miss the merge bar; the merge calibration (same speaker
        /// ≈ 0.96, different ≤ 0.31) leaves room to adopt at 0.4 without
        /// crossing a different voice. Must stay strictly below
        /// `OfflineSpeakerIdentifier.defaultMergeThreshold` (pinned by test).
        var fragmentAdoption: Float = 0.4
        /// With several survivors a fragment must lead the runner-up by this
        /// much — an ambiguous near-tie stays dropped. Both adoption values are
        /// provisional pending calibration on real recordings.
        var fragmentAdoptionMargin: Float = 0.1

        /// Calibrated on real audio (FluidAudio WeSpeaker embeddings): same speaker
        /// ≈ 0.96, different ≤ 0.31, so the gap is wide and these are forgiving.
        /// `auto` 0.6 and `suggest` 0.45 sit comfortably above the observed impostor
        /// ceiling; the 0.10 margin guards an ambiguous near-tie. These remain
        /// provisional for Bluetooth/HFP capture, so the default requires a runner-up
        /// before it automatically applies a name.
        static let provisional = Thresholds(auto: 0.6, suggest: 0.45, margin: 0.1)
    }

    /// The outcome for one detected speaker.
    enum Decision: Equatable, Sendable {
        /// Confidently the named person — apply the name without asking.
        case confirmed(profileID: UUID, name: String, similarity: Float)
        /// Plausibly the named person — surface as a suggestion the user accepts.
        case suggested(profileID: UUID, name: String, similarity: Float)
        /// No confident match — leave the speaker anonymous ("Person N").
        case anonymous
    }

    var thresholds: Thresholds = .provisional

    /// Match one speaker embedding against the enrolled candidates. `embedding`
    /// and every candidate embedding should be L2-normalized; cosine is computed
    /// defensively either way.
    func match(_ embedding: [Float], against candidates: [Candidate]) -> Decision {
        guard !candidates.isEmpty else { return .anonymous }

        let scored = candidates
            .map { (candidate: $0, similarity: Self.cosineSimilarity(embedding, $0.embedding)) }
            .sorted { $0.similarity > $1.similarity }

        let best = scored[0]
        let hasRunnerUp = scored.count > 1
        let runnerUp = hasRunnerUp ? scored[1].similarity : -Float.greatestFiniteMagnitude
        let clearWinner = hasRunnerUp && (best.similarity - runnerUp) >= thresholds.margin
        let canAutomaticallyConfirm = clearWinner || !thresholds.requireRunnerUpForAutomaticConfirmation

        if best.similarity >= thresholds.auto {
            // Confident enough to name, but only auto-apply when it's also an
            // unambiguous winner; near-ties drop to a suggestion so the user
            // disambiguates rather than us silently picking one.
            return canAutomaticallyConfirm
                ? .confirmed(profileID: best.candidate.profileID, name: best.candidate.name, similarity: best.similarity)
                : .suggested(profileID: best.candidate.profileID, name: best.candidate.name, similarity: best.similarity)
        }
        if best.similarity >= thresholds.suggest {
            return .suggested(profileID: best.candidate.profileID, name: best.candidate.name, similarity: best.similarity)
        }
        return .anonymous
    }

    /// Cosine similarity of two equal-length vectors. For unit-length inputs
    /// (the diarizer guarantees L2-normalized embeddings) this reduces to the
    /// dot product, but we divide by the norms so a caller that passes an
    /// un-normalized enrollment vector can't silently get a wrong score.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        var sumSqA: Float = 0
        var sumSqB: Float = 0
        vDSP_svesq(a, 1, &sumSqA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &sumSqB, vDSP_Length(b.count))
        guard sumSqA > 0, sumSqB > 0 else { return 0 }
        return dot / (sumSqA.squareRoot() * sumSqB.squareRoot())
    }
}
