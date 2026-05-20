import AppKit
import CoreAudio
import Foundation

struct DetectedMeeting: Equatable {
    let appName: String
    let bundleIdentifier: String
    let detectedAt: Date
}

struct KnownMeetingApp: Equatable, Sendable {
    let displayName: String
    let coreAudioBundleSubstrings: [String]
}

@MainActor @Observable
final class MeetingDetectionService {
    nonisolated static let knownMeetingApps: [String: KnownMeetingApp] = [
        "us.zoom.xos": KnownMeetingApp(displayName: "Zoom", coreAudioBundleSubstrings: ["zoom"]),
        "com.microsoft.teams": KnownMeetingApp(displayName: "Microsoft Teams", coreAudioBundleSubstrings: ["teams"]),
        "com.microsoft.teams2": KnownMeetingApp(displayName: "Microsoft Teams", coreAudioBundleSubstrings: ["teams"]),
        "com.apple.FaceTime": KnownMeetingApp(displayName: "FaceTime", coreAudioBundleSubstrings: ["facetime", "avconference"]),
        "com.tinyspeck.slackmacgap": KnownMeetingApp(displayName: "Slack", coreAudioBundleSubstrings: ["slack", "tinyspeck"]),
        "com.webex.meetingmanager": KnownMeetingApp(displayName: "Webex", coreAudioBundleSubstrings: ["webex"]),
        "com.hnc.Discord": KnownMeetingApp(displayName: "Discord", coreAudioBundleSubstrings: ["discord"]),
    ]

    private(set) var detectedMeeting: DetectedMeeting?

    @ObservationIgnored var onRecordRequested: (() -> Void)?
    @ObservationIgnored var onStopRecordingRequested: ((RecordingStopReason) -> Void)?

    @ObservationIgnored private weak var recordingState: RecordingState?
    @ObservationIgnored private weak var meetingSettings: MeetingSettings?
    @ObservationIgnored private let banner = MeetingBannerController()
    @ObservationIgnored private let audioActivityMonitor = MeetingAudioActivityMonitor()
    @ObservationIgnored private var callEndState = CallEndStateMachine()
    @ObservationIgnored private var callEndGraceTask: Task<Void, Never>?
    @ObservationIgnored private var callEndCountdownTask: Task<Void, Never>?
    @ObservationIgnored private var neverObservedActiveTask: Task<Void, Never>?
    @ObservationIgnored private var meetingDiagnostics = MeetingSessionDiagnostics()
    @ObservationIgnored private var runningMeetingApps: Set<String> = []
    @ObservationIgnored private var activationOrder: [String] = []  // most recent first
    @ObservationIgnored private var suppressedBundleIDs: Set<String> = []
    @ObservationIgnored private var micActive: Bool = false
    @ObservationIgnored private var lastNotifiedBundleID: String?
    // Attribution is sticky while mic is continuously active — see reevaluate() notes.
    @ObservationIgnored private var lockedBundleID: String?
    @ObservationIgnored private var userRejectedThisWindow: Bool = false
    // When true, detection is paused — used while voice enrollment holds the mic
    // so we don't fire a phantom "meeting detected" banner from our own recording.
    @ObservationIgnored private var isSuspended: Bool = false

    // All registration state lives on `listenerCleanup`. Single source of truth
    // so the deinit and the runtime mutators can't drift out of sync. The
    // cleanup object itself is in a nonisolated reference type so its `deinit`
    // (which runs off the main actor) can call the thread-safe removal APIs
    // without violating actor isolation. In production this lives at app root
    // for the process lifetime, but tests and future callers may construct /
    // destruct it many times.
    @ObservationIgnored private let listenerCleanup = ListenerCleanup()

    init(recordingState: RecordingState, meetingSettings: MeetingSettings) {
        self.recordingState = recordingState
        self.meetingSettings = meetingSettings
        banner.onRecord = { [weak self] in
            self?.onRecordRequested?()
        }
        banner.onDismiss = { [weak self] in
            self?.dismissCurrent()
        }
        banner.onEndStop = { [weak self] in
            self?.stopFromEndPrompt()
        }
        banner.onEndKeepRecording = { [weak self] in
            self?.keepRecordingFromEndPrompt()
        }
        audioActivityMonitor.onActivityChanged = { [weak self] state in
            self?.handleMeetingAudioActivity(state)
        }
        seedRunningApps()
        registerWorkspaceObservers()
        registerDefaultDeviceListener()
        rebindMicListener()
        reevaluate()
    }

    // Teardown of workspace observers + CoreAudio listeners is handled by
    // `listenerCleanup`'s nonisolated deinit — we can't run that work from
    // this type's deinit because the listener block isn't Sendable.

    // MARK: - Public API

    func dismissCurrent() {
        if let locked = lockedBundleID {
            suppressedBundleIDs.insert(locked)
        } else if let current = detectedMeeting {
            suppressedBundleIDs.insert(current.bundleIdentifier)
        }
        // Stay silent for the rest of this mic-active window. Don't hunt for a
        // different meeting app — mic activity is driven by the rejected one.
        userRejectedThisWindow = true
        reevaluate()
    }

    /// Pause detection — used while voice enrollment holds the mic so we don't
    /// trigger a false "meeting detected" prompt.
    func suspendDetection() {
        isSuspended = true
        clearDetected()
    }

    /// Resume detection after `suspendDetection()`.
    func resumeDetection() {
        isSuspended = false
        // CoreAudio takes a moment to report `micActive=false` after the
        // enrollment engine stops. If we'd reevaluate right now with the mic
        // still reported active, we'd pick whatever meeting app happens to be
        // running and fire a false positive. Treat the remainder of this mic
        // window as implicitly dismissed — the detector will clear the flag
        // the next time the mic genuinely goes inactive.
        if micActive {
            userRejectedThisWindow = true
        }
        reevaluate()
    }

    func recordingStateChanged() {
        if recordingState?.isRecording == true {
            beginCallEndMonitoringIfNeeded()
        } else {
            endCallEndMonitoring()
        }

        // User stopped recording while still in a call (mic still active) → treat
        // as an implicit dismiss so we don't immediately re-prompt. They made a
        // choice to stop.
        if recordingState?.isRecording == false, micActive {
            if let locked = lockedBundleID {
                suppressedBundleIDs.insert(locked)
            }
            userRejectedThisWindow = true
        }
        reevaluate()
    }

    // MARK: - Call End Monitoring

    private func beginCallEndMonitoringIfNeeded() {
        guard meetingSettings?.autoStopAfterCallEnds == true else {
            return
        }
        guard let bundleID = lockedBundleID,
              let appName = Self.knownMeetingApps[bundleID]?.displayName else {
            return
        }

        let association = MeetingRecordingAssociation(
            appName: appName,
            bundleIdentifier: bundleID,
            startedAt: Date()
        )
        meetingDiagnostics = MeetingSessionDiagnostics(association: association)
        _ = callEndState.startRecording(
            association: association,
            autoStopEnabled: true
        )
        audioActivityMonitor.startMonitoring(association: association)
        scheduleNeverObservedActiveWarning()
    }

    private func endCallEndMonitoring() {
        if meetingDiagnostics.shouldWriteSidecar {
            recordingState?.attachMeetingDiagnosticsForCurrentStop(meetingDiagnostics)
        }
        callEndGraceTask?.cancel()
        callEndGraceTask = nil
        callEndCountdownTask?.cancel()
        callEndCountdownTask = nil
        neverObservedActiveTask?.cancel()
        neverObservedActiveTask = nil
        audioActivityMonitor.stopMonitoring()
        handleCallEndEffects(callEndState.stopRecording())
        meetingDiagnostics = MeetingSessionDiagnostics()
    }

    private func handleMeetingAudioActivity(_ state: MeetingAudioActivityState) {
        recordMeetingAudioActivity(state)
        handleCallEndEffects(callEndState.receiveActivity(state))
    }

    private func handleCallEndEffects(_ effects: [CallEndStateMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .startGraceTimer(let inactiveAt):
                scheduleCallEndGraceTimer(inactiveAt: inactiveAt)
            case .cancelEndTimers:
                callEndGraceTask?.cancel()
                callEndGraceTask = nil
                callEndCountdownTask?.cancel()
                callEndCountdownTask = nil
            case .startCountdown(let inactiveAt, let remainingSeconds):
                markCallEndPromptShown(at: Date())
                startCallEndCountdown(inactiveAt: inactiveAt, remainingSeconds: remainingSeconds)
            case .updateCountdown(let remainingSeconds):
                if let association = callEndState.association {
                    banner.showEndPrompt(appName: association.appName, remainingSeconds: remainingSeconds)
                }
            case .hidePrompt:
                banner.hide()
            case .stop(let reason):
                meetingDiagnostics.stopReason = reason.diagnosticsValue
                switch reason {
                case .callEndedAuto:
                    markAutoStopFired(at: Date())
                case .callEndedUserConfirmed:
                    markUserConfirmedCallEndStop(at: Date())
                case .manual, .appQuit:
                    break
                }
                onStopRecordingRequested?(reason)
            case .stopMonitoring:
                neverObservedActiveTask?.cancel()
                neverObservedActiveTask = nil
                audioActivityMonitor.stopMonitoring()
            case .logNeverObservedActive(let date):
                markNeverObservedMeetingAudioActive(at: date)
            }
        }
    }

    private func scheduleCallEndGraceTimer(inactiveAt: Date) {
        callEndGraceTask?.cancel()
        callEndGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.handleCallEndEffects(
                self?.callEndState.graceTimerFired(inactiveAt: inactiveAt) ?? []
            )
        }
    }

    private func startCallEndCountdown(inactiveAt: Date, remainingSeconds: Int) {
        guard let association = callEndState.association else { return }
        callEndCountdownTask?.cancel()
        banner.showEndPrompt(appName: association.appName, remainingSeconds: remainingSeconds)
        callEndCountdownTask = Task { @MainActor [weak self] in
            var remaining = remainingSeconds
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                remaining -= 1
                if remaining > 0 {
                    self?.handleCallEndEffects(
                        self?.callEndState.countdownTick(remainingSeconds: remaining) ?? []
                    )
                }
            }
            self?.handleCallEndEffects(self?.callEndState.countdownFinished() ?? [])
        }
    }

    private func scheduleNeverObservedActiveWarning() {
        neverObservedActiveTask?.cancel()
        neverObservedActiveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.handleCallEndEffects(
                self?.callEndState.neverObservedTimerFired(at: Date()) ?? []
            )
        }
    }

    private func stopFromEndPrompt() {
        handleCallEndEffects(callEndState.stopNow())
    }

    private func keepRecordingFromEndPrompt() {
        markKeptRecordingAfterCallEnd(at: Date())
        handleCallEndEffects(callEndState.keepRecording())
    }

    private func recordMeetingAudioActivity(_ state: MeetingAudioActivityState) {
        switch state {
        case .active(let snapshot):
            meetingDiagnostics.lastMatchedProcesses = snapshot.matchedProcesses
            if meetingDiagnostics.firstActiveAt == nil {
                meetingDiagnostics.firstActiveAt = snapshot.observedAt
            }
        case .inactive(let snapshot):
            meetingDiagnostics.lastMatchedProcesses = snapshot.matchedProcesses
            if meetingDiagnostics.firstInactiveAt == nil {
                meetingDiagnostics.firstInactiveAt = snapshot.observedAt
            }
        case .unknown(let reason, _):
            meetingDiagnostics.lastUnknownReason = reason
        }
    }

    private func markCallEndPromptShown(at date: Date) {
        if meetingDiagnostics.promptShownAt == nil {
            meetingDiagnostics.promptShownAt = date
        }
    }

    private func markAutoStopFired(at date: Date) {
        meetingDiagnostics.autoStopFiredAt = date
    }

    private func markUserConfirmedCallEndStop(at date: Date) {
        meetingDiagnostics.userConfirmedStopAt = date
    }

    private func markKeptRecordingAfterCallEnd(at date: Date) {
        meetingDiagnostics.keptRecordingAt = date
    }

    private func markNeverObservedMeetingAudioActive(at date: Date) {
        guard meetingDiagnostics.firstActiveAt == nil,
              meetingDiagnostics.neverObservedActiveWarningAt == nil else {
            return
        }
        meetingDiagnostics.neverObservedActiveWarningAt = date
        NSLog("[SerialNotes/MeetingAudio] never observed active CoreAudio process for associated meeting")
    }

    // MARK: - NSWorkspace

    private func seedRunningApps() {
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier, Self.knownMeetingApps[bundleID] != nil {
                runningMeetingApps.insert(bundleID)
            }
        }
        if let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           Self.knownMeetingApps[frontBundle] != nil {
            recordActivation(frontBundle)
        }
    }

    private func recordActivation(_ bundleID: String) {
        activationOrder.removeAll { $0 == bundleID }
        activationOrder.insert(bundleID, at: 0)
    }

    private func registerWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter

        let launch = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let bundleID = app.bundleIdentifier,
                Self.knownMeetingApps[bundleID] != nil
            else { return }
            MainActor.assumeIsolated {
                self?.runningMeetingApps.insert(bundleID)
                self?.reevaluate()
            }
        }

        let terminate = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let bundleID = app.bundleIdentifier
            else { return }
            MainActor.assumeIsolated {
                self?.runningMeetingApps.remove(bundleID)
                self?.suppressedBundleIDs.remove(bundleID)
                self?.activationOrder.removeAll { $0 == bundleID }
                self?.reevaluate()
            }
        }

        let activate = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let bundleID = app.bundleIdentifier,
                Self.knownMeetingApps[bundleID] != nil
            else { return }
            MainActor.assumeIsolated {
                self?.recordActivation(bundleID)
                self?.reevaluate()
            }
        }

        listenerCleanup.workspaceObservers = [launch, terminate, activate]
    }

    // MARK: - CoreAudio

    nonisolated private static func makeMicRunningAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    nonisolated private static func makeDefaultInputDeviceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func registerDefaultDeviceListener() {
        var addr = Self.makeDefaultInputDeviceAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.rebindMicListener()
                }
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        if status == noErr {
            listenerCleanup.defaultDeviceListenerBlock = block
        }
    }

    private func rebindMicListener() {
        // Remove existing listener on old device.
        if let oldBlock = listenerCleanup.micListenerBlock,
           listenerCleanup.micListenerDeviceID != kAudioObjectUnknown {
            var addr = Self.makeMicRunningAddress()
            AudioObjectRemovePropertyListenerBlock(
                listenerCleanup.micListenerDeviceID, &addr, DispatchQueue.main, oldBlock)
        }
        listenerCleanup.micListenerBlock = nil
        listenerCleanup.micListenerDeviceID = kAudioObjectUnknown

        guard let newDeviceID = Self.defaultInputDeviceID() else {
            micActive = false
            reevaluate()
            return
        }

        micActive = Self.readIsRunningSomewhere(deviceID: newDeviceID)

        var addr = Self.makeMicRunningAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            let active = Self.readIsRunningSomewhere(deviceID: newDeviceID)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.micActive = active
                    self?.reevaluate()
                }
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            newDeviceID, &addr, DispatchQueue.main, block)
        if status == noErr {
            listenerCleanup.micListenerBlock = block
            listenerCleanup.micListenerDeviceID = newDeviceID
        }
        reevaluate()
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = makeDefaultInputDeviceAddress()
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func readIsRunningSomewhere(deviceID: AudioDeviceID) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = makeMicRunningAddress()
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    // MARK: - Fusion

    private func selectMeetingApp() -> String? {
        func available(_ bundleID: String) -> Bool {
            runningMeetingApps.contains(bundleID) && !suppressedBundleIDs.contains(bundleID)
        }

        // 1. Frontmost known meeting app wins — strongest signal of user intent.
        if let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           available(frontBundle) {
            return frontBundle
        }

        // 2. Otherwise prefer the most recently activated known meeting app.
        if let recent = activationOrder.first(where: available) {
            return recent
        }

        // 3. Deterministic fallback: alphabetical by bundle ID (Set order is undefined).
        return runningMeetingApps.filter { !suppressedBundleIDs.contains($0) }.sorted().first
    }

    // State machine for prompt attribution:
    //   · While mic is continuously active, we LOCK to one bundle ID — the one
    //     present at mic-activation time. Frontmost/activation changes do NOT
    //     re-attribute (avoids "Slack call detected" when Zoom warm-holds the
    //     mic after a call ends and the user switches to Slack).
    //   · If the locked app terminates mid-window, clear detection but do not
    //     hunt for a replacement — the mic is still warm from the dead app, not
    //     from any newly-candidate one.
    //   · Dismiss and Stop-Recording set `userRejectedThisWindow` so no further
    //     prompts fire until the mic cycles (signals end-of-call).
    //   · Mic inactive is the only reset: clears lock, suppression, and rejection.
    private func reevaluate() {
        if isSuspended {
            clearDetected()
            return
        }

        if recordingState?.isRecording == true {
            clearDetected()
            return
        }

        if !micActive {
            suppressedBundleIDs.removeAll()
            lastNotifiedBundleID = nil
            lockedBundleID = nil
            userRejectedThisWindow = false
            clearDetected()
            return
        }

        // Mic is active. If the user already rejected for this window, stay quiet.
        if userRejectedThisWindow {
            clearDetected()
            return
        }

        // Sticky attribution: if we locked onto an app earlier in this window,
        // keep it (even if something else became frontmost).
        if let locked = lockedBundleID {
            if runningMeetingApps.contains(locked),
               let appName = Self.knownMeetingApps[locked]?.displayName {
                applyDetection(bundleID: locked, appName: appName)
                return
            }
            // Locked app quit mid-window. Don't re-attribute — wait for mic cycle.
            lockedBundleID = nil
            clearDetected()
            return
        }

        // No prior lock: this is the start of a mic-active window (or a fresh
        // reevaluate after a reset). Pick once and lock.
        if let bundleID = selectMeetingApp(), let appName = Self.knownMeetingApps[bundleID]?.displayName {
            lockedBundleID = bundleID
            applyDetection(bundleID: bundleID, appName: appName)
        } else {
            clearDetected()
        }
    }

    private func applyDetection(bundleID: String, appName: String) {
        if detectedMeeting?.bundleIdentifier != bundleID {
            detectedMeeting = DetectedMeeting(
                appName: appName,
                bundleIdentifier: bundleID,
                detectedAt: Date()
            )
        }
        if lastNotifiedBundleID != bundleID {
            lastNotifiedBundleID = bundleID
            banner.showStartPrompt(appName: appName)
        }
    }

    private func clearDetected() {
        if detectedMeeting != nil {
            detectedMeeting = nil
        }
        if lastNotifiedBundleID != nil {
            lastNotifiedBundleID = nil
            banner.hide()
        }
    }
}

/// Holds the registration state for every observer/listener the service owns
/// and tears them down in its deinit. Lives in a separate class so the cleanup
/// runs nonisolated — `MeetingDetectionService` is `@MainActor`, but
/// `removeObserver` / `AudioObjectRemovePropertyListenerBlock` are thread-safe.
/// Marked `@unchecked Sendable` because the listener-block properties are
/// non-Sendable function types but only mutated from the main actor.
private final class ListenerCleanup: @unchecked Sendable {
    var workspaceObservers: [NSObjectProtocol] = []
    var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    var micListenerBlock: AudioObjectPropertyListenerBlock?
    var micListenerDeviceID: AudioDeviceID = kAudioObjectUnknown

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            center.removeObserver(token)
        }

        if let block = defaultDeviceListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        }

        if let block = micListenerBlock, micListenerDeviceID != kAudioObjectUnknown {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                micListenerDeviceID, &addr, DispatchQueue.main, block)
        }
    }
}
