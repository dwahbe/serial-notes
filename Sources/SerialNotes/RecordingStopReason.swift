import Foundation

enum RecordingStopReason: Equatable, Sendable {
    case manual
    case callEndedAuto(MeetingCallEndContext)
    case appQuit
    /// The capture engine died mid-recording (stream error, file-write failure).
    /// The session is stopped and finalized with whatever audio was captured.
    case captureFailed

    var summaryCutoffDate: Date? {
        switch self {
        case .manual, .appQuit, .captureFailed:
            return nil
        case .callEndedAuto(let context):
            return context.inactiveAt
        }
    }

    var isAppQuit: Bool {
        if case .appQuit = self { return true }
        return false
    }

    var diagnosticsValue: String {
        switch self {
        case .manual:
            return "manual"
        case .callEndedAuto:
            return "callEndedAuto"
        case .appQuit:
            return "appQuit"
        case .captureFailed:
            return "captureFailed"
        }
    }
}

struct MeetingCallEndContext: Codable, Equatable, Sendable {
    let appName: String
    let bundleIdentifier: String
    let inactiveAt: Date
}
