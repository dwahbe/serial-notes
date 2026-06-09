import Foundation

/// A notes app Serial Notes can push a finished transcript *into* after each
/// meeting (Phase 2 "direct send"), as opposed to just writing the Markdown to a
/// folder. Only apps that can genuinely receive a note programmatically and
/// locally belong here — Apple Notes (AppleScript) and Bear (x-callback-url).
enum ExportTarget: String, Sendable, CaseIterable {
    case appleNotes
    case bear

    var displayName: String {
        switch self {
        case .appleNotes: return "Apple Notes"
        case .bear: return "Bear"
        }
    }

    /// Bundle IDs used to detect whether the target app is installed.
    var bundleIDs: [String] {
        switch self {
        case .appleNotes: return ["com.apple.Notes"]
        case .bear: return ["net.shinyfrog.bear"]
        }
    }
}

/// Opt-in "send notes straight to an app after each meeting" toggles. Mirrors the
/// `SummarySettings` shape (UserDefaults-backed `@Observable`). Both default OFF —
/// pushing into a third-party app is opt-in. The on-disk transcript in the storage
/// folder is always written regardless; export is an *additional* delivery.
@MainActor @Observable
final class ExportSettings {
    private static let appleNotesKey = "export.sendToAppleNotes"
    private static let bearKey = "export.sendToBear"

    var sendToAppleNotes: Bool {
        didSet {
            UserDefaults.standard.set(sendToAppleNotes, forKey: Self.appleNotesKey)
        }
    }

    var sendToBear: Bool {
        didSet {
            UserDefaults.standard.set(sendToBear, forKey: Self.bearKey)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        self.sendToAppleNotes = defaults.object(forKey: Self.appleNotesKey) as? Bool ?? false
        self.sendToBear = defaults.object(forKey: Self.bearKey) as? Bool ?? false
    }

    /// The currently-enabled targets, snapshotted into the stop context at stop
    /// time so a mid-finalization toggle can't change what gets exported.
    var activeTargets: Set<ExportTarget> {
        var targets: Set<ExportTarget> = []
        if sendToAppleNotes { targets.insert(.appleNotes) }
        if sendToBear { targets.insert(.bear) }
        return targets
    }

    func setEnabled(_ target: ExportTarget, _ enabled: Bool) {
        switch target {
        case .appleNotes: sendToAppleNotes = enabled
        case .bear: sendToBear = enabled
        }
    }
}
