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

    /// Maps a CoreAudio process snapshot to the canonical bundle ID of the known
    /// meeting app it belongs to, or `nil` if it isn't one of ours. Matching
    /// mirrors the call-end monitor's matcher: exact bundle ID first (avoids
    /// Teams v1/v2 ambiguity), then the loose `coreAudioBundleSubstrings` fallback
    /// (catches helper processes like FaceTime's `avconference`), then a
    /// display-name fallback. Iterates apps in sorted key order so a substring
    /// that could match two entries resolves the same way every time.
    nonisolated static func knownMeetingAppBundleID(
        for snapshot: MeetingAudioProcessSnapshot
    ) -> String? {
        let bundleCandidates = [snapshot.coreAudioBundleIdentifier, snapshot.appBundleIdentifier]
            .compactMap { $0 }

        // 1. Exact bundle-ID match.
        for candidate in bundleCandidates where knownMeetingApps[candidate] != nil {
            return candidate
        }

        let loweredBundles = bundleCandidates.map { $0.lowercased() }
        let sortedApps = knownMeetingApps.sorted { $0.key < $1.key }

        // 2. Loose substring match on the CoreAudio / app bundle identifiers.
        for (bundleID, app) in sortedApps {
            for substring in app.coreAudioBundleSubstrings {
                let needle = substring.lowercased()
                if loweredBundles.contains(where: { $0.contains(needle) }) {
                    return bundleID
                }
            }
        }

        // 3. Display-name fallback (some helper processes only expose a name).
        //    Require the whole name to match — a substring test would misattribute
        //    unrelated processes like "Discord Overlay" or "Slack Helper".
        if let appName = snapshot.appName?.lowercased() {
            for (bundleID, app) in sortedApps where appName == app.displayName.lowercased() {
                return bundleID
            }
        }

        return nil
    }

    /// The canonical bundle IDs of every known meeting app currently capturing
    /// microphone input, derived purely from CoreAudio process snapshots.
    nonisolated static func meetingAppsCapturingInput(
        from snapshots: [MeetingAudioProcessSnapshot]
    ) -> Set<String> {
        var owners: Set<String> = []
        for snapshot in snapshots where snapshot.isRunningInput {
            if let bundleID = knownMeetingAppBundleID(for: snapshot) {
                owners.insert(bundleID)
            }
        }
        return owners
    }

    /// The canonical bundle IDs that represent the *same* meeting app as
    /// `association` — i.e. the set a process must resolve into (via
    /// `knownMeetingAppBundleID(for:)`) to count as "belonging" to this
    /// recording's app. Variants sharing a display name (Teams v1 + v2) are
    /// grouped so the call-end monitor follows audio from any of them. The
    /// association's own bundle ID is always included so a recording associated
    /// with a not-yet-known app still matches its exact processes.
    nonisolated static func relatedBundleIDs(
        for association: MeetingRecordingAssociation
    ) -> Set<String> {
        let displayName = knownMeetingApps[association.bundleIdentifier]?.displayName
            ?? association.appName
        var bundleIDs = Set(
            knownMeetingApps
                .filter { $0.value.displayName == displayName }
                .map(\.key)
        )
        bundleIDs.insert(association.bundleIdentifier)
        return bundleIDs
    }

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
    @ObservationIgnored private var attributionSettleTask: Task<Void, Never>?
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
            // The user committed to recording what the prompt showed — freeze
            // attribution so a late settle tick can't move the lock out from under
            // the about-to-start recording (and its call-end association).
            self?.cancelAttributionSettle()
            self?.onRecordRequested?()
        }
        banner.onDismiss = { [weak self] in
            self?.dismissCurrent()
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
        // Stop focus-order guessing for the rest of this mic window and keep the
        // rejected app suppressed. A genuinely different app that becomes the real
        // mic owner can still prompt (handled in reevaluate) — that's a new call,
        // not a re-guess of the one the user just dismissed.
        userRejectedThisWindow = true
        reevaluate()
    }

    /// Surface the post-meeting "name these speakers" banner. A thin pass-through to
    /// the banner the service already owns — intentionally independent of the call-end
    /// state machine (this has no detection or stop semantics; it fires after a
    /// recording has already finalized).
    func showSpeakerNamingPrompt(
        count: Int,
        onName: @escaping @MainActor () -> Void,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        banner.showSpeakerNamingPrompt(count: count, onName: onName, onDismiss: onDismiss)
    }

    /// Pause detection — used while voice enrollment holds the mic so we don't
    /// trigger a false "meeting detected" prompt.
    func suspendDetection() {
        isSuspended = true
        cancelAttributionSettle()
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
            // Recording is underway — the lock is now committed to the call-end
            // association; no late settle tick may move it.
            cancelAttributionSettle()
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
            case .startCountdown:
                markCallEndPromptShown(at: Date())
                startCallEndCountdown()
            case .hidePrompt:
                banner.hide()
            case .stop(let reason):
                meetingDiagnostics.stopReason = reason.diagnosticsValue
                switch reason {
                case .callEndedAuto:
                    markAutoStopFired(at: Date())
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
        // Read the grace duration from the state machine so the timer and the
        // reducer can't drift (the reducer owns the canonical value).
        let graceSeconds = callEndState.inactiveGraceSeconds
        callEndGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(graceSeconds))
            guard !Task.isCancelled else { return }
            self?.handleCallEndEffects(
                self?.callEndState.graceTimerFired(inactiveAt: inactiveAt) ?? []
            )
        }
    }

    private func startCallEndCountdown() {
        guard let association = callEndState.association else { return }
        callEndCountdownTask?.cancel()
        banner.showEndPrompt(appName: association.appName)
        // The banner no longer shows a ticking countdown, so this is a single
        // sleep for the auto-stop window rather than a per-second loop. Cancelled
        // by `.cancelEndTimers` (activity resumed / Keep Recording) and on stop.
        let countdownSeconds = callEndState.countdownSeconds
        callEndCountdownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(countdownSeconds))
            guard !Task.isCancelled else { return }
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
        // Seed the activation order with every already-running meeting app (sorted
        // for determinism) so the activation tiebreak isn't blind to apps that
        // launched before us and never fired a didActivate notification. The real
        // frontmost app is recorded last so it ends up first.
        for bundleID in runningMeetingApps.sorted() {
            recordActivation(bundleID)
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

    /// `true` when an app is a candidate for attribution: running and not
    /// suppressed for this mic window.
    private func isAvailable(_ bundleID: String) -> Bool {
        runningMeetingApps.contains(bundleID) && !suppressedBundleIDs.contains(bundleID)
    }

    /// Running, non-suppressed known meeting apps capturing the mic *right now*,
    /// from a single live CoreAudio scan. A canonical bundle ID resolved from a
    /// helper process (e.g. a Teams helper that only substring-matches "teams") is
    /// mapped to whichever installed variant is actually running via
    /// `runningVariant(of:)`, so the real owner is never silently dropped just
    /// because the mapper picked a sibling bundle ID. Empty when no known meeting
    /// app is running (cheap early-out — avoids a full process scan that can't
    /// produce a result) or when the per-process API yields nothing.
    private func availableInputOwners() -> Set<String> {
        guard !runningMeetingApps.isEmpty else { return [] }
        let captured = Self.meetingAppsCapturingInput(
            from: MeetingAudioProcessReader.currentInputCapturingSnapshots()
        )
        var owners: Set<String> = []
        for bundleID in captured {
            if let running = runningVariant(of: bundleID), !suppressedBundleIDs.contains(running) {
                owners.insert(running)
            }
        }
        return owners
    }

    /// Maps a canonical bundle ID to the installed variant that is actually
    /// running: itself if running, else a sibling sharing its display name (e.g.
    /// Teams v1 → v2). `nil` if no variant is running.
    private func runningVariant(of bundleID: String) -> String? {
        if runningMeetingApps.contains(bundleID) { return bundleID }
        guard let displayName = Self.knownMeetingApps[bundleID]?.displayName else { return nil }
        return runningMeetingApps
            .filter { Self.knownMeetingApps[$0]?.displayName == displayName }
            .sorted()
            .first
    }

    /// Deterministically pick one bundle ID from a candidate set: frontmost →
    /// most-recently-activated → alphabetical (never `Set.first`, which is
    /// non-deterministic).
    private func disambiguate(among candidates: Set<String>) -> String? {
        if candidates.count <= 1 { return candidates.first }
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           candidates.contains(front) {
            return front
        }
        if let recent = activationOrder.first(where: { candidates.contains($0) }) {
            return recent
        }
        return candidates.sorted().first
    }

    /// Fallback attribution when no app reports mic ownership: frontmost known
    /// meeting app → most-recently-activated → alphabetical, among running,
    /// non-suppressed apps.
    private func focusOrderCandidate() -> String? {
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           isAvailable(front) {
            return front
        }
        if let recent = activationOrder.first(where: isAvailable) {
            return recent
        }
        return runningMeetingApps.filter { !suppressedBundleIDs.contains($0) }.sorted().first
    }

    /// After locking attribution via the focus-order fallback (no app yet reports
    /// mic ownership), re-check until one of: audio truth confirms the lock, audio
    /// truth points at a different app (then `reevaluate()` corrects it), or a
    /// generous budget elapses. The per-process input flag can land a beat — and
    /// occasionally a couple of seconds (cold launch, "join with audio?" prompt) —
    /// after the device-level mic-running signal, so the window is bounded but not
    /// stingy. Bounded so it can't busy-loop; cancelled on mic cycle, record, and
    /// suspend.
    private func scheduleAttributionSettle() {
        attributionSettleTask?.cancel()
        attributionSettleTask = Task { @MainActor [weak self] in
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self else { return }
                guard self.micActive,
                      let locked = self.lockedBundleID,
                      self.recordingState?.isRecording != true,
                      !self.isSuspended,
                      !self.userRejectedThisWindow else { return }
                let owners = self.availableInputOwners()
                if owners.isEmpty { continue }        // input flag not propagated yet — keep waiting
                if owners.contains(locked) { return } // lock confirmed by audio truth
                self.reevaluate()                     // a different app owns the mic → correct, then done
                return
            }
        }
    }

    private func cancelAttributionSettle() {
        attributionSettleTask?.cancel()
        attributionSettleTask = nil
    }

    // State machine for prompt attribution:
    //   · The known meeting app actually capturing the mic (CoreAudio per-process
    //     input) is the authoritative signal. We LOCK to one bundle ID for the
    //     mic-active window. While the locked app keeps holding the mic,
    //     frontmost/activation changes do NOT re-attribute (avoids "Slack call
    //     detected" when Zoom warm-holds the mic after a call ends and the user
    //     switches to Slack — Zoom is still the input owner).
    //   · The lock moves only when audio truth says a *different* known app now
    //     owns the mic and the locked one no longer does — this corrects an
    //     initial focus-order mis-lock made before the input flag propagated.
    //   · When no app reports ownership, fall back to focus order and re-check
    //     briefly (scheduleAttributionSettle) for a late-arriving input flag. If
    //     the locked app then terminates mid-window with no owner, clear and wait
    //     for the mic to cycle rather than hunting for a replacement.
    //   · Dismiss and Stop-Recording suppress the rejected app and stop
    //     focus-order guessing for the window; a genuinely different audio owner
    //     can still prompt (a real new call), but a dismissed app stays silent.
    //   · Mic inactive is the only reset: clears lock, suppression, and rejection.
    private func reevaluate() {
        if isSuspended {
            clearDetected()
            return
        }

        if recordingState?.isRecording == true {
            cancelAttributionSettle()
            clearDetected()
            return
        }

        if !micActive {
            cancelAttributionSettle()
            suppressedBundleIDs.removeAll()
            lastNotifiedBundleID = nil
            lockedBundleID = nil
            userRejectedThisWindow = false
            clearDetected()
            return
        }

        // Mic is active. Resolve who actually holds the mic once, up front.
        let owners = availableInputOwners()

        // If the user already rejected an app for this window, stay quiet — UNLESS
        // audio truth now shows a *different*, non-rejected app is the real mic
        // owner (a genuinely new call in the same continuous mic window). We never
        // fall back to focus order after a dismiss; only a confirmed audio owner
        // re-opens the prompt, and rejected apps are excluded from `owners`.
        if userRejectedThisWindow {
            if let owner = disambiguate(among: owners),
               let appName = Self.knownMeetingApps[owner]?.displayName {
                lockedBundleID = owner
                applyDetection(bundleID: owner, appName: appName)
            } else {
                clearDetected()
            }
            return
        }

        // Sticky attribution: while the locked app is still the one capturing the
        // mic, keep it — frontmost/activation changes do NOT move it.
        if let locked = lockedBundleID {
            if owners.contains(locked), let appName = Self.knownMeetingApps[locked]?.displayName {
                applyDetection(bundleID: locked, appName: appName)
                return
            }
            // Locked app no longer holds the mic but a different known app does →
            // correct the attribution (fixes an initial focus-order mis-lock).
            if let owner = disambiguate(among: owners),
               let appName = Self.knownMeetingApps[owner]?.displayName {
                lockedBundleID = owner
                applyDetection(bundleID: owner, appName: appName)
                return
            }
            // No app reports ownership. Keep the lock while its app is still
            // running; otherwise it quit mid-window — clear and wait for the mic
            // to cycle rather than hunting for a replacement.
            if runningMeetingApps.contains(locked),
               let appName = Self.knownMeetingApps[locked]?.displayName {
                applyDetection(bundleID: locked, appName: appName)
                return
            }
            lockedBundleID = nil
            clearDetected()
            return
        }

        // No prior lock: start of a mic-active window. Prefer the real mic owner;
        // otherwise lock via focus order and re-check briefly, since the
        // per-process input flag often lands a beat after the mic-running signal.
        if let owner = disambiguate(among: owners),
           let appName = Self.knownMeetingApps[owner]?.displayName {
            lockedBundleID = owner
            applyDetection(bundleID: owner, appName: appName)
        } else if let fallback = focusOrderCandidate(),
                  let appName = Self.knownMeetingApps[fallback]?.displayName {
            lockedBundleID = fallback
            applyDetection(bundleID: fallback, appName: appName)
            scheduleAttributionSettle()
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
