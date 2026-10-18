import UIKit

typealias AppDependencies = ServiceDependencies

extension ServiceDependencies {
    func makePlaylistViewController(playlist: Playlist) -> UIViewController {
        PlaylistVideosViewController(
            playlist: playlist,
            service: playlistService,
            channelViewControllerFactory: makeChannelViewController
        )
    }

    func makeSearchViewController() -> SearchViewController {
        SearchViewController(
            service: searchService,
            channelViewControllerFactory: makeChannelViewController
        )
    }

    func makeWatchViewController(video: Video) -> WatchViewController {
        WatchViewController(
            video: video,
            watchService: watchService,
            engagementService: engagementService,
            playlistService: playlistService,
            channelInfoStore: .shared
        )
    }

    func makeShortsViewController(
        seedVideo: Video?, entry: ShortsEntry
    ) -> ShortsViewController {
        ShortsViewController(
            seedVideo: seedVideo,
            entry: entry,
            shortsService: shortsService,
            watchService: watchService,
            engagementService: engagementService,
            channelViewControllerFactory: makeChannelViewController
        )
    }

    func makeSubscriptionsViewController() -> SubscriptionsViewController {
        SubscriptionsViewController(dependencies: self)
    }

    func makeChannelViewController(
        channelId: String,
        channelName: String
    ) -> ChannelViewController {
        ChannelViewController(
            channelId: channelId,
            channelName: channelName,
            channelService: channelService,
            feedService: feedService,
            engagementService: engagementService,
            channelTabService: channelTabService,
            playlistService: playlistService,
            channelViewControllerFactory: makeChannelViewController
        )
    }
}
