import AppKit
import Foundation

/// A one-click "where should notes live" choice in the first-run setup guide. Apps
/// the user already has appear as branded tiles (real icon pulled from the
/// installed app via `NSWorkspace`); choosing one creates the notes folder in the
/// right place for that app and yields a plain-language confirmation line.
///
/// The honest split (mirrors the site's "compatible with" strip — every app can
/// *read* Markdown, but only some read it from a folder):
///   - **folder apps** (Obsidian, Logseq) read a folder of `.md` directly, so the
///     notes folder lives *inside* the vault/graph and shows up in the app;
///   - **import apps** (Apple Notes, Notion, Bear) keep notes in a private
///     database — for these the tile enables direct send (`pushTarget`) where
///     one exists; a plain folder pick means manual import.
struct NotesDestination: Identifiable {
    enum Kind {
        case folderApp  // Obsidian, Logseq — notes land inside the vault/graph
        case importApp  // Apple Notes, Notion, Bear — synced folder + manual import
        case location   // iCloud Drive, Documents — a plain folder
    }

    let id: String
    let name: String
    let kind: Kind
    /// Bundle IDs probed in order; the first installed one supplies the icon and,
    /// for folder apps, the vault search. Empty for non-app destinations.
    var bundleIDs: [String] = []
    /// SF Symbol used for non-app destinations (locations) — and as the icon
    /// fallback for a destination that isn't installed-gated (Notion is a web
    /// integration, offered even when its desktop app is absent).
    var symbol: String?
    /// When set, this tile *pushes notes straight into the destination* after each
    /// meeting instead of writing to a folder — Apple Notes and Bear locally (see
    /// `MeetingExporter`), Notion via its API over the user's OAuth connection.
    var pushTarget: ExportTarget?
}

// MARK: - Catalog

extension NotesDestination {
    /// The note apps from the site's "compatible with" strip. Apple Notes ships
    /// with macOS so it's always offered; the rest surface only when installed
    /// (see `availableApps`). Order matches the website.
    // Push-app rows derive their bundle IDs from `ExportTarget` so install
    // detection can't drift between the onboarding tile and the Settings toggle.
    static let knownApps: [NotesDestination] = [
        NotesDestination(id: "apple-notes", name: "Apple Notes", kind: .importApp, bundleIDs: ExportTarget.appleNotes.bundleIDs, pushTarget: .appleNotes),
        NotesDestination(id: "obsidian", name: "Obsidian", kind: .folderApp, bundleIDs: ["md.obsidian"]),
        NotesDestination(id: "notion", name: "Notion", kind: .importApp, bundleIDs: ExportTarget.notion.bundleIDs, symbol: "n.square", pushTarget: .notion),
        NotesDestination(id: "bear", name: "Bear", kind: .importApp, bundleIDs: ExportTarget.bear.bundleIDs, pushTarget: .bear),
        NotesDestination(id: "logseq", name: "Logseq", kind: .folderApp, bundleIDs: ["com.logseq.logseq", "com.electron.logseq"]),
    ]

    /// Generic folder destinations always offered after the app tiles.
    static var locations: [NotesDestination] {
        var out: [NotesDestination] = []
        if StorageSettings.iCloudDriveURL != nil {
            out.append(NotesDestination(id: "icloud", name: "iCloud Drive", kind: .location, symbol: "icloud"))
        }
        out.append(NotesDestination(id: "documents", name: "Documents", kind: .location, symbol: "folder"))
        return out
    }

    /// Apps the user actually has installed, with Apple Notes always present
    /// (ships with macOS) and Notion always offered (a web-service integration
    /// — the connection, not the desktop app, is what matters). Built once per
    /// render of the storage step.
    static var availableApps: [NotesDestination] {
        knownApps.filter { $0.id == "apple-notes" || $0.id == "notion" || $0.installedAppURL != nil }
    }

    /// First installed bundle URL among `bundleIDs`, or nil.
    var installedAppURL: URL? {
        for id in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return url
            }
        }
        return nil
    }

    /// The installed app's real icon, or nil for non-app destinations / missing apps.
    var appIcon: NSImage? {
        guard let url = installedAppURL else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - Resolution

extension NotesDestination {
    /// Where a chosen destination puts the notes folder, plus how to describe it.
    struct SavePlan {
        /// Parent directory the notes folder is created inside.
        let base: URL
        /// What follows "in …" in the confirmation — an app name when the folder
        /// feeds the app directly (a detected Obsidian vault), otherwise the
        /// folder's location ("iCloud Drive", "Documents").
        let locationLabel: String
        /// Optional one-time step to actually see notes in the app.
        let hint: String?
    }

    /// Resolve where this destination's notes folder should live. iCloud Drive is
    /// preferred for synced/import apps so notes follow the user across devices,
    /// falling back to Documents when iCloud Drive is off.
    func savePlan(folderName: String) -> SavePlan {
        let syncedBase = StorageSettings.iCloudDriveURL ?? StorageSettings.documentsURL
        let syncedLabel = StorageSettings.iCloudDriveURL != nil ? "iCloud Drive" : "Documents"

        switch kind {
        case .location:
            let base = id == "icloud" ? (StorageSettings.iCloudDriveURL ?? StorageSettings.documentsURL) : StorageSettings.documentsURL
            return SavePlan(base: base, locationLabel: name, hint: nil)

        case .folderApp:
            // Obsidian: drop the folder straight into the user's vault so notes
            // appear in the app with no extra step.
            if id == "obsidian", let vault = Self.detectObsidianVault() {
                return SavePlan(base: vault, locationLabel: "Obsidian", hint: nil)
            }
            // No detectable vault/graph — stage it in a synced folder and tell the
            // user the one-time step to surface it in the app.
            let verb = id == "logseq" ? "graph" : "vault"
            return SavePlan(
                base: syncedBase,
                locationLabel: syncedLabel,
                hint: "Open “\(folderName)” as a \(verb) in \(name) to see your notes there."
            )

        case .importApp:
            return SavePlan(
                base: syncedBase,
                locationLabel: syncedLabel,
                hint: "Import the Markdown files into \(name) whenever you like."
            )
        }
    }

    /// The most-recently-opened Obsidian vault on disk, read from Obsidian's own
    /// `obsidian.json` registry. Returns nil when Obsidian isn't set up or the
    /// recorded vault no longer exists.
    static func detectObsidianVault() -> URL? {
        let registry = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard
            let data = try? Data(contentsOf: registry),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let vaults = root["vaults"] as? [String: [String: Any]]
        else { return nil }

        // Prefer the currently-open vault; otherwise the one opened most recently.
        let ranked = vaults.values.sorted { lhs, rhs in
            let lOpen = (lhs["open"] as? Bool) ?? false
            let rOpen = (rhs["open"] as? Bool) ?? false
            if lOpen != rOpen { return lOpen }
            let lTs = (lhs["ts"] as? Double) ?? 0
            let rTs = (rhs["ts"] as? Double) ?? 0
            return lTs > rTs
        }

        for vault in ranked {
            guard let path = vault["path"] as? String else { continue }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return nil
    }
}
