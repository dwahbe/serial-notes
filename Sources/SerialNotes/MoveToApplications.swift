import AppKit

/// First-launch "Move to Applications folder?" flow — a native, dependency-free
/// take on the well-worn LetsMove pattern.
///
/// **Why this exists:** users download `SerialNotes.dmg`, but some still drag the
/// app out to `~/Downloads` (or run it straight from the mounted image). A freshly
/// downloaded, quarantined app is *App-Translocated* by Gatekeeper — macOS runs it
/// from a random read-only mount under `…/AppTranslocation/…`. Sparkle can't update
/// an app that isn't sitting in a stable, writable location, which is exactly the
/// "Serial Notes can't be updated if it's running from the location it was
/// downloaded to" dead end. Relocating into `/Applications` once fixes auto-updates
/// for good. The DMG's drag-to-Applications layout is the primary nudge; this is the
/// backstop for everyone who skips it.
///
/// Two flavors: launched from a **read-only volume** (the mounted DMG) it installs
/// silently — running in place is never viable there, so double-click-in-the-DMG
/// becomes a one-action install (copy in → relaunch → first-run guide). Launched
/// from a **writable spot** (`~/Downloads`) it asks first, since running in place
/// is at least possible and the user may have meant it.
enum MoveToApplications {
    /// Set once the user declines, so we don't nag on every launch. Keyed only by
    /// the decline itself — if they later move the app into /Applications by hand,
    /// `isInApplicationsFolder` short-circuits before we'd ever read this.
    private static let declinedDefaultsKey = "moveToApplications.declined"

    /// Offer to move the app into /Applications when it's running from anywhere else.
    /// On a successful move this **exits the process** — the relocated copy relaunches
    /// itself — so it returns only when nothing was moved.
    ///
    /// `replaceConsentGiven` is true when `SingleInstanceGuard`'s Quit-and-Install
    /// prompt already covered replacing (and possibly downgrading) the installed
    /// copy this launch, so the downgrade confirmation isn't shown twice.
    @MainActor
    static func moveIfNeeded(replaceConsentGiven: Bool = false) {
        // Dev builds live in the repo's .build dir on purpose (run.sh owns their
        // lifecycle), and tests must never relocate anything.
        guard !Bundle.main.isDevBuild else { return }
        guard !Bundle.main.isRunningTests else { return }

        let bundleURL = Bundle.main.bundleURL
        guard !isInApplicationsFolder(bundleURL) else { return }

        let source = resolvedSource(of: bundleURL)
        let destination = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appendingPathComponent(bundleURL.lastPathComponent)

        if isReadOnlyInstallSource(source) {
            // The mounted DMG. The app can't live there — the volume ejects and
            // Sparkle can't write — so install without asking; the declined flag
            // only applies to the prompt below, not to this path. One exception:
            // confirm before silently *downgrading* a newer installed copy (old
            // DMGs linger in ~/Downloads), unless the guard's Quit-and-Install
            // prompt already said so.
            if !replaceConsentGiven && installWouldDowngrade() {
                guard promptToDowngrade(destination: destination) else { return }
            }
        } else {
            guard !UserDefaults.standard.bool(forKey: declinedDefaultsKey) else { return }
            guard promptToMove() else {
                UserDefaults.standard.set(true, forKey: declinedDefaultsKey)
                return
            }
        }

        do {
            try install(from: source, to: destination)
        } catch {
            presentMoveFailure(error)
            return
        }

        // Exits on success; returns only if the relaunch helper couldn't be spawned,
        // in which case we keep running in place (the /Applications copy is ready for
        // the next launch).
        relaunch(at: destination, removingOriginal: source)
    }

    // MARK: - Location checks

    /// True when the bundle already lives in a system or user Applications folder.
    private static func isInApplicationsFolder(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        var roots = ["/Applications"]
        if let userApps = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first {
            roots.append(userApps.resolvingSymlinksInPath().path)
        }
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// The true on-disk location this launch came from: the translocation origin
    /// when resolvable, otherwise the bundle URL itself. (`internal` so
    /// `SingleInstanceGuard` derives install intent from the exact same recipe.)
    static func resolvedSource(of bundleURL: URL) -> URL {
        originalLocation(of: bundleURL) ?? bundleURL
    }

    /// Install intent: the resolved source is a genuinely read-only image (the
    /// mounted DMG). An *unresolved* translocation mount is read-only too, but it
    /// means a quarantined copy in some writable folder whose origin we couldn't
    /// trace — never treat that as a DMG launch, or a stale ~/Downloads copy gets
    /// offered (or silently installed) over a possibly newer app.
    static func isReadOnlyInstallSource(_ source: URL) -> Bool {
        guard !source.path.contains("/AppTranslocation/") else { return false }
        return isOnReadOnlyVolume(source)
    }

    /// True when the URL sits on a volume that can't be written — the mounted DMG,
    /// a network image, or the App Translocation mount.
    private static func isOnReadOnlyVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
    }

    // `SecTranslocate*` are public Security-framework symbols but aren't surfaced in
    // the Swift overlay, so resolve them from the already-linked framework at runtime.
    private typealias SecIsTranslocatedFn = @convention(c)
        (CFURL, UnsafeMutablePointer<Bool>?, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
    private typealias SecOriginalPathFn = @convention(c)
        (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    /// Resolve a translocated bundle URL back to the real file it was launched from.
    /// Returns `nil` when the app isn't translocated (so the bundle URL is already real).
    private static func originalLocation(of url: URL) -> URL? {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let isSym = dlsym(rtldDefault, "SecTranslocateIsTranslocatedURL"),
              let origSym = dlsym(rtldDefault, "SecTranslocateCreateOriginalPathForURL")
        else { return nil }
        let isTranslocated = unsafeBitCast(isSym, to: SecIsTranslocatedFn.self)
        let createOriginalPath = unsafeBitCast(origSym, to: SecOriginalPathFn.self)

        var translocated = false
        guard isTranslocated(url as CFURL, &translocated, nil), translocated,
              let original = createOriginalPath(url as CFURL, nil)
        else { return nil }
        return original.takeRetainedValue() as URL
    }

    // MARK: - Version comparison

    /// True when /Applications already holds a build of this app newer than the
    /// running one — i.e. installing this copy would downgrade. CFBundleVersion is
    /// the commit count (monotonic), so plain integer comparison is the whole
    /// story; missing/non-git builds compare as "not newer" and install normally.
    /// (`internal` so `SingleInstanceGuard` can warn in its Quit-and-Install prompt.)
    static func installWouldDowngrade() -> Bool {
        let destination = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
        guard let installed = buildNumber(of: Bundle(url: destination)),
              let current = buildNumber(of: Bundle.main)
        else { return false }
        return installed > current
    }

    private static func buildNumber(of bundle: Bundle?) -> Int? {
        guard let raw = bundle?.infoDictionary?["CFBundleVersion"] as? String else { return nil }
        return Int(raw)
    }

    private static func shortVersion(of bundle: Bundle?) -> String? {
        bundle?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    // MARK: - Prompt

    @MainActor
    private static func promptToDowngrade(destination: URL) -> Bool {
        let installed = shortVersion(of: Bundle(url: destination)).map { " (\($0))" } ?? ""
        let current = shortVersion(of: Bundle.main).map { " (\($0))" } ?? ""
        let alert = NSAlert()
        alert.messageText = "Install an older version of Serial Notes?"
        alert.informativeText = """
            The copy in your Applications folder\(installed) is newer than this \
            one\(current). Replacing it will undo updates — you can open the \
            installed copy instead.
            """
        alert.addButton(withTitle: "Install Older Version")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if let icon = NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private static func promptToMove() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Move Serial Notes to your Applications folder?"
        alert.informativeText = """
            Serial Notes works best — and can keep itself up to date — when it lives \
            in your Applications folder. It’ll move there and relaunch.
            """
        alert.addButton(withTitle: "Move to Applications Folder")
        alert.addButton(withTitle: "Don’t Move")
        alert.alertStyle = .informational
        if let icon = NSApp.applicationIconImage { alert.icon = icon }

        // The app is an LSUIElement accessory with no windows, so bring it forward
        // or the alert opens behind whatever the user was looking at.
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private static func presentMoveFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t move Serial Notes"
        alert.informativeText = """
            \(error.localizedDescription)

            You can move Serial Notes into your Applications folder yourself from Finder.
            """
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Install

    /// Copy the bundle to `/Applications`, replacing any existing copy and clearing
    /// the quarantine flag so the relocated app launches without a Gatekeeper prompt.
    /// Falls back to an authenticated copy when `/Applications` isn't user-writable.
    ///
    /// The copy is staged next to the destination first and only then swapped in,
    /// so a failed copy (disk full, I/O error) never costs the user their working
    /// install — especially important now that the guard's replace flow has already
    /// quit the running copy by the time this runs.
    private static func install(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let staging = stagingURL(for: destination)
        try? fm.removeItem(at: staging)  // stale leftover from an interrupted install

        do {
            try fm.copyItem(at: source, to: staging)
            if fm.fileExists(atPath: destination.path) {
                // Displace the old copy only after the new one fully copied. Trash
                // rather than hard-delete so a mistake is recoverable; fall back to
                // removeItem if the destination can't be trashed.
                if (try? fm.trashItem(at: destination, resultingItemURL: nil)) == nil {
                    try fm.removeItem(at: destination)
                }
            }
            // Same volume → atomic rename.
            try fm.moveItem(at: staging, to: destination)
        } catch {
            try? fm.removeItem(at: staging)
            // /Applications usually allows admin-group users to write directly; if
            // not (a managed/non-admin Mac), escalate with an authenticated copy.
            try privilegedCopy(from: source, to: destination)
        }

        clearQuarantine(at: destination)
    }

    /// Hidden sibling of the destination (`/Applications/.SerialNotes.app.incoming`)
    /// — same volume so the final move is an atomic rename, dot-prefixed so Finder,
    /// Spotlight, and LaunchServices ignore the half-copied bundle.
    private static func stagingURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent("." + destination.lastPathComponent + ".incoming")
    }

    /// `ditto` the bundle into place with administrator rights via Apple Events.
    /// Used only when a plain copy is denied. Throws if the user cancels the auth
    /// prompt or the script fails.
    private static func privilegedCopy(from source: URL, to destination: URL) throws {
        // One privileged shell does the whole replace: ditto into a staging path
        // first (so a failed copy never costs the working install — `set -e` aborts
        // before the rm), swap it in, hand ownership back to the invoking user (a
        // root-owned bundle would block the quarantine strip below, future Sparkle
        // updates, and normal use), then best-effort strip quarantine (xattr errors
        // when the attr is already gone).
        let user = NSUserName()
        let staging = stagingURL(for: destination)
        let command = [
            "set -e",
            "/bin/rm -rf \(shellQuote(staging.path))",
            "/usr/bin/ditto \(shellQuote(source.path)) \(shellQuote(staging.path))",
            "/bin/rm -rf \(shellQuote(destination.path))",
            "/bin/mv \(shellQuote(staging.path)) \(shellQuote(destination.path))",
            "/usr/sbin/chown -R \(shellQuote(user)) \(shellQuote(destination.path))",
            "/usr/bin/xattr -dr com.apple.quarantine \(shellQuote(destination.path)) 2>/dev/null || true",
        ].joined(separator: "; ")
        let script = "do shell script \"\(AppleScriptString.escapingLiteral(command))\" with administrator privileges"
        var errorInfo: NSDictionary?
        guard let apple = NSAppleScript(source: script) else {
            throw MoveError.scriptUnavailable
        }
        apple.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw MoveError.privilegedCopyFailed(String(describing: errorInfo[NSAppleScript.errorMessage] ?? "unknown error"))
        }
    }

    private static func clearQuarantine(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Relaunch

    /// Spawn a detached helper that waits for this process to exit, then opens the
    /// relocated copy; trash the leftover original and quit. The helper waits on our
    /// PID so the relaunched copy never races *this* process for the same bundle ID;
    /// `SingleInstanceGuard` (which ran before `moveIfNeeded`) guarantees no other
    /// pre-existing instance is occupying the destination either. Returns (without
    /// exiting) only when the helper can't be spawned, so the caller keeps the app
    /// running in place rather than leaving the user with nothing launched.
    private static func relaunch(at destination: URL, removingOriginal original: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let waitThenOpen =
            "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; " +
            "/usr/bin/open \(shellQuote(destination.path))"
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", waitThenOpen]
        do {
            try helper.run()
        } catch {
            return
        }

        // The helper is now waiting on our PID, so it's safe to trash the leftover
        // original and quit. Covers both the translocated real download and a plain
        // copy run from ~/Downloads; a read-only DMG mount can't be trashed, which
        // throws and is harmlessly ignored (the image unmounts itself once we quit).
        try? FileManager.default.trashItem(at: original, resultingItemURL: nil)
        exit(0)
    }

    // MARK: - Helpers

    private enum MoveError: LocalizedError {
        case scriptUnavailable
        case privilegedCopyFailed(String)

        var errorDescription: String? {
            switch self {
            case .scriptUnavailable:
                return "The system couldn’t prepare the move."
            case .privilegedCopyFailed(let message):
                return message
            }
        }
    }

    /// Single-quote a path for safe interpolation into a `/bin/sh -c` command.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

}
