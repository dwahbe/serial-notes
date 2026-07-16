import AppKit
import Foundation
import Security

/// The browser round trip of "Connect Notion": generate a one-shot `state`,
/// open the site's `/oauth/notion/start` in the *default browser* (the user is
/// already logged into Notion there — an `ASWebAuthenticationSession` would
/// fall back to Safari for browsers that don't implement session handling,
/// e.g. Arc, forcing a fresh Notion login), and parse the custom-scheme
/// callback the site bounces back.
///
/// Known residual risk, accepted in the design review: without PKCE, a
/// malicious local app registering the same URL scheme could race for the
/// authorization code. Mitigations: `state` is bound to a single in-flight
/// attempt and cleared on first use, codes are one-shot and short-lived, and
/// the exchange still runs through our proxy (client-secret gated).
///
/// Every exit is explicit: success, denial/error on the consent screen, a
/// stale or superseded attempt, and quit mid-flow (state is in-memory only —
/// nothing persists, so relaunching shows the disconnected state).
@MainActor
final class NotionOAuthFlow {
    enum CallbackOutcome: Equatable {
        /// Verified `state`; ready to exchange the code.
        case success(code: String)
        /// The user canceled or denied on Notion's consent screen.
        case denied
        /// Notion reported some other error.
        case failed(error: String)
        /// No attempt in flight, or the `state` didn't match (an expired page
        /// re-bounced, a superseded attempt, or a forged callback). Ignored.
        case staleState
    }

    /// Byte-exact copies of the redirect URIs registered in Notion's developer
    /// portal — the token exchange must send the same `redirect_uri` the
    /// authorize step used (start.ts picks it from the flavor).
    nonisolated static func redirectURI(isDevBuild: Bool) -> String {
        isDevBuild
            ? "https://serialnotes.app/oauth/notion/dev-callback"
            : "https://serialnotes.app/oauth/notion/callback"
    }

    nonisolated static let defaultStartURL = URL(string: "https://serialnotes.app/oauth/notion/start")!

    /// The `state` of the one attempt in flight; nil when none is.
    private(set) var pendingState: String?

    private let startURL: URL
    private let isDevBuild: Bool
    private let opener: @MainActor (URL) -> Void
    private let stateGenerator: () -> String

    init(
        startURL: URL = NotionOAuthFlow.defaultStartURL,
        isDevBuild: Bool = Bundle.main.isDevBuild,
        opener: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        stateGenerator: @escaping () -> String = NotionOAuthFlow.randomState
    ) {
        self.startURL = startURL
        self.isDevBuild = isDevBuild
        self.opener = opener
        self.stateGenerator = stateGenerator
    }

    /// The redirect URI this build's exchange must present.
    var redirectURI: String { Self.redirectURI(isDevBuild: isDevBuild) }

    /// Start (or restart) a connect attempt: a fresh `state` supersedes any
    /// attempt still in flight, then the browser opens the start route.
    /// Returns the opened URL (tests inspect it).
    @discardableResult
    func begin() -> URL {
        let state = stateGenerator()
        pendingState = state
        var components = URLComponents(url: startURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "flavor", value: isDevBuild ? "dev" : "prod"),
        ]
        let url = components.url!
        opener(url)
        return url
    }

    /// Drop the in-flight attempt (e.g. the user disconnected while a browser
    /// tab was still open) — its callback will land as `.staleState`.
    func cancel() {
        pendingState = nil
    }

    /// Route a `serialnotes://oauth/notion?…` callback. Returns nil when the
    /// URL isn't a Notion OAuth callback at all (some other URL-scheme use).
    /// The state is single-use: any terminal outcome consumes it.
    func handleCallback(_ url: URL) -> CallbackOutcome? {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.host == "oauth",
            components.path == "/notion"
        else { return nil }

        let value = { (name: String) -> String? in
            components.queryItems?.first(where: { $0.name == name })?.value
        }
        // Verify state before anything else, and leave a mismatched attempt's
        // pending state alone — a stale bounce must not tear down a newer one.
        guard let pending = pendingState, value("state") == pending else {
            return .staleState
        }
        pendingState = nil

        if let error = value("error") {
            return error == "access_denied" ? .denied : .failed(error: error)
        }
        guard let code = value("code"), !code.isEmpty else {
            return .failed(error: "missing_code")
        }
        return .success(code: code)
    }

    /// 32 random bytes, hex-encoded — URL-safe with no escaping concerns.
    nonisolated static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // SecRandomCopyBytes "can virtually never fail"; if it somehow
            // does, SystemRandomNumberGenerator is still cryptographically
            // secure on Apple platforms.
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
