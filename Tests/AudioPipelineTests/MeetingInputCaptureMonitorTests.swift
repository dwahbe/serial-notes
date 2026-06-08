import Foundation
import Testing

@testable import SerialNotes

@Suite("Meeting Input Capture Monitor", .serialized)
struct MeetingInputCaptureMonitorTests {
    @Test("Input-capture monitoring starts and stops without crashing and emits a snapshot")
    @MainActor
    func startsAndStopsAndEmits() {
        let monitor = MeetingInputCaptureMonitor()
        var observed: Set<String>?
        monitor.onCapturingChanged = { owners in
            observed = owners
        }

        monitor.start()
        // The first scan always reports (nil → some set), even when nothing is
        // capturing, so we get a deterministic emission without a real meeting app.
        #expect(observed != nil)
        #expect(monitor.isRunning)

        monitor.stop()
        #expect(!monitor.isRunning)
    }
}
