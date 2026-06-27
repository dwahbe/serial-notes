import Foundation

/// A cached speaker embedding for a voice profile, used to match an enrolled
/// person against the offline diarizer's per-speaker centroids after a meeting.
///
/// Stored next to the profile manifest as `<uuid>.embedding` (a non-`.json`
/// extension so `VoiceProfileStore.reload()` skips it). Tagged with the model
/// version that produced it, so swapping the embedding model cleanly invalidates
/// stale vectors — they're recomputed from the saved clip on demand rather than
/// silently compared across incompatible embedding spaces.
struct VoiceEmbedding: Codable, Equatable {
    /// Bump whenever the embedding model changes. v1 = FluidAudio's offline
    /// WeSpeaker model (256-dim, L2-normalized).
    static let currentModelVersion = 1

    var modelVersion: Int
    var vector: [Float]

    init(vector: [Float], modelVersion: Int = VoiceEmbedding.currentModelVersion) {
        self.vector = vector
        self.modelVersion = modelVersion
    }

    /// The vector if it was produced by the current model, else nil (caller
    /// should recompute from the enrollment clip).
    var current: [Float]? {
        modelVersion == VoiceEmbedding.currentModelVersion ? vector : nil
    }
}
