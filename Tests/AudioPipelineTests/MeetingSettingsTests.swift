import Foundation
import Testing

@testable import SerialNotes

@Suite("Meeting Settings")
struct MeetingSettingsTests {
    @Test("Auto-stop defaults enabled and persists")
    @MainActor
    func autoStopDefaultsEnabledAndPersists() {
        let key = "meeting.autoStopAfterCallEnds"
        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: key)
        defer {
            if let prior {
                defaults.set(prior, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        let fresh = MeetingSettings()
        #expect(fresh.autoStopAfterCallEnds)

        fresh.autoStopAfterCallEnds = false
        let reloaded = MeetingSettings()
        #expect(!reloaded.autoStopAfterCallEnds)
    }
}
