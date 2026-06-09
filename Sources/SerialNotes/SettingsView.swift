import AppKit
import FoundationModels
import SwiftUI

struct SettingsView: View {
    @Environment(VoiceProfileStore.self) private var voiceStore
    @Environment(StorageSettings.self) private var storageSettings
    @Environment(SettingsNavigation.self) private var navigation

    var body: some View {
        @Bindable var nav = navigation
        TabView(selection: $nav.selectedTab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }
                .tag(SettingsNavigation.Tab.general)
            PeopleSettingsTab()
                .tabItem { Label("People", systemImage: "person.wave.2") }
                .tag(SettingsNavigation.Tab.people)
            MeetingsSettingsTab()
                .tabItem { Label("Meetings", systemImage: "person.2.wave.2") }
                .tag(SettingsNavigation.Tab.meetings)
        }
        .frame(width: 520, height: 500)
        // Shared with the setup guide: restores `.accessory` only when no other
        // titled window remains, so Settings and the guide can be open together
        // without fighting over activation policy. See SetupFlowChrome.swift.
        .background(WindowCloseChrome())
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
                    Text("You haven't named anyone yet. After a call, name the people Serial Notes detected from the Meetings tab — they'll then be recognized by name in future meetings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(voiceStore.otherProfiles) { profile in
                        OtherProfileRow(
                            profile: profile,
                            onRename: { renameProfile(profile, to: $0) },
                            onDelete: { deleteProfile(profile) }
                        )
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

    @discardableResult
    private func renameProfile(_ profile: VoiceProfile, to newName: String) -> Bool {
        do {
            try voiceStore.rename(profile, to: newName)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

// MARK: - Row

private struct OtherProfileRow: View {
    let profile: VoiceProfile
    /// Returns whether the rename was accepted (false ⇒ rejected, e.g. duplicate name).
    let onRename: (String) -> Bool
    let onDelete: () -> Void

    /// Display the name as plain text by default; the pencil flips it into an
    /// inline field so a typo from the post-meeting naming flow is easy to fix.
    @State private var isEditing = false
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.circle")
                .foregroundStyle(.secondary)

            if isEditing {
                // `.labelsHidden()` stops the Form from drawing the field's own
                // title as a redundant leading label next to the value.
                TextField("Name", text: $draft)
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { focused = false }
                Spacer()
            } else {
                // Double-click the name to rename, mirroring the pencil button.
                Text(profile.name)
                    .onTapGesture(count: 2) { beginEditing() }
                Spacer()
                Button { beginEditing() } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Rename")
            }

            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        // Commit on focus loss (Return blurs the field, clicking away too) — a
        // single commit path, so no double-fire to guard against.
        .onChange(of: focused) { wasFocused, isFocused in
            if wasFocused, !isFocused { commit() }
        }
    }

    private func beginEditing() {
        draft = profile.name
        isEditing = true
        focused = true
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
        // Skip empty / no-op edits; on rejection (e.g. duplicate name) the
        // profile keeps its current name, so there's nothing to revert.
        guard !trimmed.isEmpty, trimmed != profile.name else { return }
        _ = onRename(trimmed)
    }
}

// MARK: - Meetings Tab

private struct MeetingsSettingsTab: View {
    @Environment(MeetingSessionsStore.self) private var sessionsStore
    @Environment(SettingsNavigation.self) private var navigation
    @State private var sheetSession: MeetingSession?

    var body: some View {
        Form {
            Section {
                if sessionsStore.sessions.isEmpty {
                    Text("No meetings with speakers to name yet. After a call with people Serial Notes doesn't recognize, they'll show up here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessionsStore.sessions) { session in
                        MeetingRow(session: session) { sheetSession = session }
                    }
                }
            } header: {
                Text("Recent Meetings")
            } footer: {
                Text("Name the speakers Serial Notes detected, and they'll be recognized in future meetings. Voice clips stay on your Mac and are removed once you name or skip each person.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(item: $sheetSession) { session in
            // Mutations refresh the store in place, so no full rescan is needed on close.
            SpeakerNamingView(sessionURL: session.directory, store: sessionsStore) {
                sheetSession = nil
            }
        }
        .onAppear {
            sessionsStore.reload()
            consumeDeepLink()
        }
        .onChange(of: navigation.pendingNamingSession) { _, _ in consumeDeepLink() }
    }

    /// Honor a deep link from the post-meeting prompt: open the naming sheet for the
    /// exact session it carried, then clear the request.
    private func consumeDeepLink() {
        guard let url = navigation.pendingNamingSession else { return }
        navigation.pendingNamingSession = nil
        if let session = sessionsStore.session(at: url) {
            sheetSession = session
        }
    }
}

private struct MeetingRow: View {
    let session: MeetingSession
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "person.2.wave.2.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    if session.pendingCount > 0 {
                        Text("^[\(session.pendingCount) person](inflect: true) to name")
                            .font(.body)
                            .foregroundStyle(.tint)
                    } else {
                        Text("All named")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    Text(session.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if session.pendingCount > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.pendingCount == 0)
    }
}

// MARK: - General Tab

private struct GeneralSettingsTab: View {
    @Environment(StorageSettings.self) private var storageSettings
    @Environment(SummarySettings.self) private var summarySettings
    @Environment(MeetingSettings.self) private var meetingSettings
    @Environment(ExportSettings.self) private var exportSettings
    @Environment(UpdaterController.self) private var updater
    @Environment(RecordingState.self) private var recordingState
    @Environment(SettingsNavigation.self) private var navigation

    private var foundationModelsAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    private var bearInstalled: Bool {
        MeetingExporter.isInstalled(.bear)
    }

    /// e.g. "0.1.0 (beta) · Build 42". Major version 0 is treated as beta so
    /// the label maintains itself — it drops the "(beta)" suffix at 1.0.0.
    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        let major = Int(short.split(separator: ".").first ?? "") ?? 0
        let suffix = major < 1 ? " (beta)" : ""
        let flavor = Bundle.main.isDevBuild ? " · Dev" : ""
        return "\(short)\(suffix) · Build \(build)\(flavor)"
    }

    private func showSetupGuide() {
        // Don't programmatically close Settings here. Closing it would race the
        // guide window's registration: the shared WindowCloseChrome guard could
        // run before `openWindow` makes the guide a titled window and flip the app
        // to `.accessory`, so the guide opens with no Dock presence / not in front.
        // The guard already keeps `.regular` while either window is open, so the
        // guide just layers on top; closing it returns to Settings.
        navigation.openSetupAction?()
    }

    var body: some View {
        @Bindable var summary = summarySettings
        @Bindable var storage = storageSettings
        @Bindable var meeting = meetingSettings
        @Bindable var export = exportSettings

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
                Toggle("Send to Apple Notes", isOn: $export.sendToAppleNotes)
                    .onChange(of: export.sendToAppleNotes) { _, isOn in
                        // Prompt for Automation access the moment they opt in, rather
                        // than after the first meeting concludes.
                        if isOn { Task { await MeetingExporter.requestAppleNotesAccess() } }
                    }
                Toggle("Send to Bear", isOn: $export.sendToBear)
                    .disabled(!bearInstalled)
            } header: {
                Text("Send to apps")
            } footer: {
                Text("After each meeting, the notes are also added straight into the app — Apple Notes via a “Meeting Notes” folder, Bear as a new note. A Markdown copy always stays in your storage folder. The first Apple Notes send asks permission to add notes.\(bearInstalled ? "" : " Bear isn’t installed.")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Button("Show Setup Guide…", action: showSetupGuide)
                    // The guide drives audio permissions + voice enrollment, which
                    // conflict with a live capture — block re-entry while recording.
                    .disabled(recordingState.hasActiveOrFinalizingSession)
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            // A disabled toggle can't be switched off, so if Bear was enabled and
            // later uninstalled, clear the now-stale target rather than leave a
            // stuck-on switch that quietly fails every meeting.
            if !bearInstalled, exportSettings.sendToBear {
                exportSettings.sendToBear = false
            }
        }
    }
}
