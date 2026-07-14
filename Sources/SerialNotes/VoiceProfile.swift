import Foundation

/// A saved voice profile used to carry speaker identity across sessions.
///
/// Profiles are stored as a pair of files in the profile directory:
/// - `<id>.json` — name + kind
/// - `<id>.wav`  — enrollment clip (mono float32)
/// A matched profile may also carry a derived `<id>.embedding` cache
/// (see `VoiceEmbedding`) — not part of the profile identity.
struct VoiceProfile: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        /// The user's own voice — used to prime the mic-side diarizer.
        case you
        /// Another person's voice — used to prime the system-side diarizer.
        case other
    }

    let id: UUID
    var name: String
    var kind: Kind

    init(id: UUID = UUID(), name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}
