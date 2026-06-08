import CoreAudio
import Foundation

/// Watches **every** known meeting app's processes and reports which canonical
/// bundle IDs are *currently capturing mic input*. This is the start-detection
/// counterpart to `MeetingAudioActivityMonitor` (which watches one association's
/// input **and** output for call-end). Input-only.
///
/// It mirrors that monitor's proven plumbing — a `kAudioHardwarePropertyProcessObjectList`
/// listener to learn about appearing/disappearing audio processes, per-process
/// `kAudioProcessPropertyIsRunningInput` listeners for instant start/stop edges, and
/// a polling safety net because those per-process notifications are unreliable for
/// some apps (notably Zoom). Listeners are installed on every *known meeting app*
/// process whether or not it is currently capturing, so a false→true transition is
/// caught the instant it happens rather than only on the next poll.
///
/// Emits `onCapturingChanged` with the deduped set of capturing canonical bundle
/// IDs; `MeetingStartDetector` turns that stream into edge-triggered prompts.
@MainActor
final class MeetingInputCaptureMonitor {
    var onCapturingChanged: ((Set<String>) -> Void)?

    private(set) var isRunning = false
    private var lastReported: Set<String>?
    private var pollTask: Task<Void, Never>?
    private let cleanup = ProcessInputListenerCleanup()

    /// Safety-net poll cadence — bounds worst-case latency when a per-process
    /// `IsRunningInput` notification is dropped. Short enough to keep start-prompt
    /// latency within a couple of seconds (see plan), cheap enough at idle.
    private let pollInterval: Duration = .seconds(1.5)

    func start() {
        stop()
        isRunning = true
        registerProcessListListener()
        refreshAndNotify()
        startPolling()
    }

    func stop() {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        cleanup.removeAll()
        lastReported = nil
    }

    private func startPolling() {
        pollTask?.cancel()
        let interval = pollInterval
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.isRunning else { return }
                self.refreshAndNotify()
            }
        }
    }

    private func registerProcessListListener() {
        var addr = MeetingAudioProcessReader.makeProcessObjectListAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.refreshAndNotify() }
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.main,
            block
        )
        if status == noErr {
            cleanup.processListBlock = block
        } else {
            // Without the process-list listener we fall back to the poll alone —
            // log it so a silently-degraded (poll-only) mode is diagnosable.
            NSLog("[SerialNotes/MeetingInput] process-list listener registration failed status=\(status); relying on poll")
        }
    }

    private func refreshAndNotify() {
        guard isRunning else { return }

        // A failed process-list read (transient HAL error, or the per-process API
        // being unavailable) must NOT be reported as "nothing capturing": emitting
        // an empty set would make MeetingStartDetector treat an ongoing call as
        // ended — clearing dismiss-suppression and re-prompting once the read
        // recovers. Preserve the last-known set instead (mirrors how
        // MeetingAudioActivityMonitor emits .unknown rather than .inactive on a
        // read failure).
        guard let processIDs = try? MeetingAudioProcessReader.readProcessObjectList() else {
            return
        }

        // Resolve every audio process to its known meeting app (if any). We keep the
        // non-capturing matches too, so we can install start-edge listeners on them.
        var matchedSnapshots: [MeetingAudioProcessSnapshot] = []
        for processID in processIDs {
            let snapshot = MeetingAudioProcessReader.snapshot(processID: processID)
            if MeetingDetectionService.knownMeetingAppBundleID(for: snapshot) != nil {
                matchedSnapshots.append(snapshot)
            }
        }

        let matchedProcessIDs = Set(matchedSnapshots.map(\.processObjectID))
        cleanup.removeProcessListeners(excluding: matchedProcessIDs)
        for processID in matchedProcessIDs where !cleanup.isTracking(processID) {
            installInputListener(for: processID)
        }

        let owners = MeetingDetectionService.meetingAppsCapturingInput(from: matchedSnapshots)
        if owners != lastReported {
            lastReported = owners
            onCapturingChanged?(owners)
        }
    }

    private func installInputListener(for processID: AudioObjectID) {
        var addr = MeetingAudioProcessReader.makeProcessAddress(kAudioProcessPropertyIsRunningInput)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.refreshAndNotify() }
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            processID,
            &addr,
            DispatchQueue.main,
            block
        )
        if status == noErr {
            cleanup.append(processID: processID, block: block)
        }
    }
}

/// Registration bookkeeping for the input-capture monitor's CoreAudio listeners.
/// A focused sibling of `MeetingAudioActivityMonitorCleanup` (call-end) — duplicated
/// rather than shared so the working call-end monitor is left untouched. Lives in a
/// nonisolated reference type so its `deinit` can call the thread-safe removal APIs.
private final class ProcessInputListenerCleanup: @unchecked Sendable {
    var processListBlock: AudioObjectPropertyListenerBlock?
    private var blocksByProcessID: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

    func isTracking(_ processID: AudioObjectID) -> Bool {
        blocksByProcessID[processID] != nil
    }

    func append(processID: AudioObjectID, block: @escaping AudioObjectPropertyListenerBlock) {
        blocksByProcessID[processID] = block
    }

    func removeProcessListeners(excluding retained: Set<AudioObjectID>) {
        for processID in blocksByProcessID.keys where !retained.contains(processID) {
            remove(processID: processID)
        }
    }

    func removeAll() {
        if let processListBlock {
            var addr = MeetingAudioProcessReader.makeProcessObjectListAddress()
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                DispatchQueue.main,
                processListBlock
            )
        }
        processListBlock = nil
        for processID in Array(blocksByProcessID.keys) {
            remove(processID: processID)
        }
    }

    private func remove(processID: AudioObjectID) {
        guard let block = blocksByProcessID[processID] else { return }
        var addr = MeetingAudioProcessReader.makeProcessAddress(kAudioProcessPropertyIsRunningInput)
        AudioObjectRemovePropertyListenerBlock(processID, &addr, DispatchQueue.main, block)
        blocksByProcessID[processID] = nil
    }

    deinit {
        removeAll()
    }
}
