import AppKit
import AVFoundation
import Foundation

@MainActor @Observable
final class VoiceProfileStore {
    private(set) var profiles: [VoiceProfile] = []

    private let directory: URL

    /// Caches the decoded WAV samples keyed by profile ID so repeated session
    /// starts (the read happens once per `RecordingState.start()`) don't reopen
    /// + decode each enrollment clip. Invalidated on save / rename / delete /
    /// reload — all explicit user actions.
    @ObservationIgnored
    private var clipSampleCache: [UUID: (samples: [Float], sampleRate: Double)] = [:]

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.directory = appSupport
            .appendingPathComponent("SerialNotes", isDirectory: true)
            .appendingPathComponent("voices", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        } catch {
            // If we can't create the voice directory, profiles can't be saved
            // or loaded. Surface it in the log so a missing directory doesn't
            // look like the user simply has no profiles.
            NSLog("[SerialNotes/VoiceProfileStore] failed to create directory %@: %@",
                  directory.path, error.localizedDescription)
        }
        reload()
    }

    var yourProfile: VoiceProfile? {
        profiles.first(where: { $0.kind == .you })
    }

    var otherProfiles: [VoiceProfile] {
        profiles.filter { $0.kind == .other }.sorted { $0.name < $1.name }
    }

    // MARK: - CRUD

    func reload() {
        clipSampleCache.removeAll(keepingCapacity: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            profiles = []
            return
        }

        let decoder = JSONDecoder()
        var loaded: [VoiceProfile] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let profile = try? decoder.decode(VoiceProfile.self, from: data) else {
                continue
            }
            loaded.append(profile)
        }
        profiles = loaded
    }

    /// Save a profile, writing its JSON manifest + enrollment clip.
    /// Saving a `.you` profile replaces the existing one (only a single `.you`
    /// is kept); `.other` profiles are always added alongside any existing ones.
    func save(name: String, kind: VoiceProfile.Kind, clipURL: URL) throws -> VoiceProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmed.isEmpty ? fallbackName(for: kind) : trimmed

        if kind == .you, let existing = yourProfile {
            try delete(existing)
        }

        let profile = VoiceProfile(name: resolvedName, kind: kind)

        let manifestURL = manifestURL(for: profile.id)
        let clipDestination = self.clipURL(for: profile.id)

        if FileManager.default.fileExists(atPath: clipDestination.path) {
            try FileManager.default.removeItem(at: clipDestination)
        }
        try FileManager.default.copyItem(at: clipURL, to: clipDestination)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profile)
        try data.write(to: manifestURL, options: .atomic)

        reload()
        return profile
    }

    /// Save an `.other` profile, replacing any existing `.other` profile that already
    /// carries the same (case-insensitive) name. Keeps the post-meeting naming flow from
    /// minting duplicate "Bob" profiles and makes a retried name-save idempotent.
    @discardableResult
    func upsertOther(name: String, clipURL: URL) throws -> VoiceProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        let existing = normalized.isEmpty ? nil
            : profiles.first(where: { $0.kind == .other && $0.name.lowercased() == normalized })

        // Save the new profile first, then remove the prior same-name one — so a failure
        // mid-operation never leaves the user with neither profile (vs. delete-then-save).
        let saved = try save(name: trimmed, kind: .other, clipURL: clipURL)
        if let existing, existing.id != saved.id {
            try? delete(existing)
        }
        return saved
    }

    func rename(_ profile: VoiceProfile, to newName: String) throws {
        var updated = profile
        updated.name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if updated.name.isEmpty { updated.name = fallbackName(for: updated.kind) }

        // Don't let two profiles of the same kind share a name — keep this consistent
        // with upsertOther's dedup so the post-meeting flow and a manual rename agree.
        if profiles.contains(where: {
            $0.id != updated.id && $0.kind == updated.kind
                && $0.name.lowercased() == updated.name.lowercased()
        }) {
            throw VoiceProfileError.duplicateName(updated.name)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(updated)
        try data.write(to: manifestURL(for: updated.id), options: .atomic)
        reload()
    }

    func delete(_ profile: VoiceProfile) throws {
        let manifest = manifestURL(for: profile.id)
        let clip = clipURL(for: profile.id)
        if FileManager.default.fileExists(atPath: manifest.path) {
            try FileManager.default.removeItem(at: manifest)
        }
        if FileManager.default.fileExists(atPath: clip.path) {
            try FileManager.default.removeItem(at: clip)
        }
        reload()
    }

    // MARK: - Audio loading (for priming diarizers)

    /// Load a profile's enrollment clip as mono float32 samples. Cached after
    /// the first call; cache is invalidated on `reload()` (which runs after
    /// every save / rename / delete).
    func loadClipSamples(for profile: VoiceProfile) -> (samples: [Float], sampleRate: Double)? {
        if let cached = clipSampleCache[profile.id] { return cached }

        let url = clipURL(for: profile.id)
        guard let file = try? AVAudioFile(forReading: url) else { return nil }

        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }
        guard let channelData = buffer.floatChannelData else { return nil }

        let samples = Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(buffer.frameLength)
        ))
        let result = (samples: samples, sampleRate: format.sampleRate)
        clipSampleCache[profile.id] = result
        return result
    }

    // MARK: - Paths

    private func manifestURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func clipURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).wav")
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    private func fallbackName(for kind: VoiceProfile.Kind) -> String {
        switch kind {
        case .you: return "You"
        case .other: return "Unnamed"
        }
    }
}

enum VoiceProfileError: LocalizedError {
    case duplicateName(String)

    var errorDescription: String? {
        switch self {
        case .duplicateName(let name):
            return "A profile named “\(name)” already exists."
        }
    }
}
