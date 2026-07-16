import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    weak var recordingState: RecordingState?
    weak var meetingDetectionService: MeetingDetectionService?
    weak var manualNotesStore: ManualNotesStore?
    weak var manualNotesWindowController: ManualNotesWindowController?
    weak var notionConnection: NotionConnection?
    /// Set when `SerialNotesApp.init` held back the launch-time model download
    /// because another instance was still running; invoked once this launch has
    /// survived the single-instance guard.
    var deferredModelDownload: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Single-instance fast paths: a duplicate launch defers to the running
        // copy and exits before the menu-bar icon appears. Conflicts that need
        // UI (orphan reclaim, the DMG Quit-and-Install offer) are stashed for
        // applicationDidFinishLaunching below — an alert shown before the app
        // finishes launching can land behind the frontmost app and stall the
        // launch invisibly. May not return: the defer path exits the process.
        SingleInstanceGuard.enforce()

        // Custom-scheme URLs (the Notion OAuth callback bounce). Registered
        // via kAEGetURL because this is an `.accessory` app that usually has
        // no window open — SwiftUI's `.onOpenURL` needs a live scene to fire.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard
            let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
            let url = URL(string: urlString)
        else { return }
        route(url)
    }

    /// Belt-and-suspenders alongside the kAEGetURL handler: SwiftUI/AppKit may
    /// deliver URL opens through this delegate method instead, depending on
    /// which internal handler won registration. Both paths converge here, and
    /// the OAuth flow's single-use state makes an (unobserved-in-practice)
    /// double delivery harmless.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { route(url) }
    }

    private func route(_ url: URL) {
        if notionConnection?.handleCallbackURL(url) != true {
            NSLog("[SerialNotes] unhandled URL event: %@", url.absoluteString)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Resolve any conflict the guard deferred — it may exit the process.
        // Detection is suspended around the flow's alerts and waits so a doomed
        // duplicate can't pop a meeting banner of its own.
        var resolution = SingleInstanceGuard.ConflictResolution.none
        if SingleInstanceGuard.hasPendingConflict {
            meetingDetectionService?.suspendDetection()
            resolution = SingleInstanceGuard.resolvePendingConflict()
            meetingDetectionService?.resumeDetection()
        }

        // Offer to relocate into /Applications before anything else spins up. On a
        // successful move this never returns — the relocated copy relaunches itself.
        // The guard above guarantees the destination is free of live instances, and
        // its Quit-and-Install consent already covers a downgrade, so the prompt
        // isn't shown twice.
        MoveToApplications.moveIfNeeded(
            replaceConsentGiven: resolution == .wonWithReplaceConsent
        )
        NSApp.setActivationPolicy(.accessory)

        // Still here means this launch won (or there was no conflict): start the
        // model download init held back while another instance was running.
        deferredModelDownload?()
        deferredModelDownload = nil

        // A splice failure during a previous quit left notes only in a hidden
        // sidecar — restore them into the notepad so the failure isn't silent.
        if manualNotesStore?.restoreQuitRecoveryDraft() == true {
            manualNotesWindowController?.present()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Gate on the widest lifecycle flag: a session that is still spinning up
        // (isStarting) or capturing ahead of its transcription attach has work
        // to drain just like an active or finalizing one.
        guard let recordingState, recordingState.isRecordingSessionActive else {
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
    @State private var manualNotesSettings: ManualNotesSettings
    @State private var manualNotesStore: ManualNotesStore
    @State private var manualNotesWindowController: ManualNotesWindowController
    @State private var modelDownloadState: ModelDownloadState
    @State private var meetingDetectionService: MeetingDetectionService
    @State private var voiceProfileStore: VoiceProfileStore
    @State private var meetingSessionsStore: MeetingSessionsStore
    @State private var settingsNavigation: SettingsNavigation
    @State private var updaterController: UpdaterController
    @State private var onboardingSettings: OnboardingSettings
    @State private var notionConnection: NotionConnection

    init() {
        let recording = RecordingState()
        let storage = StorageSettings()
        let summary = SummarySettings()
        let meeting = MeetingSettings()
        let identity = IdentitySettings()
        let export = ExportSettings()
        let manualNotes = ManualNotesSettings()
        let manualNotesStore = ManualNotesStore()
        let manualNotesWindow = ManualNotesWindowController()
        let voices = VoiceProfileStore()
        let sessionsStore = MeetingSessionsStore(storageSettings: storage, voiceStore: voices)
        let navigation = SettingsNavigation()
        let detector = MeetingDetectionService(recordingState: recording, meetingSettings: meeting)
        let modelState = ModelDownloadState(transcriptionService: recording.transcriptionService)
        let notion = NotionConnection()
        notion.exportSettings = export

        recording.voiceProfileStore = voices
        recording.summarySettings = summary
        recording.storageSettings = storage
        recording.identitySettings = identity
        recording.exportSettings = export
        recording.manualNotesSettings = manualNotes
        recording.manualNotesStore = manualNotesStore
        recording.manualNotesWindowController = manualNotesWindow
        recording.notionSender = notion
        manualNotesWindow.notesStore = manualNotesStore
        recording.onRecordingChange = { [weak detector] in detector?.recordingStateChanged() }
        // After a recording finalizes with unrecognized speakers, offer to name them.
        recording.onUnnamedSpeakers = { [weak detector, weak navigation, weak sessionsStore] dir, count in
            sessionsStore?.reload()
            detector?.showSpeakerNamingPrompt(
                count: count,
                onName: {
                    guard let navigation else { return }
                    navigation.openMeetings(session: dir)
                    navigation.presentSettings()
                },
                onDismiss: {}
            )
        }
        detector.onRecordRequested = { [weak recording, weak storage] in
            guard let recording, let storage else { return }
            Task { await recording.start(storageDirectory: storage.storageLocation) }
        }
        // The floating banner must not offer Record while ASR models are still
        // downloading — same gate the popover applies. (A pre-models recording
        // would capture fine, but its attach could park quit behind an
        // unbounded model download.)
        detector.isReadyToRecord = { [weak modelState] in
            modelState?.isReady ?? false
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
        _manualNotesSettings = State(initialValue: manualNotes)
        _manualNotesStore = State(initialValue: manualNotesStore)
        _manualNotesWindowController = State(initialValue: manualNotesWindow)
        _modelDownloadState = State(initialValue: modelState)
        _meetingDetectionService = State(initialValue: detector)
        _voiceProfileStore = State(initialValue: voices)
        _meetingSessionsStore = State(initialValue: sessionsStore)
        _settingsNavigation = State(initialValue: navigation)
        _updaterController = State(initialValue: UpdaterController())
        _onboardingSettings = State(initialValue: OnboardingSettings())
        _notionConnection = State(initialValue: notion)

        appDelegate.recordingState = recording
        appDelegate.meetingDetectionService = detector
        appDelegate.manualNotesStore = manualNotesStore
        appDelegate.manualNotesWindowController = manualNotesWindow
        appDelegate.notionConnection = notion

        // Surface a persisted Notion connection in Settings/onboarding without
        // blocking launch on Keychain I/O.
        Task { await notion.loadPersistedStatus() }

        // Kick model download off at app launch, not when the popover first
        // opens — the banner lets users start recording without ever opening
        // the popover, so gating downloads on the popover's .task races the user.
        // Exception: while another instance is running, hold the download back —
        // this launch is probably about to defer to it, and the survivor owns
        // the (shared-cache) download. The delegate re-kicks it if this launch
        // wins its conflict instead.
        let kickoffModelDownload = { [weak detector] in
            Task { @MainActor in
                // The offline identity models are distinct from the streaming ASR
                // bundle. Warm both at launch so Stop never becomes their first
                // download/compilation opportunity.
                async let streamingModels: Void = modelState.downloadIfNeeded()
                async let offlineModels: Void = recording.prepareOfflineIdentityModels()
                _ = await (streamingModels, offlineModels)
                // Meeting detection is gated on model readiness — wake it now
                // that recording is possible (nothing else re-evaluates at this
                // moment, and a call may already be underway).
                detector?.modelReadinessChanged()
            }
        }
        if SingleInstanceGuard.anotherInstanceIsRunning() {
            appDelegate.deferredModelDownload = { _ = kickoffModelDownload() }
        } else {
            _ = kickoffModelDownload()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(recordingState)
                .environment(storageSettings)
                .environment(summarySettings)
                .environment(meetingSettings)
                .environment(manualNotesStore)
                .environment(manualNotesWindowController)
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
                .environment(manualNotesSettings)
                .environment(manualNotesWindowController)
                .environment(meetingDetectionService)
                .environment(meetingSessionsStore)
                .environment(settingsNavigation)
                .environment(updaterController)
                .environment(recordingState)
                .environment(notionConnection)
        }

        // The notepad is a floating NSPanel owned by ManualNotesWindowController
        // (not a Window scene) so it can overlay full-screen meeting apps.

        Window("Welcome to Serial Notes", id: onboardingWindowID) {
            OnboardingFlowView(
                onboarding: onboardingSettings,
                storageSettings: storageSettings,
                exportSettings: exportSettings,
                voiceStore: voiceProfileStore,
                identitySettings: identitySettings,
                meetingDetector: meetingDetectionService,
                notionConnection: notionConnection
            )
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
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
