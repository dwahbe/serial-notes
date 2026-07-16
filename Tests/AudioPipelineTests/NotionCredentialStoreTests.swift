import Foundation
import Testing
import os

@testable import SerialNotes

/// In-memory `KeychainItemStoring` so the credential store's logic is testable
/// without touching the real Keychain.
final class InMemoryKeychain: KeychainItemStoring, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [String: Data]())

    private func key(_ service: String, _ account: String) -> String { "\(service)|\(account)" }

    func read(service: String, account: String) throws -> Data? {
        state.withLock { $0[key(service, account)] }
    }

    func write(_ data: Data, service: String, account: String) throws {
        state.withLock { $0[key(service, account)] = data }
    }

    func delete(service: String, account: String) throws {
        state.withLock { $0[key(service, account)] = nil }
    }

    var itemCount: Int { state.withLock { $0.count } }
}

@Suite("Notion Credential Store")
struct NotionCredentialStoreTests {
    private static func sampleCredentials(
        workspaceID: String = "ws-1",
        destination: String = "page-1"
    ) -> NotionCredentials {
        NotionCredentials(
            workspaceID: workspaceID,
            workspaceName: "Acme",
            botID: "bot-1",
            destinationPageID: destination,
            accessToken: "access-1",
            refreshToken: "refresh-1"
        )
    }

    private func makeStore() -> (NotionCredentialStore, InMemoryKeychain) {
        let keychain = InMemoryKeychain()
        return (NotionCredentialStore(keychain: keychain, service: "test.notion"), keychain)
    }

    @Test("Round-trips the whole record")
    func roundTrip() async throws {
        let (store, _) = makeStore()
        let credentials = Self.sampleCredentials()
        try await store.save(credentials)
        #expect(try await store.load() == credentials)
    }

    @Test("Empty store loads nil")
    func emptyLoadsNil() async throws {
        let (store, _) = makeStore()
        #expect(try await store.load() == nil)
    }

    @Test("Undecodable blob reads as disconnected, not an error")
    func garbageLoadsNil() async throws {
        let (store, keychain) = makeStore()
        try keychain.write(Data("not json".utf8), service: "test.notion", account: "connection")
        #expect(try await store.load() == nil)
    }

    @Test("A record from a newer version reads as disconnected")
    func newerVersionLoadsNil() async throws {
        let (store, keychain) = makeStore()
        var credentials = Self.sampleCredentials()
        credentials.version = NotionCredentials.currentVersion + 1
        try keychain.write(
            try JSONEncoder().encode(credentials), service: "test.notion", account: "connection"
        )
        #expect(try await store.load() == nil)
    }

    @Test("Reconnect replaces the record whole — no field survives from the old workspace")
    func atomicReplace() async throws {
        let (store, keychain) = makeStore()
        try await store.save(Self.sampleCredentials(workspaceID: "ws-old", destination: "page-old"))
        let replacement = NotionCredentials(
            workspaceID: "ws-new",
            workspaceName: "New Co",
            botID: "bot-2",
            destinationPageID: "page-new",
            accessToken: "access-2",
            refreshToken: "refresh-2"
        )
        try await store.save(replacement)
        #expect(try await store.load() == replacement)
        #expect(keychain.itemCount == 1)  // one record, updated in place
    }

    @Test("Token rotation preserves the rest of the record")
    func updateTokensPreservesRecord() async throws {
        let (store, _) = makeStore()
        try await store.save(Self.sampleCredentials())
        try await store.updateTokens(accessToken: "access-2", refreshToken: "refresh-2")
        let loaded = try await store.load()
        #expect(loaded?.accessToken == "access-2")
        #expect(loaded?.refreshToken == "refresh-2")
        #expect(loaded?.destinationPageID == "page-1")
        #expect(loaded?.workspaceID == "ws-1")
    }

    @Test("Destination self-heal preserves the tokens")
    func updateDestinationPreservesTokens() async throws {
        let (store, _) = makeStore()
        try await store.save(Self.sampleCredentials())
        try await store.updateDestinationPageID("page-2")
        let loaded = try await store.load()
        #expect(loaded?.destinationPageID == "page-2")
        #expect(loaded?.accessToken == "access-1")
        #expect(loaded?.refreshToken == "refresh-1")
    }

    @Test("Updating a cleared store throws notConnected")
    func updateWithoutRecordThrows() async throws {
        let (store, _) = makeStore()
        await #expect(throws: NotionAPIError.notConnected) {
            try await store.updateTokens(accessToken: "a", refreshToken: "r")
        }
    }

    @Test("Clear removes the record; clearing again is not an error")
    func clearIsIdempotent() async throws {
        let (store, _) = makeStore()
        try await store.save(Self.sampleCredentials())
        try await store.clear()
        #expect(try await store.load() == nil)
        try await store.clear()
    }
}
