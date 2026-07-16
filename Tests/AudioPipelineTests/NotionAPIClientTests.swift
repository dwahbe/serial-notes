import Foundation
import Testing
import os

@testable import SerialNotes

// MARK: - URLProtocol stub

/// Routes every request the client's injected `URLSession` makes through a
/// test-installed closure, recording it (URL, headers, body) for assertions.
/// State is static (URLProtocol offers no injection point), so the suite runs
/// `.serialized`.
final class NotionURLStub: URLProtocol {
    struct RecordedRequest: Sendable {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: Data

        var bodyJSON: [String: Any]? {
            try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
    }

    enum Response {
        case http(status: Int, body: Data, headers: [String: String])
        case transportError(any Error)
    }

    typealias Route = @Sendable (RecordedRequest) -> Response

    private static let state = OSAllocatedUnfairLock<(requests: [RecordedRequest], route: Route?)>(
        initialState: ([], nil)
    )

    static func install(_ route: @escaping Route) {
        state.withLock { $0 = ([], route) }
    }

    static var requests: [RecordedRequest] {
        state.withLock { $0.requests }
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NotionURLStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let recorded = RecordedRequest(
            url: request.url!,
            method: request.httpMethod ?? "",
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.drainBody(of: request)
        )
        let route = Self.state.withLock { state -> Route? in
            state.requests.append(recorded)
            return state.route
        }
        guard let route else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch route(recorded) {
        case .transportError(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .http(let status, let body, let headers):
            let response = HTTPURLResponse(
                url: recorded.url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    /// URLSession hands protocols the body as a stream, not `httpBody`.
    private static func drainBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - Suite

@Suite("Notion API Client", .serialized)
struct NotionAPIClientTests {
    private static let proxyURL = URL(string: "https://proxy.test/api/notion/token")!
    private static let apiBase = URL(string: "https://notion.test")!
    private static let destination = NotionExportDestination(workspaceID: "ws-1", pageID: "page-1")

    private static func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private static func tokenResponse(access: String, refresh: String) -> Data {
        json([
            "access_token": access,
            "refresh_token": refresh,
            "bot_id": "bot-1",
            "workspace_id": "ws-1",
            "workspace_name": "Acme",
        ])
    }

    private static func notionError(status: Int, code: String) -> NotionURLStub.Response {
        .http(
            status: status,
            body: json(["object": "error", "status": status, "code": code, "message": code]),
            headers: [:]
        )
    }

    private static func page(_ id: String) -> NotionURLStub.Response {
        .http(status: 200, body: json(["object": "page", "id": id]), headers: [:])
    }

    /// Client + seeded credential store over the URLProtocol-stubbed session.
    private func makeClient() async throws -> (NotionAPIClient, NotionCredentialStore) {
        let store = NotionCredentialStore(keychain: InMemoryKeychain(), service: "test.notion")
        try await store.save(NotionCredentials(
            workspaceID: "ws-1",
            workspaceName: "Acme",
            botID: "bot-1",
            destinationPageID: "page-1",
            accessToken: "access-1",
            refreshToken: "refresh-1"
        ))
        let client = NotionAPIClient(
            credentialStore: store,
            urlSession: NotionURLStub.makeSession(),
            tokenProxyURL: Self.proxyURL,
            notionAPIBase: Self.apiBase
        )
        return (client, store)
    }

    private static func isPages(_ request: NotionURLStub.RecordedRequest) -> Bool {
        request.url.host == "notion.test"
    }

    private static func isProxy(_ request: NotionURLStub.RecordedRequest) -> Bool {
        request.url.host == "proxy.test"
    }

    // MARK: Request construction

    /// The `properties.title` rich-text content of a create-page request body.
    private static func titleContent(of body: [String: Any]?) -> String? {
        let properties = body?["properties"] as? [String: Any]
        let titleValue = properties?["title"] as? [String: Any]
        let richTexts = titleValue?["title"] as? [[String: Any]]
        return (richTexts?.first?["text"] as? [String: Any])?["content"] as? String
    }

    @Test("createPage request: URL, version pin, bearer token, parent + explicit title + H1-stripped markdown")
    func requestConstruction() async throws {
        NotionURLStub.install { _ in Self.page("p-1") }
        let (client, _) = try await makeClient()
        try await client.sendMeetingTranscript(
            markdown: "# Meeting — test\n\nHello there.", destination: Self.destination
        )

        let requests = NotionURLStub.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url.absoluteString == "https://notion.test/v1/pages")
        #expect(request.method == "POST")
        #expect(request.headers["Notion-Version"] == "2026-03-11")
        #expect(request.headers["Authorization"] == "Bearer access-1")
        #expect(request.headers["Content-Type"] == "application/json")
        let body = try #require(request.bodyJSON)
        // The H1 is lifted into an explicit properties.title (insert-only
        // grants get no H1→title derivation from Notion) and dropped from the
        // markdown body.
        #expect(Self.titleContent(of: body) == "Meeting — test")
        #expect(body["markdown"] as? String == "Hello there.")
        #expect((body["parent"] as? [String: Any])?["page_id"] as? String == "page-1")
    }

    @Test("titleAndBody lifts the leading H1 and leaves everything else alone")
    func titleLift() {
        let lifted = NotionAPIClient.titleAndBody(fromMarkdown: "# Meeting — 3 PM\n\n## Notes\n\n- hi")
        #expect(lifted.title == "Meeting — 3 PM")
        #expect(lifted.body == "## Notes\n\n- hi")

        // Leading blank lines are skipped to find the H1.
        let padded = NotionAPIClient.titleAndBody(fromMarkdown: "\n\n# Title\nbody")
        #expect(padded.title == "Title")
        #expect(padded.body == "body")

        // No leading H1 (or a deeper heading) → untouched, untitled.
        let noHeading = NotionAPIClient.titleAndBody(fromMarkdown: "## Notes\n\n- hi")
        #expect(noHeading.title == nil)
        #expect(noHeading.body == "## Notes\n\n- hi")

        // An empty H1 is not a usable title.
        let emptyHeading = NotionAPIClient.titleAndBody(fromMarkdown: "# \nbody")
        #expect(emptyHeading.title == nil)
    }

    @Test("Exchange posts action/code/redirect_uri to the proxy and decodes the token")
    func exchangeShape() async throws {
        NotionURLStub.install { _ in
            .http(status: 200, body: Self.tokenResponse(access: "A1", refresh: "R1"), headers: [:])
        }
        let (client, _) = try await makeClient()
        let token = try await client.exchangeAuthorizationCode("code-1", redirectURI: "https://serialnotes.app/oauth/notion/callback")
        #expect(token.accessToken == "A1")
        #expect(token.workspaceID == "ws-1")

        let request = try #require(NotionURLStub.requests.first)
        #expect(request.url == Self.proxyURL)
        let body = try #require(request.bodyJSON)
        #expect(body["action"] as? String == "exchange")
        #expect(body["code"] as? String == "code-1")
        #expect(body["redirect_uri"] as? String == "https://serialnotes.app/oauth/notion/callback")
    }

    @Test("Revoke posts the stored access token to the proxy")
    func revokeShape() async throws {
        NotionURLStub.install { _ in .http(status: 200, body: Self.json([:]), headers: [:]) }
        let (client, _) = try await makeClient()
        try await client.revoke()

        let requests = NotionURLStub.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url == Self.proxyURL)
        let body = try #require(request.bodyJSON)
        #expect(body["action"] as? String == "revoke")
        #expect(body["token"] as? String == "access-1")
    }

    // MARK: Refresh

    @Test("401 → refresh → retry once, with the rotated refresh token persisted")
    func refreshOn401() async throws {
        NotionURLStub.install { request in
            if Self.isProxy(request) {
                return .http(status: 200, body: Self.tokenResponse(access: "A2", refresh: "R2"), headers: [:])
            }
            if request.headers["Authorization"] == "Bearer A2" { return Self.page("p-1") }
            return Self.notionError(status: 401, code: "unauthorized")
        }
        let (client, store) = try await makeClient()
        try await client.sendMeetingTranscript(markdown: "# M", destination: Self.destination)

        let requests = NotionURLStub.requests
        #expect(requests.filter(Self.isPages).count == 2)  // stale attempt + one retry
        #expect(requests.filter(Self.isProxy).count == 1)
        let refresh = try #require(requests.first(where: Self.isProxy))
        #expect(refresh.bodyJSON?["action"] as? String == "refresh")
        #expect(refresh.bodyJSON?["refresh_token"] as? String == "refresh-1")

        let credentials = try await store.load()
        #expect(credentials?.accessToken == "A2")
        #expect(credentials?.refreshToken == "R2")  // Notion rotates; the new pair must stick
    }

    @Test("Concurrent 401s share a single refresh — exactly one recorded")
    func singleFlightRefresh() async throws {
        NotionURLStub.install { request in
            if Self.isProxy(request) {
                return .http(status: 200, body: Self.tokenResponse(access: "A2", refresh: "R2"), headers: [:])
            }
            if request.headers["Authorization"] == "Bearer A2" { return Self.page("p-ok") }
            return Self.notionError(status: 401, code: "unauthorized")
        }
        let (client, _) = try await makeClient()
        async let first: Void = client.sendMeetingTranscript(markdown: "# A", destination: Self.destination)
        async let second: Void = client.sendMeetingTranscript(markdown: "# B", destination: Self.destination)
        try await first
        try await second

        // However the two flights interleave (both 401 before the refresh, or
        // one 401 after it), the rotated grant must be burned exactly once.
        #expect(NotionURLStub.requests.filter(Self.isProxy).count == 1)
    }

    @Test("A rejected refresh surfaces needsReconnect, not a retry loop")
    func rejectedRefreshNeedsReconnect() async throws {
        NotionURLStub.install { request in
            if Self.isProxy(request) {
                return Self.notionError(status: 400, code: "invalid_grant")
            }
            return Self.notionError(status: 401, code: "unauthorized")
        }
        let (client, _) = try await makeClient()
        await #expect(throws: NotionAPIError.needsReconnect) {
            try await client.sendMeetingTranscript(markdown: "# M", destination: Self.destination)
        }
        #expect(NotionURLStub.requests.filter(Self.isPages).count == 1)
        #expect(NotionURLStub.requests.filter(Self.isProxy).count == 1)
    }

    // MARK: Failure rules

    @Test("429 honors Retry-After and retries once")
    func rateLimitHonorsRetryAfter() async throws {
        let hits = OSAllocatedUnfairLock(initialState: 0)
        NotionURLStub.install { _ in
            let attempt = hits.withLock { $0 += 1; return $0 }
            if attempt == 1 {
                return .http(status: 429, body: Self.json([:]), headers: ["Retry-After": "0"])
            }
            return Self.page("p-1")
        }
        let (client, _) = try await makeClient()
        try await client.sendMeetingTranscript(markdown: "# M", destination: Self.destination)
        #expect(NotionURLStub.requests.count == 2)
    }

    @Test("Still rate-limited after the honored pause throws rateLimited")
    func persistentRateLimitThrows() async throws {
        NotionURLStub.install { _ in
            .http(status: 429, body: Self.json([:]), headers: ["Retry-After": "0"])
        }
        let (client, _) = try await makeClient()
        await #expect(throws: NotionAPIError.rateLimited) {
            try await client.sendMeetingTranscript(markdown: "# M", destination: Self.destination)
        }
        #expect(NotionURLStub.requests.count == 2)  // original + the one honored retry
    }

    @Test("Oversized body is rejected before anything is sent")
    func bodyGuardBlocksSend() async throws {
        NotionURLStub.install { _ in Self.page("p-1") }
        let (client, _) = try await makeClient()
        let marathon = "# M\n" + String(repeating: "a", count: NotionAPIClient.maxRequestBodyBytes)
        do {
            try await client.sendMeetingTranscript(markdown: marathon, destination: Self.destination)
            Issue.record("expected bodyTooLarge")
        } catch let error as NotionAPIError {
            guard case .bodyTooLarge = error else {
                Issue.record("expected bodyTooLarge, got \(error)")
                return
            }
        }
        #expect(NotionURLStub.requests.isEmpty)
    }

    @Test("Ambiguous transport failure is never retried — the request may have landed")
    func ambiguousFailureNoRetry() async throws {
        NotionURLStub.install { _ in .transportError(URLError(.timedOut)) }
        let (client, _) = try await makeClient()
        do {
            try await client.sendMeetingTranscript(markdown: "# M", destination: Self.destination)
            Issue.record("expected transport error")
        } catch let error as NotionAPIError {
            guard case .transport = error else {
                Issue.record("expected transport, got \(error)")
                return
            }
        }
        #expect(NotionURLStub.requests.count == 1)
    }

    // MARK: Destination

    @Test("Deleted destination self-heals: parentless recreate, new ID persisted, one retry")
    func destinationSelfHeal() async throws {
        NotionURLStub.install { request in
            guard Self.isPages(request) else {
                return Self.notionError(status: 400, code: "unexpected_proxy_call")
            }
            let parentID = (request.bodyJSON?["parent"] as? [String: Any])?["page_id"] as? String
            switch parentID {
            case "page-1": return Self.notionError(status: 404, code: "object_not_found")
            case nil: return Self.page("page-2")  // the parentless workspace-level recreate
            case "page-2": return Self.page("p-meeting")
            default: return Self.notionError(status: 400, code: "unexpected_parent")
            }
        }
        let (client, store) = try await makeClient()
        try await client.sendMeetingTranscript(markdown: "# M", destination: Self.destination)

        #expect(NotionURLStub.requests.count == 3)
        let recreate = try #require(NotionURLStub.requests.dropFirst().first)
        #expect(recreate.bodyJSON?["parent"] == nil)
        #expect(recreate.bodyJSON?["markdown"] == nil)
        #expect(Self.titleContent(of: recreate.bodyJSON) == "Meeting Notes")
        #expect(try await store.load()?.destinationPageID == "page-2")
    }

    @Test("Trashed destination (400 archived-parent) self-heals like a 404")
    func trashedDestinationSelfHeals() async throws {
        NotionURLStub.install { request in
            guard Self.isPages(request) else {
                return Self.notionError(status: 400, code: "unexpected_proxy_call")
            }
            let parentID = (request.bodyJSON?["parent"] as? [String: Any])?["page_id"] as? String
            switch parentID {
            case "page-1":
                // Notion's live rejection for a parent sitting in Trash
                // (confirmed 2026-07-16): 400 validation_error, not 404.
                return .http(
                    status: 400,
                    body: Self.json([
                        "object": "error", "status": 400, "code": "validation_error",
                        "message": "Can't create a page in an archived parent page.",
                    ]),
                    headers: [:]
                )
            case nil: return Self.page("page-2")
            case "page-2": return Self.page("p-meeting")
            default: return Self.notionError(status: 400, code: "unexpected_parent")
            }
        }
        let (client, store) = try await makeClient()
        try await client.sendMeetingTranscript(markdown: "# M\n\nbody", destination: Self.destination)

        #expect(NotionURLStub.requests.count == 3)
        #expect(try await store.load()?.destinationPageID == "page-2")
    }

    @Test("An unrelated validation error does NOT trigger the self-heal")
    func bodyValidationErrorDoesNotHeal() async throws {
        NotionURLStub.install { _ in
            .http(
                status: 400,
                body: Self.json([
                    "object": "error", "status": 400, "code": "validation_error",
                    "message": "body.markdown should be a string.",
                ]),
                headers: [:]
            )
        }
        let (client, store) = try await makeClient()
        await #expect(throws: NotionAPIError.http(status: 400, code: "validation_error")) {
            try await client.sendMeetingTranscript(markdown: "# M\n\nbody", destination: Self.destination)
        }
        // No recreate attempt, destination pointer untouched.
        #expect(NotionURLStub.requests.count == 1)
        #expect(try await store.load()?.destinationPageID == "page-1")
    }

    @Test("A snapshot from a replaced workspace is skipped, not sent")
    func workspaceChangedSkips() async throws {
        NotionURLStub.install { _ in Self.page("p-1") }
        let (client, _) = try await makeClient()
        let stale = NotionExportDestination(workspaceID: "ws-old", pageID: "page-1")
        await #expect(throws: NotionAPIError.workspaceChanged) {
            try await client.sendMeetingTranscript(markdown: "# M", destination: stale)
        }
        #expect(NotionURLStub.requests.isEmpty)
    }
}
