import AppKit
import SwiftUI

/// Owns the manual-notes notepad window. It is a custom `NSPanel` (not a SwiftUI
/// `Window` scene) for the same reason `MeetingBannerController` is: the notepad
/// is used **during** a meeting, so it has to float over a full-screen Zoom/Meet/
/// Teams Space. A `Window` scene lives on its own Space and would be stranded
/// behind the call. `.canJoinAllSpaces + .fullScreenAuxiliary` make the panel
/// overlay the active full-screen space; `canBecomeKey` lets the text view take
/// keyboard focus so the user can actually type into it.
@MainActor @Observable
final class ManualNotesWindowController {
    /// Set once at app wiring. Strong is fine — the store never references back.
    @ObservationIgnored var notesStore: ManualNotesStore?

    @ObservationIgnored private var panel: NSPanel?

    private static let defaultSize = NSSize(width: 520, height: 460)
    /// Internal so the SwiftUI content view sizes from the same source of truth.
    static let minSize = NSSize(width: 360, height: 280)

    func present() {
        guard let notesStore else { return }
        let panel = panel ?? makePanel(notesStore: notesStore)
        self.panel = panel
        // Stay `.accessory` — `NSApp.activate()` + a key panel is the menu-bar way
        // to surface a window without parking a Dock icon (mirrors Settings/onboarding).
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func dismiss() {
        // Hide, don't destroy: a stop snapshots notes but the user may re-open to
        // copy them, and a failed splice re-presents this same panel.
        panel?.orderOut(nil)
    }

    private func makePanel(notesStore: ManualNotesStore) -> NSPanel {
        let panel = ManualNotesPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [
                .titled, .closable, .miniaturizable, .resizable,
                .fullSizeContentView, .nonactivatingPanel
            ],
            backing: .buffered,
            defer: false
        )
        // App-owned, not per-meeting: the notepad exists only while recording, so
        // a meeting-date title carries no information the user doesn't have.
        panel.title = "Notepad — Serial Notes"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.animationBehavior = .utilityWindow
        panel.minSize = Self.minSize

        let hosting = NSHostingController(
            rootView: ManualNotesWindowView().environment(notesStore)
        )
        panel.contentViewController = hosting
        panel.setContentSize(Self.defaultSize)
        panel.center()
        return panel
    }
}

/// A `nonactivatingPanel` does not become key by default, but the notepad's whole
/// job is to receive typed text — so it must be able to become key/main.
private final class ManualNotesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
