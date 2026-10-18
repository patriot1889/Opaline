import Foundation
import Security

/// Credentials and the selection live together in Keychain, including in guest mode.
/// No tokens are written to UserDefaults or the purgeable tvOS file cache.
final class TVAccountStore {
    struct Account: Codable {
        let id: String
        var name: String
        var tokens: OAuthTokens
    }
    struct State: Codable {
        var accounts: [Account] = []
        var activeID: String?
    }
    static let shared = TVAccountStore()
    private var state = State()
    private var loadError: Error?
    private let write: (Data) throws -> Void

    var accounts: [Account] { TVSessionFence.withLock { state.accounts } }
    var activeAccount: Account? {
        TVSessionFence.withLock { state.accounts.first { $0.id == state.activeID } }
    }

    init(read: () throws -> Data? = { try TVAccountKeychain.read(account: "accounts.v1") },
         write: @escaping (Data) throws -> Void = { try TVAccountKeychain.write($0, account: "accounts.v1") },
         defaults: UserDefaults = .standard,
         deleteLegacy: () throws -> Void = { try TVAccountKeychain.delete(account: "youtube", service: "com.ytvlite.oauth") },
         legacyTokens: () throws -> OAuthTokens? = {
             guard let data = try TVAccountKeychain.read(account: "youtube", service: "com.ytvlite.oauth") else { return nil }
             return try JSONDecoder().decode(OAuthTokens.self, from: data)
         }) {
        self.write = write
        do {
            if let data = try read() {
                state = try JSONDecoder().decode(State.self, from: data)
            } else if let tokens = try legacyTokens() {
                let account = Account(id: UUID().uuidString, name: "YouTube", tokens: tokens)
                let migrated = State(accounts: [account], activeID: account.id)
                try write(JSONEncoder().encode(migrated))
                state = migrated
                // Keep the old credential until migration has succeeded.
                do { try deleteLegacy() }
                catch { AppLog.auth("Legacy TV credential cleanup will be deferred") }
                for (old, suffix) in [(UserDefaultsKeys.Search.history, "searchHistory"),
                                      ("WatchProgressStore.fractions", "fractions"),
                                      ("WatchProgressStore.localTimes", "localTimes")] {
                    if let value = defaults.object(forKey: old) {
                        defaults.set(value, forKey: "TV.accounts.\(account.id).\(suffix)")
                        defaults.removeObject(forKey: old)
                    }
                }
            }
        } catch { loadError = error }
    }

    private func commit(_ next: State) throws {
        if let loadError { throw loadError }
        try write(JSONEncoder().encode(next))
        state = next
    }

    @discardableResult
    func add(tokens: OAuthTokens, name: String = "YouTube") throws -> Account {
        try TVSessionFence.withLock {
            var next = state
            // Signing in again with the same grant updates that saved account.
            let index = next.accounts.firstIndex { $0.tokens.refreshToken == tokens.refreshToken }
            let account = Account(id: index.map { next.accounts[$0].id } ?? UUID().uuidString,
                                  name: name, tokens: tokens)
            if let index { next.accounts[index] = account } else { next.accounts.append(account) }
            next.activeID = account.id
            try commit(next)
            return account
        }
    }

    func select(_ id: String?) throws {
        try TVSessionFence.withLock {
            guard id == nil || state.accounts.contains(where: { $0.id == id }) else { throw APIError.unauthorized }
            var next = state
            next.activeID = id
            try commit(next)
        }
    }

    func remove(_ id: String) throws {
        try TVSessionFence.withLock {
            var next = state
            next.accounts.removeAll { $0.id == id }
            if next.activeID == id { next.activeID = nil }
            try commit(next)
        }
    }

    func updateActive(tokens: OAuthTokens) throws {
        try TVSessionFence.withLock {
            guard let index = state.accounts.firstIndex(where: { $0.id == state.activeID }),
                  state.accounts[index].tokens.refreshToken == tokens.refreshToken else { return }
            var next = state
            next.accounts[index].tokens = tokens
            try commit(next)
        }
    }

    func rename(_ id: String, to name: String) throws {
        try TVSessionFence.withLock {
            guard let index = state.accounts.firstIndex(where: { $0.id == id }) else { return }
            var next = state
            next.accounts[index].name = name
            try commit(next)
        }
    }
}

enum TVAccountKeychain {
    static func query(account: String, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func read(account: String, service: String = "com.opaline.tv.accounts") throws -> Data? {
        var query = query(account: account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return data
    }
    static func write(_ data: Data, account: String, service: String = "com.opaline.tv.accounts") throws {
        let query = query(account: account, service: service)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }
    static func delete(account: String, service: String) throws {
        let status = SecItemDelete(query(account: account, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    static func failure(_ status: OSStatus) -> Error {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "Saved accounts could not be accessed. Please try again."
        ])
    }
}

extension OAuthClient {
    func saveToKeychain(_ tokens: OAuthTokens) {
        guard persistsTokens else { return }
        do { try TVAccountStore.shared.updateActive(tokens: tokens) }
        catch { AppLog.auth("Unable to save refreshed TV credentials") }
    }
    func deleteFromKeychain() {
        guard persistsTokens, let account = TVAccountStore.shared.activeAccount else { return }
        do { try TVAccountStore.shared.remove(account.id) }
        catch { AppLog.auth("Unable to remove TV account") }
    }
}
