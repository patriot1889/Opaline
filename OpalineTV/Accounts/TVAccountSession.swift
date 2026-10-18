import Foundation

/// Serializes account transitions with response parsing. Old responses are
/// discarded, just like cancelled requests, before they can mutate shared state.
enum TVSessionFence {
    private static let lock = NSRecursiveLock()
    private static var value = UUID()
    static var generation: UUID { withLock { value } }
    static func advance() { withLock { value = UUID() } }
    static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

enum TVAccountSession {
    static func change(_ mutation: () throws -> Void) throws {
        try TVSessionFence.withLock {
            // Force stores to capture the outgoing scope before changing selection.
            let progress = WatchProgressStore.shared
            let searches = SearchHistoryStore.shared
            try mutation()
            let account = TVAccountStore.shared.activeAccount
            OAuthClient.shared.install(account?.tokens)
            OAuthClient.shared.isAnonymous = account == nil
            progress.switchAccount(to: account?.id)
            searches.switchAccount(to: account?.id)
            PlaybackQueue.shared.clear()
            AppCache.shared.clearAllDiskCache()
            UserProfileStore.shared.clear()
            WatchProgressSyncService.shared.resetForAccountSwitch()
            for key in ["WatchProgressSync.lastSync", "OAuthClient.lastRefresh",
                        UserDefaultsKeys.Account.ownChannelId, UserDefaultsKeys.Playlists.legacyFavoritesId] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
