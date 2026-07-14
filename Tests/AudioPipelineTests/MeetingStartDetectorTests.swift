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

    @Test("releaseLock clears the lock without suppressing the capture episode")
    func releaseLockClearsLockOnly() {
        var detector = MeetingStartDetector()
        feed(&detector, [])
        feed(&detector, [zoom])
        _ = detector.debounceTimerFired(bundleID: zoom)
        #expect(detector.lockedBundleID == zoom)

        // Recording stopped → the lock is released so a follow-up recording
        // can't inherit this (now ended) call's association.
        detector.releaseLock()
        #expect(detector.lockedBundleID == nil)

        // The episode was NOT suppressed: once Zoom stops capturing and starts
        // a genuinely new call, it prompts again.
        feed(&detector, [])
        #expect(feed(&detector, [zoom]) == [.startDebounceTimer(bundleID: zoom)])
        #expect(detector.debounceTimerFired(bundleID: zoom) == [.showPrompt(bundleID: zoom)])
    }
}
