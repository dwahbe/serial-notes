import Foundation

enum RecordingStopReason: Equatable, Sendable {
    case manual
    case callEndedAuto(MeetingCallEndContext)
    case callEndedUserConfirmed(MeetingCallEndContext)
    case appQuit

    var summaryCutoffDate: Date? {
        switch self {
        case .manual, .appQuit:
            return nil
        case .callEndedAuto(let context), .callEndedUserConfirmed(let context):
            return context.inactiveAt
        }
    }

    var diagnosticsValue: String {
        switch self {
        case .manual:
            return "manual"
        case .callEndedAuto:
            return "callEndedAuto"
        case .callEndedUserConfirmed:
            return "callEndedUserConfirmed"
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
