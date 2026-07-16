import Foundation

/// Failures the Notion layer surfaces. `needsReconnect` is the one the UI keys
/// off (the connection can only be repaired by re-authorizing); everything else
/// is logged by the best-effort export path.
enum NotionAPIError: Error, LocalizedError, Equatable {
    /// No credential record — never connected, or disconnected mid-flight.
    case notConnected
    /// The refresh token was rejected; only a fresh OAuth round trip helps.
    case needsReconnect
    /// The connected workspace changed between the stop press and the deferred
    /// send — the snapshot's destination no longer belongs to this connection.
    case workspaceChanged
    /// The destination page 404'd (deleted/archived) — self-heal recreates it.
    case destinationMissing
    /// Notion caps request bodies at 500 KB; the transcript stays on disk.
    case bodyTooLarge(bytes: Int)
    /// Still rate-limited after honoring one Retry-After pause.
    case rateLimited
    /// Any other HTTP failure, with Notion's machine-readable error code.
    case http(status: Int, code: String?)
    /// The transport failed (timeout, connection lost). Deliberately never
    /// retried: the request may have reached Notion, there is no idempotency
    /// key, and a duplicate page is worse than a missing one — `transcript.md`
    /// on disk is always the source of truth.
    case transport(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Notion isn't connected."
        case .needsReconnect: return "The Notion connection expired — reconnect in Settings."
        case .workspaceChanged: return "The Notion workspace changed since this meeting ended."
        case .destinationMissing: return "The Meeting Notes page in Notion is missing."
        case .bodyTooLarge(let bytes): return "Transcript too large for Notion (\(bytes) bytes)."
        case .rateLimited: return "Notion is rate-limiting requests."
        case .http(let status, let code): return "Notion request failed (\(status)\(code.map { ", \($0)" } ?? ""))."
        case .transport(let detail): return "Couldn't reach Notion — \(detail)."
        case .invalidResponse: return "Notion returned an unexpected response."
        }
    }
}

/// The fields the app keeps from Notion's token endpoint (exchange + refresh
/// share one response shape; the proxy passes it through verbatim).
struct NotionTokenResponse: Decodable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let botID: String
    let workspaceID: String
    let workspaceName: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case botID = "bot_id"
        case workspaceID = "workspace_id"
        case workspaceName = "workspace_name"
    }
}

/// Talks to `api.notion.com` (page creation, with the stored access token) and
/// to the site's token proxy (exchange/refresh/revoke — the proxy adds the
/// client-secret Basic auth Notion requires; see `site/src/pages/api/notion/`).
///
/// An actor, but actor isolation alone does NOT serialize the multi-await send
/// flow (two sends can interleave across their `await`s), so meeting sends are
/// explicitly chained through `sendChain`: two deferred exports can't both read
/// a stale destination and both self-heal it into duplicate pages, and
/// back-to-back meetings are created in call order. Credentials are re-read
/// from the store after every await — Notion rotates refresh tokens, and a
/// concurrent flight (or a reconnect) may have replaced them.
actor NotionAPIClient {
    /// Markdown Content API — `POST /v1/pages` accepts a raw `markdown` field
    /// and derives the page title from its first H1.
    static let notionVersion = "2026-03-11"
    /// Notion's documented request-body cap.
    static let maxRequestBodyBytes = 500_000
    /// Title of the workspace-level destination page (and its H1, which is
    /// what Notion derives the title from).
    static let destinationTitle = "Meeting Notes"
    /// Ceiling on how long a Retry-After pause is honored before giving up.
    static let maxRetryAfterSeconds: Double = 30

    private let credentialStore: NotionCredentialStore
    private let urlSession: URLSession
    private let tokenProxyURL: URL
    private let pagesURL: URL
    /// Single-flight refresh: concurrent 401s share one in-flight refresh
    /// (actor isolation alone doesn't prevent interleaving across awaits, and
    /// a double refresh would burn the rotated token the first one just saved).
    private var refreshTask: Task<Void, any Error>?
    /// Tail of the meeting-send chain. Each `sendMeetingTranscript` awaits its
    /// predecessor before touching the store, so sends run one at a time in
    /// FIFO order — the actual serialization the class comment promises.
    private var sendChain: Task<Void, Never>?

    init(
        credentialStore: NotionCredentialStore,
        urlSession: URLSession = .shared,
        tokenProxyURL: URL = URL(string: "https://serialnotes.app/api/notion/token")!,
        notionAPIBase: URL = URL(string: "https://api.notion.com")!
    ) {
        self.credentialStore = credentialStore
        self.urlSession = urlSession
        self.tokenProxyURL = tokenProxyURL
        self.pagesURL = notionAPIBase.appendingPathComponent("v1/pages")
    }

    // MARK: - OAuth (via the site proxy)

    /// Exchange an authorization code. Pure request/response — persisting the
    /// resulting record is the connection's job (nothing is stored until the
    /// whole connect, destination page included, succeeds).
    func exchangeAuthorizationCode(_ code: String, redirectURI: String) async throws -> NotionTokenResponse {
        let (data, response) = try await proxyPost([
            "action": "exchange", "code": code, "redirect_uri": redirectURI,
        ])
        guard response.statusCode == 200 else {
            throw NotionAPIError.http(status: response.statusCode, code: Self.notionErrorCode(in: data))
        }
        guard let token = try? JSONDecoder().decode(NotionTokenResponse.self, from: data) else {
            throw NotionAPIError.invalidResponse
        }
        return token
    }

    /// Revoke the stored authorization (disconnect). Deleting only the local
    /// record would leave the workspace connection authorized on Notion's side.
    func revoke() async throws {
        guard let credentials = try await credentialStore.load() else { return }
        try await revokeToken(credentials.accessToken)
    }

    /// Revoke a specific access token. Used by `revoke()` (disconnect) and to
    /// clean up a token that connect exchanged but then abandoned (cancel /
    /// destination-creation failure), where nothing was persisted for
    /// `revoke()` to load.
    func revokeToken(_ token: String) async throws {
        let (data, response) = try await proxyPost(["action": "revoke", "token": token])
        guard response.statusCode == 200 else {
            throw NotionAPIError.http(status: response.statusCode, code: Self.notionErrorCode(in: data))
        }
    }

    // MARK: - Pages

    /// Create the workspace-level "Meeting Notes" destination page with an
    /// explicit token — used during connect, before anything is persisted.
    /// Returns the new page's ID.
    func createDestinationPage(accessToken: String) async throws -> String {
        let body = try Self.encodeCreatePage(title: Self.destinationTitle, markdown: nil, parentPageID: nil)
        let (data, response) = try await notionPost(body: body, accessToken: accessToken)
        return try Self.pageID(fromCreateResponse: data, status: response.statusCode)
    }

    /// Recreate the destination using stored credentials (the 404 self-heal),
    /// persisting the new page ID. Returns it. `expectedWorkspaceID` guards
    /// every reload so a reconnect mid-flight can't file into the wrong space.
    private func recreateDestination(expectedWorkspaceID: String?) async throws -> String {
        let body = try Self.encodeCreatePage(title: Self.destinationTitle, markdown: nil, parentPageID: nil)
        let (data, response) = try await authorizedNotionPost(body: body, expectedWorkspaceID: expectedWorkspaceID)
        let pageID = try Self.pageID(fromCreateResponse: data, status: response.statusCode)
        try await credentialStore.updateDestinationPageID(pageID, expectedWorkspaceID: expectedWorkspaceID)
        return pageID
    }

    /// Send one finished meeting into the destination. The `destination` is the
    /// identity snapshotted at the stop press (never tokens — credentials are
    /// loaded fresh here). Skips with `workspaceChanged` when the connection
    /// was replaced since the stop; self-heals a deleted destination once.
    ///
    /// Serialized through `sendChain`: sends run one at a time in call order, so
    /// two deferred exports can't both observe a stale destination and race the
    /// self-heal into duplicate "Meeting Notes" pages.
    func sendMeetingTranscript(markdown: String, destination: NotionExportDestination) async throws {
        let predecessor = sendChain
        let work = Task { () -> Result<Void, any Error> in
            await predecessor?.value
            do {
                try await self.performSend(markdown: markdown, destination: destination)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        // Successors await this send's completion before starting (FIFO).
        sendChain = Task { _ = await work.value }
        switch await work.value {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }

    private func performSend(markdown: String, destination: NotionExportDestination) async throws {
        let credentials = try await loadVerifiedCredentials(expectedWorkspaceID: destination.workspaceID)
        // The transcript's `# Meeting — …` H1 becomes the page's explicit
        // title (insert-only grants get no H1→title derivation from Notion).
        let (title, body) = Self.titleAndBody(fromMarkdown: markdown)
        // Prefer the live record's destination — an earlier export may already
        // have self-healed past the snapshot's page.
        let parentID = credentials.destinationPageID
        do {
            try await createPage(title: title, markdown: body, parentPageID: parentID, expectedWorkspaceID: destination.workspaceID)
        } catch NotionAPIError.destinationMissing {
            let newParent = try await recreateDestination(expectedWorkspaceID: destination.workspaceID)
            try await createPage(title: title, markdown: body, parentPageID: newParent, expectedWorkspaceID: destination.workspaceID)
        }
    }

    private func createPage(title: String?, markdown: String?, parentPageID: String, expectedWorkspaceID: String?) async throws {
        let body = try Self.encodeCreatePage(title: title, markdown: markdown, parentPageID: parentPageID)
        let (data, response) = try await authorizedNotionPost(
            body: body,
            expectedWorkspaceID: expectedWorkspaceID,
            // This create has a parent, so an archived-parent rejection means
            // the destination sits in Notion's Trash — heal it like a 404.
            treatArchivedParentAsMissing: true
        )
        _ = try Self.pageID(fromCreateResponse: data, status: response.statusCode)
    }

    // MARK: - Authorized request plumbing

    /// Load the stored record, failing with `workspaceChanged` when a reconnect
    /// has swapped in a different workspace since the send's snapshot — so a
    /// reload after a refresh can never POST one workspace's token at another's
    /// page.
    private func loadVerifiedCredentials(expectedWorkspaceID: String?) async throws -> NotionCredentials {
        guard let credentials = try await credentialStore.load() else { throw NotionAPIError.notConnected }
        if let expectedWorkspaceID, credentials.workspaceID != expectedWorkspaceID {
            throw NotionAPIError.workspaceChanged
        }
        return credentials
    }

    /// POST to /v1/pages with the stored token. A single retry loop: a 401 at
    /// ANY point (including one that surfaces only after a 429 pause let the
    /// token expire) buys one refresh; a 429 buys one honored Retry-After
    /// pause; the token is reloaded (and workspace-rechecked) each iteration.
    /// Nothing ambiguous is retried.
    private func authorizedNotionPost(
        body: Data,
        expectedWorkspaceID: String?,
        treatArchivedParentAsMissing: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        var didRefresh = false
        var didPauseForRateLimit = false
        while true {
            let credentials = try await loadVerifiedCredentials(expectedWorkspaceID: expectedWorkspaceID)
            let (data, response) = try await notionPost(body: body, accessToken: credentials.accessToken)
            switch response.statusCode {
            case 200...299:
                return (data, response)
            case 401:
                guard !didRefresh else { throw NotionAPIError.needsReconnect }
                didRefresh = true
                try await refreshTokens(failedAccessToken: credentials.accessToken)
            case 429:
                guard !didPauseForRateLimit else { throw NotionAPIError.rateLimited }
                didPauseForRateLimit = true
                let delay = min(Self.retryAfterSeconds(response) ?? 2, Self.maxRetryAfterSeconds)
                // Propagate cancellation instead of swallowing it — a cancelled
                // task must abort here, not skip the pause and re-POST.
                try await Task.sleep(for: .seconds(delay))
            case 404:
                throw NotionAPIError.destinationMissing
            case 400 where treatArchivedParentAsMissing && Self.indicatesArchivedParent(data):
                // A trashed destination doesn't 404 — Notion keeps the page
                // (archived/in_trash, up to ~30 days) and rejects child
                // creation with 400 validation_error (confirmed live
                // 2026-07-16). Same self-heal as a hard delete.
                throw NotionAPIError.destinationMissing
            default:
                throw NotionAPIError.http(status: response.statusCode, code: Self.notionErrorCode(in: data))
            }
        }
    }

    private func notionPost(body: Data, accessToken: String) async throws -> (Data, HTTPURLResponse) {
        guard body.count <= Self.maxRequestBodyBytes else {
            throw NotionAPIError.bodyTooLarge(bytes: body.count)
        }
        var request = URLRequest(url: pagesURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.notionVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request)
    }

    // MARK: - Refresh (single-flight)

    private func refreshTokens(failedAccessToken: String) async throws {
        let task: Task<Void, any Error>
        if let inflight = refreshTask {
            task = inflight
        } else {
            let started = Task {
                defer { self.refreshTask = nil }
                try await self.performRefresh(failedAccessToken: failedAccessToken)
            }
            refreshTask = started
            task = started
        }
        try await task.value
    }

    private func performRefresh(failedAccessToken: String) async throws {
        guard let credentials = try await credentialStore.load() else { throw NotionAPIError.notConnected }
        // A concurrent flight already rotated the tokens while this caller was
        // waiting on its 401 — its retry should just use the fresh record.
        guard credentials.accessToken == failedAccessToken else { return }
        guard !credentials.refreshToken.isEmpty else { throw NotionAPIError.needsReconnect }
        // The connection this refresh belongs to — a reconnect to a different
        // workspace mid-flight must not get its record stamped with these tokens.
        let identityWorkspaceID = credentials.workspaceID
        let identityBotID = credentials.botID

        let (data, response) = try await proxyPost([
            "action": "refresh", "refresh_token": credentials.refreshToken,
        ])
        switch response.statusCode {
        case 200:
            guard let token = try? JSONDecoder().decode(NotionTokenResponse.self, from: data) else {
                throw NotionAPIError.invalidResponse
            }
            // Notion rotates the refresh token; persist the new pair (keeping
            // the old refresh token if the response ever omits one) only if the
            // stored record still belongs to the same connection.
            try await credentialStore.updateTokens(
                accessToken: token.accessToken,
                refreshToken: token.refreshToken ?? credentials.refreshToken,
                expectedWorkspaceID: identityWorkspaceID,
                expectedBotID: identityBotID
            )
        case 408, 429:
            // A timeout or rate limit on the token endpoint is transient — the
            // refresh token is still valid, so DON'T force a reconnect for it.
            throw NotionAPIError.rateLimited
        case 400...499:
            // The refresh grant itself was rejected — only re-authorizing helps.
            throw NotionAPIError.needsReconnect
        default:
            // Proxy or Notion hiccup: transient, NOT a reason to force re-auth.
            throw NotionAPIError.http(status: response.statusCode, code: Self.notionErrorCode(in: data))
        }
    }

    // MARK: - Transport

    private func proxyPost(_ payload: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: tokenProxyURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw NotionAPIError.invalidResponse }
            return (data, http)
        } catch let error as NotionAPIError {
            throw error
        } catch {
            throw NotionAPIError.transport(error.localizedDescription)
        }
    }

    // MARK: - Request/response helpers (pure, unit-tested)

    private struct CreatePageBody: Encodable {
        struct Parent: Encodable {
            let pageID: String
            enum CodingKeys: String, CodingKey { case pageID = "page_id" }
        }

        struct RichText: Encodable {
            let type = "text"
            let text: Content
            struct Content: Encodable { let content: String }
        }

        struct Properties: Encodable {
            let title: TitleValue
            struct TitleValue: Encodable { let title: [RichText] }
        }

        /// nil creates a workspace-level page (lands in the user's Private
        /// section) — only public connections may do this.
        let parent: Parent?
        let properties: Properties?
        let markdown: String?
    }

    /// Build the create-page body with an EXPLICIT `properties.title`. Notion's
    /// documented H1→title derivation requires the `insert_property` capability
    /// — under this integration's insert-content-only grant it silently skips
    /// and pages arrive untitled ("New page"), confirmed live 2026-07-16.
    /// Setting the title at *creation* time is an insert-content operation, so
    /// the title is lifted client-side instead (see `titleAndBody`).
    static func encodeCreatePage(title: String?, markdown: String?, parentPageID: String?) throws -> Data {
        let body = CreatePageBody(
            parent: parentPageID.map { CreatePageBody.Parent(pageID: $0) },
            properties: title.map {
                CreatePageBody.Properties(
                    title: .init(title: [.init(text: .init(content: $0))])
                )
            },
            markdown: (markdown?.isEmpty ?? true) ? nil : markdown
        )
        return try JSONEncoder().encode(body)
    }

    /// Split the leading H1 off a transcript body: it becomes the page's
    /// explicit title (see `encodeCreatePage`), and the heading is dropped from
    /// the markdown so the page doesn't open with a duplicate of its own title.
    /// Bodies without a leading H1 pass through untouched (untitled page).
    static func titleAndBody(fromMarkdown markdown: String) -> (title: String?, body: String) {
        var lines = markdown.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return (nil, markdown)
        }
        let first = lines[index].trimmingCharacters(in: .whitespaces)
        guard first.hasPrefix("# ") else { return (nil, markdown) }
        let title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return (nil, markdown) }
        // Drop everything through the heading (leading blanks included), plus
        // the blank padding after it, so the body starts at real content.
        lines.removeSubrange(0...index)
        while let next = lines.first, next.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        return (title, lines.joined(separator: "\n"))
    }

    static func pageID(fromCreateResponse data: Data, status: Int) throws -> String {
        guard (200...299).contains(status) else {
            switch status {
            case 401: throw NotionAPIError.needsReconnect
            case 404: throw NotionAPIError.destinationMissing
            case 429: throw NotionAPIError.rateLimited
            default: throw NotionAPIError.http(status: status, code: notionErrorCode(in: data))
            }
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["id"] as? String
        else { throw NotionAPIError.invalidResponse }
        return id
    }

    /// Regular Notion API errors are `{"object":"error","code":…,"message":…}`,
    /// but the OAuth token endpoints (and the site proxy's own rejections) use
    /// the OAuth shape `{"error":…,"error_description":…}` — read whichever
    /// machine-readable field is present so exchange/refresh/revoke failures
    /// don't surface with a nil reason.
    static func notionErrorCode(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["code"] as? String) ?? (object["error"] as? String)
    }

    /// Whether a 400 body is the "parent is archived/in Trash" rejection.
    /// Under insert-only capability the parent can't be *read* to check its
    /// state, so the error message is the only signal. Its wording isn't
    /// contractual — if Notion rewords it away from "archive"/"trash", this
    /// returns false and the export degrades to log-and-skip (the pre-heal
    /// behavior), never to a wrong heal.
    static func indicatesArchivedParent(_ data: Data) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["code"] as? String == "validation_error",
            let message = object["message"] as? String
        else { return false }
        let lowered = message.lowercased()
        return lowered.contains("archiv") || lowered.contains("trash")
    }

    static func retryAfterSeconds(_ response: HTTPURLResponse) -> Double? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return Double(value.trimmingCharacters(in: .whitespaces))
    }
}
