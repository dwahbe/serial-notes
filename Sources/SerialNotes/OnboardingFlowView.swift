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
            // Reflect mic + Apple Intelligence changes the user made in System
            // Settings and returned from (both are cheap, read-only checks).
            refreshPermissionState()
            // System audio has no read-only status API, so re-probe — off the main
            // thread — only while a grant is actually pending. This is what catches
            // the grant when the user dismisses the TCC prompt (which reactivates
            // the app), without churning CoreAudio on unrelated activations.
            if awaitingSystemAudio, !systemAudioGranted {
                probeSystemAudio()
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
                }
            )
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        OnboardingStepScaffold(
            icon: SetupStepIcon(systemName: "waveform"),
            title: "Welcome to Serial Notes",
            subtitle: "Serial Notes records your meetings and turns them into clean, private notes — automatically.",
            bullets: [
                ("lock.shield", "Everything runs on your Mac."),
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
                waiting: awaitingSystemAudio,
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
            icon: SetupStepIcon(systemName: "folder"),
            title: "Where should notes go?",
            subtitle: "Each meeting saves a Markdown transcript here. You can change this anytime in Settings."
        ) {
            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text(storageSettings.storageLocationName)
                        .font(.body.weight(.medium))
                    Text(storageSettings.storageLocation.path(percentEncoded: false))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Choose…", action: chooseStorage)
                    .controlSize(.large)
                primaryButton("Continue") { advance() }
            }
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
        OnboardingStepScaffold(
            icon: SetupStepIcon(
                systemName: "checkmark",
                style: .filled(.green),
                glyphColor: .green,
                glyphWeight: .semibold
            ),
            title: "You're all set",
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
        waiting: Bool = false,
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
                if waiting {
                    Label("Waiting for permission…", systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        awaitingSystemAudio = true
        probeSystemAudio()
    }

    /// Probe system-audio permission off the main thread (the CoreAudio tap
    /// create/destroy can stall) and reflect the result. The first probe triggers
    /// the TCC prompt; a later probe — on the re-activation after the user answers
    /// it — catches the grant and shows the ✓.
    private func probeSystemAudio() {
        Task {
            let granted = await Task.detached { requestSystemAudioPermission() }.value
            systemAudioGranted = granted
            if granted { awaitingSystemAudio = false }
        }
    }

    private func chooseStorage() {
        storageSettings.pickFolder()
        // pickFolder() restores `.accessory` on the way out — keep the guide in
        // the foreground.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    private func refreshPermissionState() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
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
                    .padding(.horizontal, 40)
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
