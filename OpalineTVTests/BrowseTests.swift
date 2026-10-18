import XCTest
import UIKit
@testable import OpalineTV

final class BrowseTests: XCTestCase {
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
