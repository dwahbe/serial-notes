import CoreAudio
import Foundation

@MainActor
final class MeetingAudioActivityMonitor {
    var onActivityChanged: ((MeetingAudioActivityState) -> Void)?

    private var association: MeetingRecordingAssociation?
    private var matcher: MeetingAudioProcessMatcher?
    private var hasObservedActive = false
    private let cleanup = MeetingAudioActivityMonitorCleanup()

    func startMonitoring(association: MeetingRecordingAssociation) {
        stopMonitoring()
        self.association = association
        self.matcher = MeetingAudioProcessMatcher(association: association)
        registerProcessListListener()
        refreshProcessListenersAndNotify()
    }

    func stopMonitoring() {
        cleanup.removeAll()
        association = nil
        matcher = nil
        hasObservedActive = false
    }

    private func registerProcessListListener() {
        var addr = MeetingAudioProcessReader.makeProcessObjectListAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.refreshProcessListenersAndNotify()
                }
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
            notify(.unknown(reason: "Failed to install process-list listener: \(status)", observedAt: Date()))
        }
    }

    private func refreshProcessListenersAndNotify() {
        guard let matcher else { return }
        let snapshots: [MeetingAudioProcessSnapshot]
        do {
            snapshots = try readMatchedSnapshots(matcher: matcher)
        } catch {
            notify(.unknown(reason: error.localizedDescription, observedAt: Date()))
            return
        }

        let matchedProcessIDs = Set(snapshots.map(\.processObjectID))
        cleanup.removeProcessListeners(excluding: matchedProcessIDs)
        for processID in matchedProcessIDs where !cleanup.isTracking(processID) {
            installActivityListeners(for: processID)
        }

        notifyState(from: snapshots, observedAt: Date())
    }

    private func installActivityListeners(for processID: AudioObjectID) {
        for selector in [kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput] {
            var addr = MeetingAudioProcessReader.makeProcessAddress(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.notifyCurrentState()
                    }
                }
            }
            let status = AudioObjectAddPropertyListenerBlock(
                processID,
                &addr,
                DispatchQueue.main,
                block
            )
            if status == noErr {
                cleanup.append(.init(processID: processID, selector: selector, block: block))
            }
        }
    }

    private func notifyCurrentState() {
        guard let matcher else { return }
        let snapshots: [MeetingAudioProcessSnapshot]
        do {
            snapshots = try readMatchedSnapshots(
                matcher: matcher,
                processIDs: Array(cleanup.trackedProcessIDs)
            )
        } catch {
            notify(.unknown(reason: error.localizedDescription, observedAt: Date()))
            return
        }

        notifyState(from: snapshots, observedAt: Date())
    }

    private func notifyState(from snapshots: [MeetingAudioProcessSnapshot], observedAt: Date) {
        if !snapshots.isEmpty {
            let snapshot = MeetingAudioActivitySnapshot(
                observedAt: observedAt,
                matchedProcesses: snapshots
            )
            if snapshot.isActive {
                hasObservedActive = true
                notify(.active(snapshot))
            } else if hasObservedActive {
                notify(.inactive(snapshot))
            } else {
                notify(.unknown(
                    reason: "Matching CoreAudio process has not become active",
                    observedAt: observedAt
                ))
            }
            return
        }

        if hasObservedActive {
            let snapshot = MeetingAudioActivitySnapshot(observedAt: observedAt, matchedProcesses: [])
            notify(.inactive(snapshot))
        } else {
            notify(.unknown(reason: "No matching CoreAudio process objects", observedAt: observedAt))
        }
    }

    private func notify(_ state: MeetingAudioActivityState) {
        onActivityChanged?(state)
    }

    private func readMatchedSnapshots(
        matcher: MeetingAudioProcessMatcher,
        processIDs providedProcessIDs: [AudioObjectID]? = nil
    ) throws -> [MeetingAudioProcessSnapshot] {
        let processIDs: [AudioObjectID]
        if let providedProcessIDs {
            processIDs = providedProcessIDs
        } else {
            processIDs = try MeetingAudioProcessReader.readProcessObjectList()
        }
        return processIDs.compactMap { processID -> MeetingAudioProcessSnapshot? in
            let snapshot = MeetingAudioProcessReader.snapshot(processID: processID)
            return matcher.matches(snapshot) ? snapshot : nil
        }
    }
}

/// Decides whether a CoreAudio process snapshot belongs to the meeting app a
/// recording is associated with. Rather than reimplement the exact /
/// substring / display-name rules, it defers to the single shared mapper
/// (`MeetingDetectionService.knownMeetingAppBundleID(for:)`) and asks whether
/// the resolved app is one of the association's related bundle IDs — so the
/// call-end monitor and the start-attribution path can never drift.
private struct MeetingAudioProcessMatcher {
    let relatedBundleIDs: Set<String>

    init(association: MeetingRecordingAssociation) {
        relatedBundleIDs = MeetingDetectionService.relatedBundleIDs(for: association)
    }

    func matches(_ snapshot: MeetingAudioProcessSnapshot) -> Bool {
        guard let bundleID = MeetingDetectionService.knownMeetingAppBundleID(for: snapshot) else {
            return false
        }
        return relatedBundleIDs.contains(bundleID)
    }
}

private final class MeetingAudioActivityMonitorCleanup: @unchecked Sendable {
    struct ProcessBlock: @unchecked Sendable {
        let processID: AudioObjectID
        let selector: AudioObjectPropertySelector
        let block: AudioObjectPropertyListenerBlock
    }

    var processListBlock: AudioObjectPropertyListenerBlock?
    var processBlocksByProcessID: [AudioObjectID: [ProcessBlock]] = [:]

    var trackedProcessIDs: Set<AudioObjectID> {
        Set(processBlocksByProcessID.keys)
    }

    func isTracking(_ processID: AudioObjectID) -> Bool {
        processBlocksByProcessID[processID] != nil
    }

    func append(_ processBlock: ProcessBlock) {
        processBlocksByProcessID[processBlock.processID, default: []].append(processBlock)
    }

    func removeAll() {
        if let processListBlock {
            // Address must byte-match the one used to add the listener — go
            // through the shared maker so add/remove can't drift.
            var addr = MeetingAudioProcessReader.makeProcessObjectListAddress()
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                DispatchQueue.main,
                processListBlock
            )
        }
        processListBlock = nil
        removeProcessListeners()
    }

    func removeProcessListeners(excluding retainedProcessIDs: Set<AudioObjectID>) {
        for processID in trackedProcessIDs where !retainedProcessIDs.contains(processID) {
            removeProcessListeners(for: processID)
        }
    }

    func removeProcessListeners() {
        for processID in trackedProcessIDs {
            removeProcessListeners(for: processID)
        }
    }

    private func removeProcessListeners(for processID: AudioObjectID) {
        let processBlocks = processBlocksByProcessID[processID] ?? []
        for processBlock in processBlocks {
            var addr = MeetingAudioProcessReader.makeProcessAddress(processBlock.selector)
            AudioObjectRemovePropertyListenerBlock(
                processBlock.processID,
                &addr,
                DispatchQueue.main,
                processBlock.block
            )
        }
        processBlocksByProcessID[processID] = nil
    }

    deinit {
        removeAll()
    }
}
