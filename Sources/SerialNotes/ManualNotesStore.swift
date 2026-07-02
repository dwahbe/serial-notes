import Foundation

@MainActor @Observable
final class ManualNotesStore {
    nonisolated static let sidecarFileName = ".manual-notes.md"

    /// Path of a sidecar whose transcript splice failed, stashed so the next
    /// launch can surface the notes instead of stranding them in a hidden file —
    /// the quit path has no UI left to show the failure on.
    static let recoveryPathKey = "manualNotes.recoverySidecarPath"

    /// How long to wait after the last keystroke before autosaving. Keeps the
    /// disk off the typing hot path — the in-memory `text` is always current and
    /// is what `snapshotAndEndSession()` hands to finalization, so the sidecar is
    /// only a crash-safety copy and can lag a few hundred ms safely.
    private static let autosaveDebounce: Duration = .milliseconds(600)

    private(set) var text = ""
    private(set) var isEditable = false
    var errorMessage: String?

    @ObservationIgnored private var sidecarURL: URL?
    @ObservationIgnored private var pendingCleanupURL: URL?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// Tail of the ordered sidecar disk-op chain. Every write/delete awaits its
    /// predecessor, so a slow in-flight autosave can never land after a later
    /// delete (resurrecting a reaped sidecar) or clobber a newer snapshot.
    @ObservationIgnored private var diskChainTail: Task<Void, Never>?

    func beginSession(sessionDir: URL) {
        flushTask?.cancel()
        let previousSidecarURL = sidecarURL
        sidecarURL = Self.sidecarURL(in: sessionDir)
        pendingCleanupURL = nil
        isEditable = true
        errorMessage = nil
        Self.clearRecoveryPointer()

        // A kept draft (failed start, failed splice, quit recovery) is never
        // silently wiped — it carries into the new session, its sidecar moves
        // with it, and the superseded copy is reaped. An empty draft costs no
        // disk at all: the first keystroke's debounced flush creates the file.
        if let sidecarURL, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

    /// Captures the draft for finalization. The returned in-memory text is the
    /// source of truth handed to `endSession`; the final sidecar write is
    /// enqueued behind any in-flight autosave so the on-disk crash copy is
    /// current by the time `completeSnapshotWrite` can need it.
    func snapshotAndEndSession() -> String? {
        flushTask?.cancel()
        isEditable = false
        pendingCleanupURL = sidecarURL
        sidecarURL = nil

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            deletePendingSidecar()
            resetInactiveDraft()
            return nil
        }
        if let url = pendingCleanupURL {
            enqueueWrite(text, to: url)
        }
        return text
    }

    func completeSnapshotWrite(succeeded: Bool) async {
        if succeeded {
            deletePendingSidecar()
            Self.clearRecoveryPointer()
            resetInactiveDraft()
            return
        }
        guard let url = pendingCleanupURL,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // The notes never made it into transcript.md. Don't fail silently, and
        // don't claim the sidecar is safe until a fresh write of the in-memory
        // text confirms it — the earlier flush may have failed for the same
        // disk problem the splice did.
        let outcome = await enqueueWrite(text, to: url).value
        let message: String
        switch outcome {
        case .success:
            Self.setRecoveryPointer(url)
            message = "Couldn't add your notes to transcript.md — they're saved at \(url.path)"
        case .failure:
            message = "Couldn't add your notes to transcript.md or save them to disk — copy them from this notepad."
        }
        errorMessage = message
        NSLog("[SerialNotes/ManualNotes] %@", message)
        // Keep the draft live so it can be copied, edited, or carried into the
        // next session instead of locking text that only exists here.
        sidecarURL = url
        pendingCleanupURL = nil
        isEditable = true
    }

    func discardIfEmptyAfterStartFailure() {
        flushTask?.cancel()
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Recording never started, but the user has typed text — keep it
            // editable (and autosaving); the next beginSession carries it
            // forward. Persist now since we just cancelled the debounced write.
            if let sidecarURL {
                enqueueWrite(text, to: sidecarURL)
            }
            return
        }
        pendingCleanupURL = sidecarURL
        sidecarURL = nil
        deletePendingSidecar()
        resetInactiveDraft()
    }

    /// Surfaces notes whose splice failed during an app quit. Reads the pointer
    /// stashed by `completeSnapshotWrite` back at launch; returns true when a
    /// draft was restored so the caller can present the notepad. One blocking
    /// read at launch, only ever after a rare failed-splice quit.
    func restoreQuitRecoveryDraft() -> Bool {
        guard !isEditable, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let path = UserDefaults.standard.string(forKey: Self.recoveryPathKey) else {
            return false
        }
        Self.clearRecoveryPointer()
        let url = URL(fileURLWithPath: path)
        guard let saved = try? String(contentsOf: url, encoding: .utf8),
              !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        text = saved
        sidecarURL = url
        isEditable = true
        errorMessage = "These notes couldn't be added to their meeting's transcript.md — recovered from \(url.path)"
        return true
    }

    nonisolated static func sidecarURL(in sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent(sidecarFileName)
    }

    private func deletePendingSidecar() {
        guard let url = pendingCleanupURL else { return }
        enqueueDelete(url)
        pendingCleanupURL = nil
    }

    private func resetInactiveDraft() {
        text = ""
        isEditable = false
    }

    private static func setRecoveryPointer(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: recoveryPathKey)
    }

    private static func clearRecoveryPointer() {
        UserDefaults.standard.removeObject(forKey: recoveryPathKey)
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
