import AppKit
import Testing

@testable import SerialNotes

@Suite("Manual Notes Window Controller")
@MainActor
struct ManualNotesWindowControllerTests {
    @Test("toggle presents when hidden and dismisses when visible")
    func toggleFlipsVisibility() {
        let controller = ManualNotesWindowController()
        controller.notesStore = ManualNotesStore()
        defer { controller.dismiss() }

        #expect(!controller.isNotepadVisible)
        controller.toggle()
        #expect(controller.isNotepadVisible)
        controller.toggle()
        #expect(!controller.isNotepadVisible)
        // Hide-don't-destroy: a second toggle must re-present the same panel.
        controller.toggle()
        #expect(controller.isNotepadVisible)
    }

    @Test("toggle without a store is a safe no-op")
    func toggleWithoutStore() {
        let controller = ManualNotesWindowController()
        controller.toggle()
        #expect(!controller.isNotepadVisible)
    }

    @Test("global shortcut activation is idempotent in both directions")
    func shortcutActivation() {
        let controller = ManualNotesWindowController()
        #expect(!controller.isGlobalShortcutActive)

        controller.activateGlobalShortcut()
        controller.activateGlobalShortcut()
        #expect(controller.isGlobalShortcutActive)

        controller.deactivateGlobalShortcut()
        #expect(!controller.isGlobalShortcutActive)
        controller.deactivateGlobalShortcut()
        #expect(!controller.isGlobalShortcutActive)
    }
}
