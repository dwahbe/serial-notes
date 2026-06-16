import AppKit
import Foundation

@MainActor @Observable
final class StorageSettings {
    private static let storageKey = "storageLocation"
    private static let saveAudioFilesKey = "storage.saveAudioFiles"

    var storageLocation: URL {
        didSet {
            UserDefaults.standard.set(storageLocation.path(percentEncoded: false), forKey: Self.storageKey)
        }
    }

    var saveAudioFiles: Bool {
        didSet {
            UserDefaults.standard.set(saveAudioFiles, forKey: Self.saveAudioFilesKey)
        }
    }

    var storageLocationName: String {
        storageLocation.lastPathComponent
    }

    init() {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: Self.storageKey) {
            self.storageLocation = URL(fileURLWithPath: path)
        } else {
            self.storageLocation = Self.defaultLocation
        }
        self.saveAudioFiles = defaults.object(forKey: Self.saveAudioFilesKey) as? Bool ?? true
    }

    private static var defaultLocation: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/SerialNotes")
    }

    // MARK: - Quick destinations

    /// `~/Library/Mobile Documents/com~apple~CloudDocs`, or nil when iCloud Drive
    /// is turned off. Preferred home for synced apps (Apple Notes/Notion import,
    /// iCloud-hosted Obsidian vaults) so notes follow the user across devices.
    nonisolated static var iCloudDriveURL: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    nonisolated static var documentsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
    }

    /// Create `base/folderName` (idempotent) and point storage at it — the backing
    /// for the setup guide's one-click destination tiles, so people pick a home
    /// instead of hand-navigating a folder panel. Returns the resolved folder, or
    /// nil if the directory couldn't be created.
    @discardableResult
    func useFolder(in base: URL, named folderName: String) -> URL? {
        let target = base.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        storageLocation = target
        return target
    }

    /// Show the folder panel and adopt the chosen directory. Returns `true` when
    /// the user picked a folder, `false` if they cancelled — so callers (the setup
    /// guide) can show a confirmation only on a real selection.
    @discardableResult
    func pickFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.canSelectHiddenExtension = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Select"
        panel.message = "Choose where to save recordings"
        if FileManager.default.fileExists(atPath: storageLocation.path) {
            panel.directoryURL = storageLocation
        }

        // Stay `.accessory`; activating brings the modal panel to the front.
        NSApp.activate()
        panel.level = .modalPanel

        var picked = false
        if panel.runModal() == .OK, let url = panel.url {
            storageLocation = url
            picked = true
        }
        return picked
    }
}
