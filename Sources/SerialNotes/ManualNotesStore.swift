import Foundation

/// A finalizing session's captured notes: the text handed to the transcript
/// splice plus the sidecar that backs it until the splice is confirmed. A value
/// token held by that session's finalization — NOT store state — so a new
/// recording can `beginSession` immediately while the previous session's splice
/// is still in flight, without either clobbering the other.
struct ManualNotesSnapshot: Sendable {
    let text: String
    let sidecarURL: URL
}

@MainActor @Observable
final class ManualNotesStore {
    nonisolated static let sidecarFileName = ".manual-notes.md"

    /// Legacy single-path pointer key — migrated into `recoveryPathsKey` on read.
    static let recoveryPathKey = "manualNotes.recoverySidecarPath"
    /// Paths of sidecars whose transcript splice failed, stashed so later
    /// launches can surface the notes instead of stranding them in hidden files —
    /// the quit path has no UI left to show the failure on. A LIST because
    /// overlapping recordings mean more than one splice can fail per run; each
    /// launch restores one draft and keeps the rest for the next.
    static let recoveryPathsKey = "manualNotes.recoverySidecarPaths"

    /// How long to wait after the last keystroke before autosaving. Keeps the
    /// disk off the typing hot path — the in-memory `text` is always current and
    /// is what `snapshotAndEndSession()` hands to finalization, so the sidecar is
    /// only a crash-safety copy and can lag a few hundred ms safely.
    private static let autosaveDebounce: Duration = .milliseconds(600)

    private(set) var text = ""
    private(set) var isEditable = false
    var errorMessage: String?

    /// Injectable so tests get isolated recovery-pointer state (the pointers
    /// are the store's only cross-launch global); production uses `.standard`.
    @ObservationIgnored private let defaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
    }

    @ObservationIgnored private var sidecarURL: URL?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// Tail of the ordered sidecar disk-op chain. Every write/delete awaits its
    /// predecessor, so a slow in-flight autosave can never land after a later
    /// delete (resurrecting a reaped sidecar) or clobber a newer snapshot.
    @ObservationIgnored private var diskChainTail: Task<Void, Never>?

    func beginSession(sessionDir: URL) {
        flushTask?.cancel()
        let previousSidecarURL = sidecarURL
        let carriedText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sidecarURL = Self.sidecarURL(in: sessionDir)
        isEditable = true
        errorMessage = nil
        // A carried-forward draft consumes ITS OWN recovery pointer (the text
        // lives on in the new session) — never another session's pending one.
        if carriedText, let previousSidecarURL {
            removeRecoveryPointer(previousSidecarURL)
        }

        // A kept draft (failed splice, quit recovery) is never silently wiped —
        // it carries into the new session, its sidecar moves with it, and the
        // superseded copy is reaped. An empty draft costs no disk at all: the
        // first keystroke's debounced flush creates the file.
        if let sidecarURL, carriedText {
            enqueueWrite(text, to: sidecarURL)
        }
        if let previousSidecarURL, previousSidecarURL != sidecarURL {
            enqueueDelete(previousSidecarURL)
        }
    }

    func updateText(_ newValue: String) {
        guard isEditable else { return }
        text = newValue
        scheduleFlush()
    }

    /// Debounced autosave for the typing hot path; the write itself runs on the
    /// ordered disk chain.
    private func scheduleFlush() {
        guard let sidecarURL else { return }
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDebounce)
            guard !Task.isCancelled, let self else { return }
            // Re-check the destination on the main actor: a stop may have ended
            // the session while this was sleeping.
            guard self.sidecarURL == sidecarURL else { return }
            let outcome = await self.enqueueWrite(self.text, to: sidecarURL).value
            guard !Task.isCancelled, self.sidecarURL == sidecarURL else { return }
            self.apply(outcome)
        }
    }

    private func apply(_ outcome: FlushOutcome) {
        switch outcome {
        case .success:
            errorMessage = nil
        case let .failure(message):
            errorMessage = message
            NSLog("[SerialNotes/ManualNotes] %@", message)
        }
    }

    /// Captures the draft for finalization and frees the active-draft slot —
    /// the returned token travels with that session's finalization, so a new
    /// `beginSession` can run immediately (back-to-back recordings) without
    /// touching the captured notes. The snapshot text is the source of truth
    /// handed to `endSession`; the final sidecar write is enqueued behind any
    /// in-flight autosave so the on-disk crash copy is current by the time
    /// `completeSnapshotWrite` can need it. Returns nil for an empty draft.
    func snapshotAndEndSession() -> ManualNotesSnapshot? {
        flushTask?.cancel()
        let capturedURL = sidecarURL
        let capturedText = text
        sidecarURL = nil
        resetInactiveDraft()

        guard let capturedURL else { return nil }
        guard !capturedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            enqueueDelete(capturedURL)
            return nil
        }
        enqueueWrite(capturedText, to: capturedURL)
        return ManualNotesSnapshot(text: capturedText, sidecarURL: capturedURL)
    }

    /// Returns the user-facing failure message when the splice failed (nil on
    /// success) so the caller can surface it in the right place. The store sets
    /// its OWN notepad `errorMessage` only when it re-activates the failed draft
    /// — a live successor's open notepad must never show a predecessor's failure
    /// as its own.
    @discardableResult
    func completeSnapshotWrite(_ snapshot: ManualNotesSnapshot, succeeded: Bool) async -> String? {
        if succeeded {
            enqueueDelete(snapshot.sidecarURL)
            removeRecoveryPointer(snapshot.sidecarURL)
            return nil
        }
        // The notes never made it into transcript.md. Don't fail silently, and
        // don't claim the sidecar is safe until a fresh write of the snapshot
        // text confirms it — the earlier flush may have failed for the same
        // disk problem the splice did.
        let outcome = await enqueueWrite(snapshot.text, to: snapshot.sidecarURL).value
        let message: String
        switch outcome {
        case .success:
            setRecoveryPointer(snapshot.sidecarURL)
            message = "Couldn't add your notes to transcript.md — they're saved at \(snapshot.sidecarURL.path)"
        case .failure:
            message = "Couldn't add your notes to transcript.md or save them to disk — copy them from this notepad."
        }
        NSLog("[SerialNotes/ManualNotes] %@", message)
        // Re-activate the failed notes so they can be copied, edited, or carried
        // into the next session — but only when no newer draft owns the editor;
        // a live recording's notes must never be clobbered by a predecessor's
        // failure (the sidecar + recovery pointer keep the text safe instead).
        if !isEditable, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = snapshot.text
            sidecarURL = snapshot.sidecarURL
            isEditable = true
            errorMessage = message
        }
        return message
    }

    /// Surfaces notes whose splice failed, from the pointers stashed by
    /// `completeSnapshotWrite`. Restores ONE draft per launch (the oldest valid
    /// one) and keeps the rest for subsequent launches — drafts from different
    /// meetings must not merge into one notepad. Stale/empty entries are pruned
    /// as they're encountered. Returns true when a draft was restored so the
    /// caller can present the notepad. Blocking reads at launch only, and only
    /// ever after a rare failed splice.
    func restoreQuitRecoveryDraft() -> Bool {
        guard !isEditable, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        var paths = recoveryPointers()
        while !paths.isEmpty {
            let path = paths.removeFirst()
            let url = URL(fileURLWithPath: path)
            guard let saved = try? String(contentsOf: url, encoding: .utf8),
                  !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue  // stale entry — prune and try the next
            }
            storeRecoveryPointers(paths)
            text = saved
            sidecarURL = url
            isEditable = true
            errorMessage = "These notes couldn't be added to their meeting's transcript.md — recovered from \(url.path)"
            return true
        }
        storeRecoveryPointers([])
        return false
    }

    nonisolated static func sidecarURL(in sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent(sidecarFileName)
    }

    private func resetInactiveDraft() {
        text = ""
        isEditable = false
    }

    /// Current pointer list, migrating any legacy single-path entry in place.
    private func recoveryPointers() -> [String] {
        var paths = defaults.stringArray(forKey: Self.recoveryPathsKey) ?? []
        if let legacy = defaults.string(forKey: Self.recoveryPathKey) {
            defaults.removeObject(forKey: Self.recoveryPathKey)
            if !paths.contains(legacy) {
                paths.append(legacy)
            }
            storeRecoveryPointers(paths)
        }
        return paths
    }

    private func storeRecoveryPointers(_ paths: [String]) {
        if paths.isEmpty {
            defaults.removeObject(forKey: Self.recoveryPathsKey)
        } else {
            defaults.set(paths, forKey: Self.recoveryPathsKey)
        }
    }

    private func setRecoveryPointer(_ url: URL) {
        var paths = recoveryPointers()
        guard !paths.contains(url.path) else { return }
        paths.append(url.path)
        storeRecoveryPointers(paths)
    }

    private func removeRecoveryPointer(_ url: URL) {
        var paths = recoveryPointers()
        paths.removeAll { $0 == url.path }
        storeRecoveryPointers(paths)
    }

    // MARK: - Ordered sidecar disk chain (all I/O off the main actor)

    private enum FlushOutcome: Sendable {
        case success
        case failure(String)
    }

    @discardableResult
    private func enqueueWrite(_ text: String, to url: URL) -> Task<FlushOutcome, Never> {
        let previous = diskChainTail
        // Detached on purpose: chain links must run off-main and must not
        // inherit cancellation — a cancelled debounce is decided before
        // enqueueing, never by abandoning an op mid-chain.
        let write = Task.detached(priority: .utility) {
            await previous?.value
            return Self.writeBlocking(text, to: url)
        }
        diskChainTail = Task.detached(priority: .utility) { _ = await write.value }
        return write
    }

    private func enqueueDelete(_ url: URL) {
        let previous = diskChainTail
        diskChainTail = Task.detached(priority: .utility) {
            await previous?.value
            Self.deleteBlocking(url)
        }
    }

    /// Awaits everything enqueued on the disk chain so far — lets tests (and
    /// shutdown paths) assert on-disk state without racing the utility queue.
    func drainDiskChain() async {
        await diskChainTail?.value
    }

    nonisolated private static func writeBlocking(_ text: String, to url: URL) -> FlushOutcome {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
            return .success
        } catch {
            return .failure("Manual notes autosave failed: \(error.localizedDescription)")
        }
    }

    nonisolated private static func deleteBlocking(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already gone.
        } catch {
            NSLog("[SerialNotes/ManualNotes] failed to remove draft sidecar: %@", error.localizedDescription)
        }
    }
}
