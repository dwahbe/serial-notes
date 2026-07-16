import AppKit
import CoreServices
import Foundation

/// Pushes a finished meeting transcript straight into a notes app (Phase 2).
///
/// Best-effort and side-effect-only: every failure is logged and swallowed so a
/// flaky export can never abort session finalization or block app quit. The
/// on-disk `transcript.md` in the storage folder is always the source of truth;
/// this just *also* delivers the notes into the app.
///
/// - **Apple Notes** — in-process AppleScript (`NSAppleScript`) that creates a note
///   in a "Meeting Notes" folder with an HTML body. Requires the
///   `com.apple.security.automation.apple-events` entitlement +
///   `NSAppleEventsUsageDescription`, and triggers a one-time Automation TCC prompt
///   on first send. No network — Apple Events are local IPC.
/// - **Bear** — a `bear://x-callback-url/create` URL opened via `NSWorkspace`. Bear
///   is Markdown-native, so the body goes through nearly as-is. No entitlement, no
///   prompt.
///
/// The pure Markdown→HTML/strip helpers are `internal` so they're unit-tested; the
/// app-touching send paths are `private`.
enum MeetingExporter {
    /// Folder created inside Apple Notes to collect meeting transcripts.
    static let appleNotesFolder = "Meeting Notes"

    /// Read the finalized transcript and deliver it to each enabled target. Safe to
    /// call off the main actor; reads + rendering run here, the Apple Events send
    /// hops to a background thread and the Bear URL open hops to the main actor.
    static func export(targets: Set<ExportTarget>, transcriptURL: URL) async {
        guard !targets.isEmpty else { return }
        guard let raw = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            NSLog("MeetingExporter: could not read \(transcriptURL.lastPathComponent); skipping export")
            return
        }
        // Drop the YAML front-matter — both apps would render `---` as a rule and the
        // `date:`/`duration:` lines as stray text. The `# Meeting — …` H1 stays and
        // becomes the note title in both Notes and Bear. The notes sentinel is
        // parsing plumbing, not content: Apple Notes would show it as literal text
        // (inlineHTML escapes angle brackets) and Bear shows raw comments.
        let body = strippingManualNotesMarker(strippingFrontMatter(raw))

        if targets.contains(.appleNotes) {
            await exportToAppleNotes(markdownBody: body)
        }
        if targets.contains(.bear) {
            await exportToBear(markdownBody: body)
        }
    }

    /// Whether a target app is installed (used to gate/disable UI for it).
    static func isInstalled(_ target: ExportTarget) -> Bool {
        target.bundleIDs.contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }

    /// Trigger (or re-check) the Automation permission prompt for Apple Notes
    /// *without* creating a note — call this when the user opts in, so the
    /// "wants to control Notes" prompt appears at toggle time instead of surprising
    /// them after their first meeting. `AEDeterminePermissionToAutomateTarget`
    /// prompts only when the decision is undetermined, and the grant is per
    /// source→target pair so it pre-authorizes the real note-creation later.
    ///
    /// That API only prompts when the target is *running* (else it returns
    /// `procNotFound`), so we first launch Notes hidden in the background if needed.
    /// Returns true when automation is permitted.
    @discardableResult
    static func requestAppleNotesAccess() async -> Bool {
        await launchAppleNotesInBackgroundIfNeeded()
        return await Task.detached(priority: .userInitiated) {
            var target = AEAddressDesc()
            let create = Data(appleNotesBundleID.utf8).withUnsafeBytes { raw in
                AECreateDesc(typeApplicationBundleID, raw.baseAddress, raw.count, &target)
            }
            guard create == noErr else {
                NSLog("MeetingExporter: could not build Notes AE target (status \(create))")
                return false
            }
            defer { AEDisposeDesc(&target) }
            let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true)
            switch status {
            case noErr:
                return true
            case OSStatus(errAEEventNotPermitted):
                NSLog("MeetingExporter: Apple Notes automation not permitted")
                return false
            default:
                NSLog("MeetingExporter: Apple Notes automation check returned \(status)")
                return false
            }
        }.value
    }

    /// Single source of truth for Apple Notes' bundle ID, shared with the AE target
    /// above and the launch below.
    private static var appleNotesBundleID: String {
        ExportTarget.appleNotes.bundleIDs.first ?? "com.apple.Notes"
    }

    /// Launch Notes hidden (no focus steal) if it isn't already running, so the
    /// Automation prompt can be raised against a live target. No-op if running.
    @MainActor
    private static func launchAppleNotesInBackgroundIfNeeded() async {
        let workspace = NSWorkspace.shared
        if workspace.runningApplications.contains(where: { $0.bundleIdentifier == appleNotesBundleID }) {
            return
        }
        guard let url = workspace.urlForApplication(withBundleIdentifier: appleNotesBundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        config.addsToRecentItems = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            workspace.openApplication(at: url, configuration: config) { _, _ in
                continuation.resume()
            }
        }
    }

    // MARK: - Apple Notes

    private static func exportToAppleNotes(markdownBody: String) async {
        let html = htmlBody(fromMarkdown: markdownBody)
        let folder = AppleScriptString.escapingLiteral(appleNotesFolder)
        let body = AppleScriptString.escapingLiteral(html)
        // `body` is a single line (htmlBody splits on all newline variants), so it's
        // a valid AppleScript string literal after escaping `\` and `"`.
        let source = """
        tell application "Notes"
            set folderName to "\(folder)"
            if not (exists folder folderName) then
                make new folder with properties {name:folderName}
            end if
            tell folder folderName
                make new note with properties {body:"\(body)"}
            end tell
        end tell
        """
        await runAppleScript(source, label: "Apple Notes")
    }

    /// Run an AppleScript off the main thread. The first Apple Notes send blocks on
    /// the Automation TCC prompt, so this must never run on the main actor.
    private static func runAppleScript(_ source: String, label: String) async {
        await Task.detached(priority: .utility) {
            var errorInfo: NSDictionary?
            guard let script = NSAppleScript(source: source) else {
                NSLog("MeetingExporter: failed to compile \(label) AppleScript")
                return
            }
            script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let message = errorInfo[NSAppleScript.errorMessage] ?? "unknown error"
                NSLog("MeetingExporter: \(label) export failed — \(message)")
            }
        }.value
    }

    // MARK: - Bear

    /// Conservative ceiling on the transcript body sent to Bear via its
    /// `x-callback-url`. Bear delivers the whole note through the URL, which has a
    /// practical size limit; rather than let a marathon meeting truncate silently,
    /// skip and log past this (~5h of talking). The on-disk transcript keeps it all.
    private static let maxBearBodyBytes = 250_000

    private static func exportToBear(markdownBody: String) async {
        // Re-check at send time: the Settings toggle only *disables* (doesn't clear)
        // when Bear is uninstalled, so a stale "on" target can reach here.
        guard isInstalled(.bear) else {
            NSLog("MeetingExporter: Bear isn't installed; skipping (transcript kept in the storage folder)")
            return
        }
        guard markdownBody.utf8.count <= maxBearBodyBytes else {
            NSLog("MeetingExporter: transcript too long for Bear (\(markdownBody.utf8.count) bytes); skipping (kept in the storage folder)")
            return
        }
        // Build the query by hand: URLComponents.queryItems leaves `&` and `+`
        // unencoded in values, so a transcript containing "Q&A" would truncate the
        // Bear note. Encode everything that could break the query ourselves.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?;/#")
        guard
            let text = markdownBody.addingPercentEncoding(withAllowedCharacters: allowed),
            // Don't yank focus to Bear after a meeting — file it in the background.
            let url = URL(string: "bear://x-callback-url/create?text=\(text)&open_note=no")
        else {
            NSLog("MeetingExporter: could not build Bear x-callback URL")
            return
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        if !opened {
            NSLog("MeetingExporter: Bear export failed — could not open the bear:// URL")
        }
    }

    // MARK: - Markdown rendering (pure, unit-tested)

    /// Strip a leading `---\n…\n---` YAML front-matter block (and the blank lines
    /// after it), leaving the `# Meeting — …` heading first. Returns the input
    /// unchanged when there's no well-formed front-matter.
    static func strippingFrontMatter(_ markdown: String) -> String {
        guard markdown.hasPrefix("---") else { return markdown }
        let lines = markdown.components(separatedBy: "\n")
        // Find the closing `---` (lines[0] is the opening one).
        var close = 1
        while close < lines.count, lines[close] != "---" { close += 1 }
        guard close < lines.count else { return markdown }  // no closing fence
        var start = close + 1
        while start < lines.count, lines[start].trimmingCharacters(in: .whitespaces).isEmpty {
            start += 1
        }
        return lines[start...].joined(separator: "\n")
    }

    /// Drop the invisible `## Notes` closing sentinel lines from an export body.
    static func strippingManualNotesMarker(_ markdown: String) -> String {
        markdown
            .components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) != TranscriptFormatter.manualNotesEndMarker }
            .joined(separator: "\n")
    }

    /// Render the transcript body Markdown (front-matter already stripped) to a
    /// single line of HTML for Apple Notes. Handles the same focused grammar as the
    /// notepad: ATX headings, `-`/`+`/`*` bullets, `1.`/`1)` ordered items, task
    /// items, nesting by indentation, and the shared inline parser. Blank lines in
    /// the source become explicit empty lines — Notes gives `<p>` no margin, so
    /// without them the whole note collapses into a wall of text.
    static func htmlBody(fromMarkdown markdown: String) -> String {
        var html = ""
        // Open lists as (tag, indent level), innermost last. An `<li>` stays open
        // until its sibling arrives or its list closes, so a deeper item nests
        // INSIDE its parent (`<li>parent<ul>…</ul></li>`) — the shape Notes needs
        // to show real nesting. Levels come from `TranscriptFormatter
        // .listIndentLevel`, the same rule the notepad editor renders from.
        var openLists: [(tag: String, level: Int)] = []
        // Blank lines are emitted lazily, just before the next content block: a run
        // of blanks collapses to one (CRLF sources split into extra empties), and
        // leading/trailing blanks vanish. `<div><br></div>` is Notes' own
        // serialization of an empty line; an empty `<p>` gets dropped by its parser.
        var pendingBlank = false

        func flushPendingBlank() {
            if pendingBlank {
                html += "<div><br></div>"
                pendingBlank = false
            }
        }

        func closeInnermostList() {
            if let list = openLists.popLast() {
                html += "</li></\(list.tag)>"
            }
        }
        func closeAllLists() {
            while !openLists.isEmpty { closeInnermostList() }
        }
        func appendListItem(_ tag: String, level: Int, content: String) {
            while let top = openLists.last,
                  top.level > level || (top.level == level && top.tag != tag)
            {
                closeInnermostList()
            }
            if openLists.last?.level == level {
                html += "</li><li>\(content)"
            } else {
                // Deeper than (or first after) the current list — open a new one
                // inside the still-open parent item. A multi-level jump opens a
                // single list at the target level rather than synthesizing
                // intermediates.
                html += "<\(tag)><li>\(content)"
                openLists.append((tag, level))
            }
        }

        // Split on every newline variant (CR, CRLF, U+2028/2029, NEL) — transcript.md
        // is the user's editing surface, so it may arrive with non-LF separators; the
        // single-line invariant the AppleScript literal relies on must hold for all.
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                closeAllLists()
                if !html.isEmpty { pendingBlank = true }
                continue
            }
            flushPendingBlank()
            let level = TranscriptFormatter.listIndentLevel(
                of: rawLine.prefix(while: { $0 == " " || $0 == "\t" })
            )
            if let heading = headingRegex.firstMatch(
                in: line,
                range: NSRange(location: 0, length: (line as NSString).length)
            ) {
                closeAllLists()
                let lineSource = line as NSString
                let fence = lineSource.substring(with: heading.range(at: 1))
                let content = heading.range(at: 2).location == NSNotFound
                    ? ""
                    : lineSource.substring(with: heading.range(at: 2))
                html += "<h\(fence.count)>\(inlineHTML(content))</h\(fence.count)>"
            } else if let item = listItemRegex.firstMatch(
                in: line,
                range: NSRange(location: 0, length: (line as NSString).length)
            ) {
                let lineSource = line as NSString
                let marker = lineSource.substring(with: item.range(at: 1))
                let ordered = marker.hasSuffix(".") || marker.hasSuffix(")")
                let taskMatched = item.range(at: 3).location != NSNotFound
                if taskMatched, !ordered {
                    let task = lineSource.substring(with: item.range(at: 3))
                    let glyph = task.lowercased() == "x" ? "\u{2611}\u{FE0E} " : "\u{2610} "
                    appendListItem(
                        "ul",
                        level: level,
                        content: glyph + inlineHTML(lineSource.substring(from: item.range.length))
                    )
                } else {
                    // Ordered "tasks" aren't part of the grammar — the notepad
                    // renders their brackets literally, so the export keeps them
                    // as content too.
                    let contentStart = taskMatched
                        ? NSMaxRange(item.range(at: 2))
                        : item.range.length
                    appendListItem(
                        ordered ? "ol" : "ul",
                        level: level,
                        content: inlineHTML(lineSource.substring(from: contentStart))
                    )
                }
            } else {
                closeAllLists()
                html += "<p>\(inlineHTML(line))</p>"
            }
        }
        closeAllLists()
        return html
    }

    /// Render the notepad's shared inline grammar to safe HTML.
    static func inlineHTML(_ text: String) -> String {
        MarkdownInlineParser.html(from: text)
    }

    private static let headingRegex = try! NSRegularExpression(
        pattern: #"^(#{1,6})(?:[ \t]+(.*)|$)"#
    )
    // Digits are ASCII-only and the task box may sit at end of line (an empty
    // task item is "- [ ]" once the line is trimmed) — keep in lockstep with
    // ManualNotesMarkdownEditor's listRegex.
    private static let listItemRegex = try! NSRegularExpression(
        pattern: #"^([-+*]|[0-9]+[.)])(\s+)(?:\[([ xX])\](\s+|$))?"#
    )
}
