import AppKit
import AVFoundation
import FoundationModels
import SwiftUI

/// Window identifier for the first-run setup guide. Shared between the `Window`
/// scene in `SerialNotesApp` and the dismiss call below.
let onboardingWindowID = "setup-guide"

/// Face-ID-style first-run setup guide. Auto-opens once on first install (see
/// `SerialNotesApp`), drives the microphone + system-audio permission prompts
/// inline, points the way to Apple Intelligence, lets the user pick a storage
/// location, and offers voice enrollment — then hands off to the menu bar.
///
/// Mirrors `VoiceEnrollmentFlowView` and shares its chrome (`BulletList`,
/// `PhraseDots`, `SetupStepIcon`, `WindowCloseChrome`).
struct OnboardingFlowView: View {
    let onboarding: OnboardingSettings
    let storageSettings: StorageSettings
    let exportSettings: ExportSettings
    let voiceStore: VoiceProfileStore
    let identitySettings: IdentitySettings
    let meetingDetector: MeetingDetectionService
    let notionConnection: NotionConnection

    enum Step: Int, CaseIterable {
        case welcome, microphone, systemAudio, appleIntelligence, storage, voice, done
    }

    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the auto-advance gate: the story only cycles while the app is the
    /// active one, so a backgrounded / occluded guide doesn't tick forever.
    @Environment(\.controlActiveState) private var controlActiveState

    @State private var step: Step = .welcome
    /// Active beat of the welcome screen's "how it works" story (stage +
    /// numbered list, kept in lockstep). Auto-cycles; tapping a row jumps.
    @State private var storyStep = 0
    /// Bumped on every list tap so re-selecting the *current* beat still
    /// restarts the auto-advance clock — a plain `storyStep` write to its
    /// existing value wouldn't change the task id.
    @State private var storyGeneration = 0
    @State private var micGranted = false
    @State private var systemAudioGranted = false
    /// True from the moment the user taps "Allow System Audio Recording" until the
    /// grant is confirmed. Gates the re-probe so we only touch CoreAudio while a
    /// decision is actually pending (not on every app activation).
    @State private var awaitingSystemAudio = false
    @State private var aiAvailable = false
    @State private var showingEnrollment = false
    @State private var enrollmentRecorder = VoiceEnrollmentRecorder()
    /// Set once the user picks a notes home in the storage step — drives the
    /// "saved in … in …" confirmation. Nil while still choosing.
    @State private var storageConfirmation: StorageConfirmation?
    /// True while the Notion tile's OAuth round trip is out in the browser —
    /// the storage step shows a waiting state until the callback lands.
    @State private var awaitingNotion = false

    /// On-disk folder created inside the chosen storage destination. Human-friendly
    /// so it reads well in the confirmation ("saved in Meeting Notes in Obsidian").
    /// Deliberately separate from `MeetingExporter.appleNotesFolder` (the folder
    /// created *inside* the Notes app) — they share the display name by intent, not
    /// coupling.
    private let notesFolderName = "Meeting Notes"

    /// Captured guide window, so the mic-permission flow can re-front it — the prompt
    /// buries an `.accessory` window without posting `didBecomeActive`.
    @State private var guideWindow = WeakWindow()

    var body: some View {
        VStack(spacing: 0) {
            PhraseDots(count: Step.allCases.count, active: step.rawValue)
                .padding(.top, 18)

            Group {
                switch step {
                case .welcome: welcomeStep
                case .microphone: microphoneStep
                case .systemAudio: systemAudioStep
                case .appleIntelligence: appleIntelligenceStep
                case .storage: storageStep
                case .voice: voiceStep
                case .done: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: step)
        }
        .frame(width: 520, height: 560)
        // Suspend meeting detection for the whole guide lifetime — the single
        // owner. The voice-enrollment sheet below deliberately leaves the
        // recorder's own detection closures unwired, since `isSuspended` is a
        // plain bool and a recorder-driven resume would unsuspend mid-guide.
        .onAppear {
            // Reset to a clean first step. A SwiftUI `Window` scene can retain its
            // content @State across close/reopen, so a re-entry via "Show Setup
            // Guide…" must not resume mid-flow with stale steps / permission ticks.
            // Disable animations for the reset so a reopen snaps straight to a
            // fresh welcome instead of visibly cross-fading back from the
            // retained step/beat (the step + story changes are otherwise animated).
            var resetTransaction = Transaction()
            resetTransaction.disablesAnimations = true
            withTransaction(resetTransaction) {
                step = .welcome
                storyStep = 0
                storyGeneration = 0
                systemAudioGranted = false
                awaitingSystemAudio = false
                showingEnrollment = false
                storageConfirmation = nil
                awaitingNotion = false
            }
            // Mark shown the moment the guide actually appears (not at the
            // auto-open decision point), so a failed openWindow can't suppress
            // onboarding forever. Idempotent, so manual re-opens are harmless.
            onboarding.markShown()
            meetingDetector.suspendDetection()
            refreshPermissionState()
        }
        .background(WindowBringToFront(keepFrontOnReactivate: true) { guideWindow.value = $0 })
        .background(WindowCloseChrome(onClose: handleWindowClose))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Reflect mic + system-audio + Apple Intelligence changes the user made
            // in System Settings (or in the TCC prompt) and returned from — all
            // cheap, read-only checks.
            refreshPermissionState()
            // System audio can't be confirmed in-session: macOS caches the TCC
            // status per-process, so the app that fired the prompt can't observe
            // the grant it just received (only a later launch can). If the user
            // requested it and we're now reactivating — i.e. they just answered the
            // prompt — optimistically show the same ✓ as microphone. A later launch
            // reads the true value either way.
            if awaitingSystemAudio, !systemAudioGranted {
                awaitingSystemAudio = false
                systemAudioGranted = true
                settleAppWindows(keeping: guideWindow.value)
            }
        }
        .sheet(isPresented: $showingEnrollment) {
            VoiceEnrollmentFlowView(
                recorder: enrollmentRecorder,
                voiceStore: voiceStore,
                identitySettings: identitySettings,
                onDismiss: {
                    showingEnrollment = false
                    advance(from: .voice)
                },
                // Onboarding owns the single finale (doneStep), personalized with
                // the name — so enrollment skips its own "You're all set" screen.
                showsCompletion: false
            )
        }
    }

    // MARK: - Steps

    /// Shared animation for story beat changes (auto-advance + tap-to-jump), so
    /// the stage cross-fade and the numbered-list highlight move in lockstep
    /// under one curve — `WelcomeStageView` and `NumberedStepList` carry no
    /// `.animation(value:)` of their own, they inherit this transaction.
    private static let storyAnimation: Animation = .easeInOut(duration: 0.3)
    private static let storyInterval: Duration = .seconds(3.4)

    /// The story auto-cycles only while motion is allowed AND the app is active
    /// — a backgrounded or occluded guide shouldn't wake a timer every few
    /// seconds. Folded into the task id, so toggling either condition restarts
    /// (or stops) the loop immediately.
    private var storyAutoplays: Bool {
        !reduceMotion && controlActiveState != .inactive
    }

    /// Equatable task id for the auto-advance loop. Any field change cancels the
    /// in-flight sleep and re-evaluates: a same-beat tap (`generation`), a
    /// Reduce Motion / active-state toggle (`autoplays`), or an auto-advance
    /// (`step`) each reset the clock correctly.
    private struct StoryClock: Equatable {
        var step: Int
        var generation: Int
        var autoplays: Bool
    }

    private var welcomeStep: some View {
        OnboardingStepScaffold(
            header: AnyView(
                WelcomeStageView(step: storyStep)
                    .padding(.horizontal, 40)
            ),
            title: "Welcome to Serial Notes",
            subtitle: "From call to clean notes — all on your Mac.",
            primary: PrimaryAction("Get Started") { advance() },
            extra: {
                NumberedStepList(
                    items: WelcomeStoryBeat.allCases.map(\.caption),
                    active: storyStep,
                    onSelect: selectStory
                )
                .padding(.horizontal, 40)
            },
            utilityRow: {
                // Restores the explicit recordings-stay-local promise (and lock
                // iconography) the welcome bullets used to carry — the one
                // privacy guarantee every first-run user is shown.
                Label("Your recordings never leave your Mac.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        )
        // Auto-advance the story every `storyInterval`. The id restarts the
        // clock on any beat change or condition toggle; toggling autoplay off
        // mid-wait cancels the in-flight task before it can fire.
        .task(id: StoryClock(step: storyStep, generation: storyGeneration, autoplays: storyAutoplays)) {
            guard storyAutoplays else { return }
            try? await Task.sleep(for: Self.storyInterval)
            guard !Task.isCancelled else { return }
            withAnimation(Self.storyAnimation) {
                storyStep = (storyStep + 1) % WelcomeStoryBeat.allCases.count
            }
        }
    }

    /// Jump the story to `index` (list tap / VoiceOver activate). Bumps the
    /// generation so re-selecting the *current* beat still restarts the clock.
    private func selectStory(_ index: Int) {
        storyGeneration += 1
        withAnimation(Self.storyAnimation) { storyStep = index }
    }

    private var microphoneStep: some View {
        OnboardingStepScaffold(
            icon: SetupStepIcon(
                systemName: micGranted ? "checkmark" : "mic",
                style: micGranted ? .filled(.green) : .outline,
                glyphColor: micGranted ? .green : .accentColor
            ),
            title: "Allow microphone access",
            subtitle: "Serial Notes records your microphone so your own voice is part of the transcript.",
            primary: micGranted
                ? PrimaryAction("Continue", action: { advance() })
                : PrimaryAction("Allow Microphone Access", action: requestMicrophone),
            utilityRow: {
                permissionUtilityRow(
                    granted: micGranted,
                    settingsCandidates: ["x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]
                )
            }
        )
    }

    private var systemAudioStep: some View {
        OnboardingStepScaffold(
            icon: SetupStepIcon(
                systemName: systemAudioGranted ? "checkmark" : "speaker.wave.2",
                style: systemAudioGranted ? .filled(.green) : .outline,
                glyphColor: systemAudioGranted ? .green : .accentColor
            ),
            title: "Allow system audio recording",
            subtitle: "This lets Serial Notes hear the other side of your calls — the people you're meeting with.",
            primary: systemAudioGranted
                ? PrimaryAction("Continue", action: { advance() })
                : PrimaryAction("Allow System Audio Recording", action: requestSystemAudio),
            utilityRow: {
                permissionUtilityRow(
                    granted: systemAudioGranted,
                    settingsCandidates: ["x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]
                )
            }
        )
    }

    private var appleIntelligenceStep: some View {
        OnboardingStepScaffold(
            icon: SetupStepIcon(
                systemName: "sparkles",
                style: aiAvailable ? .filled(.green) : .outline,
                glyphColor: aiAvailable ? .green : .accentColor
            ),
            title: aiAvailable ? "Summaries are ready" : "Turn on Apple Intelligence",
            subtitle: aiAvailable
                ? "Apple Intelligence will add a summary and action items to each transcript — and tidy up punctuation. All on-device."
                : "Optional. With Apple Intelligence, Serial Notes adds a summary and action items to every transcript and cleans up punctuation. Everything stays on your Mac.",
            primary: aiAvailable
                ? PrimaryAction("Continue", action: { advance() })
                : PrimaryAction("Open Apple Intelligence Settings", action: {
                    openSystemSettings([
                        "x-apple.systempreferences:com.apple.Apple-Intelligence-Settings.extension",
                        "x-apple.systempreferences:com.apple.preference.security",
                    ])
                }),
            utilityRow: {
                if !aiAvailable {
                    skipButton("Skip for now") { advance() }
                }
            }
        )
    }

    private var storageStep: some View {
        OnboardingStepScaffold(
            icon: SetupStepIcon(
                systemName: storageConfirmation == nil ? "folder" : "checkmark",
                style: storageConfirmation == nil ? .outline : .filled(.green),
                glyphColor: storageConfirmation == nil ? .accentColor : .green,
                diameter: 104,
                glyphSize: 42
            ),
            title: storageConfirmation == nil ? "Where should notes go?" : "Saved",
            subtitle: storageConfirmation == nil
                ? "Each meeting saves a Markdown transcript. Pick a home for them — Serial Notes makes the folder for you."
                : "You can change this anytime in Settings.",
            primary: storageConfirmation == nil
                ? nil
                : PrimaryAction("Continue", action: { advance() }),
            extra: {
                if let confirmation = storageConfirmation {
                    storageConfirmationDetails(confirmation)
                } else if awaitingNotion {
                    notionAwaitingDetails
                } else {
                    destinationGrid
                }
            },
            utilityRow: {
                if awaitingNotion, storageConfirmation == nil {
                    Button("Cancel") {
                        notionConnection.cancelConnect()
                        awaitingNotion = false
                    }
                    .buttonStyle(.link)
                } else if storageConfirmation == nil {
                    HStack(spacing: 16) {
                        Button("Choose a folder…", action: chooseCustomStorage)
                            .buttonStyle(.link)
                        skipButton("Skip for now") { advance() }
                    }
                } else {
                    Button("Pick a different place") { storageConfirmation = nil }
                        .buttonStyle(.link)
                }
            }
        )
        // The Notion tile's confirmation can only land once the browser round
        // trip completes; watch the connection instead of blocking the step.
        .onChange(of: notionConnection.status) { _, newStatus in
            guard awaitingNotion else { return }
            switch newStatus {
            case .connected:
                awaitingNotion = false
                storageConfirmation = StorageConfirmation(
                    markdownMessage: "After each meeting, your notes go straight into **Notion**.",
                    hint: "A Markdown copy is also kept on your Mac."
                )
            case .disconnected, .needsReconnect:
                // Denied, failed, or canceled — back to the grid; any failure
                // detail is shown there via the connection's error message.
                awaitingNotion = false
            case .connecting:
                break
            }
        }
    }

    /// Waiting state while the Notion consent screen is open in the browser.
    private var notionAwaitingDetails: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.small)
            Text("Finish connecting in your browser — approve Serial Notes in Notion, and you'll come right back here.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
        }
    }

    private var destinationGrid: some View {
        VStack(spacing: 10) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 78), spacing: 12)],
                alignment: .center,
                spacing: 12
            ) {
                ForEach(NotesDestination.availableApps + NotesDestination.locations) { dest in
                    DestinationTile(destination: dest) { choose(dest) }
                }
            }
            // A failed/denied Notion connect returns here; say why.
            if let error = notionConnection.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 40)
    }

    private func storageConfirmationDetails(_ confirmation: StorageConfirmation) -> some View {
        VStack(spacing: 14) {
            Text(confirmation.message)
                .font(.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            if let hint = confirmation.hint {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }
        }
    }

    private var voiceStep: some View {
        OnboardingStepScaffold(
            icon: SetupStepIcon(systemName: "person.wave.2"),
            title: "Get recognized by name",
            subtitle: "Read three short phrases so Serial Notes can label you by name instead of “You” in transcripts. Optional — you can do this later in Settings.",
            primary: PrimaryAction("Set Up Voice") { showingEnrollment = true },
            utilityRow: {
                skipButton("Skip for now") { advance() }
            }
        )
    }

    private var doneStep: some View {
        // Fold the voice confirmation into this single finale: when the user
        // enrolled with a name, greet them by it (the name only exists because the
        // voice saved) rather than stacking a second "You're all set" screen.
        let name = identitySettings.yourName.trimmingCharacters(in: .whitespacesAndNewlines)
        return OnboardingStepScaffold(
            icon: SetupStepIcon(
                systemName: "checkmark",
                style: .filled(.green),
                glyphColor: .green,
                glyphWeight: .semibold
            ),
            title: name.isEmpty ? "You're all set" : "You're all set, \(name)",
            subtitle: "Serial Notes is ready. It lives in your menu bar and offers to record when it notices a meeting.",
            bullets: [
                // Only promise summaries when Apple Intelligence is actually
                // available — the summarizer has no non-AI fallback, so a user
                // who skipped that step would never see one.
                aiAvailable
                    ? ("sparkles", "Transcribes and summarizes on-device.")
                    : ("waveform", "Transcribes every meeting on-device."),
                ("doc.text", "Saves a Markdown transcript per meeting."),
                ("gearshape", "Adjust anything in Settings."),
            ],
            primary: PrimaryAction("Done") {
                onboarding.markCompleted()
                close()
            }
        )
    }

    // MARK: - Step pieces

    /// The utility row for a permission step: System Settings + Skip links while
    /// undecided, a green "Granted" tick once allowed. Swapping content within
    /// the row (instead of stacking a label above the button) is what keeps the
    /// primary button from moving when the grant lands.
    @ViewBuilder
    private func permissionUtilityRow(granted: Bool, settingsCandidates: [String]) -> some View {
        if granted {
            Label("Granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            HStack(spacing: 16) {
                Button("Open System Settings") { openSystemSettings(settingsCandidates) }
                    .buttonStyle(.link)
                skipButton("Skip") { advance() }
            }
        }
    }

    private func skipButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    /// Advance only if still on `from` — used when the enrollment sheet dismisses,
    /// so we don't skip a step the user already moved past.
    private func advance(from: Step) {
        if step == from { advance() }
    }

    private func requestMicrophone() {
        Task {
            floatAppWindows(keeping: guideWindow.value)
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refreshPermissionState()
            settleAppWindows(keeping: guideWindow.value)
        }
    }

    private func requestSystemAudio() {
        let status = systemAudioAuthorizationStatus()
        // Already granted (from a prior launch, or the user answered then clicked
        // again) — reflect it without re-firing anything.
        if case .granted = status {
            systemAudioGranted = true
            awaitingSystemAudio = false
            return
        }
        // Fire the prompt off the main thread (the CoreAudio tap dance can stall).
        // We can't observe the resulting grant in this process (TCC caches the
        // status per-process), so `awaitingSystemAudio` lets the didBecomeActive
        // handler optimistically show ✓ once the user answers and the app
        // reactivates.
        awaitingSystemAudio = true
        // Only float when a prompt will actually appear (undetermined). A prior denial
        // shows no prompt and never deactivates us, so floating then would leave the
        // window stuck above other apps with no didBecomeActive to settle it.
        let willPrompt: Bool
        if case .undetermined = status {
            floatAppWindows(keeping: guideWindow.value)
            willPrompt = true
        } else {
            willPrompt = false
        }
        Task {
            await Task.detached { triggerSystemAudioPrompt() }.value
            // The TCC prompt has no completion callback (unlike the mic's
            // requestAccess, which lets us settle immediately), and an `.accessory`
            // app won't reactivate itself once the user answers — so the guide
            // would just sit there until clicked. Reclaim focus ourselves: pulse
            // activation until the system prompt closes, at which point
            // `didBecomeActive` fires, shows the optimistic ✓, and settles.
            if willPrompt {
                await reclaimActivationAfterSystemAudioPrompt()
            }
        }
    }

    /// Pulse `NSApp.activate()` until the app is frontmost again, so the guide
    /// reclaims focus once the system-audio TCC prompt is answered. Cooperative
    /// activation (macOS 14+) grants the request only after the system prompt is
    /// dismissed; the resulting `didBecomeActive` clears `awaitingSystemAudio`,
    /// which ends this loop. Bounded (~30s) so a never-answered prompt can't spin
    /// forever — the user can still click the window as a fallback.
    private func reclaimActivationAfterSystemAudioPrompt() async {
        for _ in 0..<120 {
            guard awaitingSystemAudio else { return }
            if !NSApp.isActive { NSApp.activate() }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// One-click destination tile. For Apple Notes / Bear this enables direct-send
    /// (notes pushed into the app after each meeting); Notion routes through its
    /// OAuth connect flow first; for everything else it creates the notes folder
    /// in the right place. Falls back to the folder panel if the directory can't
    /// be created (e.g. a permissions hiccup).
    private func choose(_ destination: NotesDestination) {
        if destination.pushTarget == .notion {
            connectNotion()
            return
        }
        if let target = destination.pushTarget {
            exportSettings.setEnabled(target, true)
            // Prompt for Apple Notes access right now (at opt-in) rather than after
            // the first meeting — so the confirmation doesn't need to forewarn them.
            if target == .appleNotes {
                Task { await MeetingExporter.requestAppleNotesAccess() }
            }
            storageConfirmation = StorageConfirmation(
                markdownMessage: "After each meeting, your notes go straight into **\(target.displayName)**.",
                hint: "A Markdown copy is also kept on your Mac."
            )
            return
        }
        let plan = destination.savePlan(folderName: notesFolderName)
        guard storageSettings.useFolder(in: plan.base, named: notesFolderName) != nil else {
            chooseCustomStorage()
            return
        }
        storageConfirmation = .folder(notesFolderName, in: plan.locationLabel, hint: plan.hint)
    }

    /// The Notion tile: already connected just flips the toggle on; otherwise
    /// run the OAuth round trip, waiting in place until the browser bounces
    /// back (`.onChange(of: notionConnection.status)` lands the confirmation).
    private func connectNotion() {
        if notionConnection.isConnected {
            exportSettings.setEnabled(.notion, true)
            storageConfirmation = StorageConfirmation(
                markdownMessage: "After each meeting, your notes go straight into **Notion**.",
                hint: "A Markdown copy is also kept on your Mac."
            )
            return
        }
        awaitingNotion = true
        // Re-front the guide when the callback lands — the browser took focus,
        // and an `.accessory` app won't come back on its own.
        let window = guideWindow
        notionConnection.onFlowFinished = {
            window.value?.orderFrontRegardless()
        }
        notionConnection.connect()
    }

    private func chooseCustomStorage() {
        let picked = storageSettings.pickFolder()
        guard picked else { return }
        let url = storageSettings.storageLocation
        let parent = url.deletingLastPathComponent().lastPathComponent
        storageConfirmation = .folder(
            url.lastPathComponent,
            in: parent.isEmpty ? "your Mac" : parent
        )
    }

    private func refreshPermissionState() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if case .granted = systemAudioAuthorizationStatus() {
            systemAudioGranted = true
            awaitingSystemAudio = false
        } else {
            systemAudioGranted = false
        }
        if case .available = SystemLanguageModel.default.availability {
            aiAvailable = true
        } else {
            aiAvailable = false
        }
    }

    private func close() {
        dismissWindow(id: onboardingWindowID)
    }

    /// Window `willClose` teardown: resume detection (the suspend owner) and stop
    /// the enrollment recorder defensively if the sheet was mid-capture.
    private func handleWindowClose() {
        meetingDetector.resumeDetection()
        let recorder = enrollmentRecorder
        Task { await recorder.cancel() }
    }
}

// MARK: - Step scaffold

/// The bottom-pinned call to action for a step.
private struct PrimaryAction {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
}

/// Shared vertical layout for an onboarding step. Icon, title, subtitle, and
/// optional bullets / `extra` content center in the flexible zone; below them
/// sits a footer whose geometry is identical on every step and in every state —
/// a reserved primary-button slot over a fixed-height utility row (links / skip
/// / status). Steps express state changes by swapping content *within* those
/// slots (the button retitles, links become a "Granted" tick), never by adding
/// or removing rows — so the primary button never shifts as the user moves
/// through the guide.
private struct OnboardingStepScaffold<Extra: View, UtilityRow: View>: View {
    /// Top visual of the centered zone — the circled step icon on most steps,
    /// or a custom view (the welcome step's animated stage). `AnyView` is fine
    /// for a private single-file helper; it spares a third generic parameter.
    let header: AnyView
    let title: String
    let subtitle: String
    let bullets: [(icon: String, text: String)]
    /// `nil` leaves the primary slot empty but still reserved — e.g. the storage
    /// step while a destination is being chosen.
    let primary: PrimaryAction?
    /// Step-specific content rendered under the text block (tile grid,
    /// confirmation copy) — part of the centered zone, not the footer.
    let extra: () -> Extra
    /// Content for the footer's utility row. The row keeps its height even when
    /// this is empty.
    let utilityRow: () -> UtilityRow

    init(
        header: AnyView,
        title: String,
        subtitle: String,
        bullets: [(icon: String, text: String)] = [],
        primary: PrimaryAction? = nil,
        @ViewBuilder extra: @escaping () -> Extra,
        @ViewBuilder utilityRow: @escaping () -> UtilityRow
    ) {
        self.header = header
        self.title = title
        self.subtitle = subtitle
        self.bullets = bullets
        self.primary = primary
        self.extra = extra
        self.utilityRow = utilityRow
    }

    init(
        icon: SetupStepIcon,
        title: String,
        subtitle: String,
        bullets: [(icon: String, text: String)] = [],
        primary: PrimaryAction? = nil,
        @ViewBuilder extra: @escaping () -> Extra,
        @ViewBuilder utilityRow: @escaping () -> UtilityRow
    ) {
        self.init(
            header: AnyView(icon), title: title, subtitle: subtitle,
            bullets: bullets, primary: primary, extra: extra, utilityRow: utilityRow
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 24) {
                header

                VStack(spacing: 12) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 360)
                }

                if !bullets.isEmpty {
                    BulletList(items: bullets)
                        .padding(.horizontal, 40)
                }

                extra()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 12) {
                ZStack {
                    // Invisible metrics donor: holds the slot at exact button
                    // height even when a step has no primary action.
                    primaryButton("Continue", action: {})
                        .hidden()
                    if let primary {
                        primaryButton(primary.title, action: primary.action)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                ZStack {
                    utilityRow()
                        .font(.callout)
                }
                .frame(height: 20)
            }
            .padding(.horizontal, 40)
        }
        .padding(.top, 16)
        .padding(.bottom, 24)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

extension OnboardingStepScaffold where Extra == EmptyView {
    init(
        icon: SetupStepIcon,
        title: String,
        subtitle: String,
        bullets: [(icon: String, text: String)] = [],
        primary: PrimaryAction? = nil,
        @ViewBuilder utilityRow: @escaping () -> UtilityRow
    ) {
        self.init(
            icon: icon, title: title, subtitle: subtitle, bullets: bullets,
            primary: primary, extra: { EmptyView() }, utilityRow: utilityRow
        )
    }
}

extension OnboardingStepScaffold where Extra == EmptyView, UtilityRow == EmptyView {
    init(
        icon: SetupStepIcon,
        title: String,
        subtitle: String,
        bullets: [(icon: String, text: String)] = [],
        primary: PrimaryAction? = nil
    ) {
        self.init(
            icon: icon, title: title, subtitle: subtitle, bullets: bullets,
            primary: primary, extra: { EmptyView() }, utilityRow: { EmptyView() }
        )
    }
}

// MARK: - Storage destination tile + confirmation

/// The confirmation shown after the user picks a notes home. Carries a ready-made
/// Markdown sentence so folder picks ("saved in … in …") and direct-send picks
/// ("sent straight to …") can be phrased differently.
private struct StorageConfirmation {
    let markdownMessage: String
    /// Optional one-time step to surface notes in the chosen app.
    let hint: String?

    var message: AttributedString {
        (try? AttributedString(markdown: markdownMessage)) ?? AttributedString(markdownMessage)
    }

    /// "Your notes will be saved in **Meeting Notes** in **iCloud Drive**."
    static func folder(_ folderName: String, in location: String, hint: String? = nil) -> StorageConfirmation {
        StorageConfirmation(
            markdownMessage: "Your notes will be saved in **\(folderName)** in **\(location)**.",
            hint: hint
        )
    }
}

/// A tappable destination in the storage step — an installed app's real icon, or
/// an SF Symbol fallback (generic locations, and Notion when its desktop app
/// isn't installed — the tile is offered either way, since the integration is
/// the connection, not the app).
private struct DestinationTile: View {
    let destination: NotesDestination
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                icon
                    .frame(width: 40, height: 40)
                Text(destination.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 78, height: 82)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var icon: some View {
        if let nsImage = destination.appIcon {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if let symbol = destination.symbol {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.tint)
        } else {
            Image(systemName: "folder")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }
}
