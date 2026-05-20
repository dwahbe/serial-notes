import Foundation
import Testing

@testable import SerialNotes

@Suite("Meeting Audio Activity Monitor", .serialized)
struct MeetingAudioActivityMonitorTests {
    @Test("Process-list monitoring starts and stops without crashing")
    @MainActor
    func processListMonitoringStartsAndStops() {
        let monitor = MeetingAudioActivityMonitor()
        let association = MeetingRecordingAssociation(
            appName: "Impossible Meeting App",
            bundleIdentifier: "com.serialnotes.impossible-meeting-app",
            startedAt: Date()
        )
        var observedState: MeetingAudioActivityState?
        monitor.onActivityChanged = { state in
            observedState = state
        }

        monitor.startMonitoring(association: association)
        monitor.stopMonitoring()

        #expect(observedState != nil)
    }
}
