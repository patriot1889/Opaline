import XCTest
@testable import OpalineTV

final class AccountTests: XCTestCase {
    private func tokens(_ user: String) -> OAuthTokens {
        OAuthTokens(accessToken: user, refreshToken: user, expiryDate: .distantFuture,
                    clientId: "fixture", clientSecret: "fixture")
    }
    private func store() -> TVAccountStore {
        TVAccountStore(read: { nil }, write: { _ in }, legacyTokens: { nil })
    }

    func testSwitchAndGuestPreserveSavedCredentialsAcrossRelaunch() throws {
        var data: Data?
        let store = TVAccountStore(read: { nil }, write: { data = $0 }, legacyTokens: { nil })
        let first = try store.add(tokens: tokens("one"), name: "One")
        let second = try store.add(tokens: tokens("two"), name: "Two")
        try store.select(first.id)
        XCTAssertEqual(store.activeAccount?.tokens.accessToken, "one")
        try store.select(nil)
        let restored = TVAccountStore(read: { data }, write: { _ in }, legacyTokens: { nil })
        XCTAssertNil(restored.activeAccount)
        XCTAssertEqual(restored.accounts.map(\.id), [first.id, second.id])
        try restored.select(second.id)
        XCTAssertEqual(restored.activeAccount?.tokens.accessToken, "two")
    }

    func testRefreshUpdatesOnlyActiveAccount() throws {
        let store = store()
        let first = try store.add(tokens: tokens("one"))
        let second = try store.add(tokens: tokens("two"))
        var refreshed = tokens("one")
        refreshed.accessToken = "refreshed"
        try store.updateActive(tokens: refreshed)
        XCTAssertEqual(store.activeAccount?.tokens.accessToken, "two")
        try store.select(first.id)
        try store.updateActive(tokens: refreshed)
        XCTAssertEqual(store.activeAccount?.tokens.accessToken, "refreshed")
        XCTAssertEqual(store.accounts.first { $0.id == second.id }?.tokens.accessToken, "two")
    }

    func testRemovingActiveAccountEntersGuestAndKeepsOtherAccount() throws {
        let store = store()
        let first = try store.add(tokens: tokens("one"))
        let second = try store.add(tokens: tokens("two"))
        try store.remove(second.id)
        XCTAssertNil(store.activeAccount)
        XCTAssertEqual(store.accounts.map(\.id), [first.id])
    }

    func testFailedWriteKeepsSelectionAndCredentials() throws {
        var fails = false
        let store = TVAccountStore(read: { nil }, write: { _ in
            if fails { throw URLError(.cannotWriteToFile) }
        }, legacyTokens: { nil })
        let first = try store.add(tokens: tokens("one"))
        fails = true
        XCTAssertThrowsError(try store.add(tokens: tokens("two")))
        XCTAssertThrowsError(try store.select(nil))
        XCTAssertThrowsError(try store.remove(first.id))
        XCTAssertEqual(store.activeAccount?.id, first.id)
        XCTAssertEqual(store.accounts.count, 1)
    }

    func testUnreadableVaultCannotBeOverwritten() {
        var writes = 0
        let store = TVAccountStore(read: { throw URLError(.noPermissionsToReadFile) },
                                   write: { _ in writes += 1 }, legacyTokens: { nil })
        XCTAssertThrowsError(try store.add(tokens: tokens("one")))
        XCTAssertEqual(writes, 0)
    }

    func testDuplicateGrantUpdatesExistingSavedAccount() throws {
        let store = store()
        let first = try store.add(tokens: tokens("one"))
        let updated = try store.add(tokens: tokens("one"), name: "Updated")
        XCTAssertEqual(first.id, updated.id)
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.activeAccount?.name, "Updated")
    }

    func testSearchHistoryIsIsolatedBetweenAccountsAndGuest() {
        let name = "TVAccountsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let history = SearchHistoryStore(defaults: defaults)
        history.switchAccount(to: "one")
        history.add("First query")
        history.switchAccount(to: "two")
        XCTAssertTrue(history.queries.isEmpty)
        history.add("Second query")
        history.switchAccount(to: nil)
        XCTAssertTrue(history.queries.isEmpty)
        history.switchAccount(to: "one")
        XCTAssertEqual(history.queries, ["First query"])
    }

    func testLegacyAccountAndHistoryMigrateWithoutSigningInAgain() throws {
        let suite = "TVMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["Legacy query"], forKey: UserDefaultsKeys.Search.history)
        var saved: Data?
        var deleted = false
        let store = TVAccountStore(read: { nil }, write: { saved = $0 }, defaults: defaults,
                                   deleteLegacy: { deleted = true }, legacyTokens: { self.tokens("legacy") })
        let account = try XCTUnwrap(store.activeAccount)
        XCTAssertEqual(account.tokens.accessToken, "legacy")
        XCTAssertNotNil(saved)
        XCTAssertTrue(deleted)
        XCTAssertEqual(defaults.stringArray(forKey: "TV.accounts.\(account.id).searchHistory"), ["Legacy query"])
        XCTAssertNil(defaults.object(forKey: UserDefaultsKeys.Search.history))
    }

    func testFailedMigrationKeepsLegacyCredential() {
        var deleted = false
        let store = TVAccountStore(read: { nil }, write: { _ in throw URLError(.cannotWriteToFile) },
                                   deleteLegacy: { deleted = true }, legacyTokens: { self.tokens("legacy") })
        XCTAssertFalse(deleted)
        XCTAssertNil(store.activeAccount)
        XCTAssertThrowsError(try store.add(tokens: tokens("new")))
    }

    func testWatchPositionsAndLinkStartsAreIsolatedBetweenAccounts() {
        let first = UUID().uuidString
        let second = UUID().uuidString
        let progress = WatchProgressStore()
        progress.switchAccount(to: first)
        progress.setLocalFraction(videoId: "video", fraction: 0.4)
        progress.setLinkStart(seconds: 85, forVideoId: "video")
        progress.switchAccount(to: second)
        XCTAssertNil(progress.progress(forVideoId: "video"))
        XCTAssertNil(progress.resumeSeconds(forVideoId: "video", duration: 100))
        progress.setLocalFraction(videoId: "video", fraction: 0.7)
        progress.switchAccount(to: first)
        XCTAssertEqual(progress.resumeSeconds(forVideoId: "video", duration: 100), 40)
        progress.switchAccount(to: nil)
        for id in [first, second] {
            for suffix in ["fractions", "localTimes"] {
                UserDefaults.standard.removeObject(forKey: "TV.accounts.\(id).\(suffix)")
            }
        }
    }

    func testLateRefreshCannotReplaceNewAccount() {
        let transport = PendingAccountTransport()
        let client = OAuthClient(transport: transport, loadStoredTokens: false)
        client.tokens = tokens("one")
        client.doRefresh(tokens: tokens("one")) { _ in XCTFail("Old refresh completed") }
        client.install(tokens("two"))
        transport.complete?(.success(HTTPResponse(status: 200, headers: [:],
            data: Data("{\"access_token\":\"old-refreshed\",\"expires_in\":3600}".utf8))))
        XCTAssertEqual(client.tokens?.accessToken, "two")
    }

    func testLateAPIResponseIsDiscardedAfterSwitch() {
        let raw = PendingAccountTransport()
        let transport = AuthorizingTransport(raw)
        transport.send(HTTPRequest(method: .get, url: URL(string: "https://fixture.invalid")!), cancellationToken: nil) { _ in
            XCTFail("Previous account response delivered")
        }
        TVSessionFence.advance()
        raw.complete?(.success(HTTPResponse(status: 200, headers: [:], data: Data())))
    }
}

private final class PendingAccountTransport: HTTPTransport {
    var complete: ((Result<HTTPResponse, Error>) -> Void)?
    func send(_ request: HTTPRequest, cancellationToken: CancellationToken?,
              completion: @escaping (Result<HTTPResponse, Error>) -> Void) {
        complete = completion
    }
}
