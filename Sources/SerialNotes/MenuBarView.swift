import FoundationModels
import SwiftUI

struct MenuBarView: View {
    @Environment(RecordingState.self) private var recordingState
    @Environment(StorageSettings.self) private var storageSettings
    @Environment(SummarySettings.self) private var summarySettings
    @Environment(ModelDownloadState.self) private var modelDownloadState
    @Environment(MeetingDetectionService.self) private var meetingDetectionService
    @Environment(SettingsNavigation.self) private var navigation
    @Environment(\.openSettings) private var openSettings

    private var foundationModelsAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    private func showSettings() {
        // .accessory apps don't front their Settings window automatically.
        // Match the pattern used by StorageSettings.pickFolder(): flip to
        // .regular, activate, then flip back once the window is dismissed.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        openSettings()
    }

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 16) {
                if recordingState.isRecording {
                    recordingContent
                } else {
                    idleContent
                }
            }
            .padding(20)
            .frame(width: 280)
            // Do NOT animate this size change. MenuBarExtra(.window) sizes its
            // backing NSWindow to the content's committed fitting size; animating
            // the idle↔recording swap feeds it an in-flight (Core Animation)
            // size that it never reads as a discrete layout change, so the window
            // stays at the taller idle height. The shorter recording content then
            // leaves a transparent dead zone (apps show through) plus a detached
            // drop shadow at the stale frame. Instant resize keeps the window
            // glued to the content.
        }
        // Keep controls bright when Settings (or any other window) is key —
        // otherwise the popover renders as an inactive window and the
        // .glassProminent button washes out to near-white.
        .environment(\.controlActiveState, .active)
        // Re-capture the known-good `openSettings` action (the gear button uses it) so
        // the post-meeting banner can open Settings even before the popover is first opened.
        .onAppear { navigation.openSettingsAction = { openSettings() } }
    }

    // MARK: - Idle

    @ViewBuilder
    private var idleContent: some View {
        HStack {
            BrandMark()
                .frame(width: 24, height: 24)
            Text("Serial Notes")
                .font(.headline)
            Spacer()
            Button(action: showSettings) {
                Image(systemName: "gearshape")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }

        switch modelDownloadState.status {
        case .downloading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading models…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text("Model error: \(message)")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        default:
            EmptyView()
        }

        if let meeting = meetingDetectionService.detectedMeeting, modelDownloadState.isReady {
            VStack(spacing: 8) {
                Text("\(meeting.appName) call detected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Dismiss") { meetingDetectionService.dismissCurrent() }
                        .controlSize(.large)
                        .buttonStyle(.glass)
                    Button(action: {
                        Task { await recordingState.start(storageDirectory: storageSettings.storageLocation) }
                    }) {
                        Label("Record", systemImage: "record.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.glassProminent)
                }
            }
        } else {
            Button(action: {
                Task { await recordingState.start(storageDirectory: storageSettings.storageLocation) }
            }) {
                Label("Start Recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.glassProminent)
            .disabled(!modelDownloadState.isReady)
        }

        if let error = recordingState.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        summaryControls

        storageRow
    }

    private var storageRow: some View {
        @Bindable var storage = storageSettings

        return VStack(spacing: 0) {
            Button(action: { storageSettings.pickFolder() }) {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text("Save To")
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(storageSettings.storageLocationName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()
                .padding(.horizontal, 12)

            toggleRow(
                icon: "waveform",
                title: "Save Audio Files",
                isOn: $storage.saveAudioFiles
            )
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var summaryControls: some View {
        @Bindable var summary = summarySettings

        VStack(spacing: 0) {
            toggleRow(
                icon: "doc.text",
                title: "Meeting Summary",
                isOn: $summary.generateSummary
            )
            Divider()
                .padding(.horizontal, 12)
            toggleRow(
                icon: "checklist",
                title: "Action Items",
                isOn: $summary.generateActionItems
            )
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
        .disabled(!foundationModelsAvailable)

        if !foundationModelsAvailable {
            Text("Summaries require Apple Intelligence")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toggleRow(
        icon: String,
        title: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .font(.caption)
            Spacer(minLength: 0)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { isOn.wrappedValue.toggle() }
    }

    // MARK: - Recording

    @ViewBuilder
    private var recordingContent: some View {
        HStack {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            Text("Recording")
                .font(.headline)
        }

        // Extracted so SwiftUI's @Observable dependency tracking only invalidates
        // this small subtree on each 1Hz tick — the rest of `recordingContent`
        // (and the parent `body`) stays stable.
        ElapsedTimeText(recordingState: recordingState)

        Button(action: { recordingState.stop() }) {
            Label("Stop Recording", systemImage: "stop.circle")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.glassProminent)

        if let error = recordingState.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

private struct ElapsedTimeText: View {
    let recordingState: RecordingState

    var body: some View {
        Text(recordingState.formattedElapsedTime)
            .font(.system(.title, design: .monospaced))
            .contentTransition(.numericText())
    }
}
