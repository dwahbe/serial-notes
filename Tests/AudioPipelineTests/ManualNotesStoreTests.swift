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

            #expect(snapshot == "latest")
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
            _ = store.snapshotAndEndSession()
            await store.completeSnapshotWrite(succeeded: true)
            await store.drainDiskChain()

            let sidecar = ManualNotesStore.sidecarURL(in: dir)
            #expect(!FileManager.default.fileExists(atPath: sidecar.path))
            #expect(store.text == "")
        }
    }

    @Test("Failed finalization keeps sidecar, draft, and a recovery pointer")
    func failedFinalizationKeepsSidecarAndDraft() async throws {
        defer { UserDefaults.standard.removeObject(forKey: ManualNotesStore.recoveryPathKey) }
        try await withTempSession { dir in
            let store = ManualNotesStore()
            store.beginSession(sessionDir: dir)
            store.updateText("notes")
            _ = store.snapshotAndEndSession()
            await store.completeSnapshotWrite(succeeded: false)
            await store.drainDiskChain()

            let sidecar = ManualNotesStore.sidecarURL(in: dir)
            let saved = try String(contentsOf: sidecar, encoding: .utf8)
            #expect(saved == "notes")
            #expect(store.text == "notes")
            #expect(store.isEditable)
            #expect(store.errorMessage?.contains(sidecar.path) == true)
            #expect(UserDefaults.standard.string(forKey: ManualNotesStore.recoveryPathKey) == sidecar.path)
        }
    }

    @Test("A kept draft carries into the next session instead of being wiped")
    func keptDraftCarriesForward() async throws {
        defer { UserDefaults.standard.removeObject(forKey: ManualNotesStore.recoveryPathKey) }
        try await withTempSession { oldDir in
            try await withTempSession { newDir in
                let store = ManualNotesStore()
                store.beginSession(sessionDir: oldDir)
                store.updateText("keep me")
                _ = store.snapshotAndEndSession()
                await store.completeSnapshotWrite(succeeded: false)

                store.beginSession(sessionDir: newDir)
                await store.drainDiskChain()

                #expect(store.text == "keep me")
                #expect(store.errorMessage == nil)
                let oldSidecar = ManualNotesStore.sidecarURL(in: oldDir)
                let newSidecar = ManualNotesStore.sidecarURL(in: newDir)
                #expect(!FileManager.default.fileExists(atPath: oldSidecar.path))
                let carried = try String(contentsOf: newSidecar, encoding: .utf8)
                #expect(carried == "keep me")
                #expect(UserDefaults.standard.string(forKey: ManualNotesStore.recoveryPathKey) == nil)
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

    @Test("Start failure discards an empty draft")
    func startFailureDiscardsEmptyDraft() async throws {
        await withTempSession { dir in
            let store = ManualNotesStore()
            store.beginSession(sessionDir: dir)
            store.discardIfEmptyAfterStartFailure()
            await store.drainDiskChain()

            let sidecar = ManualNotesStore.sidecarURL(in: dir)
            #expect(!FileManager.default.fileExists(atPath: sidecar.path))
            #expect(!store.isEditable)
        }
    }

    @Test("Start failure preserves a non-empty draft for the next session")
    func startFailurePreservesNonEmptyDraft() async throws {
        try await withTempSession { dir in
            let store = ManualNotesStore()
            store.beginSession(sessionDir: dir)
            store.updateText("important")
            store.discardIfEmptyAfterStartFailure()
            await store.drainDiskChain()

            let sidecar = ManualNotesStore.sidecarURL(in: dir)
            let saved = try String(contentsOf: sidecar, encoding: .utf8)
            #expect(saved == "important")
            #expect(store.text == "important")
            #expect(store.isEditable)
        }
    }

    @Test("Quit recovery restores notes from the stashed sidecar pointer")
    func quitRecoveryRestoresDraft() async throws {
        defer { UserDefaults.standard.removeObject(forKey: ManualNotesStore.recoveryPathKey) }
        try await withTempSession { dir in
            let sidecar = ManualNotesStore.sidecarURL(in: dir)
            try "orphaned notes".write(to: sidecar, atomically: true, encoding: .utf8)
            UserDefaults.standard.set(sidecar.path, forKey: ManualNotesStore.recoveryPathKey)

            let store = ManualNotesStore()
            #expect(store.restoreQuitRecoveryDraft())
            #expect(store.text == "orphaned notes")
            #expect(store.isEditable)
            #expect(store.errorMessage != nil)
            #expect(UserDefaults.standard.string(forKey: ManualNotesStore.recoveryPathKey) == nil)
        }
    }
}
