import AppKit
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
        var addr = Self.makeProcessObjectListAddress()
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
            var addr = Self.makeProcessAddress(selector)
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
            processIDs = try Self.readProcessObjectList()
        }
        return processIDs.compactMap { processID -> MeetingAudioProcessSnapshot? in
            let snapshot = Self.snapshot(processID: processID)
            return matcher.matches(snapshot) ? snapshot : nil
        }
    }

    // MARK: - Matching

    // MARK: - CoreAudio Reads

    private static func makeProcessObjectListAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func makeProcessAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func readProcessObjectList() throws -> [AudioObjectID] {
        var addr = makeProcessObjectListAddress()
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size
        )
        guard sizeStatus == noErr else {
            throw MonitorError.coreAudio("AudioObjectGetPropertyDataSize(process list)", sizeStatus)
        }
        guard size >= MemoryLayout<AudioObjectID>.size else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var processIDs = Array(repeating: AudioObjectID(0), count: count)
        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &processIDs
        )
        guard dataStatus == noErr else {
            throw MonitorError.coreAudio("AudioObjectGetPropertyData(process list)", dataStatus)
        }
        return processIDs.filter { $0 != kAudioObjectUnknown }
    }

    private static func snapshot(processID: AudioObjectID) -> MeetingAudioProcessSnapshot {
        let pid = readPID(processID: processID)
        let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        return MeetingAudioProcessSnapshot(
            processObjectID: processID,
            pid: pid.map { Int32($0) },
            coreAudioBundleIdentifier: readBundleID(processID: processID),
            appBundleIdentifier: app?.bundleIdentifier,
            appName: app?.localizedName,
            isRunningInput: readRunningFlag(processID: processID, selector: kAudioProcessPropertyIsRunningInput),
            isRunningOutput: readRunningFlag(processID: processID, selector: kAudioProcessPropertyIsRunningOutput)
        )
    }

    private static func readPID(processID: AudioObjectID) -> pid_t? {
        var value = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)
        var addr = makeProcessAddress(kAudioProcessPropertyPID)
        let status = AudioObjectGetPropertyData(processID, &addr, 0, nil, &size, &value)
        guard status == noErr, value > 0 else { return nil }
        return value
    }

    private static func readBundleID(processID: AudioObjectID) -> String? {
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = makeProcessAddress(kAudioProcessPropertyBundleID)
        let status = AudioObjectGetPropertyData(processID, &addr, 0, nil, &size, &unmanaged)
        guard status == noErr, let unmanaged else { return nil }
        return unmanaged.takeRetainedValue() as String
    }

    private static func readRunningFlag(
        processID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = makeProcessAddress(selector)
        let status = AudioObjectGetPropertyData(processID, &addr, 0, nil, &size, &value)
        return status == noErr && value != 0
    }
}

private enum MonitorError: LocalizedError {
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .coreAudio(let operation, let status):
            return "\(operation) failed with status \(status)"
        }
    }
}

private struct MeetingAudioProcessMatcher {
    let appName: String
    let exactBundleIDs: Set<String>
    let bundleSubstrings: [String]

    init(association: MeetingRecordingAssociation) {
        appName = association.appName.lowercased()
        let app = MeetingDetectionService.knownMeetingApps[association.bundleIdentifier]
        let displayName = app?.displayName ?? association.appName
        let relatedApps = MeetingDetectionService.knownMeetingApps.filter { _, knownApp in
            knownApp.displayName == displayName
        }
        var exactBundleIDs = Set(relatedApps.map(\.key))
        exactBundleIDs.insert(association.bundleIdentifier)
        self.exactBundleIDs = exactBundleIDs
        self.bundleSubstrings = Array(
            Set(relatedApps.flatMap { $0.value.coreAudioBundleSubstrings }.map { $0.lowercased() })
        )
    }

    func matches(_ snapshot: MeetingAudioProcessSnapshot) -> Bool {
        if let bundleID = snapshot.coreAudioBundleIdentifier,
           bundleMatches(bundleID) {
            return true
        }
        if let bundleID = snapshot.appBundleIdentifier,
           bundleMatches(bundleID) {
            return true
        }
        if let snapshotAppName = snapshot.appName?.lowercased(),
           snapshotAppName.contains(appName) {
            return true
        }
        return false
    }

    private func bundleMatches(_ bundleID: String) -> Bool {
        if exactBundleIDs.contains(bundleID) { return true }
        let lower = bundleID.lowercased()
        return bundleSubstrings.contains { lower.contains($0) }
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
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
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
            var addr = AudioObjectPropertyAddress(
                mSelector: processBlock.selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
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
