import AppKit
import Darwin

/// Launch-time single-instance enforcement, keyed to the app's own bundle ID.
///
/// LaunchServices deduplicates launches by *path*, not bundle ID, so a second
/// copy of Serial Notes — a stale `~/Downloads` download picked by Raycast or
/// Spotlight, the copy inside the mounted DMG, or an instance orphaned when an
/// install replaced its bundle — runs happily alongside the first: two menu-bar
/// icons, two meeting detectors. The guard resolves the conflict in two phases:
///
/// 1. **`enforce()`** (in `applicationWillFinishLaunching`, before the menu-bar
///    icon): the fast paths. The running instance wins by default — the new
///    launch activates it and exits without a flash. It may be mid-meeting, and
///    its work is never interrupted.
/// 2. **`resolvePendingConflict()`** (in `applicationDidFinishLaunching`, before
///    `MoveToApplications.moveIfNeeded()`): the slow flows that show UI and wait —
///    orphan reclaim and the DMG Quit-and-Install offer. Deferred because an
///    alert shown before the app finishes launching can land *behind* the
///    frontmost (possibly fullscreen) app and stall the launch invisibly.
///
/// - **Orphans are reclaimed.** An instance whose executable now sits in the
///   Trash (or is gone entirely) is the residue of an install that replaced its
///   bundle while it ran. It's asked to quit *gracefully* — its quit path drains
///   in-flight finalization — and this launch proceeds once it exits. If it
///   needs longer than the grace window, this side explains and steps aside;
///   the next launch finds it gone.
/// - **A read-only source signals install intent** (the app double-clicked
///   inside the mounted DMG while a copy runs): offer to quit the running copy
///   and install, the standard installer pattern. On consent the running copy
///   drains and exits, then `moveIfNeeded()` performs the usual silent install.
///
/// Never `forceTerminate()` — a graceful quit may take its time so a meeting
/// mid-finalization is always saved; when it does, this side steps aside.
///
/// Dev builds skip the guard entirely: `run.sh` owns their lifecycle, and its
/// kills are deliberately scoped to *this repo's* `.build` path — a dev build
/// from another worktree shares the `.dev` bundle ID, and deferring to it would
/// turn `run.sh` into a silent no-op launch. Two DEV icons are tellable apart;
/// a build that silently refuses to start is not. Production instances never
/// collide with dev ones regardless (different bundle IDs).
enum SingleInstanceGuard {

    enum Decision: Equatable {
        /// No conflicting instance (or this one wins the simultaneous-launch
        /// tie-break) — continue launching.
        case proceed
        /// A healthy instance is already running — activate it and exit.
        case deferToOther
        /// Every other instance runs from a trashed/deleted bundle — ask them to
        /// quit gracefully and take over once they're gone.
        case reclaimFromOrphans
        /// Launched from a read-only volume (the DMG) with the app running —
        /// offer to quit the running copy and install this one.
        case offerReplace
    }

    /// The facts about one running instance that the decision needs, separated
    /// from `NSRunningApplication` so `decide` stays pure and unit-testable.
    struct InstanceSnapshot: Equatable, Sendable {
        var pid: pid_t
        var launchDate: Date?
        var executableStillExists: Bool
        var executableInTrash: Bool

        /// Residue of an install (or Finder replace) that swapped the bundle out
        /// from under a running process.
        var isOrphan: Bool { executableInTrash || !executableStillExists }
    }

    /// A conflict whose resolution needs UI: carried from `enforce()` to
    /// `resolvePendingConflict()`.
    private struct PendingConflict {
        let decision: Decision
        let others: [NSRunningApplication]
        let orphans: [NSRunningApplication]
    }

    @MainActor private static var pending: PendingConflict?

    /// How a deferred conflict ended, for the caller to thread into
    /// `moveIfNeeded(replaceConsentGiven:)`.
    enum ConflictResolution {
        case none
        case wonQuietly
        case wonWithReplaceConsent
    }

    // MARK: - Enforcement (phase 1, applicationWillFinishLaunching)

    /// Resolve duplicate instances before the rest of launch runs. Fast paths
    /// only — may exit the process (defer), or stash a pending conflict for
    /// `resolvePendingConflict()`.
    @MainActor
    static func enforce() {
        guard !Bundle.main.isRunningTests else { return }
        guard !Bundle.main.isDevBuild else { return }
        guard let bundleID = Bundle.main.bundleIdentifier else { return }

        let others = liveInstances(bundleID: bundleID)
        guard !others.isEmpty else { return }

        let source = MoveToApplications.resolvedSource(of: Bundle.main.bundleURL)
        let snapshots = others.map(InstanceSnapshot.init)
        let decision = decide(
            others: snapshots,
            ownLaunchDate: NSRunningApplication.current.launchDate,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            launchedFromReadOnlyVolume: MoveToApplications.isReadOnlyInstallSource(source)
        )
        let orphans = zip(others, snapshots).filter { $1.isOrphan }.map(\.0)

        switch decision {
        case .proceed:
            // Won the tie-break with stale leftovers still around: ask them to
            // wind down (graceful — their quit drain still runs) and carry on.
            orphans.forEach { $0.terminate() }
        case .deferToOther:
            let healthy = zip(others, snapshots).filter { !$1.isOrphan }.map(\.0)
            NSLog("[SingleInstanceGuard] Another instance is running (pid %d) — deferring", healthy.first?.processIdentifier ?? -1)
            orphans.forEach { $0.terminate() }
            healthy.first?.activate()
            exit(0)
        case .reclaimFromOrphans, .offerReplace:
            pending = PendingConflict(decision: decision, others: others, orphans: orphans)
        }
    }

    /// True when another live instance of this bundle ID exists right now.
    /// Cheap enough for `SerialNotesApp.init` to gate launch-time side effects
    /// (the model download) that a soon-to-defer duplicate shouldn't start.
    @MainActor
    static func anotherInstanceIsRunning() -> Bool {
        guard !Bundle.main.isRunningTests, !Bundle.main.isDevBuild,
              let bundleID = Bundle.main.bundleIdentifier
        else { return false }
        return !liveInstances(bundleID: bundleID).isEmpty
    }

    @MainActor
    static var hasPendingConflict: Bool { pending != nil }

    /// Other instances of `bundleID` that are actually alive. `isTerminated` can
    /// lag (it's KVO-fed), so `kill(pid, 0)` is checked too — a dead-but-still-
    /// listed entry (e.g. the old instance right after a Sparkle relaunch) must
    /// never be deferred to: its bundleURL points at a path the update just
    /// refilled, so it would otherwise classify as a healthy instance.
    @MainActor
    private static func liveInstances(bundleID: String) -> [NSRunningApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ownPID && !hasExited($0) }
    }

    // MARK: - Conflict resolution (phase 2, applicationDidFinishLaunching)

    /// Run the UI-bearing flow stashed by `enforce()`, if any. May exit the
    /// process; returns how the conflict ended so the caller can thread consent
    /// into `moveIfNeeded(replaceConsentGiven:)`.
    @MainActor
    static func resolvePendingConflict() -> ConflictResolution {
        guard let conflict = pending else { return .none }
        pending = nil

        switch conflict.decision {
        case .reclaimFromOrphans:
            reclaim(conflict.orphans)
            return .wonQuietly
        case .offerReplace:
            offerReplace(conflict.others)
            return .wonWithReplaceConsent
        case .proceed, .deferToOther:
            return .none  // never stashed by enforce()
        }
    }

    /// Ask orphans to quit and take over once they're gone. An idle orphan exits
    /// well inside the grace window; one still finalizing a meeting keeps its
    /// drain — this side explains, steps aside, and the next launch finds it gone.
    @MainActor
    private static func reclaim(_ orphans: [NSRunningApplication]) {
        NSLog("[SingleInstanceGuard] Reclaiming from %d orphaned instance(s)", orphans.count)
        orphans.forEach { $0.terminate() }
        if waitForExit(of: orphans, timeout: 10) { return }
        NSLog("[SingleInstanceGuard] Orphan still draining — stepping aside")
        presentStillFinishing(
            """
            The previous copy of Serial Notes is still finishing — it may be \
            saving a meeting. Open Serial Notes again once its menu-bar icon \
            disappears.
            """
        )
        exit(0)
    }

    /// The user double-clicked the app inside the DMG with a copy already
    /// running: confirm, quit the running copy gracefully, and return so
    /// `moveIfNeeded()` performs the normal silent install. Exits on cancel or
    /// when the running copy needs longer than the grace window to drain.
    @MainActor
    private static func offerReplace(_ others: [NSRunningApplication]) {
        NSApp.activate(ignoringOtherApps: true)
        guard promptQuitAndInstall() else {
            others.first?.activate()
            exit(0)
        }
        others.forEach { $0.terminate() }
        if waitForExit(of: others, timeout: 30) { return }
        presentStillFinishing(
            """
            The running copy is taking a while to quit — it may still be saving \
            a meeting. Once its menu-bar icon disappears, double-click Serial \
            Notes in the disk image again to install.
            """
        )
        exit(0)
    }

    // MARK: - Decision

    /// Pure decision over the instance facts. Rules, in order: nothing else
    /// running → proceed; read-only source → install intent; only orphans →
    /// reclaim; otherwise the healthy instances win unless this one beats them
    /// all in the tie-break.
    static func decide(
        others: [InstanceSnapshot],
        ownLaunchDate: Date?,
        ownPID: pid_t,
        launchedFromReadOnlyVolume: Bool
    ) -> Decision {
        guard !others.isEmpty else { return .proceed }
        if launchedFromReadOnlyVolume { return .offerReplace }
        let healthy = others.filter { !$0.isOrphan }
        guard !healthy.isEmpty else { return .reclaimFromOrphans }
        let beatsAllHealthy = healthy.allSatisfy {
            winsTieBreak(ownLaunchDate: ownLaunchDate, ownPID: ownPID, otherLaunchDate: $0.launchDate, otherPID: $0.pid)
        }
        return beatsAllHealthy ? .proceed : .deferToOther
    }

    /// Deterministic winner for the simultaneous-launch race: earlier launch
    /// wins; equal or unknown dates fall back to the lower PID. Both racers
    /// compute the same comparison, so with consistent facts exactly one
    /// survives without any IPC.
    ///
    /// Known limitation (accepted — closing it needs IPC): each side reads the
    /// *peer's* launchDate from LaunchServices, which can briefly report nil for
    /// a just-spawned process. Asymmetric views can then make both racers defer
    /// (self-healing — the next click launches clean) or, with PID order
    /// opposing date order, both proceed (two icons until one quits).
    static func winsTieBreak(ownLaunchDate: Date?, ownPID: pid_t, otherLaunchDate: Date?, otherPID: pid_t) -> Bool {
        if let own = ownLaunchDate, let other = otherLaunchDate, own != other {
            return own < other
        }
        return ownPID < otherPID
    }

    // MARK: - Alerts

    @MainActor
    private static func promptQuitAndInstall() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Quit the running Serial Notes and install this version?"
        var info = """
            Serial Notes is already running. It’ll finish saving any meeting in \
            progress and quit, then this version will be installed in your \
            Applications folder.
            """
        if MoveToApplications.installWouldDowngrade() {
            info += "\n\nNote: the installed copy is newer than this one — continuing will downgrade it."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Quit and Install")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        if let icon = NSApp.applicationIconImage { alert.icon = icon }
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private static func presentStillFinishing(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Serial Notes is still finishing up"
        alert.informativeText = message
        alert.alertStyle = .warning
        if let icon = NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Waiting

    /// Block (sleeping, not pumping) until every process exits or the deadline
    /// passes. Sleeping is deliberate: pumping the run loop here would execute
    /// this doomed instance's queued main-actor work — the model download,
    /// detection timers — inside a process that's about to exit. Nothing in the
    /// loop needs run-loop turns: `terminate()`'s quit event was already sent,
    /// and `hasExited`'s ground truth is `kill(pid, 0)`, not KVO.
    ///
    /// Known limitation (covered by the timeout alerts): a target parked in its
    /// own modal alert won't service the quit Apple Event until that modal ends.
    @MainActor
    private static func waitForExit(of apps: [NSRunningApplication], timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if apps.allSatisfy(hasExited) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return apps.allSatisfy(hasExited)
    }

    @MainActor
    private static func hasExited(_ app: NSRunningApplication) -> Bool {
        if app.isTerminated { return true }
        if kill(app.processIdentifier, 0) == 0 { return false }
        return errno == ESRCH
    }
}

// MARK: - Snapshot construction

extension SingleInstanceGuard.InstanceSnapshot {
    /// `proc_pidpath` reports the executable's *current* vnode path, so a bundle
    /// trashed-by-rename after launch shows its `.Trash` location — `bundleURL`
    /// would keep reporting the original path, which an install may since have
    /// refilled with a brand-new copy. When nothing can be inspected, assume
    /// healthy: deferring to a live instance is always safe; quitting one on bad
    /// data is not. (Residual gap, accepted: an orphan whose bundle was hard-
    /// deleted rather than trashed can report its old — refilled — path through
    /// the kernel name cache and read as healthy; deferring to it still leaves
    /// the user a working, if stale, instance.)
    @MainActor
    init(app: NSRunningApplication) {
        let path = Self.currentExecutablePath(pid: app.processIdentifier) ?? app.bundleURL?.path
        self.init(
            pid: app.processIdentifier,
            launchDate: app.launchDate,
            executableStillExists: path.map { FileManager.default.fileExists(atPath: $0) } ?? true,
            executableInTrash: path.map(Self.isTrashPath) ?? false
        )
    }

    private static func currentExecutablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func isTrashPath(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0 == ".Trash" || $0 == ".Trashes" }
    }
}
