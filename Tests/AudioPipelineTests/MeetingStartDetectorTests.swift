import Foundation
import Testing

@testable import SerialNotes

@Suite("Meeting Start Detector")
struct MeetingStartDetectorTests {
    typealias Effect = MeetingStartDetector.Effect

    private let zoom = "us.zoom.xos"
    private let slack = "com.tinyspeck.slackmacgap"

    /// Convenience: feed a snapshot with the owners in a fixed disambiguation order
    /// (defaults to alphabetical via the reducer's own fallback when `order` empty).
    @discardableResult
    private func feed(
        _ detector: inout MeetingStartDetector,
        _ owners: Set<String>,
        order: [String]? = nil
    ) -> [Effect] {
        detector.receiveCapturing(owners, order: order ?? owners.sorted())
    }

    @Test("First snapshot is baseline — an app already capturing never prompts")
    func baselineNeverPrompts() {
        var detector = MeetingStartDetector()
        #expect(feed(&detector, [zoom]).isEmpty)          // baseline: Zoom already capturing
        #expect(feed(&detector, [zoom]).isEmpty)          // still capturing → no transition
        #expect(feed(&detector, [zoom]).isEmpty)
        #expect(detector.lockedBundleID == nil)
    }

    @Test("A fresh start-of-capture transition prompts after the sustain debounce")
    func transitionPrompts() {
        var detector = MeetingStartDetector()
        feed(&detector, [])                                // baseline: nothing capturing
        #expect(feed(&detector, [zoom]) == [.startDebounceTimer(bundleID: zoom)])
        #expect(detector.debounceTimerFired(bundleID: zoom) == [.showPrompt(bundleID: zoom)])
        #expect(detector.lockedBundleID == zoom)
    }

    @Test("A capture that stops before the debounce fires never prompts")
    func transientCaptureSuppressed() {
        var detector = MeetingStartDetector()
        feed(&detector, [])
        #expect(feed(&detector, [zoom]) == [.startDebounceTimer(bundleID: zoom)])
        // Zoom stops before the timer fires.
        #expect(feed(&detector, []) == [.cancelDebounceTimer])
        // The (now stale) timer fires → nothing.
        #expect(detector.debounceTimerFired(bundleID: zoom).isEmpty)
        #expect(detector.lockedBundleID == nil)
    }

    @Test("Stop then start again re-prompts (a new call)")
    func reTransitionPrompts() {
        var detector = MeetingStartDetector()
        feed(&detector, [])
        feed(&detector, [zoom])
        _ = detector.debounceTimerFired(bundleID: zoom)            // prompt shown, locked
        #expect(detector.lockedBundleID == zoom)
        // Call ends — Zoom stops capturing → prompt retracts.
        #expect(feed(&detector, []) == [.hidePrompt])
        #expect(detector.lockedBundleID == nil)
        // A new call starts → prompts again.
        #expect(feed(&detector, [zoom]) == [.startDebounceTimer(bundleID: zoom)])
        #expect(detector.debounceTimerFired(bundleID: zoom) == [.showPrompt(bundleID: zoom)])
    }

    @Test("Dismiss suppresses the current episode; the same app stays quiet while it keeps capturing")
    func dismissSuppressesEpisode() {
        var detector = MeetingStartDetector()
        feed(&detector, [])
        feed(&detector, [zoom])
        _ = detector.debounceTimerFired(bundleID: zoom)
        #expect(detector.dismiss() == [.hidePrompt])
        #expect(detector.lockedBundleID == nil)
        // Zoom keeps capturing → no re-prompt (suppressed + not a new transition).
        #expect(feed(&detector, [zoom]).isEmpty)
        #expect(feed(&detector, [zoom]).isEmpty)
    }

    @Test("After dismiss, the same app re-prompts once its capture stops and restarts")
    func dismissThenReCapturePrompts() {
        var detector = MeetingStartDetector()
        feed(&detector, [])
        feed(&detector, [zoom])
        _ = detector.debounceTimerFired(bundleID: zoom)
        _ = detector.dismiss()
        feed(&detector, [zoom])                                    // still capturing, suppressed
        #expect(feed(&detector, []) == [])                         // stops → episode ends (lock already nil)
        #expect(feed(&detector, [zoom]) == [.startDebounceTimer(bundleID: zoom)])
        #expect(detector.debounceTimerFired(bundleID: zoom) == [.showPrompt(bundleID: zoom)])
    }

    @Test("Dismissing one app still lets a different app prompt in the same window")
    func dismissOneAllowsAnother() {
        var detector = MeetingStartDetector()
        feed(&detector, [])
        feed(&detector, [zoom])
        _ = detector.debounceTimerFired(bundleID: zoom)
        _ = detector.dismiss()                                     // zoom suppressed
        // A second app starts capturing while Zoom still holds the mic.
        #expect(feed(&detector, [zoom, slack]) == [.startDebounceTimer(bundleID: slack)])
        #expect(detector.debounceTimerFired(bundleID: slack) == [.showPrompt(bundleID: slack)])
        #expect(detector.lockedBundleID == slack)
    }

    @Test("Simultaneous new transitions pick the disambiguation winner; the loser is ignored while locked")
    func simultaneousTransitionsDisambiguate() {
        var detector = MeetingStartDetector()
        feed(&detector, [])
        // Both start at once; order prefers Slack (e.g. frontmost).
        #expect(
            detector.receiveCapturing([zoom, slack], order: [slack, zoom])
                == [.startDebounceTimer(bundleID: slack)]
        )
        #expect(detector.debounceTimerFired(bundleID: slack) == [.showPrompt(bundleID: slack)])
        // Zoom keeps capturing but Slack is locked → no second prompt.
        #expect(detector.receiveCapturing([zoom, slack], order: [slack, zoom]).isEmpty)
        #expect(detector.lockedBundleID == slack)
    }

    @Test("A pending candidate that the debounce confirms is gone does not prompt")
    func pendingCandidateGoneDoesNotPrompt() {
        var detector = MeetingStartDetector()
        feed(&detector, [])
        feed(&detector, [zoom])                                    // pending = zoom
        feed(&detector, [])                                        // zoom gone → cancel
        feed(&detector, [slack])                                   // new pending = slack
        // The original zoom timer fires late → stale, ignored.
        #expect(detector.debounceTimerFired(bundleID: zoom).isEmpty)
        #expect(detector.debounceTimerFired(bundleID: slack) == [.showPrompt(bundleID: slack)])
    }

    @Test("consumeLock returns and clears the lock without suppressing the capture episode")
    func consumeLockClearsLockOnly() {
        var detector = MeetingStartDetector()
        feed(&detector, [])
        feed(&detector, [zoom])
        _ = detector.debounceTimerFired(bundleID: zoom)
        #expect(detector.lockedBundleID == zoom)

        // A recording begins → the service consumes the lock for call-end
        // association; the reducer is free to track the next call.
        #expect(detector.consumeLock() == zoom)
        #expect(detector.lockedBundleID == nil)
        #expect(detector.consumeLock() == nil)

        // The episode was NOT suppressed: once Zoom stops capturing and starts
        // a genuinely new call, it prompts again.
        feed(&detector, [])
        #expect(feed(&detector, [zoom]) == [.startDebounceTimer(bundleID: zoom)])
        #expect(detector.debounceTimerFired(bundleID: zoom) == [.showPrompt(bundleID: zoom)])
    }

    // MARK: Prompt gate

    @Test("A debounce that matures behind a closed gate defers, then surfaces on open")
    func closedGateDefersPromptUntilOpen() {
        var detector = MeetingStartDetector()
        feed(&detector, [])
        detector.promptGateClosed()
        #expect(feed(&detector, [zoom]) == [.startDebounceTimer(bundleID: zoom)])
        // Gate closed → the matured candidate defers instead of prompting.
        #expect(detector.debounceTimerFired(bundleID: zoom).isEmpty)
        #expect(detector.lockedBundleID == nil)
        // A second app can't displace the deferred candidate.
        #expect(feed(&detector, [zoom, slack]).isEmpty)
        // Gate reopens → the still-capturing candidate surfaces immediately.
        #expect(detector.promptGateOpened() == [.showPrompt(bundleID: zoom)])
        #expect(detector.lockedBundleID == zoom)
    }

    @Test("A deferred candidate whose capture ended before the gate opens is dropped")
    func deferredCandidateGoneDoesNotPrompt() {
        var detector = MeetingStartDetector()
        feed(&detector, [])
        detector.promptGateClosed()
        feed(&detector, [zoom])
        _ = detector.debounceTimerFired(bundleID: zoom)            // deferred
        feed(&detector, [])                                        // call ended while closed
        #expect(detector.promptGateOpened().isEmpty)
        #expect(detector.lockedBundleID == nil)
        // The episode ended cleanly: a new call prompts normally.
        #expect(feed(&detector, [zoom]) == [.startDebounceTimer(bundleID: zoom)])
        #expect(detector.debounceTimerFired(bundleID: zoom) == [.showPrompt(bundleID: zoom)])
    }

    @Test("An app capturing steadily across a gate close/open cycle never prompts")
    func warmHoldAcrossGateCycleStaysQuiet() {
        var detector = MeetingStartDetector()
        feed(&detector, [zoom])                                    // baseline: warm-holding
        detector.promptGateClosed()
        #expect(feed(&detector, [zoom]).isEmpty)
        #expect(detector.promptGateOpened().isEmpty)
        #expect(feed(&detector, [zoom]).isEmpty)                   // still no transition
        #expect(detector.lockedBundleID == nil)
    }

    @Test("Back-to-back calls: the next call's edge during a recording prompts at the stop")
    func backToBackCallEdgeDuringRecordingPromptsOnGateOpen() {
        var detector = MeetingStartDetector()
        feed(&detector, [])
        // Call 1: edge → prompt → the user records (the service consumes the
        // lock and closes the gate).
        feed(&detector, [zoom])
        _ = detector.debounceTimerFired(bundleID: zoom)
        #expect(detector.consumeLock() == zoom)
        detector.promptGateClosed()
        // Call 1 ends mid-recording; call 2 starts before the recording stops.
        #expect(feed(&detector, []).isEmpty)
        #expect(feed(&detector, [zoom]) == [.startDebounceTimer(bundleID: zoom)])
        #expect(detector.debounceTimerFired(bundleID: zoom).isEmpty)  // deferred
        // The recording stops → the gate reopens → call 2 prompts.
        #expect(detector.promptGateOpened() == [.showPrompt(bundleID: zoom)])
        #expect(detector.lockedBundleID == zoom)
    }

    @Test("An edge whose debounce is still pending at gate open prompts via the normal path")
    func pendingDebounceAtGateOpenPromptsNormally() {
        var detector = MeetingStartDetector()
        feed(&detector, [])
        detector.promptGateClosed()
        feed(&detector, [zoom])                                    // debounce in flight
        #expect(detector.promptGateOpened().isEmpty)               // nothing deferred yet
        #expect(detector.debounceTimerFired(bundleID: zoom) == [.showPrompt(bundleID: zoom)])
    }

    @Test("Dismissal while a candidate is deferred suppresses its episode")
    func dismissSuppressesDeferredCandidate() {
        var detector = MeetingStartDetector()
        feed(&detector, [])
        detector.promptGateClosed()
        feed(&detector, [zoom])
        _ = detector.debounceTimerFired(bundleID: zoom)            // deferred
        #expect(detector.dismiss().isEmpty)                        // nothing shown → no effects
        #expect(detector.promptGateOpened().isEmpty)               // suppressed, not surfaced
        // Suppression is episode-scoped: stop + restart re-prompts.
        feed(&detector, [])
        #expect(feed(&detector, [zoom]) == [.startDebounceTimer(bundleID: zoom)])
        #expect(detector.debounceTimerFired(bundleID: zoom) == [.showPrompt(bundleID: zoom)])
    }

    @Test("A deferral survives a mid-recording monitor restart and surfaces at the stop")
    func carriedDeferralSurvivesMonitorRestart() {
        var detector = MeetingStartDetector()
        feed(&detector, [])
        detector.promptGateClosed()
        feed(&detector, [zoom])
        _ = detector.debounceTimerFired(bundleID: zoom)            // deferred
        // Suspend/resume replaces the reducer mid-recording; the deferral and
        // the closed gate carry into the replacement instead of vanishing
        // into the fresh baseline.
        var restarted = MeetingStartDetector(promptGateClosed: true, resumingFrom: detector)
        #expect(feed(&restarted, [zoom]).isEmpty)                  // baseline; gate closed
        #expect(restarted.promptGateOpened() == [.showPrompt(bundleID: zoom)])
        #expect(restarted.lockedBundleID == zoom)
    }

    @Test("A deferral whose gate opened while the monitor was down surfaces on the next live snapshot")
    func carriedDeferralSurfacesOnLiveSnapshot() {
        var detector = MeetingStartDetector()
        feed(&detector, [])
        detector.promptGateClosed()
        feed(&detector, [zoom])
        _ = detector.debounceTimerFired(bundleID: zoom)            // deferred
        // The stop landed while the monitor was down, so the service reopened
        // the gate without calling promptGateOpened; the restart carries the
        // deferral into an open-gate reducer, and the first live snapshot is
        // the still-capturing confirmation it was waiting for.
        var restarted = MeetingStartDetector(resumingFrom: detector)
        #expect(feed(&restarted, [zoom]) == [.showPrompt(bundleID: zoom)])
        #expect(restarted.lockedBundleID == zoom)
    }

    @Test("A carried deferral for a call that ended offline clears without prompting")
    func carriedDeferralForEndedCallClears() {
        var detector = MeetingStartDetector()
        feed(&detector, [])
        detector.promptGateClosed()
        feed(&detector, [zoom])
        _ = detector.debounceTimerFired(bundleID: zoom)            // deferred
        var restarted = MeetingStartDetector(resumingFrom: detector)
        #expect(feed(&restarted, []).isEmpty)                      // live read: call over
        // The candidate slot is free again: a genuinely new call prompts.
        #expect(feed(&restarted, [zoom]) == [.startDebounceTimer(bundleID: zoom)])
        #expect(restarted.debounceTimerFired(bundleID: zoom) == [.showPrompt(bundleID: zoom)])
    }

    @Test("Carried suppressions are pruned against the restart's live baseline")
    func carriedSuppressionPrunesAgainstLiveBaseline() {
        var detector = MeetingStartDetector()
        feed(&detector, [])
        feed(&detector, [zoom])
        _ = detector.debounceTimerFired(bundleID: zoom)            // prompt shown
        _ = detector.dismiss()                                     // episode suppressed
        // The call ends while the monitor is down — the stop edge that would
        // have cleared the suppression is never observed.
        var restarted = MeetingStartDetector(resumingFrom: detector)
        #expect(feed(&restarted, []).isEmpty)                      // live baseline: call over
        // A genuinely new call must prompt again.
        #expect(feed(&restarted, [zoom]) == [.startDebounceTimer(bundleID: zoom)])
        #expect(restarted.debounceTimerFired(bundleID: zoom) == [.showPrompt(bundleID: zoom)])
    }

    @Test("A carried suppression for a still-live episode keeps gating its app")
    func carriedSuppressionKeepsGatingLiveEpisode() {
        var detector = MeetingStartDetector()
        feed(&detector, [])
        feed(&detector, [zoom])
        _ = detector.debounceTimerFired(bundleID: zoom)            // prompt shown
        _ = detector.dismiss()                                     // episode suppressed
        var restarted = MeetingStartDetector(resumingFrom: detector)
        feed(&restarted, [zoom])                                   // baseline: episode continues
        // Ending the episode and starting a new call re-prompts as usual.
        feed(&restarted, [])
        #expect(feed(&restarted, [zoom]) == [.startDebounceTimer(bundleID: zoom)])
    }
}
