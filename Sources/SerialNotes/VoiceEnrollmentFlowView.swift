import SwiftUI

/// Face-ID-style guided flow for voice enrollment.
struct VoiceEnrollmentFlowView: View {
    enum Step {
        case intro
        case capture
        case naming(clipURL: URL)
        case done(profileName: String)
    }

    @Bindable var recorder: VoiceEnrollmentRecorder
    let voiceStore: VoiceProfileStore
    let identitySettings: IdentitySettings
    let onDismiss: () -> Void

    @State private var step: Step = .intro
    @State private var nameDraft: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .intro: IntroStep(onStart: startCapture)
                case .capture: CaptureStep(recorder: recorder)
                case .naming(let clipURL):
                    NamingStep(
                        nameDraft: $nameDraft,
                        errorMessage: errorMessage,
                        onSave: { save(clipURL: clipURL) },
                        onRetry: { retryCapture(oldClipURL: clipURL) }
                    )
                case .done(let name):
                    DoneStep(name: name, onFinish: onDismiss)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Button(cancelButtonTitle, role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
            .padding(16)
        }
        .frame(width: 520, height: 560)
        .onChange(of: recorder.state) { _, newState in
            handleRecorderStateChange(newState)
        }
    }

    private var cancelButtonTitle: String {
        switch step {
        case .done: return "Close"
        default: return "Cancel"
        }
    }

    // MARK: - Step derivation

    // MARK: - Actions

    private func startCapture() {
        errorMessage = nil
        step = .capture
        Task { await recorder.start() }
    }

    private func retryCapture(oldClipURL: URL) {
        try? FileManager.default.removeItem(at: oldClipURL)
        startCapture()
    }

    private func cancel() {
        Task {
            await recorder.cancel()
            onDismiss()
        }
    }

    private func save(clipURL: URL) {
        // The name is optional — an empty value stores the profile under the "You"
        // fallback and clears any preferred name. Persist the trimmed value so the
        // Settings field and transcript labels stay in sync.
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try voiceStore.save(name: trimmed, kind: .you, clipURL: clipURL)
            identitySettings.yourName = trimmed
            try? FileManager.default.removeItem(at: clipURL)
            step = .done(profileName: trimmed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleRecorderStateChange(_ newState: VoiceEnrollmentRecorder.State) {
        switch newState {
        case .finished(let clipURL):
            // Pre-fill from the persisted preferred name, but don't clobber an
            // in-progress edit carried over from a re-record.
            if nameDraft.isEmpty { nameDraft = identitySettings.yourName }
            step = .naming(clipURL: clipURL)
        case .failed(let message):
            errorMessage = message
            step = .intro
        default:
            break
        }
    }
}

// MARK: - Intro

private struct IntroStep: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 4)
                    .frame(width: 140, height: 140)
                Image(systemName: "waveform")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(.tint)
            }

            VStack(spacing: 12) {
                Text("Teach Serial Notes your voice")
                    .font(.title2.weight(.semibold))
                Text("Read three short phrases out loud. Serial Notes will learn your voice so it can label you by name in future meeting transcripts.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 40)
            }

            BulletList(items: [
                (icon: "lock.shield", text: "Audio stays on your Mac."),
                (icon: "clock", text: "Takes about 15 seconds."),
                (icon: "mic", text: "Uses your default microphone."),
            ])
            .padding(.horizontal, 40)

            Spacer()

            Button(action: onStart) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 40)

            Spacer(minLength: 0)
        }
        .padding(.top, 24)
    }
}

// MARK: - Capture

private struct CaptureStep: View {
    @Bindable var recorder: VoiceEnrollmentRecorder

    static let phrases = [
        "The quick brown fox jumps over the lazy dog.",
        "I use this app to take notes during meetings and calls.",
        "Bright sunshine brings calm to a quiet afternoon.",
    ]

    private var activePhraseIndex: Int {
        min(Self.phrases.count - 1, max(0, recorder.currentPhraseIndex))
    }

    private var progress: Double {
        Double(recorder.currentPhraseIndex) / Double(Self.phrases.count)
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            ProgressRing(progress: progress, audioLevel: recorder.audioLevel)
                .frame(width: 180, height: 180)

            VStack(spacing: 8) {
                Text("Read aloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                Text(Self.phrases[activePhraseIndex])
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 40)
                    .frame(minHeight: 80, alignment: .top)
                    .id(activePhraseIndex)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            .animation(.easeOut(duration: 0.25), value: activePhraseIndex)

            PhraseDots(count: Self.phrases.count, active: activePhraseIndex)

            Spacer()
        }
        .onAppear {
            recorder.phraseCount = Self.phrases.count
        }
    }
}

private struct ProgressRing: View {
    let progress: Double
    let audioLevel: Float

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 6)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: progress)

            // Inner audio-level glow
            Circle()
                .fill(Color.accentColor.opacity(0.15 + Double(audioLevel) * 0.25))
                .scaleEffect(0.55 + Double(audioLevel) * 0.25)
                .animation(.easeOut(duration: 0.12), value: audioLevel)

            Image(systemName: "mic.fill")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.tint)
        }
    }
}

// MARK: - Naming

private struct NamingStep: View {
    @Binding var nameDraft: String
    let errorMessage: String?
    let onSave: () -> Void
    let onRetry: () -> Void

    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 140, height: 140)
                Image(systemName: "person.wave.2.fill")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(.tint)
            }

            VStack(spacing: 12) {
                Text("Add your name")
                    .font(.title2.weight(.semibold))
                Text("Optional. Your name replaces “You” in transcripts. You can change it anytime in Settings.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 40)
            }

            TextField("Your name", text: $nameDraft, prompt: Text("You"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .focused($nameFocused)
                .onSubmit(onSave)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 40)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            HStack(spacing: 12) {
                Button(action: onRetry) {
                    Text("Re-record")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: onSave) {
                    Text("Save")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 40)

            Spacer(minLength: 0)
        }
        .padding(.top, 24)
        .task {
            // Defer the focus past the initial render so the focus ring draws
            // once instead of flashing during view mount.
            try? await Task.sleep(for: .milliseconds(120))
            nameFocused = true
        }
    }
}

// MARK: - Done

private struct DoneStep: View {
    /// The user's preferred name, or empty when they skipped it.
    let name: String
    let onFinish: () -> Void

    private var headline: String {
        name.isEmpty ? "You're all set." : "You're all set, \(name)."
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 140, height: 140)
                Image(systemName: "checkmark")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.green)
            }

            VStack(spacing: 12) {
                Text(headline)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Serial Notes will use your voice to identify you in future transcripts. You can re-record or delete your profile anytime from Settings.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 40)
            }

            Spacer()

            Button(action: onFinish) {
                Text("Done")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 40)

            Spacer(minLength: 0)
        }
        .padding(.top, 24)
    }
}
