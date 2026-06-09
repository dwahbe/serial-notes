import AppKit

/// First-launch "Move to Applications folder?" prompt — a native, dependency-free
/// take on the well-worn LetsMove flow.
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
enum MoveToApplications {
    /// Set once the user declines, so we don't nag on every launch. Keyed only by
    /// the decline itself — if they later move the app into /Applications by hand,
    /// `isInApplicationsFolder` short-circuits before we'd ever read this.
    private static let declinedDefaultsKey = "moveToApplications.declined"

    /// Offer to move the app into /Applications when it's running from anywhere else.
    /// On a successful move this **exits the process** — the relocated copy relaunches
    /// itself — so it returns only when nothing was moved.
    @MainActor
    static func moveIfNeeded() {
        // Dev builds live in the repo's .build dir on purpose (run.sh owns their
        // lifecycle), and tests must never relocate anything.
        guard !Bundle.main.isDevBuild else { return }
        guard NSClassFromString("XCTestCase") == nil else { return }

        let bundleURL = Bundle.main.bundleURL
        guard !isInApplicationsFolder(bundleURL) else { return }
        guard !UserDefaults.standard.bool(forKey: declinedDefaultsKey) else { return }

        // A translocated app runs from a read-only mount; the thing we actually
        // want to relocate is the original download it was translocated from.
        let source = originalLocation(of: bundleURL) ?? bundleURL
        let destination = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appendingPathComponent(bundleURL.lastPathComponent)

        guard promptToMove() else {
            UserDefaults.standard.set(true, forKey: declinedDefaultsKey)
            return
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

    // MARK: - Prompt

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
    private static func install(from source: URL, to destination: URL) throws {
        let fm = FileManager.default

        if fm.fileExists(atPath: destination.path) {
            // Replace an older copy. Trash rather than hard-delete so a mistake is
            // recoverable; fall back to removeItem if the destination can't be trashed.
            if (try? fm.trashItem(at: destination, resultingItemURL: nil)) == nil {
                try? fm.removeItem(at: destination)
            }
        }

        do {
            try fm.copyItem(at: source, to: destination)
        } catch {
            // /Applications usually allows admin-group users to write directly; if
            // not (a managed/non-admin Mac), escalate with an authenticated copy.
            try privilegedCopy(from: source, to: destination)
        }

        clearQuarantine(at: destination)
    }

    /// `ditto` the bundle into place with administrator rights via Apple Events.
    /// Used only when a plain copy is denied. Throws if the user cancels the auth
    /// prompt or the script fails.
    private static func privilegedCopy(from source: URL, to destination: URL) throws {
        // One privileged shell does the whole replace: remove any stale copy (so we
        // never merge old files into the new bundle), ditto the app in, hand
        // ownership back to the invoking user (a root-owned bundle would block the
        // quarantine strip below, future Sparkle updates, and normal use), then
        // best-effort strip quarantine. `set -e` aborts on any critical step; the
        // quarantine strip is non-fatal (xattr errors when the attr is already gone).
        let user = NSUserName()
        let command = [
            "set -e",
            "/bin/rm -rf \(shellQuote(destination.path))",
            "/usr/bin/ditto \(shellQuote(source.path)) \(shellQuote(destination.path))",
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
    /// PID so the new instance never races the old one for the same bundle ID. Returns
    /// (without exiting) only when the helper can't be spawned, so the caller keeps the
    /// app running in place rather than leaving the user with nothing launched.
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
