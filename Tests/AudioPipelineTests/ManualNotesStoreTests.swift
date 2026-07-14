import Foundation
import Testing

@testable import SerialNotes

@Suite("Manual Notes Store")
@MainActor
struct ManualNotesStoreTests {
    private func withTempSession(_ body: (URL) async throws -> Void) async rethrows {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sn-notes-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }

    @Test("Begin session with an empty draft touches no disk")
    func beginSessionWritesNothing() async throws {
        await withTempSession { dir in
            let store = ManualNotesStore()
            store.beginSession(sessionDir: dir)
            await store.drainDiskChain()

            let sidecar = ManualNotesStore.sidecarURL(in: dir)
            #expect(!FileManager.default.fileExists(atPath: sidecar.path))
            #expect(store.text == "")
            #expect(store.isEditable)
        }
    }

    @Test("Updates autosave to the sidecar (debounced)")
    func updatesFlushToSidecar() async throws {
        try await withTempSession { dir in
            let store = ManualNotesStore()
            store.beginSession(sessionDir: dir)
            store.updateText("- one\n- two")

            // The debounce timer's resume order vs. this task isn't guaranteed
            // under parallel test load — poll (draining the write chain each
            // pass) instead of racing it with a single sleep.
            let sidecar = ManualNotesStore.sidecarURL(in: dir)
            var saved = ""
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(50))
                await store.drainDiskChain()
                if let text = try? String(contentsOf: sidecar, encoding: .utf8) {
                    saved = text
                    break
                }
            }
            #expect(saved == "- one\n- two")
        }
    }

    @Test("Stop snapshot returns latest notes and locks editing")
    func snapshotReturnsLatestNotes() async throws {
        await withTempSession { dir in
            let store = ManualNotesStore()
            store.beginSession(sessionDir: dir)
            store.updateText("latest")

            let snapshot = store.snapshotAndEndSession()

            #expect(snapshot?.text == "latest")
            #expect(!store.isEditable)
        }
    }

    @Test("Stop snapshot persists the final text despite a pending debounce")
    func snapshotPersistsFinalText() async throws {
        try await withTempSession { dir in
            let store = ManualNotesStore()
            store.beginSession(sessionDir: dir)
            store.updateText("latest")
            _ = store.snapshotAndEndSession()
            await store.drainDiskChain()

            let sidecar = ManualNotesStore.sidecarURL(in: dir)
            let saved = try String(contentsOf: sidecar, encoding: .utf8)
            #expect(saved == "latest")
        }
    }

    @Test("Successful finalization deletes sidecar")
    func successfulFinalizationDeletesSidecar() async throws {
        await withTempSession { dir in
            let store = ManualNotesStore()
            store.beginSession(sessionDir: dir)
            store.updateText("notes")
            let snapshot = store.snapshotAndEndSession()
            #expect(snapshot != nil)
            if let snapshot {
                await store.completeSnapshotWrite(snapshot, succeeded: true)
            }
            await store.drainDiskChain()

            let sidecar = ManualNotesStore.sidecarURL(in: dir)
            #expect(!FileManager.default.fileExists(atPath: sidecar.path))
            #expect(store.text == "")
        }
    }

    /// Isolated defaults per test: the recovery pointers are global state, and
    /// suites run in parallel — `.standard` would bleed entries between tests.
    private func makeTestDefaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let name = "manual-notes-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    @Test("Failed finalization keeps sidecar, draft, and a recovery pointer")
    func failedFinalizationKeepsSidecarAndDraft() async throws {
        let (defaults, cleanup) = makeTestDefaults()
        defer { cleanup() }
        try await withTempSession { dir in
            let store = ManualNotesStore(userDefaults: defaults)
            store.beginSession(sessionDir: dir)
            store.updateText("notes")
            let snapshot = store.snapshotAndEndSession()
            #expect(snapshot != nil)
            if let snapshot {
                await store.completeSnapshotWrite(snapshot, succeeded: false)
            }
            await store.drainDiskChain()

            let sidecar = ManualNotesStore.sidecarURL(in: dir)
            let saved = try String(contentsOf: sidecar, encoding: .utf8)
            #expect(saved == "notes")
            #expect(store.text == "notes")
            #expect(store.isEditable)
            #expect(store.errorMessage?.contains(sidecar.path) == true)
            #expect(defaults.stringArray(forKey: ManualNotesStore.recoveryPathsKey) == [sidecar.path])
        }
    }

    @Test("A kept draft carries into the next session instead of being wiped")
    func keptDraftCarriesForward() async throws {
        let (defaults, cleanup) = makeTestDefaults()
        defer { cleanup() }
        try await withTempSession { oldDir in
            try await withTempSession { newDir in
                let store = ManualNotesStore(userDefaults: defaults)
                store.beginSession(sessionDir: oldDir)
                store.updateText("keep me")
                let snapshot = store.snapshotAndEndSession()
                if let snapshot {
                    await store.completeSnapshotWrite(snapshot, succeeded: false)
                }

                store.beginSession(sessionDir: newDir)
                await store.drainDiskChain()

                #expect(store.text == "keep me")
                #expect(store.errorMessage == nil)
                let oldSidecar = ManualNotesStore.sidecarURL(in: oldDir)
                let newSidecar = ManualNotesStore.sidecarURL(in: newDir)
                #expect(!FileManager.default.fileExists(atPath: oldSidecar.path))
                let carried = try String(contentsOf: newSidecar, encoding: .utf8)
                #expect(carried == "keep me")
                #expect(defaults.stringArray(forKey: ManualNotesStore.recoveryPathsKey) == nil)
            }
        }
    }

    @Test("Two failed splices both get recovery pointers; launches restore one draft each")
    func recoveryPointerListSurvivesTwoFailures() async throws {
        let (defaults, cleanup) = makeTestDefaults()
        defer { cleanup() }
        try await withTempSession { dirA in
            try await withTempSession { dirB in
                let store = ManualNotesStore(userDefaults: defaults)
                store.beginSession(sessionDir: dirA)
                store.updateText("meeting A notes")
                let snapshotA = store.snapshotAndEndSession()

                store.beginSession(sessionDir: dirB)
                store.updateText("meeting B notes")
                let snapshotB = store.snapshotAndEndSession()

                if let snapshotA { await store.completeSnapshotWrite(snapshotA, succeeded: false) }
                if let snapshotB { await store.completeSnapshotWrite(snapshotB, succeeded: false) }
                await store.drainDiskChain()

                // Both failures are pointed to — the second must not overwrite
                // the first (the old single-slot key silently lost meeting A).
                let sidecarA = ManualNotesStore.sidecarURL(in: dirA)
                let sidecarB = ManualNotesStore.sidecarURL(in: dirB)
                #expect(defaults.stringArray(forKey: ManualNotesStore.recoveryPathsKey)
                        == [sidecarA.path, sidecarB.path])

                // "Next launch": the oldest draft is restored, the other kept.
                let launch1 = ManualNotesStore(userDefaults: defaults)
                #expect(launch1.restoreQuitRecoveryDraft())
                #expect(launch1.text == "meeting A notes")
                #expect(defaults.stringArray(forKey: ManualNotesStore.recoveryPathsKey)
                        == [sidecarB.path])

                // "Launch after that": the remaining draft surfaces.
                let launch2 = ManualNotesStore(userDefaults: defaults)
                #expect(launch2.restoreQuitRecoveryDraft())
                #expect(launch2.text == "meeting B notes")
                #expect(defaults.stringArray(forKey: ManualNotesStore.recoveryPathsKey) == nil)
            }
        }
    }

    @Test("A pending snapshot never collides with a new session's draft (back-to-back recordings)")
    func pendingSnapshotIsIndependentOfNewDraft() async throws {
        let (defaults, cleanup) = makeTestDefaults()
        defer { cleanup() }
        try await withTempSession { oldDir in
            try await withTempSession { newDir in
                let store = ManualNotesStore(userDefaults: defaults)
                store.beginSession(sessionDir: oldDir)
                store.updateText("meeting A notes")
                let snapshotA = store.snapshotAndEndSession()

                // The next recording begins before A's splice resolves.
                store.beginSession(sessionDir: newDir)
                store.updateText("meeting B notes")

                // A's failed splice must not clobber B's live draft — the notes
                // stay safe in A's sidecar with a recovery pointer instead.
                if let snapshotA {
                    await store.completeSnapshotWrite(snapshotA, succeeded: false)
                }
                await store.drainDiskChain()

                #expect(store.text == "meeting B notes")
                #expect(store.isEditable)
                let oldSidecar = ManualNotesStore.sidecarURL(in: oldDir)
                let savedA = try String(contentsOf: oldSidecar, encoding: .utf8)
                #expect(savedA == "meeting A notes")
                #expect(defaults.stringArray(forKey: ManualNotesStore.recoveryPathsKey) == [oldSidecar.path])

                // B ends normally and its own snapshot is intact.
                let snapshotB = store.snapshotAndEndSession()
                #expect(snapshotB?.text == "meeting B notes")
            }
        }
    }

    @Test("Empty snapshot leaves no sidecar behind")
    func emptySnapshotDeletesSidecar() async throws {
        await withTempSession { dir in
            let store = ManualNotesStore()
            store.beginSession(sessionDir: dir)
            store.updateText("scratch")
            store.updateText("   ")

            let snapshot = store.snapshotAndEndSession()
            await store.drainDiskChain()

            let sidecar = ManualNotesStore.sidecarURL(in: dir)
            #expect(snapshot == nil)
            #expect(!FileManager.default.fileExists(atPath: sidecar.path))
        }
    }

    @Test("Quit recovery restores notes from a LEGACY single-path pointer (migration)")
    func quitRecoveryRestoresDraft() async throws {
        let (defaults, cleanup) = makeTestDefaults()
        defer { cleanup() }
        try await withTempSession { dir in
            let sidecar = ManualNotesStore.sidecarURL(in: dir)
            try "orphaned notes".write(to: sidecar, atomically: true, encoding: .utf8)
            // Pre-list versions stored a single path — restore must migrate it.
            defaults.set(sidecar.path, forKey: ManualNotesStore.recoveryPathKey)

            let store = ManualNotesStore(userDefaults: defaults)
            #expect(store.restoreQuitRecoveryDraft())
            #expect(store.text == "orphaned notes")
            #expect(store.isEditable)
            #expect(store.errorMessage != nil)
            #expect(defaults.string(forKey: ManualNotesStore.recoveryPathKey) == nil)
            #expect(defaults.stringArray(forKey: ManualNotesStore.recoveryPathsKey) == nil)
        }
    }
}
