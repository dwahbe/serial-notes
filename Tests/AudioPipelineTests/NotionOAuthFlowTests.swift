import Foundation
import Testing

@testable import SerialNotes

@Suite("Notion OAuth Flow")
@MainActor
struct NotionOAuthFlowTests {
    /// Flow with a deterministic state sequence and a recording opener.
    private func makeFlow(
        isDevBuild: Bool = false,
        states: [String] = ["state-1", "state-2", "state-3"]
    ) -> (NotionOAuthFlow, opened: () -> [URL]) {
        let openedBox = Box<[URL]>([])
        let statesBox = Box(states)
        let flow = NotionOAuthFlow(
            isDevBuild: isDevBuild,
            opener: { openedBox.value.append($0) },
            stateGenerator: { statesBox.value.removeFirst() }
        )
        return (flow, { openedBox.value })
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private func callback(_ query: String, scheme: String = "serialnotes") -> URL {
        URL(string: "\(scheme)://oauth/notion?\(query)")!
    }

    @Test("begin() opens the start route with state + flavor")
    func beginBuildsStartURL() {
        let (flow, opened) = makeFlow(isDevBuild: false)
        let url = flow.begin()
        #expect(opened() == [url])
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        #expect(components.host == "serialnotes.app")
        #expect(components.path == "/oauth/notion/start")
        #expect(components.queryItems?.first(where: { $0.name == "state" })?.value == "state-1")
        #expect(components.queryItems?.first(where: { $0.name == "flavor" })?.value == "prod")
    }

    @Test("Dev builds ask for the dev flavor and exchange against the dev redirect URI")
    func devFlavor() {
        let (flow, _) = makeFlow(isDevBuild: true)
        let url = flow.begin()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        #expect(components.queryItems?.first(where: { $0.name == "flavor" })?.value == "dev")
        #expect(flow.redirectURI == "https://serialnotes.app/oauth/notion/dev-callback")
    }

    @Test("Happy path: matching state yields the code, and the state is single-use")
    func happyPath() {
        let (flow, _) = makeFlow()
        flow.begin()
        let url = callback("code=abc123&state=state-1")
        #expect(flow.handleCallback(url) == .success(code: "abc123"))
        // Replaying the same bounce (stale tab, forged URL) must not yield a
        // second success.
        #expect(flow.handleCallback(url) == .staleState)
    }

    @Test("The dev scheme parses the same")
    func devSchemeParses() {
        let (flow, _) = makeFlow(isDevBuild: true)
        flow.begin()
        let url = callback("code=abc&state=state-1", scheme: "serialnotes-dev")
        #expect(flow.handleCallback(url) == .success(code: "abc"))
    }

    @Test("access_denied maps to denied; other errors to failed — both consume the state")
    func errorExits() {
        let (flow, _) = makeFlow()
        flow.begin()
        #expect(flow.handleCallback(callback("error=access_denied&state=state-1")) == .denied)
        #expect(flow.pendingState == nil)

        flow.begin()  // state-2
        #expect(flow.handleCallback(callback("error=server_error&state=state-2"))
            == .failed(error: "server_error"))
        #expect(flow.pendingState == nil)
    }

    @Test("A callback with neither code nor error fails rather than succeeding empty")
    func missingCodeFails() {
        let (flow, _) = makeFlow()
        flow.begin()
        #expect(flow.handleCallback(callback("state=state-1")) == .failed(error: "missing_code"))
    }

    @Test("Mismatched state is stale and leaves the in-flight attempt intact")
    func badStatePreservesAttempt() {
        let (flow, _) = makeFlow()
        flow.begin()
        #expect(flow.handleCallback(callback("code=evil&state=wrong")) == .staleState)
        // The real bounce still completes afterwards.
        #expect(flow.handleCallback(callback("code=abc&state=state-1")) == .success(code: "abc"))
    }

    @Test("A second begin() supersedes the first — the old state is dead, the new one works")
    func supersededAttempt() {
        let (flow, opened) = makeFlow()
        flow.begin()
        flow.begin()
        #expect(opened().count == 2)
        #expect(flow.handleCallback(callback("code=old&state=state-1")) == .staleState)
        #expect(flow.handleCallback(callback("code=new&state=state-2")) == .success(code: "new"))
    }

    @Test("Callbacks with no attempt in flight are stale")
    func noAttemptIsStale() {
        let (flow, _) = makeFlow()
        #expect(flow.handleCallback(callback("code=abc&state=state-1")) == .staleState)
    }

    @Test("cancel() kills the in-flight attempt")
    func cancelKillsAttempt() {
        let (flow, _) = makeFlow()
        flow.begin()
        flow.cancel()
        #expect(flow.handleCallback(callback("code=abc&state=state-1")) == .staleState)
    }

    @Test("URLs that aren't the OAuth callback are ignored, not consumed")
    func foreignURLsIgnored() {
        let (flow, _) = makeFlow()
        flow.begin()
        #expect(flow.handleCallback(URL(string: "serialnotes://something/else?code=x")!) == nil)
        // Attempt untouched by the foreign URL.
        #expect(flow.handleCallback(callback("code=abc&state=state-1")) == .success(code: "abc"))
    }

    @Test("Generated states are unique, long, and URL-safe")
    func randomStateShape() {
        let one = NotionOAuthFlow.randomState()
        let two = NotionOAuthFlow.randomState()
        #expect(one != two)
        #expect(one.count == 64)
        #expect(one.allSatisfy { $0.isHexDigit })
    }
}
