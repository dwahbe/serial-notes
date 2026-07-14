import AppKit
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
    /// Whether the app can start a recording right now (ASR models ready).
    /// Gates the start prompt the same way the popover gates its Record card —
    /// nil (unwired, e.g. tests) means always ready.
    @ObservationIgnored var isReadyToRecord: (() -> Bool)?

    @ObservationIgnored private weak var recordingState: RecordingState?
    @ObservationIgnored private weak var meetingSettings: MeetingSettings?
    @ObservationIgnored private let banner = MeetingBannerController()

    // MARK: Start detection (edge-triggered)
    @ObservationIgnored private let inputCaptureMonitor = MeetingInputCaptureMonitor()
    @ObservationIgnored private var startDetector = MeetingStartDetector()
    @ObservationIgnored private var startDebounceTask: Task<Void, Never>?
    // Most-recently-activated known meeting apps (front first) — a deterministic
    // tiebreak when two apps start capturing in the same scan.
    @ObservationIgnored private var activationOrder: [String] = []
    // Known meeting apps currently running (NSWorkspace). The input monitor only
    // runs while at least one is open — when none is, nothing can be in a call, so
    // the monitor and its poll stay off entirely (no idle churn).
    @ObservationIgnored private var runningMeetingApps: Set<String> = []
    // Paused while voice enrollment holds the mic (so its own capture can't prompt).
    @ObservationIgnored private var isSuspended: Bool = false

    // Post-meeting naming prompts, queued because the banner is a single panel
    // (see showSpeakerNamingPrompt).
    private struct NamingPrompt {
        let count: Int
        let onName: @MainActor () -> Void
        let onDismiss: @MainActor () -> Void
    }
    @ObservationIgnored private var pendingNamingPrompts: [NamingPrompt] = []
    @ObservationIgnored private var activeNamingPrompt: NamingPrompt?

    // MARK: Call-end monitoring (unchanged)
    @ObservationIgnored private let audioActivityMonitor = MeetingAudioActivityMonitor()
    @ObservationIgnored private var callEndState = CallEndStateMachine()
    @ObservationIgnored private var callEndGraceTask: Task<Void, Never>?
    @ObservationIgnored private var callEndCountdownTask: Task<Void, Never>?
    @ObservationIgnored private var neverObservedActiveTask: Task<Void, Never>?
    @ObservationIgnored private var meetingDiagnostics = MeetingSessionDiagnostics()
    // Last observed *active-recording* state, so `recordingStateChanged` drives
    // call-end monitoring off real transitions only (it's also pinged mid-spin-up).
    @ObservationIgnored private var wasRecordingActive: Bool = false

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
        banner.onEndKeepRecording = { [weak self] in
            self?.keepRecordingFromEndPrompt()
        }
        audioActivityMonitor.onActivityChanged = { [weak self] state in
            self?.handleMeetingAudioActivity(state)
        }
        inputCaptureMonitor.onCapturingChanged = { [weak self] owners in
            self?.handleCapturingChanged(owners)
        }
        seedRunningApps()
        registerWorkspaceObservers()
        updateInputMonitoring()
    }

    // Teardown of workspace observers is handled by `listenerCleanup`'s nonisolated
    // deinit; the input-capture monitor cleans up its own CoreAudio listeners.

    // MARK: - Public API

    func dismissCurrent() {
        handleStartEffects(startDetector.dismiss())
    }

    /// Surface the post-meeting "name these speakers" banner. Intentionally
    /// independent of the call-end state machine (this has no detection or stop
    /// semantics; it fires after a recording has already finalized).
    ///
    /// QUEUED, one at a time: back-to-back meetings can finish with unnamed
    /// speakers together (deferred post-meeting actions flush in one burst), and
    /// the banner is a single panel — showing them synchronously would replace
    /// every prompt but the last within one run-loop tick. Each prompt shows
    /// when its predecessor is named/dismissed/auto-dismissed.
    func showSpeakerNamingPrompt(
        count: Int,
        onName: @escaping @MainActor () -> Void,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        pendingNamingPrompts.append(NamingPrompt(count: count, onName: onName, onDismiss: onDismiss))
        showNextNamingPromptIfFree()
    }

    private func showNextNamingPromptIfFree() {
        guard activeNamingPrompt == nil, !pendingNamingPrompts.isEmpty else { return }
        let prompt = pendingNamingPrompts.removeFirst()
        activeNamingPrompt = prompt
        banner.showSpeakerNamingPrompt(
            count: prompt.count,
            onName: { [weak self] in
                prompt.onName()
                self?.namingPromptFinished()
            },
            onDismiss: { [weak self] in
                prompt.onDismiss()
                self?.namingPromptFinished()
            }
        )
    }

    private func namingPromptFinished() {
        activeNamingPrompt = nil
        showNextNamingPromptIfFree()
    }

    /// A start/end prompt is about to take the shared banner panel while a
    /// naming prompt is visible — its callbacks will never fire, so put it back
    /// at the head of the queue to reappear once the panel frees up.
    private func requeueActiveNamingPromptIfAny() {
        guard let active = activeNamingPrompt else { return }
        activeNamingPrompt = nil
        pendingNamingPrompts.insert(active, at: 0)
    }

    /// Pause detection — used while voice enrollment holds the mic. (Edge-triggering
    /// already wouldn't false-fire on our own mic use, but pausing keeps the monitor
    /// quiet and discards any in-flight prompt for the enrollment window.)
    func suspendDetection() {
        isSuspended = true
        updateInputMonitoring()
    }

    /// Resume detection after `suspendDetection()`. Restarting the monitor
    /// re-establishes the baseline, so an app still capturing when enrollment ends
    /// is treated as in-progress rather than a fresh transition.
    func resumeDetection() {
        isSuspended = false
        updateInputMonitoring()
    }

    func recordingStateChanged() {
        // Drive call-end monitoring off the actual recording transition only.
        // `start()` also pings this while still spinning up (isRecording == false),
        // and the transition guard keeps that ping from tearing down — or
        // double-starting — call-end monitoring.
        let isActive = recordingState?.isRecording == true
        if isActive != wasRecordingActive {
            wasRecordingActive = isActive
            if isActive {
                beginCallEndMonitoringIfNeeded()
            } else {
                endCallEndMonitoring()
            }
        }

        // A recording session in any phase owns the mic, so the start monitor pauses
        // for its lifetime (and re-baselines after) — this both fixes the phantom
        // prompt during the await-heavy start window and stops an idle app that was
        // warm-holding the mic from re-prompting right after the recording ends.
        updateInputMonitoring()
    }

    // MARK: - Start detection (monitor → reducer → banner)

    /// Whether the input-capture monitor should be running: a known meeting app is
    /// open, no recording session is in flight (start-up → active → finalizing),
    /// detection isn't suspended, and the app can actually record (ASR models
    /// ready). Gating the MONITOR on readiness — not just the prompt — matters:
    /// a prompt suppressed after the reducer locked would wedge the lock for the
    /// whole call; keeping the monitor down means no transitions are consumed at
    /// all, and `modelReadinessChanged` re-baselines once models arrive. When no
    /// meeting app is running nothing can be in a call, so the monitor and its
    /// poll stay off entirely — no idle churn.
    private var shouldMonitorInput: Bool {
        !isSuspended
            && !runningMeetingApps.isEmpty
            && recordingState?.isRecordingSessionActive != true
            && isReadyToRecord?() != false
    }

    /// Nudge from the app shell when the model download completes — nothing else
    /// re-evaluates monitoring at that moment, so without this the monitor would
    /// stay down until the next workspace/recording event.
    func modelReadinessChanged() {
        updateInputMonitoring()
    }

    /// Start the monitor with a fresh `MeetingStartDetector`, re-establishing the
    /// baseline so whatever is already capturing now is treated as in-progress.
    private func startInputMonitoring() {
        guard !inputCaptureMonitor.isRunning else { return }
        startDetector = MeetingStartDetector()
        inputCaptureMonitor.start()
    }

    private func stopInputMonitoring() {
        startDebounceTask?.cancel()
        startDebounceTask = nil
        inputCaptureMonitor.stop()
        clearDetected()
    }

    private func updateInputMonitoring() {
        if shouldMonitorInput {
            startInputMonitoring()
        } else {
            stopInputMonitoring()
        }
    }

    private func handleCapturingChanged(_ owners: Set<String>) {
        handleStartEffects(startDetector.receiveCapturing(owners, order: captureOrder(owners)))
    }

    private func handleStartEffects(_ effects: [MeetingStartDetector.Effect]) {
        for effect in effects {
            switch effect {
            case .startDebounceTimer(let bundleID):
                scheduleStartDebounce(bundleID: bundleID)
            case .cancelDebounceTimer:
                startDebounceTask?.cancel()
                startDebounceTask = nil
            case .showPrompt(let bundleID):
                // Defense in depth: never surface a start prompt while a recording
                // session is active or before the ASR models are ready (the
                // monitor is gated on both, but the windows aren't all signalled
                // through recordingStateChanged). A suppressed prompt must also
                // RELEASE the reducer's lock — the lock was set when the prompt
                // fired, and holding it promptless would block every later
                // prompt until the app stops capturing.
                guard recordingState?.isRecordingSessionActive != true,
                      isReadyToRecord?() != false,
                      let appName = Self.knownMeetingApps[bundleID]?.displayName else {
                    startDetector.releaseLock()
                    break
                }
                applyDetection(bundleID: bundleID, appName: appName)
            case .hidePrompt:
                clearDetected()
            }
        }
    }

    private func scheduleStartDebounce(bundleID: String) {
        startDebounceTask?.cancel()
        // Read the debounce from the reducer so the timer and the reducer can't drift.
        let seconds = startDetector.debounceSeconds
        startDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.handleStartEffects(self.startDetector.debounceTimerFired(bundleID: bundleID))
        }
    }

    /// Disambiguation order for simultaneous new transitions: frontmost →
    /// most-recently-activated → alphabetical (never `Set.first`, which is
    /// non-deterministic). Only the apps in `owners` are included.
    private func captureOrder(_ owners: Set<String>) -> [String] {
        var order: [String] = []
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           owners.contains(front) {
            order.append(front)
        }
        for bundleID in activationOrder where owners.contains(bundleID) && !order.contains(bundleID) {
            order.append(bundleID)
        }
        for bundleID in owners.sorted() where !order.contains(bundleID) {
            order.append(bundleID)
        }
        return order
    }

    private func applyDetection(bundleID: String, appName: String) {
        requeueActiveNamingPromptIfAny()
        detectedMeeting = DetectedMeeting(
            appName: appName,
            bundleIdentifier: bundleID,
            detectedAt: Date()
        )
        banner.showStartPrompt(appName: appName)
    }

    private func clearDetected() {
        guard detectedMeeting != nil else { return }
        detectedMeeting = nil
        banner.hide()
        // The panel is free again — a naming prompt the start prompt displaced
        // (or one that queued behind it) can show now.
        showNextNamingPromptIfFree()
    }

    // MARK: - Call End Monitoring

    private func beginCallEndMonitoringIfNeeded() {
        guard meetingSettings?.autoStopAfterCallEnds == true else {
            return
        }
        // Associate auto-stop with the app the start prompt locked onto — i.e. a
        // meeting we actually detected (edge-triggered). A manual recording with no
        // detected meeting (e.g. idle Zoom warm-holding the mic, no call) leaves the
        // lock nil and gets no auto-stop, so it can't be stopped by that app merely
        // releasing the mic.
        guard let bundleID = startDetector.lockedBundleID,
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
        // The recording this lock produced is over. Release it so a follow-up
        // recording started during this one's finalization can't inherit the
        // association (see MeetingStartDetector.releaseLock).
        startDetector.releaseLock()
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
                case .manual, .appQuit, .captureFailed:
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

    // MARK: - NSWorkspace (running set + activation order)

    private func seedRunningApps() {
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, Self.knownMeetingApps[bundleID] != nil else { continue }
            runningMeetingApps.insert(bundleID)
        }
        // Sorted for determinism; the real frontmost app is recorded last so it
        // ends up first.
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
                // A meeting app opened → start watching for a call to begin.
                self?.updateInputMonitoring()
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
                self?.activationOrder.removeAll { $0 == bundleID }
                // Last meeting app closed → stop watching (no idle poll).
                self?.updateInputMonitoring()
            }
        }

        listenerCleanup.workspaceObservers = [launch, activate, terminate]
    }
}

/// Holds the workspace observer tokens the service registers and removes them in
/// its deinit. Lives in a separate class so the cleanup runs nonisolated —
/// `MeetingDetectionService` is `@MainActor`, but `removeObserver` is thread-safe.
/// Marked `@unchecked Sendable` because `NSObjectProtocol` tokens aren't Sendable
/// but are only mutated from the main actor.
private final class ListenerCleanup: @unchecked Sendable {
    var workspaceObservers: [NSObjectProtocol] = []

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            center.removeObserver(token)
        }
    }
}
