import UIKit

enum TVFeed {
    case home, subscriptions, history
    case channel(String, String)
    case playlist(Playlist)
}

final class TVRouter {
    let dependencies: ServiceDependencies
    init(dependencies: ServiceDependencies) { self.dependencies = dependencies }

    func feed(_ destination: TVFeed) -> UIViewController {
        if case .subscriptions = destination {
            let screen = TVSubscriptionsController(
                channelsLoader: dependencies.subscribedChannelsService.fetchSubscribedChannels,
                videosLoader: { [dependencies] channel, token, completion in
                    let done: (Result<FeedPage, Error>) -> Void = { result in
                        completion(result.map { feed in
                            var page = TVBrowsePage(feed)
                            if let channel {
                                for index in page.sections.indices {
                                    page.sections[index].items = page.sections[index].items.map { item in
                                        guard case .video(var video) = item else { return item }
                                        if video.channelId == nil { video.channelId = channel.id }
                                        if video.channelName.isEmpty { video.channelName = channel.title }
                                        if video.channelAvatarURL == nil { video.channelAvatarURL = channel.avatarURL }
                                        return .video(video)
                                    }
                                }
                            }
                            return page
                        })
                    }
                    if let channel {
                        if let token {
                            dependencies.channelTabService.fetchChannelTabNextPage(continuation: token, completion: done)
                        } else {
                            dependencies.channelTabService.fetchChannelTab(channelId: channel.id, params: ChannelTabParams.videos) {
                                done($0.map(\.feedPage))
                            }
                        }
                    } else if let token {
                        dependencies.feedService.fetchSubscriptionsNextPage(continuation: token, completion: done)
                    } else {
                        dependencies.feedService.fetchSubscriptionFeed(completion: done)
                    }
                }
            )
            screen.grid.selection = { [self] item, sender in open(item, from: sender) }
            return screen
        }
        let title: String
        switch destination {
        case .home: title = "home.title".localized
        case .subscriptions: title = "subscriptions.title".localized
        case .history: title = "library.history".localized
        case .channel(_, let name): title = name
        case .playlist(let playlist): title = playlist.title
        }
        let screen = TVGridController(title: title)
        switch destination {
        case .subscriptions, .history: screen.requiresAccount = true
        default: break
        }
        let services = dependencies
        screen.loader = { token, completion in
            let done: (Result<FeedPage, Error>) -> Void = { result in
                completion(result.map { feedPage in
                    var page = TVBrowsePage(feedPage)
                    if case .home = destination {
                        for index in page.sections.indices {
                            page.sections[index].scrollsHorizontally = true
                        }
                    }
                    return page
                })
            }
            switch destination {
            case .home:
                if let token { services.feedService.fetchNextPage(continuation: token, completion: done) }
                else { services.feedService.fetchHomeFeed(completion: done) }
            case .subscriptions:
                if let token { services.feedService.fetchSubscriptionsNextPage(continuation: token, completion: done) }
                else { services.feedService.fetchSubscriptionFeed(completion: done) }
            case .history:
                if let token {
                    OAuthClient.shared.validToken { result in
                        switch result {
                        case .success(let auth):
                            services.historyService.fetchHistoryNextPage(continuation: token, token: auth, completion: done)
                        case .failure(let error): done(.failure(error))
                        }
                    }
                } else { services.historyService.fetchHistory(completion: done) }
            case .channel(let id, _):
                if let token { services.channelTabService.fetchChannelTabNextPage(continuation: token, completion: done) }
                else { services.channelService.fetchChannelPage(channelId: id) { done($0.map(\.videosPage)) } }
            case .playlist(let playlist):
                services.playlistService.fetchPlaylistVideos(playlistId: playlist.id, continuation: token, completion: done)
            }
        }
        screen.selection = { [self, weak screen] item, sender in
            guard let screen else { return }
            if case .playlist(let playlist) = destination, case .video(let video) = item {
                let videos = screen.sections.flatMap(\.items).compactMap { entry -> Video? in
                    if case .video(let video) = entry { return video }; return nil
                }
                PlaybackQueue.shared.setQueue(videos, playlistId: playlist.id, title: playlist.title,
                                               continuation: screen.continuation)
                PlaybackQueue.shared.seekTo(videoId: video.id)
                play(video, from: sender, queued: true)
            } else { open(item, from: sender) }
        }
        return screen
    }

    func open(_ item: TVItem, from sender: UIViewController) {
        switch item {
        case .video(let video):
            if video.id.hasPrefix("UC") { pushChannel(id: video.id, name: video.title, from: sender) }
            else if let playlistId = video.playlistId, video.id.isEmpty {
                let playlist = Playlist(id: playlistId, title: video.title, description: "",
                                        thumbnailURL: video.thumbnailURL, itemCount: nil)
                sender.navigationController?.pushViewController(feed(.playlist(playlist)), animated: true)
            } else { play(video, from: sender) }
        case .channel(let id, let name, _): pushChannel(id: id, name: name, from: sender)
        case .playlist(let playlist): sender.navigationController?.pushViewController(feed(.playlist(playlist)), animated: true)
        case .action(_, let action): action()
        }
    }

    func pushChannel(id: String, name: String, from sender: UIViewController) {
        sender.navigationController?.pushViewController(feed(.channel(id, name)), animated: true)
    }

    func play(_ video: Video, from sender: UIViewController, queued: Bool = false) {
        if !queued { PlaybackQueue.shared.clear() }
        let player = TVPlayerController(video: video, dependencies: dependencies, playlistQueue: queued)
        player.onChannelRequested = { [weak player, weak sender, self] id, name in
            player?.dismiss(animated: true) {
                guard let sender else { return }
                self.pushChannel(id: id, name: name, from: sender)
            }
        }
        player.modalPresentationStyle = .fullScreen
        sender.present(player, animated: true)
    }

    func library() -> TVGridController {
        let screen = TVGridController(title: "library.title".localized)
        screen.requiresAccount = true
        screen.selection = { [self] item, sender in open(item, from: sender) }
        screen.loader = { [self, weak screen] _, done in
            dependencies.historyService.fetchHistory { [self] historyResult in
                dependencies.playlistService.fetchPlaylists { playlistsResult in
                    let result = historyResult.flatMap { history in
                        playlistsResult.map { playlists in
                            var historyItems = history.videos.filter { !$0.isShort }.map(TVItem.video)
                            if history.continuation != nil || !(history.shelfContinuations ?? []).isEmpty {
                                historyItems.append(.action("TV.viewAll".tvLocalized) { [weak screen, self] in
                                    screen?.navigationController?.pushViewController(feed(.history), animated: true)
                                })
                            }
                            return TVBrowsePage(sections: [
                                TVSection(title: "library.history".localized, items: historyItems,
                                          scrollsHorizontally: true),
                                TVSection(title: "library.playlists".localized, items: playlists.map(TVItem.playlist),
                                          scrollsHorizontally: true)
                            ])
                        }
                    }
                    done(result)
                }
            }
        }
        return screen
    }

    func playlists() -> TVGridController {
        let screen = TVGridController(title: "library.playlists".localized)
        screen.requiresAccount = true
        screen.selection = { [self] item, sender in open(item, from: sender) }
        screen.loader = { [dependencies] _, done in
            dependencies.playlistService.fetchPlaylists { result in
                done(result.map { TVBrowsePage(sections: [TVSection(title: nil, items: $0.map(TVItem.playlist))]) })
            }
        }
        return screen
    }

    func channels() -> TVGridController {
        let screen = TVGridController(title: "TV.channels".tvLocalized)
        screen.requiresAccount = true
        screen.selection = { [self] item, sender in open(item, from: sender) }
        screen.loader = { [dependencies] _, done in
            dependencies.subscribedChannelsService.fetchSubscribedChannels { result in
                done(result.map { channels in
                    TVBrowsePage(sections: [TVSection(title: nil, items: channels.map {
                        .channel($0.id, $0.title, $0.avatarURL)
                    })])
                })
            }
        }
        return screen
    }
}
