import UIKit

final class TVSearchController: UISearchContainerViewController, UISearchResultsUpdating, UISearchBarDelegate {
    private let results: TVGridController
    private let service: SearchService
    private let history: SearchHistoryStore
    private let debounceInterval: TimeInterval
    private var requestToken = CancellationToken()
    private var pending: DispatchWorkItem?
    private var activeQuery = ""
    private var searchStarted = false
    private var filters = SearchFilters()

    convenience init(router: TVRouter) {
        self.init(service: router.dependencies.searchService) { item, sender in
            router.open(item, from: sender)
        }
    }

    init(service: SearchService, history: SearchHistoryStore = .shared,
         debounceInterval: TimeInterval = 0.3, selection: @escaping (TVItem, UIViewController) -> Void) {
        self.service = service
        self.history = history
        self.debounceInterval = debounceInterval
        results = TVGridController(title: "search.title".localized)
        let search = UISearchController(searchResultsController: results)
        super.init(searchController: search)
        search.searchResultsUpdater = self
        search.searchBar.delegate = self
        search.searchBar.placeholder = "search.title".localized
        search.obscuresBackgroundDuringPresentation = false
        results.selection = { [weak self] item, sender in
            if let query = self?.activeQuery { history.add(query) }
            selection(item, sender)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = ""
        showRecentQueries()
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "search.filters".localized, menu: filterMenu())
    }

    func updateSearchResults(for searchController: UISearchController) {
        requestQuery(searchController.searchBar.text ?? "")
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        runSearch(searchBar.text ?? "")
    }

    private func requestQuery(_ text: String, immediately: Bool = false, force: Bool = false) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // UIKit also updates on focus and presentation changes; these must not cancel results.
        guard force || query != activeQuery else {
            if immediately, !searchStarted, !query.isEmpty {
                pending?.cancel()
                beginSearch(query, token: requestToken)
            }
            return
        }
        pending?.cancel()
        pending = nil
        requestToken.cancel()
        let token = CancellationToken()
        requestToken = token
        activeQuery = query
        searchStarted = false
        results.loader = nil
        results.setLeadingSections([])
        guard !query.isEmpty else { showRecentQueries(); return }
        results.replace([])
        if immediately {
            beginSearch(query, token: token)
        } else {
            let work = DispatchWorkItem { [weak self] in self?.beginSearch(query, token: token) }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
        }
    }

    private func showRecentQueries() {
        let items = history.queries.map(suggestionItem)
        results.replace(items.isEmpty ? [] : [TVSection(title: "TV.suggestions".localized, items: items)])
    }

    private func suggestionItem(_ query: String) -> TVItem {
        .action(query, { [weak self] in
            self?.searchController.searchBar.text = query
            self?.runSearch(query)
        })
    }

    private func runSearch(_ text: String, force: Bool = false) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        history.add(query)
        requestQuery(query, immediately: true, force: force)
        searchController.searchBar.resignFirstResponder()
    }

    private func beginSearch(_ query: String, token: CancellationToken) {
        guard requestToken === token, !token.isCancelled, !searchStarted else { return }
        pending = nil
        searchStarted = true
        let service = service
        let selectedFilters = filters
        results.loader = { continuation, done in
            guard !token.isCancelled else { return }
            service.search(query: query, filters: selectedFilters, continuation: continuation,
                           cancellationToken: token) { result in
                guard !token.isCancelled else { return }
                done(result.map { Self.browsePage($0, filters: selectedFilters) })
            }
        }
        results.refresh()
        service.fetchSearchSuggestions(query: query, cancellationToken: token) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.requestToken === token, !token.isCancelled else { return }
                let suggestions = Array(((try? result.get()) ?? []).filter { $0 != query }.prefix(3))
                let items = suggestions.map(self.suggestionItem)
                self.results.setLeadingSections([TVSection(title: "TV.suggestions".localized, items: items)])
            }
        }
    }

    private static func browsePage(_ page: SearchPage, filters: SearchFilters) -> TVBrowsePage {
        var result = TVBrowsePage(FeedPage(videos: filters.type == .playlist ? [] : page.videos,
                                          continuation: page.continuation))
        result.sections = result.sections.map {
            TVSection(title: "channel.tab.videos".localized, items: $0.items)
        }
        if !page.channels.isEmpty {
            result.sections.insert(TVSection(title: "TV.channels".localized, items: page.channels.map {
                .channel($0.id, $0.title, $0.avatarURL)
            }), at: 0)
        }
        if !page.playlists.isEmpty {
            result.sections.append(TVSection(title: "library.playlists".localized,
                                             items: page.playlists.map(TVItem.playlist)))
        }
        return result
    }
    private func filterMenu() -> UIMenu {
        func options<T: Equatable>(_ title: String, values: [T], selected: T,
                                   name: (T) -> String, set: @escaping (T) -> Void) -> UIMenu {
            UIMenu(title: title, children: values.map { value in
                UIAction(title: name(value), state: value == selected ? .on : .off) { [weak self] _ in
                    set(value)
                    guard let self else { return }
                    self.navigationItem.rightBarButtonItem?.menu = self.filterMenu()
                    if let query = self.searchController.searchBar.text, !query.isEmpty { self.runSearch(query, force: true) }
                }
            })
        }
        return UIMenu(children: [
            options("search.filters.sortTitle".localized, values: SearchFilters.Sort.allCases, selected: filters.sort,
                    name: { $0.displayName }) { [weak self] in self?.filters.sort = $0 },
            options("search.filters.dateTitle".localized, values: SearchFilters.UploadDate.allCases, selected: filters.uploadDate,
                    name: { $0.displayName }) { [weak self] in self?.filters.uploadDate = $0 },
            options("search.filters.typeTitle".localized, values: SearchFilters.ContentType.allCases, selected: filters.type,
                    name: { $0.displayName }) { [weak self] in self?.filters.type = $0 },
            options("search.filters.durationTitle".localized, values: SearchFilters.Duration.allCases, selected: filters.duration,
                    name: { $0.displayName }) { [weak self] in self?.filters.duration = $0 }
        ])
    }
    deinit { pending?.cancel(); requestToken.cancel() }
}
