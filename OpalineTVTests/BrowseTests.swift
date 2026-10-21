import XCTest
import UIKit
@testable import OpalineTV

final class BrowseTests: XCTestCase {
    @MainActor
    func testSubscriptionsSidebarSwitchesFeedsAndIgnoresOldResponses() throws {
        var requests: [(String?, String?, TVGridController.Completion)] = []
        let channels = [SubscribedChannel(id: "UCfirst", title: "First", avatarURL: nil),
                        SubscribedChannel(id: "UCsecond", title: "Second", avatarURL: nil)]
        let screen = TVSubscriptionsController(channelsLoader: { $0(.success(channels)) }) { channel, token, done in
            requests.append((channel?.id, token, done))
        }
        screen.loadViewIfNeeded()
        screen.grid.requiresAccount = false
        screen.grid.refresh()
        drainBrowseQueue()
        XCTAssertEqual(screen.tableView(screen.sidebar, numberOfRowsInSection: 0), 3)
        let all = screen.tableView(screen.sidebar, cellForRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(all.accessibilityIdentifier, "TV.allSubscriptions")
        XCTAssertEqual(all.accessoryType, .checkmark)
        XCTAssertNil(requests[0].0)

        screen.tableView(screen.sidebar, didSelectRowAt: IndexPath(row: 1, section: 0))
        screen.tableView(screen.sidebar, didSelectRowAt: IndexPath(row: 2, section: 0))
        XCTAssertEqual(requests.map { $0.0 }, [nil, "UCfirst", "UCsecond"])
        requests[2].2(.success(TVBrowsePage(FeedPage(videos: [Video(id: "second")], continuation: "second-page"))))
        requests[1].2(.success(TVBrowsePage(FeedPage(videos: [Video(id: "stale")], continuation: "stale-page"))))
        requests[0].2(.success(TVBrowsePage(FeedPage(videos: [Video(id: "old-all")], continuation: nil))))
        drainBrowseQueue()
        let ids = screen.grid.sections.flatMap(\.items).compactMap { item -> String? in
            if case .video(let video) = item { return video.id }; return nil
        }
        XCTAssertEqual(ids, ["second"])
        XCTAssertEqual(screen.grid.continuation, "second-page")
        screen.grid.collectionView(screen.grid.collectionView, willDisplay: UICollectionViewCell(),
                                   forItemAt: IndexPath(item: 0, section: 0))
        XCTAssertEqual(requests.last?.0, "UCsecond")
        XCTAssertEqual(requests.last?.1, "second-page")

        screen.tableView(screen.sidebar, didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertNil(screen.selectedChannel)
        XCTAssertNil(requests.last?.0)
        XCTAssertNil(requests.last?.1)
        requests.last?.2(.success(TVBrowsePage(FeedPage(videos: [Video(id: "all")], continuation: nil))))
        drainBrowseQueue()
        XCTAssertEqual(screen.grid.sections.count, 1)
        guard case .video(let video) = screen.grid.sections[0].items[0] else { return XCTFail("Expected video") }
        XCTAssertEqual(video.id, "all")
    }

    @MainActor
    func testSubscriptionsSidebarRemainsBesideGridAndRetriesChannelList() {
        var attempts = 0
        let screen = TVSubscriptionsController(channelsLoader: { done in
            attempts += 1
            if attempts == 1 { done(.failure(URLError(.notConnectedToInternet))) }
            else { done(.success([SubscribedChannel(id: "UCfixture", title: "Fixture", avatarURL: nil)])) }
        }, videosLoader: { _, _, done in done(.success(TVBrowsePage(sections: []))) })
        screen.loadViewIfNeeded()
        screen.grid.requiresAccount = false
        let navigation = UINavigationController(rootViewController: screen)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        screen.view.layoutIfNeeded()
        drainBrowseQueue()
        XCTAssertTrue(navigation.isNavigationBarHidden)
        XCTAssertEqual(screen.sidebar.frame.width, 360)
        XCTAssertGreaterThan(screen.grid.view.frame.minX, screen.sidebar.frame.maxX)
        XCTAssertEqual(screen.tableView(screen.sidebar, numberOfRowsInSection: 0), 2)
        XCTAssertEqual(screen.tableView(screen.sidebar, cellForRowAt: IndexPath(row: 1, section: 0))
            .accessibilityIdentifier, "TV.retryChannels")
        screen.tableView(screen.sidebar, didSelectRowAt: IndexPath(row: 1, section: 0))
        drainBrowseQueue()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(screen.channels.first?.id, "UCfixture")
    }

    @MainActor
    private func drainBrowseQueue() {
        let drained = expectation(description: "Browse callbacks delivered")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    @MainActor
    func testVideosHeadingStaysWithFeedWhenChannelsArrive() {
        let grid = TVGridController(title: "Subscriptions")
        grid.contentHeading = "Videos"
        grid.replace([
            TVSection(title: nil, items: [.video(Video(id: "first"))]),
            TVSection(title: nil, items: [.video(Video(id: "next-page"))])
        ])
        XCTAssertEqual(grid.sections.map(\.title), ["Videos", nil])
        grid.setLeadingSections([TVSection(title: "Channels", items: [.channel("UCfixture", "Channel", nil)],
                                           scrollsHorizontally: true)])
        XCTAssertEqual(grid.sections.map(\.title), ["Channels", "Videos", nil])
    }

    @MainActor
    func testRootMenuHasNoBarOverlayAndKeepsRowsInsideSafeArea() throws {
        let menu = TVMenuController(title: "Settings")
        menu.rows = (0..<30).map { TVMenuRow("Setting \($0)") {} }
        let navigation = UINavigationController(rootViewController: menu)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        navigation.view.layoutIfNeeded()
        menu.view.layoutIfNeeded()
        XCTAssertTrue(navigation.isNavigationBarHidden)
        XCTAssertEqual(menu.edgesForExtendedLayout, [])
        let path = IndexPath(row: 10, section: 0)
        menu.tableView.scrollToRow(at: path, at: .top, animated: false)
        menu.tableView.layoutIfNeeded()
        let cell = try XCTUnwrap(menu.tableView.cellForRow(at: path))
        let visibleTop = menu.tableView.convert(menu.tableView.bounds, to: window).minY
        XCTAssertGreaterThanOrEqual(cell.convert(cell.bounds, to: window).minY, visibleTop)
    }

    @MainActor
    func testRefreshHeaderScrollsAwayAndReturnsAtTop() throws {
        let grid = TVGridController(title: "Home")
        grid.replace([TVSection(title: nil, items: (0..<30).map {
            .video(Video(id: "fixture-\($0)"))
        })])
        let navigation = UINavigationController(rootViewController: grid)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        navigation.view.layoutIfNeeded()
        grid.view.layoutIfNeeded()
        grid.collectionView.layoutIfNeeded()

        let path = IndexPath(item: 0, section: 0)
        let kind = UICollectionView.elementKindSectionHeader
        let topHeader = try XCTUnwrap(grid.collectionView.collectionViewLayout.layoutAttributesForSupplementaryView(ofKind: kind, at: path))
        XCTAssertGreaterThan(topHeader.frame.maxY, grid.collectionView.contentOffset.y)
        XCTAssertNil(grid.navigationItem.rightBarButtonItem)
        XCTAssertTrue(navigation.isNavigationBarHidden)

        grid.collectionView.setContentOffset(CGPoint(x: 0, y: 900), animated: false)
        grid.collectionView.layoutIfNeeded()
        let scrolledHeader = try XCTUnwrap(grid.collectionView.collectionViewLayout.layoutAttributesForSupplementaryView(ofKind: kind, at: path))
        XCTAssertLessThan(scrolledHeader.frame.maxY, grid.collectionView.contentOffset.y)

        grid.collectionView.setContentOffset(CGPoint(x: 0, y: -grid.collectionView.adjustedContentInset.top), animated: false)
        grid.collectionView.layoutIfNeeded()
        XCTAssertNotNil(grid.collectionView.supplementaryView(forElementKind: kind, at: path))
    }

    @MainActor
    func testShelfContinuationVideosStayInTheirOriginalCategories() {
        var requests: [(String?, TVGridController.Completion)] = []
        let grid = TVGridController(title: "Home")
        grid.loader = { token, done in requests.append((token, done)) }
        grid.loadViewIfNeeded()
        grid.refresh()

        func deliver(_ feed: FeedPage) {
            var page = TVBrowsePage(feed)
            for index in page.sections.indices { page.sections[index].scrollsHorizontally = true }
            requests.last?.1(.success(page))
            drainBrowseQueue()
        }
        func loadNext(_ token: String, section: Int) {
            grid.collectionView(grid.collectionView, willDisplay: UICollectionViewCell(),
                                forItemAt: IndexPath(item: grid.sections[section].items.count - 1, section: section))
            XCTAssertEqual(requests.last?.0, token)
        }
        func videoIDs() -> [[String]] {
            grid.sections.map { $0.items.compactMap {
                if case .video(let video) = $0 { return video.id }; return nil
            } }
        }

        deliver(FeedPage(videos: [Video(id: "music")], continuation: "home-next",
                         shelves: [FeedShelf(title: "Music", count: 1)],
                         shelfContinuations: [ShelfContinuation(title: "Music", token: "music-next")]))
        loadNext("home-next", section: 0)
        deliver(FeedPage(videos: [Video(id: "games")], continuation: nil,
                         shelves: [FeedShelf(title: "Gaming", count: 1)],
                         shelfContinuations: [ShelfContinuation(title: "Gaming", token: "games-next")]))
        loadNext("music-next", section: 0)
        deliver(FeedPage(videos: [Video(id: "music"), Video(id: "music-2")], continuation: "music-last"))
        XCTAssertEqual(grid.sections.map(\.title), ["Music", "Gaming"])
        XCTAssertEqual(videoIDs(), [["music", "music-2"], ["games"]])
        loadNext("music-last", section: 0)
        deliver(FeedPage(videos: [Video(id: "music-3")], continuation: nil))
        let countBeforeExhaustedRow = requests.count
        grid.collectionView(grid.collectionView, willDisplay: UICollectionViewCell(),
                            forItemAt: IndexPath(item: 2, section: 0))
        XCTAssertEqual(requests.count, countBeforeExhaustedRow)
        loadNext("games-next", section: 1)
        deliver(FeedPage(videos: [Video(id: "games-2"), Video(id: "short", isShort: true)], continuation: nil))
        XCTAssertEqual(grid.sections.map(\.title), ["Music", "Gaming"])
        XCTAssertTrue(grid.sections.allSatisfy(\.scrollsHorizontally))
        XCTAssertEqual(videoIDs(), [["music", "music-2", "music-3"], ["games", "games-2"]])
        XCTAssertNil(grid.continuation)
    }

    func testShelvesRetainTitlesAndExcludeShorts() {
        let videos = [Video(id: "short", isShort: true), Video(id: "long")]
        let page = TVBrowsePage(FeedPage(videos: videos, continuation: "next", shelves: [
            FeedShelf(title: "Shorts", count: 1), FeedShelf(title: "Recommended", count: 1)
        ]))
        XCTAssertEqual(page.continuation, "next")
        XCTAssertEqual(page.sections.count, 1)
        XCTAssertEqual(page.sections.first?.title, "Recommended")
        XCTAssertEqual(page.sections.first?.items.count, 1)
    }

    func testSearchRetainsChannelsAndContinuation() throws {
        let response: [String: Any] = ["contents": ["twoColumnSearchResultsRenderer": ["primaryContents": [
            "sectionListRenderer": ["contents": [
                ["itemSectionRenderer": ["contents": [
                    ["channelRenderer": ["channelId": "UCfixture", "title": ["simpleText": "Fixture Channel"]]]
                ]]],
                ["continuationItemRenderer": ["continuationEndpoint": ["continuationCommand": ["token": "next"]]]]
            ]]
        ]]]]
        let page = InnertubeClient.parseSearchPage(try JSONSerialization.data(withJSONObject: response))
        XCTAssertEqual(page.channels.first?.id, "UCfixture")
        XCTAssertEqual(page.channels.first?.title, "Fixture Channel")
        XCTAssertEqual(page.continuation, "next")
        XCTAssertTrue(page.videos.isEmpty)
    }
}
