import AppKit
import FoundationModels
import SwiftUI

struct SettingsView: View {
    @Environment(VoiceProfileStore.self) private var voiceStore
    @Environment(StorageSettings.self) private var storageSettings

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }
            PeopleSettingsTab()
                .tabItem { Label("People", systemImage: "person.wave.2") }
        }
        .frame(width: 520, height: 500)
        .background(SettingsWindowChrome())
    }
}

/// Watches the hosting NSWindow and returns the app to `.accessory` activation
/// policy once Settings closes. Without this, clicking the gear flips us to
/// `.regular` and we'd stay there after the window goes away — putting the
/// app into the Dock and Cmd-Tab until relaunched.
private struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = WindowCloseObserver()
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowCloseObserver: NSView {
    private var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Drop any prior registration before re-registering — guards against
        // SwiftUI recreating the representable or the view being remounted on
        // a different window. Otherwise observers accumulate and `windowWillClose`
        // fires N times per close.
        if let prior = observedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: prior
            )
            observedWindow = nil
        }

        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
        observedWindow = window
    }

    deinit {
        // Selector-based observers don't retain self, but the registration
        // entry persists. Explicit removal keeps NotificationCenter clean.
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowWillClose(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Stops the Settings window from auto-focusing the first text field (the name
/// field) when the tab appears. macOS otherwise makes it the initial first
/// responder, leaving a blinking caret the moment the tab opens. Pointing
/// `initialFirstResponder` at the content view keeps AppKit from re-selecting the
/// field each time the window becomes key.
private struct InitialFocusSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.initialFirstResponder = window.contentView
            if window.firstResponder is NSText || window.firstResponder is NSTextView {
                window.makeFirstResponder(nil)
            }
        }
    }
}

// MARK: - People Tab

private struct PeopleSettingsTab: View {
    @Environment(VoiceProfileStore.self) private var voiceStore
    @Environment(IdentitySettings.self) private var identitySettings
    @Environment(MeetingDetectionService.self) private var meetingDetector
    @State private var recorder = VoiceEnrollmentRecorder()
    @State private var showingEnrollmentFlow = false
    @State private var errorMessage: String?
    /// Local edit buffer for the name so it commits on an explicit Save (or Return)
    /// rather than persisting every keystroke. Kept in sync with the stored value
    /// in `.onAppear` and when the enrollment flow changes it.
    @State private var nameDraft = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        Form {
            Section {
                yourNameRow
                yourVoiceRow
            } header: {
                Text("You")
            } footer: {
                Text("Your name replaces “You” in transcripts when Serial Notes recognizes your voice. Recording a sample is optional — it helps tell your voice apart from others. Nothing leaves your machine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if voiceStore.otherProfiles.isEmpty {
                    Text("You haven't named anyone yet. After a meeting, you can name the people Serial Notes detected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(voiceStore.otherProfiles) { profile in
                        OtherProfileRow(profile: profile) { deleteProfile(profile) }
                    }
                }
            } header: {
                Text("Known People")
            }

            Section("Voice Profiles") {
                Button("Reveal in Finder") { voiceStore.revealInFinder() }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .padding()
        .background(InitialFocusSuppressor())
        .sheet(isPresented: $showingEnrollmentFlow) {
            VoiceEnrollmentFlowView(
                recorder: recorder,
                voiceStore: voiceStore,
                identitySettings: identitySettings,
                onDismiss: { showingEnrollmentFlow = false }
            )
        }
        .onAppear {
            nameDraft = identitySettings.yourName
            let detector = meetingDetector
            recorder.onSuspendDetection = { detector.suspendDetection() }
            recorder.onResumeDetection = { detector.resumeDetection() }
        }
        .onChange(of: identitySettings.yourName) { _, newValue in
            // The enrollment flow can change the stored name out from under us —
            // resync the draft unless the user is mid-edit on the same value.
            if trimmedNameDraft != newValue { nameDraft = newValue }
        }
        .onChange(of: nameFieldFocused) { wasFocused, isFocused in
            // Commit on focus loss so clicking away (or closing Settings) doesn't
            // silently drop a typed name. Save is still explicit via the button/Return.
            if wasFocused, !isFocused, isNameDirty { saveName() }
        }
    }

    // MARK: - Your Name

    private var trimmedNameDraft: String {
        nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isNameDirty: Bool {
        trimmedNameDraft != identitySettings.yourName
    }

    private func saveName() {
        nameDraft = trimmedNameDraft
        identitySettings.yourName = nameDraft
        nameFieldFocused = false
    }

    @ViewBuilder
    private var yourNameRow: some View {
        HStack(spacing: 8) {
            Text("Your name")
            // `.labelsHidden()` stops the Form from drawing the field's own title
            // as a second leading label next to the "Your name" text above; the
            // placeholder lives in `prompt` so it only shows when empty.
            TextField("Your name", text: $nameDraft, prompt: Text("You"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .focused($nameFieldFocused)
                .onSubmit(saveName)

            if isNameDirty {
                Button("Save", action: saveName)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
            } else if !identitySettings.yourName.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Saved")
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isNameDirty)
    }

    // MARK: - Smart Voice Detection Row

    @ViewBuilder
    private var yourVoiceRow: some View {
        if let profile = voiceStore.yourProfile {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart voice detection")
                        .font(.body)
                    Text("On — Serial Notes recognizes your voice in meetings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Re-record") { showingEnrollmentFlow = true }
                Button(role: .destructive) {
                    try? voiceStore.delete(profile)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart voice detection")
                        .font(.body)
                    Text("Record a short sample so Serial Notes can tell your voice apart from others.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Set Up") { showingEnrollmentFlow = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func deleteProfile(_ profile: VoiceProfile) {
        do {
            try voiceStore.delete(profile)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Row

private struct OtherProfileRow: View {
    let profile: VoiceProfile
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "person.circle")
                .foregroundStyle(.secondary)
            Text(profile.name)
            Spacer()
            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - General Tab

private struct GeneralSettingsTab: View {
    @Environment(StorageSettings.self) private var storageSettings
    @Environment(SummarySettings.self) private var summarySettings
    @Environment(MeetingSettings.self) private var meetingSettings

    private var foundationModelsAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// e.g. "0.1.0 (beta) · Build 42". Major version 0 is treated as beta so
    /// the label maintains itself — it drops the "(beta)" suffix at 1.0.0.
    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        let major = Int(short.split(separator: ".").first ?? "") ?? 0
        let suffix = major < 1 ? " (beta)" : ""
        return "\(short)\(suffix) · Build \(build)"
    }

    var body: some View {
        @Bindable var summary = summarySettings
        @Bindable var storage = storageSettings
        @Bindable var meeting = meetingSettings

        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(storageSettings.storageLocationName)
                            .font(.body)
                        Text(storageSettings.storageLocation.path(percentEncoded: false))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Change…") { storageSettings.pickFolder() }
                }
                Toggle("Save audio files", isOn: $storage.saveAudioFiles)
            } header: {
                Text("Storage")
            } footer: {
                Text("When off, system.wav and mic.wav are removed once the transcript is finalized. Only transcript.md is kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Generate meeting summary", isOn: $summary.generateSummary)
                Toggle("Generate action items", isOn: $summary.generateActionItems)
            } header: {
                Text("Summary")
            } footer: {
                if foundationModelsAvailable {
                    Text("Added to the top of transcript.md after each recording. Runs on-device with Apple Intelligence.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Requires Apple Intelligence — turn it on in System Settings to enable summaries.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!foundationModelsAvailable)

            Section {
                Toggle("Stop recording after call ends", isOn: $meeting.autoStopAfterCallEnds)
            } header: {
                Text("Meetings")
            } footer: {
                Text("When on, Serial Notes prompts when the associated call ends and stops automatically after a short countdown unless you keep recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(versionString)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
