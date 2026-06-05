import Foundation

enum RecordingStopReason: Equatable, Sendable {
    case manual
    case callEndedAuto(MeetingCallEndContext)
    case appQuit

    var summaryCutoffDate: Date? {
        switch self {
        case .manual, .appQuit:
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
        }
    }
}

struct MeetingCallEndContext: Codable, Equatable, Sendable {
    let appName: String
    let bundleIdentifier: String
    let inactiveAt: Date
}
