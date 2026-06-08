import AppKit
import CoreAudio
import Foundation

/// Shared CoreAudio reads for per-process audio activity.
///
/// Two callers depend on the same process-object plumbing and must not drift:
///   · `MeetingAudioActivityMonitor` — call-*end* monitoring of the one app a
///     recording is associated with.
///   · `MeetingDetectionService` — start-time attribution: which *known* meeting
///     app is actually capturing the mic right now.
///
/// Both go through this enum so there is a single source of truth for the
/// `kAudioHardwarePropertyProcessObjectList` / `kAudioProcessProperty*` reads.
enum MeetingAudioProcessReader {
    enum ReadError: LocalizedError {
        case coreAudio(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .coreAudio(let operation, let status):
                return "\(operation) failed with status \(status)"
            }
        }
    }

    static func makeProcessObjectListAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func makeProcessAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func readProcessObjectList() throws -> [AudioObjectID] {
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
            throw ReadError.coreAudio("AudioObjectGetPropertyDataSize(process list)", sizeStatus)
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
            throw ReadError.coreAudio("AudioObjectGetPropertyData(process list)", dataStatus)
        }
        return processIDs.filter { $0 != kAudioObjectUnknown }
    }

    static func snapshot(processID: AudioObjectID) -> MeetingAudioProcessSnapshot {
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
