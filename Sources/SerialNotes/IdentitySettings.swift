import Foundation

/// The user's own display identity. Currently just a preferred name used to label
/// the user's (mic) voice in transcripts. Persisted in UserDefaults like the other
/// `*Settings` stores. Intentionally independent of `VoiceProfileStore`: the name
/// works whether or not the user has recorded a voice sample.
@MainActor @Observable
final class IdentitySettings {
    private static let yourNameKey = "identity.yourName"

    /// The user's preferred name. When non-empty, it replaces the default "You"
    /// label for the user's own voice throughout transcripts. Optional — an empty
    /// value falls back to "You".
    var yourName: String {
        didSet {
            UserDefaults.standard.set(yourName, forKey: Self.yourNameKey)
        }
    }

    init() {
        self.yourName = UserDefaults.standard.string(forKey: Self.yourNameKey) ?? ""
    }

    /// The label to use for the user's mic voice: the trimmed preferred name, or
    /// "You" when unset. Single source of truth for the streaming default label,
    /// the `.you` diarizer enrollment name, and the final-render collapse target.
    var micDisplayName: String {
        let trimmed = yourName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "You" : trimmed
    }
}
