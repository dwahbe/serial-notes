import Foundation

/// First-run setup state, persisted in `UserDefaults.standard` (the
/// `com.serialnotes.app` domain, keyed by bundle ID — so it survives Sparkle's
/// in-place `.app` replacement and never re-triggers on update).
///
/// Two distinct flags on purpose:
/// - `hasShown` gates the automatic first-launch presentation. Set the moment we
///   decide to show the guide (or skip it for a migrating user), so it never
///   auto-opens twice.
/// - `completed` records that the user actually reached the final "Done" step.
///   Closing the guide early sets `hasShown` but not `completed`, so the flag
///   never lies. Re-entry from Settings is unaffected by either flag.
@MainActor @Observable
final class OnboardingSettings {
    private static let hasShownKey = "setup.hasShown"
    private static let completedKey = "setup.completed"

    private(set) var hasShown: Bool
    private(set) var completed: Bool

    /// True until the guide has been shown (or skipped) once.
    var needsAutoOpen: Bool { !hasShown }

    init() {
        let defaults = UserDefaults.standard
        self.hasShown = defaults.bool(forKey: Self.hasShownKey)
        self.completed = defaults.bool(forKey: Self.completedKey)
    }

    /// Record that the guide has been presented (or deliberately skipped for an
    /// existing user) so it won't auto-open again.
    func markShown() {
        guard !hasShown else { return }
        hasShown = true
        UserDefaults.standard.set(true, forKey: Self.hasShownKey)
    }

    /// Record that the user finished the guide. Implies `markShown()`.
    func markCompleted() {
        markShown()
        guard !completed else { return }
        completed = true
        UserDefaults.standard.set(true, forKey: Self.completedKey)
    }
}
