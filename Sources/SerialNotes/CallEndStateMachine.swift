import Foundation

struct CallEndStateMachine: Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case monitoring
        case inactiveGrace(inactiveAt: Date)
        case prompting(inactiveAt: Date)
        case suppressed
    }

    enum Effect: Equatable, Sendable {
        case startGraceTimer(inactiveAt: Date)
        case cancelEndTimers
        case startCountdown
        case hidePrompt
        case stop(RecordingStopReason)
        case stopMonitoring
        case logNeverObservedActive(Date)
    }

    private(set) var phase: Phase = .idle
    private(set) var association: MeetingRecordingAssociation?
    private(set) var firstInactiveAt: Date?

    let inactiveGraceSeconds: TimeInterval
    let countdownSeconds: Int

    // Grace is a short debounce so a brief mid-call audio blip (mute toggle,
    // screen-share transition, network hiccup) doesn't false-fire the end prompt;
    // it's deliberately small so the prompt appears almost as soon as the call
    // ends. Countdown is the window the user has to "Keep Recording" before
    // auto-stop. Kept short now that grace is short — a false trigger would
    // otherwise stop a live recording too aggressively.
    init(inactiveGraceSeconds: TimeInterval = 2, countdownSeconds: Int = 5) {
        self.inactiveGraceSeconds = inactiveGraceSeconds
        self.countdownSeconds = countdownSeconds
    }

    mutating func startRecording(
        association: MeetingRecordingAssociation?,
        autoStopEnabled: Bool
    ) -> [Effect] {
        reset()
        guard autoStopEnabled, let association else {
            phase = .idle
            return []
        }
        self.association = association
        phase = .monitoring
        return []
    }

    mutating func stopRecording() -> [Effect] {
        let shouldHide: Bool
        if case .prompting = phase {
            shouldHide = true
        } else {
            shouldHide = false
        }
        reset()
        return shouldHide ? [.hidePrompt, .stopMonitoring] : [.stopMonitoring]
    }

    mutating func receiveActivity(_ state: MeetingAudioActivityState) -> [Effect] {
        guard association != nil else { return [] }
        switch state {
        case .unknown:
            return []
        case .active:
            firstInactiveAt = nil
            let effects: [Effect]
            switch phase {
            case .inactiveGrace:
                effects = [.cancelEndTimers]
            case .prompting:
                effects = [.cancelEndTimers, .hidePrompt]
            default:
                effects = []
            }
            phase = .monitoring
            return effects
        case .inactive(let snapshot):
            switch phase {
            case .monitoring:
                let inactiveAt = firstInactiveAt ?? snapshot.observedAt
                firstInactiveAt = inactiveAt
                phase = .inactiveGrace(inactiveAt: inactiveAt)
                return [.startGraceTimer(inactiveAt: inactiveAt)]
            case .inactiveGrace, .prompting, .suppressed, .idle:
                return []
            }
        }
    }

    mutating func graceTimerFired(inactiveAt: Date) -> [Effect] {
        guard case .inactiveGrace(let currentInactiveAt) = phase,
              currentInactiveAt == inactiveAt else {
            return []
        }
        phase = .prompting(inactiveAt: inactiveAt)
        return [.startCountdown]
    }

    mutating func countdownFinished() -> [Effect] {
        guard let association,
              case .prompting(let inactiveAt) = phase else {
            return []
        }
        phase = .suppressed
        let context = MeetingCallEndContext(
            appName: association.appName,
            bundleIdentifier: association.bundleIdentifier,
            inactiveAt: inactiveAt
        )
        return [.hidePrompt, .stop(.callEndedAuto(context))]
    }

    mutating func keepRecording() -> [Effect] {
        guard association != nil else { return [] }
        phase = .suppressed
        return [.cancelEndTimers, .hidePrompt, .stopMonitoring]
    }

    mutating func neverObservedTimerFired(at date: Date) -> [Effect] {
        guard association != nil else { return [] }
        return [.logNeverObservedActive(date)]
    }

    private mutating func reset() {
        phase = .idle
        association = nil
        firstInactiveAt = nil
    }
}
