import UIKit
import XCTest
@testable import OpalineTV

@MainActor
final class SearchControllerTests: XCTestCase {
    func testTypingLoadsResultsWithoutSubmittingOrSelectingSuggestion() throws {
        let service = SearchFixtureService()
        let controller = makeController(service)
        beginQuery("swift", controller: controller, service: service)
        service.searches[0].complete(.success(SearchPage(videos: [Video(id: "result")], continuation: nil)))
        drainMainQueue()
        XCTAssertEqual(try videoIDs(controller), ["result"])
    }

    func testLateSuggestionsPreserveResultsAndPagination() throws {
        let service = SearchFixtureService()
        let controller = makeController(service)
        beginQuery("swift", controller: controller, service: service)
        service.searches[0].complete(.success(SearchPage(videos: [Video(id: "first")], continuation: "next")))
        drainMainQueue()
        service.suggestions[0].complete(.success(["swift tutorial", "swift language", "swift code", "swift videos"]))
        drainMainQueue()
        let grid = try XCTUnwrap(controller.searchController.searchResultsController as? TVGridController)
        XCTAssertEqual(try videoIDs(controller), ["first"])
        XCTAssertEqual(grid.continuation, "next")
        XCTAssertEqual(grid.sections.first?.items.count, 3)
        XCTAssertFalse(try XCTUnwrap(service.searches[0].token).isCancelled)

        let path = IndexPath(item: 0, section: grid.sections.count - 1)
        grid.collectionView(grid.collectionView, willDisplay: UICollectionViewCell(), forItemAt: path)
        XCTAssertEqual(service.searches.count, 2)
        XCTAssertEqual(service.searches[1].continuation, "next")
        service.searches[1].complete(.success(SearchPage(videos: [Video(id: "second")], continuation: nil)))
        drainMainQueue()
        XCTAssertEqual(try videoIDs(controller), ["first", "second"])
    }

    func testSuggestionsArrivingFirstDoNotInvalidatePendingResults() throws {
        let service = SearchFixtureService()
        let controller = makeController(service)
        beginQuery("swift", controller: controller, service: service)
        service.suggestions[0].complete(.success(["swift tutorial"]))
        drainMainQueue()
        service.searches[0].complete(.success(SearchPage(videos: [Video(id: "result")], continuation: nil)))
        drainMainQueue()
        XCTAssertEqual(try videoIDs(controller), ["result"])
    }

    func testUnchangedUIKitUpdateDoesNotCancelSubmittedSearch() throws {
        let service = SearchFixtureService()
        let controller = makeController(service)
        controller.searchController.searchBar.text = "swift"
        controller.updateSearchResults(for: controller.searchController)
        controller.searchBarSearchButtonClicked(controller.searchController.searchBar)
        controller.updateSearchResults(for: controller.searchController)
        drainMainQueue()
        XCTAssertEqual(service.searches.count, 1)
        XCTAssertFalse(try XCTUnwrap(service.searches[0].token).isCancelled)
        service.searches[0].complete(.success(SearchPage(videos: [Video(id: "submitted")], continuation: nil)))
        drainMainQueue()
        controller.updateSearchResults(for: controller.searchController)
        XCTAssertEqual(try videoIDs(controller), ["submitted"])
    }

    func testRapidEditsOnlyRequestLatestQuery() {
        let service = SearchFixtureService()
        let controller = makeController(service)
        let requested = expectation(description: "Latest query requested")
        service.onSearch = { requested.fulfill() }
        controller.searchController.searchBar.text = "swi"
        controller.updateSearchResults(for: controller.searchController)
        controller.searchController.searchBar.text = "swift"
        controller.updateSearchResults(for: controller.searchController)
        wait(for: [requested], timeout: 2)
        XCTAssertEqual(service.searches.map(\.query), ["swift"])
    }

    func testPreviousQueryResponsesCannotReplaceNewResults() throws {
        let service = SearchFixtureService()
        let controller = makeController(service)
        beginQuery("old", controller: controller, service: service)
        beginQuery("new", controller: controller, service: service)
        XCTAssertTrue(try XCTUnwrap(service.searches[0].token).isCancelled)
        service.searches[1].complete(.success(SearchPage(videos: [Video(id: "new-result")], continuation: nil)))
        service.searches[0].complete(.success(SearchPage(videos: [Video(id: "stale-result")], continuation: nil)))
        service.suggestions[0].complete(.success(["stale suggestion"]))
        drainMainQueue()
        XCTAssertEqual(try videoIDs(controller), ["new-result"])
        let grid = try XCTUnwrap(controller.searchController.searchResultsController as? TVGridController)
        XCTAssertFalse(grid.sections.flatMap(\.items).contains { $0.title == "stale suggestion" })
    }

    func testSelectingSuggestionStartsItsSearchImmediately() throws {
        let service = SearchFixtureService()
        let controller = makeController(service)
        beginQuery("swift", controller: controller, service: service)
        service.suggestions[0].complete(.success(["swift tutorial"]))
        drainMainQueue()
        let grid = try XCTUnwrap(controller.searchController.searchResultsController as? TVGridController)
        let item = try XCTUnwrap(grid.sections.first?.items.first)
        guard case .action(_, let select) = item else { return XCTFail("Expected suggestion action") }
        select()
        XCTAssertEqual(service.searches.map(\.query), ["swift", "swift tutorial"])
        controller.updateSearchResults(for: controller.searchController)
        XCTAssertFalse(try XCTUnwrap(service.searches[1].token).isCancelled)
        service.searches[1].complete(.success(SearchPage(videos: [Video(id: "tutorial")], continuation: nil)))
        drainMainQueue()
        XCTAssertEqual(try videoIDs(controller), ["tutorial"])
    }

    func testClearingQueryCancelsSearchAndRestoresRecentQueries() throws {
        let service = SearchFixtureService()
        let history = makeHistory()
        history.add("recent query")
        let controller = makeController(service, history: history)
        beginQuery("unfinished", controller: controller, service: service)
        controller.searchController.searchBar.text = "  "
        controller.updateSearchResults(for: controller.searchController)
        service.searches[0].complete(.success(SearchPage(videos: [Video(id: "stale")], continuation: nil)))
        service.suggestions[0].complete(.success(["stale suggestion"]))
        drainMainQueue()
        XCTAssertTrue(try XCTUnwrap(service.searches[0].token).isCancelled)
        XCTAssertEqual(history.queries, ["recent query"])
        XCTAssertEqual(try videoIDs(controller), [])
        let grid = try XCTUnwrap(controller.searchController.searchResultsController as? TVGridController)
        XCTAssertEqual(grid.sections.flatMap(\.items).map(\.title), ["recent query"])
        XCTAssertNil(grid.loader)
    }

    private func makeController(_ service: SearchFixtureService, history: SearchHistoryStore? = nil) -> TVSearchController {
        let controller = TVSearchController(service: service, history: history ?? makeHistory(), debounceInterval: 0) { _, _ in }
        controller.loadViewIfNeeded()
        return controller
    }

    private func makeHistory() -> SearchHistoryStore {
        let name = "TVSearchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return SearchHistoryStore(defaults: defaults)
    }

    private func beginQuery(_ query: String, controller: TVSearchController, service: SearchFixtureService) {
        let requested = expectation(description: "Search for \(query)")
        service.onSearch = { requested.fulfill() }
        controller.searchController.searchBar.text = query
        controller.updateSearchResults(for: controller.searchController)
        wait(for: [requested], timeout: 2)
        service.onSearch = nil
    }

    private func videoIDs(_ controller: TVSearchController) throws -> [String] {
        let grid = try XCTUnwrap(controller.searchController.searchResultsController as? TVGridController)
        return grid.sections.flatMap(\.items).compactMap {
            if case .video(let video) = $0 { return video.id }
            return nil
        }
    }

    private func drainMainQueue() {
        let drained = expectation(description: "Main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }
}

private final class SearchFixtureService: SearchService {
    struct Request {
        let query: String
        let continuation: String?
        let token: CancellationToken?
        let complete: (Result<SearchPage, Error>) -> Void
    }
    struct Suggestions {
        let complete: (Result<[String], Error>) -> Void
    }
    var searches: [Request] = []
    var suggestions: [Suggestions] = []
    var onSearch: (() -> Void)?

    func search(query: String, filters: SearchFilters?, continuation: String?, cancellationToken: CancellationToken?,
                completion: @escaping (Result<SearchPage, Error>) -> Void) {
        searches.append(Request(query: query, continuation: continuation, token: cancellationToken, complete: completion))
        onSearch?()
    }
    func fetchSearchSuggestions(query: String, cancellationToken: CancellationToken?,
                                completion: @escaping (Result<[String], Error>) -> Void) {
        suggestions.append(Suggestions(complete: completion))
    }
}
