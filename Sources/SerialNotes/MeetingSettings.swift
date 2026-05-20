import Foundation

@MainActor @Observable
final class MeetingSettings {
    private static let autoStopKey = "meeting.autoStopAfterCallEnds"

    var autoStopAfterCallEnds: Bool {
        didSet {
            UserDefaults.standard.set(autoStopAfterCallEnds, forKey: Self.autoStopKey)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        self.autoStopAfterCallEnds = defaults.object(forKey: Self.autoStopKey) as? Bool ?? true
    }
}
