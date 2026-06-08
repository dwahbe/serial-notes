import Foundation
import Testing

@testable import SerialNotes

@Suite("Onboarding Settings")
struct OnboardingSettingsTests {
    @Test("Flags default false, persist, and markCompleted implies shown")
    @MainActor
    func flagsDefaultPersistAndImply() {
        let hasShownKey = "setup.hasShown"
        let completedKey = "setup.completed"
        let defaults = UserDefaults.standard
        let priorShown = defaults.object(forKey: hasShownKey)
        let priorCompleted = defaults.object(forKey: completedKey)
        defer {
            if let priorShown { defaults.set(priorShown, forKey: hasShownKey) }
            else { defaults.removeObject(forKey: hasShownKey) }
            if let priorCompleted { defaults.set(priorCompleted, forKey: completedKey) }
            else { defaults.removeObject(forKey: completedKey) }
        }

        defaults.removeObject(forKey: hasShownKey)
        defaults.removeObject(forKey: completedKey)

        let fresh = OnboardingSettings()
        #expect(fresh.needsAutoOpen)
        #expect(!fresh.hasShown)
        #expect(!fresh.completed)

        // Showing the guide gates auto-open but does not mark completion.
        fresh.markShown()
        #expect(!fresh.needsAutoOpen)
        let afterShown = OnboardingSettings()
        #expect(afterShown.hasShown)
        #expect(!afterShown.completed)

        // Completing implies shown, and both flags persist across instances.
        fresh.markCompleted()
        let afterCompleted = OnboardingSettings()
        #expect(afterCompleted.hasShown)
        #expect(afterCompleted.completed)
    }
}
