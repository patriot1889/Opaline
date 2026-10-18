import Foundation

struct ServiceDependencies {
    let feedService: FeedService
    let historyService: HistoryService
    let playlistService: PlaylistService
    let searchService: SearchService
    let channelService: ChannelService
    let channelTabService: ChannelTabService
    let watchService: WatchService
    let engagementService: EngagementService
    let accountService: AccountService
    let subscribedChannelsService: SubscribedChannelsService
    let shortsService: ShortsService
    let channelRSSService: ChannelRSSFeedService
    let localePreferences: LocalePreferences

    static func live() -> ServiceDependencies {
        ServiceDependencies(
            feedService: ServiceContainer.feed,
            historyService: ServiceContainer.history,
            playlistService: ServiceContainer.playlists,
            searchService: ServiceContainer.search,
            channelService: ServiceContainer.channel,
            channelTabService: ServiceContainer.channelTabs,
            watchService: ServiceContainer.watch,
            engagementService: ServiceContainer.engagement,
            accountService: ServiceContainer.account,
            subscribedChannelsService: ServiceContainer.subscribedChannels,
            shortsService: ServiceContainer.shorts,
            channelRSSService: ServiceContainer.channelRSS,
            localePreferences: ServiceContainer.localePreferences
        )
    }
}
