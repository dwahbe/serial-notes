import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    weak var recordingState: RecordingState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Offer to relocate into /Applications before anything else spins up. On a
        // successful move this never returns — the relocated copy relaunches itself.
        MoveToApplications.moveIfNeeded()
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recordingState, recordingState.hasActiveOrFinalizingSession else {
            return .terminateNow
        }

        Task { @MainActor in
            await recordingState.stopAndWait(reason: .appQuit)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct SerialNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var recordingState: RecordingState
    @State private var storageSettings: StorageSettings
    @State private var summarySettings: SummarySettings
    @State private var meetingSettings: MeetingSettings
    @State private var identitySettings: IdentitySettings
    @State private var exportSettings: ExportSettings
    @State private var modelDownloadState: ModelDownloadState
    @State private var meetingDetectionService: MeetingDetectionService
    @State private var voiceProfileStore: VoiceProfileStore
    @State private var meetingSessionsStore: MeetingSessionsStore
    @State private var settingsNavigation: SettingsNavigation
    @State private var updaterController: UpdaterController
    @State private var onboardingSettings: OnboardingSettings

    init() {
        let recording = RecordingState()
        let storage = StorageSettings()
        let summary = SummarySettings()
        let meeting = MeetingSettings()
        let identity = IdentitySettings()
        let export = ExportSettings()
        let voices = VoiceProfileStore()
        let sessionsStore = MeetingSessionsStore(storageSettings: storage, voiceStore: voices)
        let navigation = SettingsNavigation()
        let detector = MeetingDetectionService(recordingState: recording, meetingSettings: meeting)
        let modelState = ModelDownloadState(transcriptionService: recording.transcriptionService)

        recording.voiceProfileStore = voices
        recording.summarySettings = summary
        recording.storageSettings = storage
        recording.identitySettings = identity
        recording.exportSettings = export
        recording.onRecordingChange = { [weak detector] in detector?.recordingStateChanged() }
        // After a recording finalizes with unrecognized speakers, offer to name them.
        recording.onUnnamedSpeakers = { [weak detector, weak navigation, weak sessionsStore] dir, count in
            sessionsStore?.reload()
            detector?.showSpeakerNamingPrompt(
                count: count,
                onName: {
                    guard let navigation else { return }
                    navigation.openMeetings(session: dir)
                    SerialNotesApp.openSettings(navigation: navigation)
                },
                onDismiss: {}
            )
        }
        detector.onRecordRequested = { [weak recording, weak storage] in
            guard let recording, let storage else { return }
            Task { await recording.start(storageDirectory: storage.storageLocation) }
        }
        detector.onStopRecordingRequested = { [weak recording] reason in
            recording?.stop(reason: reason)
        }

        _recordingState = State(initialValue: recording)
        _storageSettings = State(initialValue: storage)
        _summarySettings = State(initialValue: summary)
        _meetingSettings = State(initialValue: meeting)
        _identitySettings = State(initialValue: identity)
        _exportSettings = State(initialValue: export)
        _modelDownloadState = State(initialValue: modelState)
        _meetingDetectionService = State(initialValue: detector)
        _voiceProfileStore = State(initialValue: voices)
        _meetingSessionsStore = State(initialValue: sessionsStore)
        _settingsNavigation = State(initialValue: navigation)
        _updaterController = State(initialValue: UpdaterController())
        _onboardingSettings = State(initialValue: OnboardingSettings())

        appDelegate.recordingState = recording

        // Kick model download off at app launch, not when the popover first
        // opens — the banner lets users start recording without ever opening
        // the popover, so gating downloads on the popover's .task races the user.
        Task { @MainActor in await modelState.downloadIfNeeded() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(recordingState)
                .environment(storageSettings)
                .environment(summarySettings)
                .environment(meetingSettings)
                .environment(modelDownloadState)
                .environment(meetingDetectionService)
                .environment(voiceProfileStore)
                .environment(settingsNavigation)
                .preferredColorScheme(.dark)
        } label: {
            // The label renders at launch, so its `.onAppear` captures the real
            // `openSettings`/`openWindow` actions and decides whether to auto-open
            // the first-run setup guide before any banner needs them.
            MenuBarLabel(
                isRecording: recordingState.isRecording,
                navigation: settingsNavigation,
                onboarding: onboardingSettings,
                recordingState: recordingState,
                voiceStore: voiceProfileStore,
                storageSettings: storageSettings
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(voiceProfileStore)
                .environment(storageSettings)
                .environment(summarySettings)
                .environment(meetingSettings)
                .environment(identitySettings)
                .environment(exportSettings)
                .environment(meetingDetectionService)
                .environment(meetingSessionsStore)
                .environment(settingsNavigation)
                .environment(updaterController)
                .environment(recordingState)
        }

        Window("Welcome to Serial Notes", id: onboardingWindowID) {
            OnboardingFlowView(
                onboarding: onboardingSettings,
                storageSettings: storageSettings,
                exportSettings: exportSettings,
                voiceStore: voiceProfileStore,
                identitySettings: identitySettings,
                meetingDetector: meetingDetectionService
            )
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    /// Bring the Settings window to the front from non-view code (the post-meeting
    /// prompt). Mirrors `MenuBarView.showSettings` / `StorageSettings.pickFolder`: flip
    /// to `.regular`, activate, open. `WindowCloseChrome` restores `.accessory` on close.
    @MainActor
    static func openSettings(navigation: SettingsNavigation) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let action = navigation.openSettingsAction {
            // The real SwiftUI `openSettings` action — works reliably in a menu-bar app.
            action()
            return
        }
        // Fallback: the AppKit selector (macOS 13+ `showSettingsWindow:`, previously
        // `showPreferencesWindow:`). Restore `.accessory` if neither is handled so we
        // don't leave the app stuck in the Dock with no window open.
        let opened = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            || NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        if !opened {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// The menu bar icon. Captures the `openSettings` / `openWindow` environment
/// actions into the shared navigation (so non-view code can open Settings and the
/// setup guide reliably) and decides whether to auto-open the first-run guide.
private struct MenuBarLabel: View {
    let isRecording: Bool
    let navigation: SettingsNavigation
    let onboarding: OnboardingSettings
    let recordingState: RecordingState
    let voiceStore: VoiceProfileStore
    let storageSettings: StorageSettings
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            // Custom brand mark (see BrandMark.swift) instead of an SF Symbol so
            // the menu bar matches the website + app icon. Idle is a monochrome
            // template (macOS tints/inverts it); recording is the red "live" variant.
            Image(nsImage: isRecording ? BrandMark.menuBarRecording : BrandMark.menuBarIdle)
            // Tag the local dev build so it's tellable apart from a downloaded
            // production build sitting in the same menu bar.
            if Bundle.main.isDevBuild {
                Text("DEV")
                    .font(.system(size: 10, weight: .bold))
            }
        }
        .onAppear {
            navigation.openSettingsAction = { openSettings() }
            navigation.openSetupAction = {
                // Stay `.accessory` (no Dock icon) — WindowBringToFront surfaces the
                // window via orderFrontRegardless. Keeps the menu-bar app out of the
                // Dock during first-run setup.
                NSApp.activate()
                openWindow(id: onboardingWindowID)
            }
            // Defer one runloop turn so the Window scene is registered before
            // we ask to open it.
            Task { @MainActor in maybeAutoOpenSetup() }
        }
    }

    /// Present the first-run guide once on a fresh install. Skip silently for an
    /// existing user updating from a pre-onboarding build (they already have app
    /// state), and never interrupt an in-flight recording.
    private func maybeAutoOpenSetup() {
        guard onboarding.needsAutoOpen else { return }

        if hasExistingUserState() {
            onboarding.markShown()
            return
        }

        guard !recordingState.hasActiveOrFinalizingSession else { return }

        // Don't mark shown here: if openWindow no-ops (e.g. the Window scene
        // isn't registered yet), we want to retry on the next launch rather than
        // suppress onboarding forever. The guide marks itself shown in its own
        // onAppear, once it has actually appeared.
        navigation.openSetupAction?()
    }

    /// True when the app has prior state — voice profiles, saved meetings, or
    /// persisted settings — i.e. a returning user rather than a fresh install.
    private func hasExistingUserState() -> Bool {
        if !voiceStore.profiles.isEmpty { return true }
        let defaults = UserDefaults.standard
        if let name = defaults.string(forKey: "identity.yourName"), !name.isEmpty { return true }
        if defaults.string(forKey: "storageLocation") != nil { return true }
        // Cheap directory probe — any saved session folder means a returning
        // user. Avoids MeetingSessionsStore.reload(), which decodes every
        // session's sidecar on the main thread at launch.
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: storageSettings.storageLocation,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ), !entries.isEmpty {
            return true
        }
        return false
    }
}
