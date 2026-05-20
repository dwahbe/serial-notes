import Foundation

struct MeetingRecordingAssociation: Codable, Equatable, Sendable {
    let appName: String
    let bundleIdentifier: String
    let startedAt: Date
}

struct MeetingAudioProcessSnapshot: Codable, Equatable, Sendable {
    let processObjectID: UInt32
    let pid: Int32?
    let coreAudioBundleIdentifier: String?
    let appBundleIdentifier: String?
    let appName: String?
    let isRunningInput: Bool
    let isRunningOutput: Bool

    var isActive: Bool {
        isRunningInput || isRunningOutput
    }
}

struct MeetingAudioActivitySnapshot: Codable, Equatable, Sendable {
    let observedAt: Date
    let matchedProcesses: [MeetingAudioProcessSnapshot]

    var isActive: Bool {
        matchedProcesses.contains { $0.isActive }
    }
}

enum MeetingAudioActivityState: Equatable, Sendable {
    case active(MeetingAudioActivitySnapshot)
    case inactive(MeetingAudioActivitySnapshot)
    case unknown(reason: String, observedAt: Date)

    var observedAt: Date {
        switch self {
        case .active(let snapshot), .inactive(let snapshot):
            return snapshot.observedAt
        case .unknown(_, let observedAt):
            return observedAt
        }
    }
}

struct MeetingSessionDiagnostics: Codable, Sendable {
    var association: MeetingRecordingAssociation?
    var lastMatchedProcesses: [MeetingAudioProcessSnapshot] = []
    var firstActiveAt: Date?
    var firstInactiveAt: Date?
    var promptShownAt: Date?
    var autoStopFiredAt: Date?
    var userConfirmedStopAt: Date?
    var keptRecordingAt: Date?
    var neverObservedActiveWarningAt: Date?
    var lastUnknownReason: String?
    var stopReason: String?

    var shouldWriteSidecar: Bool {
        association != nil
    }
}
