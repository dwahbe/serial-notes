import Foundation

/// Pure reducer for *start*-of-meeting detection. **Edge-triggered**: it prompts
/// only when a known meeting app *transitions* into capturing the mic — never for
/// an app that was already capturing when monitoring began (the baseline). This is
/// what keeps an idle Zoom warm-holding the mic from firing a phantom "meeting
/// detected" prompt: a steady warm-hold never produces a transition.
///
/// Mirrors `CallEndStateMachine`: fed successive capturing-owner snapshots plus
/// user events, it emits `[Effect]` consumed by `MeetingDetectionService`. The
/// service supplies the CoreAudio scan (which known meeting apps currently capture
/// input) and a frontmost→recent→alphabetical `order` for disambiguating
/// simultaneous transitions, so this type stays pure and fully unit-testable.
///
/// A candidate must *sustain* capture past a debounce before it prompts — the
/// service runs the timer and calls `debounceTimerFired`; the reducer confirms the
/// app is still capturing and unsuppressed. This rejects momentary idle mic-pokes
/// while a real call (which holds the mic continuously) survives.
struct MeetingStartDetector: Sendable {
    enum Effect: Equatable, Sendable {
        /// Begin (or restart) the sustain debounce for `bundleID`; on expiry the
        /// service calls `debounceTimerFired(bundleID:)`.
        case startDebounceTimer(bundleID: String)
        /// Cancel any in-flight debounce timer.
        case cancelDebounceTimer
        /// Surface the start prompt for `bundleID`.
        case showPrompt(bundleID: String)
        /// Retract the start prompt.
        case hidePrompt
    }

    /// The set of capturing bundle IDs observed on the first snapshot — treated as
    /// already-in-progress and never prompted. `nil` until the first snapshot lands.
    private var baseline: Set<String>?
    /// Capturing set from the most recent snapshot.
    private var previouslyCapturing: Set<String> = []
    /// The app a prompt is currently shown for. Held until it stops capturing (or
    /// the user acts), so a focus change / a second app can't move the prompt.
    private(set) var lockedBundleID: String?
    /// The app whose debounce is in flight (not yet prompted).
    private var pendingBundleID: String?
    /// Apps whose *current* capture episode the user rejected (dismissed). Cleared
    /// when the app stops capturing, so a genuinely new later call re-prompts.
    private var suppressedEpisodes: Set<String> = []

    /// Seconds a fresh capture must be sustained before prompting. Read by the
    /// service's debounce timer so the two can't drift (mirrors
    /// `CallEndStateMachine.inactiveGraceSeconds`).
    let debounceSeconds: TimeInterval

    init(debounceSeconds: TimeInterval = 1.5) {
        self.debounceSeconds = debounceSeconds
    }

    /// Feed the current set of known meeting apps capturing mic input. `order` lists
    /// the same apps in disambiguation preference (frontmost → most-recent →
    /// alphabetical) for picking among simultaneous new transitions.
    mutating func receiveCapturing(_ owners: Set<String>, order: [String]) -> [Effect] {
        // First snapshot establishes the baseline — nothing already capturing prompts.
        guard baseline != nil else {
            baseline = owners
            previouslyCapturing = owners
            return []
        }

        let previous = previouslyCapturing
        previouslyCapturing = owners

        var effects: [Effect] = []

        // Apps that stopped capturing end their episode: drop suppression (so a
        // future call re-prompts) and retract any prompt/debounce tied to them.
        let stopped = previous.subtracting(owners)
        for bundleID in stopped {
            suppressedEpisodes.remove(bundleID)
        }
        if let locked = lockedBundleID, stopped.contains(locked) {
            lockedBundleID = nil
            effects.append(.hidePrompt)
        }
        if let pending = pendingBundleID, stopped.contains(pending) {
            pendingBundleID = nil
            effects.append(.cancelDebounceTimer)
        }

        // One prompt at a time: while something is shown or pending, don't chase a
        // second candidate (a focus change can't move the lock either).
        guard lockedBundleID == nil, pendingBundleID == nil else {
            return effects
        }

        // A genuine false→true transition: capturing now, wasn't last snapshot, and
        // not a rejected episode. Baseline apps only become candidates after they
        // stop and start again (their stop clears `previous`).
        let started = owners.subtracting(previous).subtracting(suppressedEpisodes)
        guard let candidate = Self.pick(from: started, order: order) else {
            return effects
        }
        pendingBundleID = candidate
        effects.append(.startDebounceTimer(bundleID: candidate))
        return effects
    }

    /// Called by the service when a candidate's sustain debounce elapses.
    mutating func debounceTimerFired(bundleID: String) -> [Effect] {
        guard pendingBundleID == bundleID else { return [] }  // stale timer
        pendingBundleID = nil
        guard previouslyCapturing.contains(bundleID),
              !suppressedEpisodes.contains(bundleID) else {
            return []
        }
        lockedBundleID = bundleID
        return [.showPrompt(bundleID: bundleID)]
    }

    /// The user dismissed the prompt — suppress this capture episode so we stay
    /// quiet until the app stops capturing (signalling the call ended).
    mutating func dismiss() -> [Effect] {
        suppressCurrentEpisode()
    }

    /// Forget the app the current lock is bound to, without suppressing its
    /// episode. Called when a recording stops: back-to-back recordings keep the
    /// input monitor down continuously, so the fresh-detector re-baseline that
    /// used to clear the lock implicitly never happens — and a surviving lock
    /// would bind the *next* recording's call-end monitoring to the previous,
    /// already-ended call, auto-stopping it spuriously. The lock's only consumer
    /// is call-end association at recording start, so clearing at stop is
    /// behavior-preserving for every other flow.
    mutating func releaseLock() {
        lockedBundleID = nil
    }

    private mutating func suppressCurrentEpisode() -> [Effect] {
        var effects: [Effect] = []
        if let locked = lockedBundleID {
            suppressedEpisodes.insert(locked)
            lockedBundleID = nil
            effects.append(.hidePrompt)
        }
        if let pending = pendingBundleID {
            suppressedEpisodes.insert(pending)
            pendingBundleID = nil
            effects.append(.cancelDebounceTimer)
        }
        return effects
    }

    private static func pick(from candidates: Set<String>, order: [String]) -> String? {
        for bundleID in order where candidates.contains(bundleID) {
            return bundleID
        }
        // Fallback if `order` is incomplete — deterministic, never `Set.first`.
        return candidates.sorted().first
    }
}
