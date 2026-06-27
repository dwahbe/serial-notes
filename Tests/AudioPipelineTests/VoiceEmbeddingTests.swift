import Foundation
import Testing

@testable import SerialNotes

@Suite("Voice Embedding — persistence + versioning")
struct VoiceEmbeddingTests {
    @Test("Round-trips through JSON")
    func roundTrips() throws {
        let original = VoiceEmbedding(vector: [0.1, -0.2, 0.97])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VoiceEmbedding.self, from: data)
        #expect(decoded == original)
        #expect(decoded.modelVersion == VoiceEmbedding.currentModelVersion)
    }

    @Test("current returns the vector for the current model version")
    func currentForMatchingVersion() {
        let embedding = VoiceEmbedding(vector: [1, 0])
        #expect(embedding.current == [1, 0])
    }

    @Test("current returns nil for a stale model version")
    func nilForStaleVersion() {
        let stale = VoiceEmbedding(vector: [1, 0], modelVersion: VoiceEmbedding.currentModelVersion - 1)
        #expect(stale.current == nil)
    }
}
