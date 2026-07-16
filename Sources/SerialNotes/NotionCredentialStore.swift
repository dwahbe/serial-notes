import Foundation
import Security

/// The one Notion connection record — a single versioned blob written atomically
/// and replaced whole on reconnect, so a newly connected workspace can never
/// inherit a previous workspace's destination page ID. A record is only ever
/// saved *complete* (connect finishes by creating the destination page first),
/// so `load()` returning one means the connection is usable.
struct NotionCredentials: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = NotionCredentials.currentVersion
    var workspaceID: String
    /// Display-only; Notion may return null for it, stored as "".
    var workspaceName: String
    var botID: String
    /// The workspace-level "Meeting Notes" page meetings are filed under.
    var destinationPageID: String
    var accessToken: String
    var refreshToken: String
}

/// Minimal seam over the Keychain so the credential store is testable with an
/// in-memory fake — `SecItem*` has no injection point of its own.
protocol KeychainItemStoring: Sendable {
    /// nil when no item exists for the service/account pair.
    func read(service: String, account: String) throws -> Data?
    /// Insert-or-replace in one call (the Keychain updates items in place).
    func write(_ data: Data, service: String, account: String) throws
    /// Removing a missing item is not an error.
    func delete(service: String, account: String) throws
}

struct KeychainStoreError: Error, LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain error: \(detail)"
    }
}

/// Production Keychain access — a generic-password item per service/account.
///
/// Deliberately the *file-based* login keychain (no `kSecUseDataProtectionKeychain`):
/// the data-protection keychain needs a keychain-access-group / application
/// identifier entitlement the ad-hoc dev build doesn't carry, so requesting it
/// would fail dev builds outright. The tradeoff: a file-keychain item's ACL is
/// bound to the creating app's code signature, and an **ad-hoc** dev build's
/// signature changes on every `./scripts/run.sh` rebuild — so after a rebuild
/// the read hits a keychain-consent prompt or `errSecAuthFailed`. A real
/// Developer ID (production) has a stable team-based signature, so an installed
/// build and its Sparkle updates read their own item cleanly. `read()`
/// surfaces that failure as a thrown error (not `nil`), so the connection layer
/// can tell "couldn't read" apart from "never connected" instead of silently
/// showing disconnected.
struct SecItemKeychain: KeychainItemStoring {
    func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainStoreError(status: status)
        }
    }

    func write(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            // Tokens are only useful while the user is around to export.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainStoreError(status: status) }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError(status: status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Owns the Keychain record for the Notion connection. An actor so every
/// read-modify-write (token rotation, destination self-heal) is serialized and
/// all Keychain I/O stays off the main actor.
actor NotionCredentialStore {
    /// Scoped by bundle ID so a dev build's connection is isolated from a
    /// production install's, matching the TCC + UserDefaults split.
    nonisolated static func defaultService() -> String {
        "\(Bundle.main.bundleIdentifier ?? "com.serialnotes.app").notion"
    }

    private let keychain: any KeychainItemStoring
    private let service: String
    private let account = "connection"

    init(
        keychain: any KeychainItemStoring = SecItemKeychain(),
        service: String = NotionCredentialStore.defaultService()
    ) {
        self.keychain = keychain
        self.service = service
    }

    /// The stored connection, or nil when there is none. A blob that doesn't
    /// decode or carries an unknown (newer) version also reads as nil — the
    /// safe interpretation is "not connected", which routes the user through a
    /// fresh connect that atomically replaces the record.
    func load() throws -> NotionCredentials? {
        guard let data = try keychain.read(service: service, account: account) else { return nil }
        guard
            let credentials = try? JSONDecoder().decode(NotionCredentials.self, from: data),
            credentials.version == NotionCredentials.currentVersion
        else {
            NSLog("[SerialNotes/Notion] stored credentials unreadable or from a newer version — treating as disconnected")
            return nil
        }
        return credentials
    }

    /// Write the whole record (insert-or-replace).
    func save(_ credentials: NotionCredentials) throws {
        try keychain.write(try JSONEncoder().encode(credentials), service: service, account: account)
    }

    func clear() throws {
        try keychain.delete(service: service, account: account)
    }

    /// Persist rotated tokens (Notion rotates the refresh token on every
    /// refresh), preserving the rest of the record. When `expectedWorkspaceID`/
    /// `expectedBotID` are given, the write is skipped if the stored record no
    /// longer matches — a reconnect to a different workspace may have replaced
    /// it while the refresh was in flight, and must not inherit these tokens.
    func updateTokens(
        accessToken: String,
        refreshToken: String,
        expectedWorkspaceID: String? = nil,
        expectedBotID: String? = nil
    ) throws {
        guard var credentials = try load() else { throw NotionAPIError.notConnected }
        if let expectedWorkspaceID, credentials.workspaceID != expectedWorkspaceID { return }
        if let expectedBotID, credentials.botID != expectedBotID { return }
        credentials.accessToken = accessToken
        credentials.refreshToken = refreshToken
        try save(credentials)
    }

    /// Persist a re-created destination page (the 404 self-heal path). Skipped
    /// if a reconnect replaced the record with a different workspace meanwhile.
    func updateDestinationPageID(_ pageID: String, expectedWorkspaceID: String? = nil) throws {
        guard var credentials = try load() else { throw NotionAPIError.notConnected }
        if let expectedWorkspaceID, credentials.workspaceID != expectedWorkspaceID { return }
        credentials.destinationPageID = pageID
        try save(credentials)
    }
}
