import Foundation
import Testing

@testable import SerialNotes

@Suite("Call End State Machine")
struct CallEndStateMachineTests {
    private let association = MeetingRecordingAssociation(
        appName: "Zoom",
        bundleIdentifier: "us.zoom.xos",
        startedAt: Date(timeIntervalSince1970: 100)
    )

    @Test("Unknown state does not prompt before first observed active")
    func unknownDoesNotPromptBeforeFirstObservedActive() {
        var machine = CallEndStateMachine()
        _ = machine.startRecording(association: association, autoStopEnabled: true)

        let effects = machine.receiveActivity(.unknown(
            reason: "Matching CoreAudio process has not become active",
            observedAt: Date(timeIntervalSince1970: 105)
        ))

        #expect(effects.isEmpty)
    }

    @Test("Inactive starts grace after observed active")
    func inactiveStartsGraceAfterObservedActive() {
        var machine = CallEndStateMachine()
        _ = machine.startRecording(association: association, autoStopEnabled: true)
        _ = machine.receiveActivity(.active(snapshot(at: 101, active: true)))

        let inactiveAt = Date(timeIntervalSince1970: 110)
        let effects = machine.receiveActivity(.inactive(snapshot(at: 110, active: false)))

        #expect(effects == [.startGraceTimer(inactiveAt: inactiveAt)])
    }

    @Test("Activity resume cancels grace")
    func activityResumeCancelsGrace() {
        var machine = CallEndStateMachine()
        _ = machine.startRecording(association: association, autoStopEnabled: true)
        _ = machine.receiveActivity(.active(snapshot(at: 101, active: true)))
        _ = machine.receiveActivity(.inactive(snapshot(at: 110, active: false)))

        let effects = machine.receiveActivity(.active(snapshot(at: 112, active: true)))

        #expect(effects == [.cancelEndTimers])
    }

    @Test("Grace completion starts countdown")
    func graceCompletionStartsCountdown() {
        var machine = CallEndStateMachine(countdownSeconds: 20)
        _ = machine.startRecording(association: association, autoStopEnabled: true)
        _ = machine.receiveActivity(.active(snapshot(at: 101, active: true)))
        let inactiveAt = Date(timeIntervalSince1970: 110)
        _ = machine.receiveActivity(.inactive(snapshot(at: 110, active: false)))

        let effects = machine.graceTimerFired(inactiveAt: inactiveAt)

        #expect(effects == [.startCountdown])
    }

    @Test("Countdown completion auto stops with inactive cutoff")
    func countdownCompletionAutoStopsWithInactiveCutoff() {
        var machine = CallEndStateMachine(countdownSeconds: 20)
        _ = machine.startRecording(association: association, autoStopEnabled: true)
        _ = machine.receiveActivity(.active(snapshot(at: 101, active: true)))
        let inactiveAt = Date(timeIntervalSince1970: 110)
        _ = machine.receiveActivity(.inactive(snapshot(at: 110, active: false)))
        _ = machine.graceTimerFired(inactiveAt: inactiveAt)

        let effects = machine.countdownFinished()

        let context = MeetingCallEndContext(
            appName: "Zoom",
            bundleIdentifier: "us.zoom.xos",
            inactiveAt: inactiveAt
        )
        #expect(effects == [.hidePrompt, .stop(.callEndedAuto(context))])
    }

    @Test("Keep recording suppresses only the current recording")
    func keepRecordingSuppressesCurrentRecording() {
        var machine = CallEndStateMachine()
        _ = machine.startRecording(association: association, autoStopEnabled: true)

        let effects = machine.keepRecording()

        #expect(effects == [.cancelEndTimers, .hidePrompt, .stopMonitoring])
        _ = machine.startRecording(association: association, autoStopEnabled: true)
        _ = machine.receiveActivity(.active(snapshot(at: 130, active: true)))
        let newInactiveAt = Date(timeIntervalSince1970: 140)
        let newEffects = machine.receiveActivity(.inactive(snapshot(at: 140, active: false)))
        #expect(newEffects == [.startGraceTimer(inactiveAt: newInactiveAt)])
    }

    @Test("Unknown state never counts as inactivity")
    func unknownDoesNotCountAsInactivity() {
        var machine = CallEndStateMachine()
        _ = machine.startRecording(association: association, autoStopEnabled: true)
        _ = machine.receiveActivity(.active(snapshot(at: 101, active: true)))

        let effects = machine.receiveActivity(.unknown(
            reason: "No matching process",
            observedAt: Date(timeIntervalSince1970: 110)
        ))

        #expect(effects.isEmpty)
    }

    private func snapshot(at timestamp: TimeInterval, active: Bool) -> MeetingAudioActivitySnapshot {
        MeetingAudioActivitySnapshot(
            observedAt: Date(timeIntervalSince1970: timestamp),
            matchedProcesses: [
                MeetingAudioProcessSnapshot(
                    processObjectID: 1,
                    pid: 42,
                    coreAudioBundleIdentifier: "us.zoom.xos",
                    appBundleIdentifier: "us.zoom.xos",
                    appName: "Zoom",
                    isRunningInput: active,
                    isRunningOutput: false
                )
            ]
        )
    }
}
