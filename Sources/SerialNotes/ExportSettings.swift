import Foundation

/// A notes destination Serial Notes can push a finished transcript *into* after
/// each meeting ("direct send"), as opposed to just writing the Markdown to a
/// folder — Apple Notes (AppleScript), Bear (x-callback-url), and Notion (the
/// Markdown Content API over the user's OAuth connection; the one target that
/// sends content off-device, opt-in like the rest).
enum ExportTarget: String, Sendable, CaseIterable {
    case appleNotes
    case bear
    case notion

    var displayName: String {
        switch self {
        case .appleNotes: return "Apple Notes"
        case .bear: return "Bear"
        case .notion: return "Notion"
        }
    }

    /// Bundle IDs used to detect whether the target app is installed. For
    /// Notion this only locates the desktop app's icon — availability is
    /// "connected", not "installed" (`MeetingExporter.isInstalled` gating
    /// doesn't apply; the export is a web API call).
    var bundleIDs: [String] {
        switch self {
        case .appleNotes: return ["com.apple.Notes"]
        case .bear: return ["net.shinyfrog.bear"]
        case .notion: return ["notion.id"]
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
    private static let notionKey = "export.sendToNotion"

    /// Backing store. Injectable (mirroring `ManualNotesStore`) so tests use an
    /// isolated suite instead of the shared `.standard` domain — otherwise a
    /// toggle one test persists leaks into another that constructs its own
    /// `ExportSettings`.
    @ObservationIgnored private let defaults: UserDefaults

    var sendToAppleNotes: Bool {
        didSet {
            defaults.set(sendToAppleNotes, forKey: Self.appleNotesKey)
        }
    }

    var sendToBear: Bool {
        didSet {
            defaults.set(sendToBear, forKey: Self.bearKey)
        }
    }

    var sendToNotion: Bool {
        didSet {
            defaults.set(sendToNotion, forKey: Self.notionKey)
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        self.sendToAppleNotes = userDefaults.object(forKey: Self.appleNotesKey) as? Bool ?? false
        self.sendToBear = userDefaults.object(forKey: Self.bearKey) as? Bool ?? false
        self.sendToNotion = userDefaults.object(forKey: Self.notionKey) as? Bool ?? false
    }

    /// The currently-enabled targets, snapshotted into the stop context at stop
    /// time so a mid-finalization toggle can't change what gets exported.
    var activeTargets: Set<ExportTarget> {
        var targets: Set<ExportTarget> = []
        if sendToAppleNotes { targets.insert(.appleNotes) }
        if sendToBear { targets.insert(.bear) }
        if sendToNotion { targets.insert(.notion) }
        return targets
    }

    func setEnabled(_ target: ExportTarget, _ enabled: Bool) {
        switch target {
        case .appleNotes: sendToAppleNotes = enabled
        case .bear: sendToBear = enabled
        case .notion: sendToNotion = enabled
        }
    }
}
