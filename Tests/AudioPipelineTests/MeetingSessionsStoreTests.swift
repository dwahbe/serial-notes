import Foundation
import Testing

@testable import SerialNotes

@Suite("Meeting Sessions Store")
@MainActor
struct MeetingSessionsStoreTests {
    // MARK: - Helpers

    private func makeSpeaker(label: String, index: Int, state: SpeakerState = .pending) -> DetectedSpeaker {
        DetectedSpeaker(
            label: label,
            speakerIndex: index,
            totalSpeechSeconds: 10,
            sampleRate: 48_000,
            segments: [Segment(start: 0, end: 5)],
            sampleText: "hi",
            clipFile: "speaker-\(index).wav",
            state: state,
            resolvedName: nil
        )
    }

    @discardableResult
    private func writeSession(
        in root: URL,
        folder: String,
        startedAt: Date,
        speakers: [DetectedSpeaker],
        transcript: String = "x"
    ) throws -> URL {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try transcript.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        let sidecar = SpeakerSidecar(version: 1, sessionStartedAt: startedAt, speakers: speakers)
        try SpeakerClipExtractor.writeSidecar(sidecar, inSessionDirectory: dir)
        return dir
    }

    /// Run `body` with a fresh temp storage location, restoring the UserDefaults key after.
    private func withTempStorage(
        _ body: (StorageSettings, VoiceProfileStore, URL) throws -> Void
    ) rethrows {
        let key = "storageLocation"
        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: key)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snsessions-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            if let prior { defaults.set(prior, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let storage = StorageSettings()
        storage.storageLocation = root
        let voices = VoiceProfileStore()
        try body(storage, voices, root)
    }

    // MARK: - Scanning / ordering

    @Test("Lists sessions newest-first by startedAt, not folder name")
    func ordersByStartedAt() throws {
        try withTempStorage { storage, voices, root in
            // Folder names sort lexicographically opposite to chronological order
            // ("10..." < "9..."), so a folder-name sort would be wrong.
            try writeSession(
                in: root, folder: "2026-06-05 at 9.00.00 AM",
                startedAt: Date(timeIntervalSince1970: 1_000_000), // older
                speakers: [makeSpeaker(label: "Person 1", index: 1)]
            )
            try writeSession(
                in: root, folder: "2026-06-05 at 10.00.00 AM",
                startedAt: Date(timeIntervalSince1970: 2_000_000), // newer
                speakers: [makeSpeaker(label: "Person 1", index: 1)]
            )
            let store = MeetingSessionsStore(storageSettings: storage, voiceStore: voices)
            #expect(store.sessions.count == 2)
            #expect(store.sessions.first?.startedAt == Date(timeIntervalSince1970: 2_000_000))
        }
    }

    @Test("Caps the list at 20 sessions")
    func capsAtTwenty() throws {
        try withTempStorage { storage, voices, root in
            for i in 0..<25 {
                try writeSession(
                    in: root, folder: "s-\(i)",
                    startedAt: Date(timeIntervalSince1970: TimeInterval(i)),
                    speakers: [makeSpeaker(label: "Person 1", index: 1)]
                )
            }
            let store = MeetingSessionsStore(storageSettings: storage, voiceStore: voices)
            #expect(store.sessions.count == 20)
        }
    }

    @Test("Ignores directories without a speakers.json")
    func ignoresNonSpeakerDirs() throws {
        try withTempStorage { storage, voices, root in
            let plain = root.appendingPathComponent("no-speakers", isDirectory: true)
            try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
            try "hi".write(to: plain.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
            try writeSession(
                in: root, folder: "has-speakers",
                startedAt: Date(timeIntervalSince1970: 1),
                speakers: [makeSpeaker(label: "Person 1", index: 1)]
            )
            let store = MeetingSessionsStore(storageSettings: storage, voiceStore: voices)
            #expect(store.sessions.count == 1)
        }
    }

    // MARK: - Mutations

    @Test("Skipping a speaker drops it from pending")
    func skipSpeaker() throws {
        try withTempStorage { storage, voices, root in
            let dir = try writeSession(
                in: root, folder: "skip-test",
                startedAt: Date(timeIntervalSince1970: 1),
                speakers: [makeSpeaker(label: "Person 2", index: 2)]
            )
            let store = MeetingSessionsStore(storageSettings: storage, voiceStore: voices)
            let session = try #require(store.session(at: dir))
            try store.skipSpeaker(in: session, speaker: session.pendingSpeakers[0])
            #expect(try #require(store.session(at: dir)).pendingSpeakers.isEmpty)
        }
    }

    @Test("Dismiss marks all pending speakers skipped")
    func dismissSession() throws {
        try withTempStorage { storage, voices, root in
            let dir = try writeSession(
                in: root, folder: "dismiss-test",
                startedAt: Date(timeIntervalSince1970: 1),
                speakers: [
                    makeSpeaker(label: "Person 1", index: 1),
                    makeSpeaker(label: "Person 2", index: 2),
                ]
            )
            let store = MeetingSessionsStore(storageSettings: storage, voiceStore: voices)
            let session = try #require(store.session(at: dir))
            store.dismiss(session)
            #expect(try #require(store.session(at: dir)).pendingSpeakers.isEmpty)
        }
    }

    @Test("Naming relabels the transcript, creates a profile, and reaps the clip")
    func nameSpeakerTransaction() throws {
        try withTempStorage { storage, voices, root in
            let folder = "name-test-\(UUID().uuidString)"
            let uniqueName = "ZZTest-\(UUID().uuidString.prefix(8))"
            let transcript = "**Person 2** (00:00:05): Hello there everyone.\n"
            let dir = try writeSession(
                in: root, folder: folder,
                startedAt: Date(timeIntervalSince1970: 1),
                speakers: [makeSpeaker(label: "Person 2", index: 2)],
                transcript: transcript
            )

            // Place a clip where nameSpeaker expects it (the app-support pending area).
            let clipURL = SpeakerClipExtractor.clipURL(sessionFolder: folder, clipFile: "speaker-2.wav")
            try FileManager.default.createDirectory(
                at: clipURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("fake-wav".utf8).write(to: clipURL)

            defer {
                SpeakerClipExtractor.reapPendingClips(forSessionFolder: folder)
                if let profile = voices.otherProfiles.first(where: { $0.name == uniqueName }) {
                    try? voices.delete(profile)
                }
            }

            let store = MeetingSessionsStore(storageSettings: storage, voiceStore: voices)
            let session = try #require(store.session(at: dir))
            try store.nameSpeaker(in: session, speaker: session.pendingSpeakers[0], rawName: uniqueName)

            let rewritten = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
            #expect(rewritten.contains("**\(uniqueName)** (00:00:05): Hello there everyone."))
            #expect(!rewritten.contains("**Person 2**"))

            let updated = try #require(store.session(at: dir))
            #expect(updated.pendingSpeakers.isEmpty)
            #expect(updated.namedSpeakers.first?.resolvedName == uniqueName)

            #expect(voices.otherProfiles.contains { $0.name == uniqueName })
            #expect(!FileManager.default.fileExists(atPath: clipURL.path))
        }
    }

    @Test("A pending speaker with no clip on disk is not nameable")
    func clipLessPendingNotNameable() throws {
        try withTempStorage { storage, voices, root in
            // Sidecar says pending, but no clip exists (e.g. aged out by the 30-day sweep).
            let dir = try writeSession(
                in: root, folder: "no-clip",
                startedAt: Date(timeIntervalSince1970: 1),
                speakers: [makeSpeaker(label: "Person 2", index: 2)]
            )
            let store = MeetingSessionsStore(storageSettings: storage, voiceStore: voices)
            let session = try #require(store.session(at: dir))
            #expect(session.pendingSpeakers.count == 1) // sidecar still marks it pending
            #expect(session.nameableSpeakers.isEmpty)   // but it's not offered (clip gone)
            #expect(session.pendingCount == 0)
        }
    }

    @Test("A suggested speaker remains actionable like a pending speaker")
    func suggestedSpeakerIsPending() throws {
        try withTempStorage { storage, voices, root in
            let folder = "suggested-\(UUID().uuidString)"
            let dir = try writeSession(
                in: root, folder: folder,
                startedAt: Date(timeIntervalSince1970: 1),
                speakers: [makeSpeaker(label: "Person 2", index: 2, state: .suggested)]
            )
            let clipURL = SpeakerClipExtractor.clipURL(sessionFolder: folder, clipFile: "speaker-2.wav")
            try FileManager.default.createDirectory(
                at: clipURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("fake-wav".utf8).write(to: clipURL)
            defer { SpeakerClipExtractor.reapPendingClips(forSessionFolder: folder) }

            let store = MeetingSessionsStore(storageSettings: storage, voiceStore: voices)
            let session = try #require(store.session(at: dir))
            #expect(session.pendingSpeakers.count == 1)
            #expect(session.nameableSpeakers.count == 1)
        }
    }

    @Test("Renaming a Known Person to an existing name is rejected")
    func renameRejectsDuplicate() throws {
        try withTempStorage { _, voices, root in
            let nameA = "ZZDupA-\(UUID().uuidString.prefix(6))"
            let nameB = "ZZDupB-\(UUID().uuidString.prefix(6))"
            let clipA = root.appendingPathComponent("a.wav")
            let clipB = root.appendingPathComponent("b.wav")
            try Data("a".utf8).write(to: clipA)
            try Data("b".utf8).write(to: clipB)

            let profileA = try voices.upsertOther(name: nameA, clipURL: clipA)
            let profileB = try voices.upsertOther(name: nameB, clipURL: clipB)
            defer {
                try? voices.delete(profileA)
                try? voices.delete(profileB)
            }

            #expect(throws: VoiceProfileError.self) {
                try voices.rename(profileB, to: nameA)
            }
        }
    }

    @Test("Naming rejects an empty / whitespace-only name")
    func nameSpeakerRejectsEmpty() throws {
        try withTempStorage { storage, voices, root in
            let folder = "empty-name-\(UUID().uuidString)"
            let dir = try writeSession(
                in: root, folder: folder,
                startedAt: Date(timeIntervalSince1970: 1),
                speakers: [makeSpeaker(label: "Person 2", index: 2)],
                transcript: "**Person 2** (00:00:05): Hi.\n"
            )
            let clipURL = SpeakerClipExtractor.clipURL(sessionFolder: folder, clipFile: "speaker-2.wav")
            try FileManager.default.createDirectory(
                at: clipURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("fake-wav".utf8).write(to: clipURL)
            defer { SpeakerClipExtractor.reapPendingClips(forSessionFolder: folder) }

            let store = MeetingSessionsStore(storageSettings: storage, voiceStore: voices)
            let session = try #require(store.session(at: dir))
            #expect(throws: SpeakerNamingError.self) {
                try store.nameSpeaker(in: session, speaker: session.pendingSpeakers[0], rawName: "   ")
            }
        }
    }
}
