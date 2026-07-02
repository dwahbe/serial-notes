import Foundation

/// A past recording that detected one or more unrecognized system-side speakers,
/// built from its `speakers.json` sidecar. The heavy clips live in the app-support
/// pending area; this only holds the (text) metadata.
struct MeetingSession: Identifiable {
    let directory: URL
    let sidecar: SpeakerSidecar
    /// Speaker indices that are `.pending` AND still have a clip on disk — the only ones
    /// that can actually be named. Computed once at load so a stale sidecar whose clips
    /// were reaped (30-day sweep, a failed dismiss, a deleted folder) doesn't keep
    /// advertising un-nameable speakers in the list.
    let nameableIndices: Set<Int>

    var id: URL { directory }
    var startedAt: Date { sidecar.sessionStartedAt }

    /// Pending speakers whose clip still exists — what the naming UI offers.
    var nameableSpeakers: [DetectedSpeaker] { sidecar.speakers.filter { nameableIndices.contains($0.speakerIndex) } }
    var namedSpeakers: [DetectedSpeaker] { sidecar.speakers.filter { $0.state == .named } }
    /// Speakers still awaiting a user decision, regardless of clip availability.
    /// A suggested speaker is equally actionable: the UI can accept or correct it.
    var pendingSpeakers: [DetectedSpeaker] {
        sidecar.speakers.filter { $0.state == .pending || $0.state == .suggested }
    }
    /// What the list/badge shows — only speakers that can actually be named.
    var pendingCount: Int { nameableSpeakers.count }

    /// Human-readable title from the recording's start time. The session *folder* name
    /// uses 12-hour time and is not reliably sortable — always derive from `startedAt`.
    var title: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d 'at' h:mm a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: startedAt)
    }

    /// Resolve the on-disk clip URL for one of this session's speakers.
    func clipURL(for speaker: DetectedSpeaker) -> URL {
        SpeakerClipExtractor.clipURL(
            sessionFolder: directory.lastPathComponent,
            clipFile: speaker.clipFile
        )
    }
}

enum SpeakerNamingError: LocalizedError {
    case emptyName
    case clipMissing
    case sidecarMissing

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Enter a name."
        case .clipMissing: return "The voice clip for this speaker is no longer available."
        case .sidecarMissing: return "This meeting's speaker data is no longer available."
        }
    }
}

/// Backs the Settings → Meetings list and the post-meeting naming flow. Scans the
/// storage folder for sessions that wrote a `speakers.json`, and owns the
/// name/skip/dismiss mutations (profile upsert + transcript relabel + sidecar update +
/// clip cleanup).
@MainActor @Observable
final class MeetingSessionsStore {
    private(set) var sessions: [MeetingSession] = []

    @ObservationIgnored private let storageSettings: StorageSettings
    @ObservationIgnored private let voiceStore: VoiceProfileStore

    private static let maxSessions = 20

    init(storageSettings: StorageSettings, voiceStore: VoiceProfileStore) {
        self.storageSettings = storageSettings
        self.voiceStore = voiceStore
        SpeakerClipExtractor.sweepStalePendingClips()
        reload()
    }

    /// Full rescan of the storage folder. Used on launch and when the Meetings tab opens;
    /// mutations use the cheaper `refreshSession` instead.
    func reload() {
        let root = storageSettings.storageLocation
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            sessions = []
            return
        }

        var loaded: [MeetingSession] = []
        for dir in entries {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir, let session = Self.loadSession(at: dir) else { continue }
            loaded.append(session)
        }
        // Newest first by recorded start time — the folder name's 12-hour format isn't
        // lexicographically sortable.
        loaded.sort { $0.startedAt > $1.startedAt }
        sessions = Array(loaded.prefix(Self.maxSessions))
    }

    func session(at url: URL) -> MeetingSession? {
        sessions.first { $0.directory.standardizedFileURL == url.standardizedFileURL }
    }

    /// Build a `MeetingSession` from one directory's sidecar, resolving which pending
    /// speakers still have a clip. Returns nil when there's no sidecar.
    static func loadSession(at directory: URL) -> MeetingSession? {
        guard let sidecar = SpeakerClipExtractor.loadSidecar(inSessionDirectory: directory) else { return nil }
        let folder = directory.lastPathComponent
        let nameable = Set(
            sidecar.speakers
                .filter { speaker in
                    (speaker.state == .pending || speaker.state == .suggested)
                        && FileManager.default.fileExists(
                            atPath: SpeakerClipExtractor.clipURL(sessionFolder: folder, clipFile: speaker.clipFile).path
                        )
                }
                .map(\.speakerIndex)
        )
        return MeetingSession(directory: directory, sidecar: sidecar, nameableIndices: nameable)
    }

    // MARK: - Mutations

    /// Name a detected speaker: create/replace the reusable `.other` profile from its
    /// clip, relabel this meeting's transcript, and mark the sidecar entry named.
    /// Ordered so a retry is safe (upsert dedupes the profile; relabel is idempotent).
    func nameSpeaker(in session: MeetingSession, speaker: DetectedSpeaker, rawName: String) throws {
        guard let name = SpeakerClipExtractor.sanitizedName(rawName) else {
            throw SpeakerNamingError.emptyName
        }

        let clipURL = session.clipURL(for: speaker)
        guard FileManager.default.fileExists(atPath: clipURL.path) else {
            throw SpeakerNamingError.clipMissing
        }

        // 1. Reusable profile for future recognition (copies the clip into the voices dir).
        try voiceStore.upsertOther(name: name, clipURL: clipURL)

        // 2. Relabel this transcript — headers + the top notes/summary/action-items region (idempotent).
        relabelTranscript(in: session.directory, from: speaker.label, to: name)

        // 3. Persist state + reap the now-consumed clip.
        let updated = try updateSidecar(in: session.directory) { sidecar in
            if let idx = sidecar.speakers.firstIndex(where: { $0.speakerIndex == speaker.speakerIndex }) {
                sidecar.speakers[idx].state = .named
                sidecar.speakers[idx].resolvedName = name
                sidecar.speakers[idx].suggestedName = nil
            }
        }
        try? FileManager.default.removeItem(at: clipURL)
        reapClipsIfResolved(session.directory, sidecar: updated)
        refreshSession(session.directory)
    }

    func skipSpeaker(in session: MeetingSession, speaker: DetectedSpeaker) throws {
        let updated = try updateSidecar(in: session.directory) { sidecar in
            if let idx = sidecar.speakers.firstIndex(where: { $0.speakerIndex == speaker.speakerIndex }) {
                sidecar.speakers[idx].state = .skipped
                sidecar.speakers[idx].suggestedName = nil
            }
        }
        try? FileManager.default.removeItem(at: session.clipURL(for: speaker))
        reapClipsIfResolved(session.directory, sidecar: updated)
        refreshSession(session.directory)
    }

    /// Drop the remaining pending speakers for a session and reap its clips — but only
    /// reap once the sidecar update has actually persisted, so we never delete the clips
    /// while leaving speakers marked `.pending` (which would strand them as un-nameable).
    func dismiss(_ session: MeetingSession) {
        do {
            _ = try updateSidecar(in: session.directory) { sidecar in
                for idx in sidecar.speakers.indices
                where sidecar.speakers[idx].state == .pending || sidecar.speakers[idx].state == .suggested {
                    sidecar.speakers[idx].state = .skipped
                    sidecar.speakers[idx].suggestedName = nil
                }
            }
            SpeakerClipExtractor.reapPendingClips(forSessionFolder: session.directory.lastPathComponent)
        } catch {
            // Couldn't persist the skip — leave the clips in place so the speakers stay
            // nameable rather than becoming stuck pending-with-no-clip.
        }
        refreshSession(session.directory)
    }

    // MARK: - Helpers

    /// Reload a single session in-place (cheap), instead of rescanning the whole folder
    /// after every mutation. Removes it if its sidecar is gone, inserts it if newly present.
    private func refreshSession(_ directory: URL) {
        let existingIndex = sessions.firstIndex {
            $0.directory.standardizedFileURL == directory.standardizedFileURL
        }
        guard let updated = Self.loadSession(at: directory) else {
            if let existingIndex { sessions.remove(at: existingIndex) }
            return
        }
        if let existingIndex {
            sessions[existingIndex] = updated
        } else {
            sessions.append(updated)
            sessions.sort { $0.startedAt > $1.startedAt }
            sessions = Array(sessions.prefix(Self.maxSessions))
        }
    }

    @discardableResult
    private func updateSidecar(
        in directory: URL,
        _ mutate: (inout SpeakerSidecar) -> Void
    ) throws -> SpeakerSidecar {
        guard var sidecar = SpeakerClipExtractor.loadSidecar(inSessionDirectory: directory) else {
            throw SpeakerNamingError.sidecarMissing
        }
        mutate(&sidecar)
        try SpeakerClipExtractor.writeSidecar(sidecar, inSessionDirectory: directory)
        return sidecar
    }

    private func relabelTranscript(in directory: URL, from label: String, to name: String) {
        let url = directory.appendingPathComponent("transcript.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let rewritten = SpeakerClipExtractor.relabelSpeaker(in: text, from: label, to: name)
        guard rewritten != text else { return }
        try? rewritten.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Reap the pending-clip directory once no speakers remain pending. Takes the
    /// just-written sidecar so it doesn't re-read it from disk.
    private func reapClipsIfResolved(_ directory: URL, sidecar: SpeakerSidecar) {
        if !sidecar.speakers.contains(where: { $0.state == .pending || $0.state == .suggested }) {
            SpeakerClipExtractor.reapPendingClips(forSessionFolder: directory.lastPathComponent)
        }
    }
}
