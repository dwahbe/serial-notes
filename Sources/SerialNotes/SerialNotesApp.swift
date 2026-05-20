import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    weak var recordingState: RecordingState?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
    @State private var modelDownloadState: ModelDownloadState
    @State private var meetingDetectionService: MeetingDetectionService
    @State private var voiceProfileStore: VoiceProfileStore

    init() {
        let recording = RecordingState()
        let storage = StorageSettings()
        let summary = SummarySettings()
        let meeting = MeetingSettings()
        let voices = VoiceProfileStore()
        let detector = MeetingDetectionService(recordingState: recording, meetingSettings: meeting)
        let modelState = ModelDownloadState(transcriptionService: recording.transcriptionService)

        recording.voiceProfileStore = voices
        recording.summarySettings = summary
        recording.storageSettings = storage
        recording.onRecordingChange = { [weak detector] in detector?.recordingStateChanged() }
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
        _modelDownloadState = State(initialValue: modelState)
        _meetingDetectionService = State(initialValue: detector)
        _voiceProfileStore = State(initialValue: voices)

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
                .preferredColorScheme(.dark)
        } label: {
            Image(systemName: recordingState.isRecording ? "record.circle" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(voiceProfileStore)
                .environment(storageSettings)
                .environment(summarySettings)
                .environment(meetingSettings)
                .environment(meetingDetectionService)
        }
    }
}
