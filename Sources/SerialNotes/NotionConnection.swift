import AppKit
import Foundation

/// UI model for the Notion connection — drives the Settings export section and
/// the onboarding tile, owns the connect/disconnect flows, and is the
/// production `NotionSending` conformer for per-meeting exports.
///
/// Nothing is persisted until an entire connect succeeds (exchange **and**
/// destination-page creation), so quitting mid-authorization leaves no state
/// and `load` never sees a half-built record.
@MainActor @Observable
final class NotionConnection {
    enum Status: Equatable {
        case disconnected
        /// Browser round trip (or exchange/destination creation) in flight.
        case connecting
        case connected(workspaceName: String)
        /// Stored tokens were rejected and refresh failed — exports skip with
        /// a logged reason until the user re-authorizes.
        case needsReconnect
    }

    private(set) var status: Status = .disconnected
    /// Connect/disconnect failure surfaced in Settings. Cleared on retry.
    private(set) var errorMessage: String?

    /// Set by whichever window initiated a connect (Settings, the setup
    /// guide) to bring itself back to the front when the browser bounces the
    /// user into the app; invoked once per finished flow, then cleared.
    @ObservationIgnored var onFlowFinished: (@MainActor () -> Void)?
    @ObservationIgnored weak var exportSettings: ExportSettings?

    @ObservationIgnored private let credentialStore: NotionCredentialStore
    @ObservationIgnored private let apiClient: NotionAPIClient
    @ObservationIgnored private let flow: NotionOAuthFlow
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    /// Main-actor mirror of the persisted destination identity, so the
    /// synchronous stop-time snapshot (`exportDestination`) needs no Keychain
    /// hop. Set wherever the record is (re)read or written.
    @ObservationIgnored private var cachedDestination: NotionExportDestination?
    /// Whether the stored connection is known-rejected (refresh failed).
    /// Persisted (not just in-memory) so it survives relaunch — otherwise the
    /// record reads back as healthy and every export silently 401-and-skips —
    /// and so a denied/cancelled reconnect restores TO needsReconnect, not a
    /// false "connected". Bundle-scoped like the Keychain service.
    @ObservationIgnored private let needsReconnectKey =
        "\(Bundle.main.bundleIdentifier ?? "com.serialnotes.app").notion.needsReconnect"
    private var persistedNeedsReconnect: Bool {
        get { UserDefaults.standard.bool(forKey: needsReconnectKey) }
        set { UserDefaults.standard.set(newValue, forKey: needsReconnectKey) }
    }

    init(
        credentialStore: NotionCredentialStore? = nil,
        apiClient: NotionAPIClient? = nil,
        flow: NotionOAuthFlow = NotionOAuthFlow()
    ) {
        let store = credentialStore ?? NotionCredentialStore()
        self.credentialStore = store
        self.apiClient = apiClient ?? NotionAPIClient(credentialStore: store)
        self.flow = flow
    }

    /// Read the persisted connection at launch (Keychain I/O off the main
    /// actor via the store).
    func loadPersistedStatus() async {
        guard status == .disconnected else { return }
        await applyPersistedStatus()
    }

    /// Resolve status + cache from the persisted record and the needsReconnect
    /// flag. The single place both launch and post-cancel/deny restore agree,
    /// so a rejected connection is never shown as healthy and a read *failure*
    /// (vs. "no record") doesn't masquerade as disconnected.
    private func applyPersistedStatus() async {
        do {
            guard let credentials = try await credentialStore.load() else {
                cachedDestination = nil
                status = .disconnected
                return
            }
            cachedDestination = NotionExportDestination(
                workspaceID: credentials.workspaceID,
                pageID: credentials.destinationPageID
            )
            status = persistedNeedsReconnect
                ? .needsReconnect
                : .connected(workspaceName: credentials.workspaceName)
        } catch {
            // A Keychain READ error, not "no record" (e.g. an ad-hoc dev build
            // rebuilt under a new signature — see SecItemKeychain). Leave the
            // current status and log rather than silently claiming disconnected.
            NSLog("[SerialNotes/Notion] couldn't read the stored connection (status unchanged): %@",
                  error.localizedDescription)
        }
    }

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    // MARK: - Connect

    /// Open the authorize round trip in the default browser. Safe to call
    /// again mid-flight (a fresh `state` supersedes the old attempt) and from
    /// `needsReconnect`/`connected` (reconnect replaces the record whole).
    func connect() {
        errorMessage = nil
        connectTask?.cancel()
        connectTask = nil
        status = .connecting
        flow.begin()
    }

    /// Abandon an in-flight connect (nothing was persisted).
    func cancelConnect() {
        guard status == .connecting else { return }
        flow.cancel()
        connectTask?.cancel()
        connectTask = nil
        Task { await restorePersistedStatus() }
    }

    /// Entry point for `serialnotes://oauth/notion?…` (kAEGetURL). Returns
    /// false when the URL wasn't a Notion OAuth callback.
    @discardableResult
    func handleCallbackURL(_ url: URL) -> Bool {
        guard let outcome = flow.handleCallback(url) else { return false }
        switch outcome {
        case .staleState:
            // A superseded/expired bounce (or a forged one). Never tears down
            // the attempt in flight — just log and ignore.
            NSLog("[SerialNotes/Notion] ignoring OAuth callback with stale state")
        case .denied:
            // The user changed their mind on the consent screen — not an error.
            Task { await restorePersistedStatus() }
            finishFlow()
        case .failed(let error):
            NSLog("[SerialNotes/Notion] OAuth callback failed: %@", error)
            errorMessage = "Notion couldn't complete the connection (\(error))."
            Task { await restorePersistedStatus() }
            finishFlow()
        case .success(let code):
            let redirectURI = flow.redirectURI
            connectTask = Task { [weak self] in
                await self?.completeConnect(code: code, redirectURI: redirectURI)
            }
        }
        return true
    }

    /// Exchange the code, create the workspace-level "Meeting Notes" page,
    /// then persist the whole record atomically and flip the export toggle on.
    private func completeConnect(code: String, redirectURI: String) async {
        // finishFlow runs on every exit (success, cancel, failure); connectTask
        // is deliberately NOT nil'd here — a newer attempt owns it, and this
        // finished task is harmless to leave referenced (cancelling it is a
        // no-op), whereas nil'ing could clobber the newer attempt's handle.
        defer { finishFlow() }
        do {
            let token = try await apiClient.exchangeAuthorizationCode(code, redirectURI: redirectURI)
            // The token is live on Notion's side now; if the attempt was
            // cancelled, revoke it rather than abandoning a dangling grant.
            if Task.isCancelled {
                await revokeAbandonedToken(token.accessToken)
                return
            }
            let destinationID = try await apiClient.createDestinationPage(accessToken: token.accessToken)
            if Task.isCancelled {
                await revokeAbandonedToken(token.accessToken)
                return
            }
            let credentials = NotionCredentials(
                workspaceID: token.workspaceID,
                workspaceName: token.workspaceName ?? "",
                botID: token.botID,
                destinationPageID: destinationID,
                accessToken: token.accessToken,
                refreshToken: token.refreshToken ?? ""
            )
            try await credentialStore.save(credentials)
            persistedNeedsReconnect = false  // a fresh connect clears any prior rejection
            cachedDestination = NotionExportDestination(
                workspaceID: credentials.workspaceID,
                pageID: credentials.destinationPageID
            )
            status = .connected(workspaceName: credentials.workspaceName)
            exportSettings?.setEnabled(.notion, true)
        } catch {
            NSLog("[SerialNotes/Notion] connect failed: %@", error.localizedDescription)
            errorMessage = "Couldn't finish connecting Notion — \(error.localizedDescription)"
            await restorePersistedStatus()
        }
    }

    /// Best-effort revoke of a token connect exchanged but then abandoned
    /// (cancelled, or destination creation failed) before persisting it —
    /// otherwise the workspace stays authorized on Notion's side with no local
    /// record, the exact leak `disconnect()` exists to prevent.
    private func revokeAbandonedToken(_ token: String) async {
        do {
            try await apiClient.revokeToken(token)
        } catch {
            NSLog("[SerialNotes/Notion] couldn't revoke an abandoned connect token: %@",
                  error.localizedDescription)
        }
    }

    /// Bring the originating window back after the browser round trip — an
    /// `.accessory` app won't re-front on its own.
    private func finishFlow() {
        NSApp.activate()
        let callback = onFlowFinished
        onFlowFinished = nil
        callback?()
    }

    /// Restore the pre-connect status after a cancelled/denied/failed attempt.
    /// Routes through `applyPersistedStatus`, so a reconnect abandoned from
    /// needsReconnect lands back on needsReconnect (the flag is still set),
    /// not a false "connected".
    private func restorePersistedStatus() async {
        await applyPersistedStatus()
    }

    // MARK: - Disconnect

    /// Best-effort revoke (deleting only the local record would leave the
    /// authorization live on Notion's side), then clear the Keychain and turn
    /// the toggle off. The local record clears even when the revoke fails.
    func disconnect() async {
        flow.cancel()
        connectTask?.cancel()
        connectTask = nil
        do {
            try await apiClient.revoke()
        } catch {
            NSLog("[SerialNotes/Notion] revoke failed (clearing local connection anyway): %@",
                  error.localizedDescription)
        }
        do {
            try await credentialStore.clear()
        } catch {
            NSLog("[SerialNotes/Notion] failed to clear Notion credentials: %@", error.localizedDescription)
            errorMessage = "Couldn't remove the stored Notion connection — \(error.localizedDescription)"
        }
        exportSettings?.setEnabled(.notion, false)
        persistedNeedsReconnect = false
        cachedDestination = nil
        status = .disconnected
    }
}

// MARK: - NotionSending (per-meeting export)

extension NotionConnection: NotionSending {
    var exportDestination: NotionExportDestination? {
        // `requestStop` runs synchronously on the main actor, so this reads
        // the cached identity rather than hopping to the Keychain. A self-heal
        // may have moved the destination page since the cache was set; that's
        // fine — the send path checks only the workspace ID from the snapshot
        // and files under the live record's page ID.
        guard case .connected = status else { return nil }
        return cachedDestination
    }

    func sendTranscript(at transcriptURL: URL, destination: NotionExportDestination) {
        // Send-time re-check, mirroring the Bear install re-check: the stop
        // context may be minutes old (deferred behind a successor recording).
        guard case .connected = status else {
            NSLog("[SerialNotes/Notion] skipping export — not connected (transcript kept in the storage folder)")
            return
        }
        let client = apiClient
        Task.detached(priority: .utility) { [weak self] in
            guard let raw = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
                NSLog("[SerialNotes/Notion] could not read %@; skipping export", transcriptURL.lastPathComponent)
                return
            }
            let body = MeetingExporter.strippingManualNotesMarker(
                MeetingExporter.strippingFrontMatter(raw)
            )
            do {
                try await client.sendMeetingTranscript(markdown: body, destination: destination)
            } catch NotionAPIError.needsReconnect {
                NSLog("[SerialNotes/Notion] export skipped — connection needs reauthorization")
                await self?.markNeedsReconnect()
            } catch {
                // Best-effort like every exporter: log and move on; the
                // on-disk transcript is the source of truth.
                NSLog("[SerialNotes/Notion] export failed: %@", error.localizedDescription)
            }
        }
    }

    private func markNeedsReconnect() {
        persistedNeedsReconnect = true
        status = .needsReconnect
    }
}
