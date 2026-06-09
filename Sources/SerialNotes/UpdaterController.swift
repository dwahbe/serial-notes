import AppKit
import Sparkle
import SwiftUI

/// Wraps Sparkle's updater for SwiftUI. We build `SPUUpdater` + a user driver
/// directly (rather than the `SPUStandardUpdaterController` convenience wrapper)
/// so we can swap in `QuietUserDriver` — Sparkle's stock "no update found" alert
/// is verbose ("X is currently the newest version available. (You are currently
/// running version Y.)"), and the wrapper gives no hook to replace it. Starting
/// the updater schedules background appcast checks and owns the update UI, so
/// existing users get prompted when a newer signed build appears in the feed. We
/// mirror Sparkle's KVO `canCheckForUpdates` onto an `@Observable` field so the
/// "Check for Updates…" command can disable itself while a check is in flight.
@MainActor
@Observable
final class UpdaterController {
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private let updater: SPUUpdater
    @ObservationIgnored private let userDriver: QuietUserDriver
    @ObservationIgnored private let userDriverDelegate: UpdaterUserDriverDelegate
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        // Create the delegate + driver + updater as locals first so `self` is
        // fully initialized before we use it. The user driver weakly references
        // its delegate, so the delegate must outlive init — hence it's stored.
        let delegate = UpdaterUserDriverDelegate()
        let host = Bundle.main
        let userDriver = QuietUserDriver(hostBundle: host, delegate: delegate)
        let updater = SPUUpdater(
            hostBundle: host,
            applicationBundle: host,
            userDriver: userDriver,
            delegate: nil
        )
        self.userDriverDelegate = delegate
        self.userDriver = userDriver
        self.updater = updater
        self.observation = nil

        // `SPUStandardUpdaterController(startingUpdater: true)` did this for us;
        // building the updater by hand means we start it ourselves.
        do {
            try updater.start()
        } catch {
            NSLog("Sparkle updater failed to start: \(error)")
        }

        canCheckForUpdates = updater.canCheckForUpdates
        // Pull the value from the KVO change (a Sendable Bool?) rather than the
        // updater — its `canCheckForUpdates` is main-actor-isolated, so touching
        // it from this Sendable closure would warn. Hop to the main actor to
        // update our observable property.
        observation = updater.observe(
            \.canCheckForUpdates,
            options: [.new]
        ) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}

/// Serial Notes is an `.accessory` (LSUIElement) menu-bar app. Without gentle
/// reminders, Sparkle shows a scheduled "update available" alert *behind* the
/// frontmost app — where the user never notices it (Sparkle even logs a warning
/// about this exact configuration). Declaring gentle-reminder support and
/// activating the app when the alert is about to show brings it to the front.
private final class UpdaterUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Let Sparkle present its standard update alert; we just ensure focus.
        true
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        // Sparkle calls this on the main thread; hop explicitly so the call is
        // clean under Swift 6 concurrency.
        Task { @MainActor in NSApp.activate() }
    }
}

/// Replaces Sparkle's stock "no update found" alert with a minimal one: a single
/// "You're up to date!" line and the running version below it in secondary text.
/// Everything else (download/install/error UI) falls through to the standard
/// driver. Only the manual "Check for Updates…" path reaches this alert;
/// scheduled checks stay silent when there's nothing new.
private final class QuietUserDriver: SPUStandardUserDriver {
    // Suppress Sparkle's "Checking for updates…" progress window. The standard
    // driver normally tears it down *inside* its own `showUpdateNotFound`, but we
    // replace that method below without calling super — so the window would
    // otherwise linger next to our alert. Not showing it at all keeps the result
    // a single clean dialog (the appcast fetch is effectively instant). The
    // found/error paths still present super's UI; their teardown of this
    // never-shown window is a safe no-op.
    override func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    // Not `override`: `SPUStandardUserDriver` satisfies this as a protocol witness
    // from `SPUUserDriver` (it's async via `NS_SWIFT_ASYNC`) without redeclaring
    // it in its header, so Swift won't accept `override`. Pinning the exact ObjC
    // selector makes the runtime dispatch here instead of to the inherited
    // (verbose) default.
    @objc(showUpdateNotFoundWithError:acknowledgement:)
    func showUpdateNotFound(error: any Error, acknowledgement: @escaping () -> Void) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "You're up to date!"
        alert.informativeText = Self.currentVersionText
        alert.addButton(withTitle: "OK")
        alert.runModal()
        acknowledgement()
    }

    /// e.g. "Version 0.1.2 (beta)". Mirrors Settings → About: major version 0 is
    /// the beta signal, so the suffix self-maintains and drops at 1.0.0.
    private static var currentVersionText: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let major = Int(short.split(separator: ".").first ?? "") ?? 0
        let suffix = major < 1 ? " (beta)" : ""
        return "Version \(short)\(suffix)"
    }
}
