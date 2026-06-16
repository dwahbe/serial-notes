import AppKit
import Foundation

/// Shared navigation state for the Settings window so the post-meeting prompt can
/// deep-link straight to a specific session on the Meetings tab. Constructed at the
/// app root and injected into the Settings scene.
@MainActor @Observable
final class SettingsNavigation {
    enum Tab: Hashable {
        case general
        case people
        case meetings
    }

    var selectedTab: Tab = .general
    /// When set, the Meetings tab presents the naming sheet for this exact session URL.
    var pendingNamingSession: URL?

    /// SwiftUI's `openSettings` environment action, captured from a live view at launch.
    /// Non-view code (the post-meeting banner) can't read `@Environment(\.openSettings)`
    /// directly, and the AppKit `showSettingsWindow:` selector has no responder in a
    /// menu-bar-only app — so we stash the real action here and call it.
    @ObservationIgnored var openSettingsAction: (@MainActor () -> Void)?

    /// Opens the first-run setup guide window. Captured from a live view at launch
    /// (same reason as `openSettingsAction`) so the auto-open path and the
    /// "Show Setup Guide…" button in Settings can both present it.
    @ObservationIgnored var openSetupAction: (@MainActor () -> Void)?

    /// The live Settings window, captured when it appears, so non-view code can
    /// re-front it without flipping activation policy (which would park a Dock icon).
    @ObservationIgnored weak var settingsWindow: NSWindow?

    /// Switch to the Meetings tab and (optionally) open a specific session for naming.
    func openMeetings(session: URL?) {
        selectedTab = .meetings
        pendingNamingSession = session
    }

    /// Front the Settings window without flipping activation policy: activate, open
    /// (or focus) via the captured SwiftUI action, then raise the window above the
    /// frontmost app on a repeat open (the once-only `WindowBringToFront` can't).
    func presentSettings() {
        NSApp.activate()
        guard let openSettingsAction else {
            // The SwiftUI action wasn't captured yet — fall back to the AppKit selector.
            _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                || NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            return
        }
        openSettingsAction()
        settingsWindow?.orderFrontRegardless()
    }
}
