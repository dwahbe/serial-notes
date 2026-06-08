import AppKit
import Sparkle
import SwiftUI

/// Wraps Sparkle's standard updater for SwiftUI. `SPUStandardUpdaterController`
/// starts the updater on init — it schedules background appcast checks and owns
/// the standard update UI, so existing users get prompted when a newer signed
/// build appears in the feed. We mirror Sparkle's KVO `canCheckForUpdates` onto
/// an `@Observable` field so the "Check for Updates…" command can disable itself
/// while a check is already in flight.
@MainActor
@Observable
final class UpdaterController {
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private let userDriverDelegate: UpdaterUserDriverDelegate
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        // Create the delegate + controller as locals first so `self` is fully
        // initialized before we use it (the delegate must outlive init, so it's
        // also stored). SPUStandardUpdaterController holds the user-driver
        // delegate weakly.
        let delegate = UpdaterUserDriverDelegate()
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: delegate
        )
        self.userDriverDelegate = delegate
        self.controller = controller
        self.observation = nil

        canCheckForUpdates = controller.updater.canCheckForUpdates
        // Pull the value from the KVO change (a Sendable Bool?) rather than the
        // updater — its `canCheckForUpdates` is main-actor-isolated, so touching
        // it from this Sendable closure would warn. Hop to the main actor to
        // update our observable property.
        observation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.new]
        ) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
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
