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

    enum Step: Int, CaseIterable {
        case welcome, microphone, systemAudio, appleIntelligence, storage, voice, done
    }

    @Environment(\.dismissWindow) private var dismissWindow

    @State private var step: Step = .welcome
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

    /// On-disk folder created inside the chosen storage destination. Human-friendly
    /// so it reads well in the confirmation ("saved in Meeting Notes in Obsidian").
    /// Deliberately separate from `MeetingExporter.appleNotesFolder` (the folder
    /// created *inside* the Notes app) — they share the display name by intent, not
    /// coupling.
    private let notesFolderName = "Meeting Notes"

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
            step = .welcome
            systemAudioGranted = false
            awaitingSystemAudio = false
            showingEnrollment = false
            storageConfirmation = nil
            // Mark shown the moment the guide actually appears (not at the
            // auto-open decision point), so a failed openWindow can't suppress
            // onboarding forever. Idempotent, so manual re-opens are harmless.
            onboarding.markShown()
            meetingDetector.suspendDetection()
            refreshPermissionState()
        }
        .background(WindowBringToFront())
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
                systemAudioGranted = true
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

    private var welcomeStep: some View {
        OnboardingStepScaffold(
            icon: SetupStepIcon(systemName: "waveform"),
            title: "Welcome to Serial Notes",
            subtitle: "Serial Notes records your meetings and turns them into clean, private notes.",
            bullets: [
                ("lock.shield", "Your recordings never leave your Mac."),
                ("menubar.rectangle", "Lives quietly in your menu bar."),
                ("sparkles", "Transcribes and summarizes on-device."),
            ]
        ) {
            primaryButton("Get Started") { advance() }
        }
    }

    private var microphoneStep: some View {
        OnboardingStepScaffold(
            icon: SetupStepIcon(
                systemName: micGranted ? "checkmark" : "mic",
                style: micGranted ? .filled(.green) : .outline,
                glyphColor: micGranted ? .green : .accentColor
            ),
            title: "Allow microphone access",
            subtitle: "Serial Notes records your microphone so your own voice is part of the transcript."
        ) {
            permissionFooter(
                granted: micGranted,
                grantTitle: "Allow Microphone Access",
                onGrant: requestMicrophone,
                settingsCandidates: ["x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]
            )
        }
    }

    private var systemAudioStep: some View {
        OnboardingStepScaffold(
            icon: SetupStepIcon(
                systemName: systemAudioGranted ? "checkmark" : "speaker.wave.2",
                style: systemAudioGranted ? .filled(.green) : .outline,
                glyphColor: systemAudioGranted ? .green : .accentColor
            ),
            title: "Allow system audio recording",
            subtitle: "This lets Serial Notes hear the other side of your calls — the people you're meeting with."
        ) {
            permissionFooter(
                granted: systemAudioGranted,
                grantTitle: "Allow System Audio Recording",
                onGrant: requestSystemAudio,
                settingsCandidates: ["x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]
            )
        }
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
                : "Optional. With Apple Intelligence, Serial Notes adds a summary and action items to every transcript and cleans up punctuation. Everything stays on your Mac."
        ) {
            if aiAvailable {
                primaryButton("Continue") { advance() }
            } else {
                VStack(spacing: 12) {
                    primaryButton("Open Apple Intelligence Settings") {
                        openSystemSettings([
                            "x-apple.systempreferences:com.apple.Apple-Intelligence-Settings.extension",
                            "x-apple.systempreferences:com.apple.preference.security",
                        ])
                    }
                    skipButton("Skip for now") { advance() }
                }
            }
        }
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
                : "You can change this anytime in Settings."
        ) {
            if let confirmation = storageConfirmation {
                storageConfirmationFooter(confirmation)
            } else {
                storagePickerFooter
            }
        }
    }

    private var storagePickerFooter: some View {
        VStack(spacing: 16) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 78), spacing: 12)],
                alignment: .center,
                spacing: 12
            ) {
                ForEach(NotesDestination.availableApps + NotesDestination.locations) { dest in
                    DestinationTile(destination: dest) { choose(dest) }
                }
            }
            VStack(spacing: 8) {
                Button("Choose a folder…", action: chooseCustomStorage)
                    .buttonStyle(.link)
                    .font(.callout)
                skipButton("Skip for now") { advance() }
            }
        }
    }

    private func storageConfirmationFooter(_ confirmation: StorageConfirmation) -> some View {
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
            primaryButton("Continue") { advance() }
            Button("Pick a different place") { storageConfirmation = nil }
                .buttonStyle(.link)
                .font(.callout)
        }
    }

    private var voiceStep: some View {
        OnboardingStepScaffold(
            icon: SetupStepIcon(systemName: "person.wave.2"),
            title: "Get recognized by name",
            subtitle: "Read three short phrases so Serial Notes can label you by name instead of “You” in transcripts. Optional — you can do this later in Settings."
        ) {
            VStack(spacing: 12) {
                primaryButton("Set Up Voice") { showingEnrollment = true }
                skipButton("Skip for now") { advance() }
            }
        }
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
                ("waveform.circle", "Detects calls and offers to record."),
                ("doc.text", "Saves a Markdown transcript per meeting."),
                ("gearshape", "Adjust anything in Settings."),
            ]
        ) {
            primaryButton("Done") {
                onboarding.markCompleted()
                close()
            }
        }
    }

    // MARK: - Footer builders

    @ViewBuilder
    private func permissionFooter(
        granted: Bool,
        grantTitle: String,
        onGrant: @escaping () -> Void,
        settingsCandidates: [String]
    ) -> some View {
        if granted {
            VStack(spacing: 12) {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                primaryButton("Continue") { advance() }
            }
        } else {
            VStack(spacing: 12) {
                primaryButton(grantTitle, action: onGrant)
                HStack(spacing: 16) {
                    Button("Open System Settings") { openSystemSettings(settingsCandidates) }
                        .buttonStyle(.link)
                    skipButton("Skip") { advance() }
                }
                .font(.callout)
            }
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
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
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refreshPermissionState()
        }
    }

    private func requestSystemAudio() {
        // Already granted (from a prior launch, or the user answered then clicked
        // again) — reflect it without re-firing anything.
        if case .granted = systemAudioAuthorizationStatus() {
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
        Task { await Task.detached { triggerSystemAudioPrompt() }.value }
    }

    /// One-click destination tile. For Apple Notes / Bear this enables direct-send
    /// (notes pushed into the app after each meeting); for everything else it
    /// creates the notes folder in the right place. Falls back to the folder panel
    /// if the directory can't be created (e.g. a permissions hiccup).
    private func choose(_ destination: NotesDestination) {
        guard !destination.comingSoon else { return }
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

    private func chooseCustomStorage() {
        let picked = storageSettings.pickFolder()
        // pickFolder() restores `.accessory` on the way out — keep the guide in
        // the foreground.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
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

/// Shared vertical layout for an onboarding step: icon, title, subtitle, optional
/// bullets, then a caller-provided footer. Matches `VoiceEnrollmentFlowView`'s
/// step layout.
private struct OnboardingStepScaffold<Footer: View>: View {
    let icon: SetupStepIcon
    let title: String
    let subtitle: String
    var bullets: [(icon: String, text: String)] = []
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            icon

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

            Spacer()

            footer()
                .padding(.horizontal, 40)

            Spacer(minLength: 0)
        }
        .padding(.top, 16)
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
/// an SF Symbol for a generic location. A `comingSoon` destination (e.g. Notion)
/// renders dimmed, labeled, and non-interactive.
private struct DestinationTile: View {
    let destination: NotesDestination
    let action: () -> Void

    @State private var hovering = false

    private var comingSoon: Bool { destination.comingSoon }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                icon
                    .frame(width: 40, height: 40)
                    .opacity(comingSoon ? 0.4 : 1)
                Text(destination.name)
                    .font(.caption)
                    .foregroundStyle(comingSoon ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if comingSoon {
                    Text("Coming soon")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 78, height: 82)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(hovering && !comingSoon ? 0.08 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(comingSoon)
        .onHover { hovering = comingSoon ? false : $0 }
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
