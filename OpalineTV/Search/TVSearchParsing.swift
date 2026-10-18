import Foundation

extension InnertubeClient {
    /// Parses both the initial search response and continuation responses
    /// into videos plus the next-page token.
    ///
    /// Item shapes are handled by `VideoRendererParserChain`, the same one
    /// every other surface uses — search used to hand-roll a traversal that
    /// knew `videoRenderer` alone, which dropped shorts (and with them the
    /// "show Shorts" setting), mixes and inline watch progress.
    static func parseSearchPage(
        _ data: Data
    ) -> SearchPage {
        guard let json = try? JSONSerialization
            .jsonObject(with: data) as? [String: Any]
        else {
            return SearchPage(videos: [], continuation: nil)
        }
        let sections = initialSearchSections(json)
            ?? continuationSearchSections(json)
            ?? []
        var videos: [Video] = []
        var token: String?
        var channels: [SubscribedChannel] = []
        var playlists: [Playlist] = []
        for section in sections {
            let items = (section["itemSectionRenderer"]
                as? [String: Any])?["contents"] as? [[String: Any]]
                ?? [section]
            let parsed = VideoRendererParserChain.parse(items: items)
            videos += parsed.videos
            channels += searchChannels(in: items)
            playlists += searchPlaylists(in: items)
            token = token ?? parsed.continuation
        }
        return SearchPage(
            videos: videos, continuation: token, channels: channels, playlists: playlists
        )
    }
}

private extension InnertubeClient {
    static func searchChannels(in items: [[String: Any]]) -> [SubscribedChannel] {
        items.compactMap { item in
            guard let channel = item["channelRenderer"] as? [String: Any],
                  let id = channel["channelId"] as? String else {
                return nil
            }
            return SubscribedChannel(
                id: id,
                title: channel.innertubeText("title") ?? "",
                avatarURL: channel.thumbnailURL()
            )
        }
    }

    static func searchPlaylists(in items: [[String: Any]]) -> [Playlist] {
        items.compactMap { item in
            if let renderer = item["playlistRenderer"] as? [String: Any],
               let id = renderer["playlistId"] as? String {
                return Playlist(
                    id: id,
                    title: renderer.innertubeText("title") ?? "",
                    description: "",
                    thumbnailURL: renderer.thumbnailURL(),
                    itemCount: nil
                )
            }
            guard let lockup = item["lockupViewModel"] as? [String: Any],
                  lockup["contentType"] as? String == "LOCKUP_CONTENT_TYPE_PLAYLIST" else {
                return nil
            }
            return parseLockupPlaylist(lockup)
        }
    }

    static func initialSearchSections(
        _ json: [String: Any]
    ) -> [[String: Any]]? {
        json.digArray(
            "contents",
            "twoColumnSearchResultsRenderer",
            "primaryContents",
            "sectionListRenderer",
            "contents"
        )
    }

    static func continuationSearchSections(
        _ json: [String: Any]
    ) -> [[String: Any]]? {
        guard let commands = json["onResponseReceivedCommands"]
            as? [[String: Any]]
        else {
            return nil
        }
        return commands
            .compactMap {
                $0.digArray(
                    "appendContinuationItemsAction",
                    "continuationItems"
                )
            }
            .first
    }
}
