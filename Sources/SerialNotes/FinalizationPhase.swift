import Foundation

/// Coarse milestones of the post-meeting pipeline (`TranscriptionService.endSession`),
/// surfaced in the popover while a stopped recording finalizes. The two long stages —
/// the batch high-accuracy ASR pass and the Foundation Models summary call — expose
/// no incremental progress, so the bar advances at stage boundaries only:
/// `fractionComplete` is a milestone position, not a measurement.
enum FinalizationPhase: Sendable {
    /// Draining streaming rewrites, finalizing diarizers, flushing entries.
    case finishingTranscript
    /// High-accuracy second ASR pass over the saved WAVs — usually the longest stage.
    case improvingTranscript
    /// Foundation Models summary + action items.
    case summarizing
    /// Speaker clip extraction, audio cleanup, diagnostics.
    case wrappingUp

    var label: String {
        switch self {
        case .finishingTranscript: "Finalizing transcript…"
        case .improvingTranscript: "Improving accuracy…"
        case .summarizing: "Writing summary…"
        case .wrappingUp: "Wrapping up…"
        }
    }

    var fractionComplete: Double {
        switch self {
        case .finishingTranscript: 0.1
        case .improvingTranscript: 0.35
        case .summarizing: 0.7
        case .wrappingUp: 0.9
        }
    }
}
