import UIKit

/// Keeps channel navigation visible while the shared grid pages through the selected feed.
final class TVSubscriptionsController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    typealias ChannelsLoader = (@escaping (Result<[SubscribedChannel], Error>) -> Void) -> Void
    typealias VideosLoader = (SubscribedChannel?, String?, @escaping TVGridController.Completion) -> Void

    let grid = TVGridController(title: "subscriptions.title".localized)
    let sidebar = UITableView(frame: .zero, style: .plain)
    private(set) var channels: [SubscribedChannel] = []
    private(set) var selectedChannel: SubscribedChannel?
    private let channelsLoader: ChannelsLoader
    private let videosLoader: VideosLoader
    private var channelsGeneration = 0
    private var channelsFailed = false

    init(channelsLoader: @escaping ChannelsLoader, videosLoader: @escaping VideosLoader) {
        self.channelsLoader = channelsLoader
        self.videosLoader = videosLoader
        super.init(nibName: nil, bundle: nil)
        title = "subscriptions.title".localized
        grid.requiresAccount = true
        grid.contentHeading = "channel.tab.videos".localized
        grid.loader = { [weak self] token, completion in
            guard let self else { return }
            self.videosLoader(self.selectedChannel, token, completion)
        }
        grid.onRefresh = { [weak self] in self?.loadChannels() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        edgesForExtendedLayout = []
        view.backgroundColor = TVPalette.background
        sidebar.backgroundColor = TVPalette.background
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.rowHeight = 90
        sidebar.remembersLastFocusedIndexPath = true
        sidebar.register(UITableViewCell.self, forCellReuseIdentifier: "channel")
        sidebar.accessibilityIdentifier = "TV.subscriptionChannels"
        addChild(grid)
        [sidebar, grid.view!].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: safe.topAnchor, constant: 24),
            sidebar.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 360),
            grid.view.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 20),
            grid.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.view.topAnchor.constraint(equalTo: safe.topAnchor),
            grid.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        grid.didMove(toParent: self)
    }

    private func loadChannels() {
        channelsGeneration += 1
        let generation = channelsGeneration
        channelsLoader { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.channelsGeneration == generation else { return }
                switch result {
                case .success(let channels):
                    let changed = self.channels.map(\.id) != channels.map(\.id)
                        || self.channels.map(\.title) != channels.map(\.title) || self.channelsFailed
                    self.channels = channels
                    self.channelsFailed = false
                    if changed { self.sidebar.reloadData() }
                case .failure:
                    self.channelsFailed = true
                    self.sidebar.reloadData()
                }
            }
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        1 + channels.count + (channelsFailed ? 1 : 0)
    }

    func tableView(_ tableView: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "channel", for: path)
        let isRetry = path.row > channels.count
        let channel = path.row > 0 && !isRetry ? channels[path.row - 1] : nil
        let selected = !isRetry && selectedChannel?.id == channel?.id
        var content = cell.defaultContentConfiguration()
        content.text = isRetry ? "TV.retry".tvLocalized : channel?.title ?? "TV.all".tvLocalized
        content.textProperties.font = .systemFont(ofSize: 27, weight: selected ? .semibold : .regular)
        content.textProperties.numberOfLines = 2
        cell.contentConfiguration = content
        cell.accessoryType = selected ? .checkmark : .none
        cell.accessibilityTraits = selected ? [.button, .selected] : [.button]
        cell.accessibilityIdentifier = isRetry ? "TV.retryChannels" : channel?.id ?? "TV.allSubscriptions"
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt path: IndexPath) {
        if path.row > channels.count { loadChannels(); return }
        let channel = path.row == 0 ? nil : channels[path.row - 1]
        guard selectedChannel?.id != channel?.id else { return }
        selectedChannel = channel
        grid.contentHeading = channel?.title ?? "channel.tab.videos".localized
        sidebar.reloadData()
        grid.refresh()
        grid.collectionView.setContentOffset(.zero, animated: false)
    }
}
