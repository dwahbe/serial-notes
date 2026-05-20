import Foundation

struct CallEndStateMachine: Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case monitoring
        case inactiveGrace(inactiveAt: Date)
        case prompting(inactiveAt: Date, remainingSeconds: Int)
        case suppressed
    }

    enum Effect: Equatable, Sendable {
        case startGraceTimer(inactiveAt: Date)
        case cancelEndTimers
        case startCountdown(inactiveAt: Date, remainingSeconds: Int)
        case updateCountdown(remainingSeconds: Int)
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

    init(inactiveGraceSeconds: TimeInterval = 10, countdownSeconds: Int = 20) {
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
        phase = .prompting(inactiveAt: inactiveAt, remainingSeconds: countdownSeconds)
        return [.startCountdown(inactiveAt: inactiveAt, remainingSeconds: countdownSeconds)]
    }

    mutating func countdownTick(remainingSeconds: Int) -> [Effect] {
        guard case .prompting(let inactiveAt, _) = phase else { return [] }
        phase = .prompting(inactiveAt: inactiveAt, remainingSeconds: remainingSeconds)
        return [.updateCountdown(remainingSeconds: remainingSeconds)]
    }

    mutating func countdownFinished() -> [Effect] {
        guard let association,
              case .prompting(let inactiveAt, _) = phase else {
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

    mutating func stopNow() -> [Effect] {
        guard let association else { return [] }
        let inactiveAt = firstInactiveAt ?? Date()
        phase = .suppressed
        let context = MeetingCallEndContext(
            appName: association.appName,
            bundleIdentifier: association.bundleIdentifier,
            inactiveAt: inactiveAt
        )
        return [.hidePrompt, .stop(.callEndedUserConfirmed(context))]
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
