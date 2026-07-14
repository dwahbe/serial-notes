import AppKit
import KeyboardShortcuts
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

    @Test("shortcut display tracks recorder changes, clears, and the ⌃⌘N default")
    func shortcutDisplayTracksChanges() {
        // Restore the initial shortcut whatever happens — setShortcut persists
        // into the test runner's UserDefaults.
        defer { KeyboardShortcuts.reset(.toggleNotepad) }
        KeyboardShortcuts.reset(.toggleNotepad)

        let controller = ManualNotesWindowController()
        #expect(controller.shortcutDisplay == "⌃⌘N")

        KeyboardShortcuts.setShortcut(.init(.t, modifiers: [.option, .command]), for: .toggleNotepad)
        controller.shortcutDidChange()
        #expect(controller.shortcutDisplay == "⌥⌘T")

        // Clearing the shortcut hides the hints entirely.
        KeyboardShortcuts.setShortcut(nil, for: .toggleNotepad)
        controller.shortcutDidChange()
        #expect(controller.shortcutDisplay == nil)
    }

    @Test("a combo recorded while idle stays disabled until a recording claims it")
    func idleRecordingStaysDisabled() {
        defer { KeyboardShortcuts.reset(.toggleNotepad) }
        KeyboardShortcuts.reset(.toggleNotepad)

        let controller = ManualNotesWindowController()
        KeyboardShortcuts.setShortcut(.init(.b, modifiers: [.control, .command]), for: .toggleNotepad)
        controller.shortcutDidChange()
        #expect(!controller.isGlobalShortcutActive)

        controller.activateGlobalShortcut()
        #expect(controller.isGlobalShortcutActive)
        #expect(controller.shortcutDisplay == "⌃⌘B")
        controller.deactivateGlobalShortcut()
    }
}
