import Foundation

@MainActor @Observable
final class ManualNotesSettings {
    private static let openAtStartKey = "manualNotes.openNotepadWhenRecordingStarts"

    var openNotepadWhenRecordingStarts: Bool {
        didSet {
            UserDefaults.standard.set(openNotepadWhenRecordingStarts, forKey: Self.openAtStartKey)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        self.openNotepadWhenRecordingStarts = defaults.object(forKey: Self.openAtStartKey) as? Bool ?? false
    }
}
