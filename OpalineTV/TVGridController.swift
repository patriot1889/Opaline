import UIKit

enum TVItem {
    case video(Video)
    case channel(String, String, String?)
    case playlist(Playlist)
    case action(String, () -> Void)

    var title: String {
        switch self {
        case .video(let video): return video.title
        case .channel(_, let name, _): return name
        case .playlist(let playlist): return playlist.title
        case .action(let title, _): return title
        }
    }
    var subtitle: String? {
        if case .video(let video) = self { return video.channelName }
        return nil
    }
    var imageURL: String? {
        switch self {
        case .video(let video): return video.thumbnailURL
        case .channel(_, _, let url): return url
        case .playlist(let playlist): return playlist.thumbnailURL
        case .action: return nil
        }
    }
}

struct TVSection {
    var title: String?
    var items: [TVItem]
    var scrollsHorizontally = false
}


struct TVBrowsePage {
    var sections: [TVSection]
    let continuation: String?
    var shelfContinuations: [ShelfContinuation] = []

    init(sections: [TVSection], continuation: String? = nil) {
        self.sections = sections
        self.continuation = continuation
    }

    init(_ page: FeedPage) {
        continuation = page.continuation
        shelfContinuations = page.shelfContinuations ?? []
        sections = []
        var offset = 0
        for shelf in page.shelves ?? [FeedShelf(title: nil, count: page.videos.count)] {
            let end = min(offset + max(0, shelf.count), page.videos.count)
            let items = page.videos[offset..<end].filter { !$0.isShort }.map(TVItem.video)
            if !items.isEmpty { sections.append(TVSection(title: shelf.title, items: items)) }
            offset = end
        }
    }
}

final class TVCardCell: UICollectionViewCell {
    private let thumbnail = UIImageView()
    private let durationLabel = UILabel()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let metadataLabel = UILabel()
    private var imageToken: CancellationToken?

    override init(frame: CGRect) {
        super.init(frame: frame)
        thumbnail.contentMode = .scaleAspectFill
        thumbnail.clipsToBounds = true
        thumbnail.layer.cornerRadius = 12
        thumbnail.backgroundColor = .darkGray
        titleLabel.font = .systemFont(ofSize: 27, weight: .medium)
        titleLabel.numberOfLines = 2
        subtitleLabel.font = .systemFont(ofSize: 22)
        subtitleLabel.textColor = .secondaryLabel
        metadataLabel.font = .systemFont(ofSize: 22)
        metadataLabel.textColor = .secondaryLabel
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        durationLabel.textColor = .white
        durationLabel.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        durationLabel.textAlignment = .center
        durationLabel.layer.cornerRadius = 6
        durationLabel.clipsToBounds = true
        durationLabel.isHidden = true
        [thumbnail, titleLabel, subtitleLabel, metadataLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.addSubview(durationLabel)
        NSLayoutConstraint.activate([
            thumbnail.topAnchor.constraint(equalTo: contentView.topAnchor),
            thumbnail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            thumbnail.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            thumbnail.heightAnchor.constraint(equalTo: thumbnail.widthAnchor, multiplier: 9.0 / 16),
            durationLabel.trailingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: -10),
            durationLabel.bottomAnchor.constraint(equalTo: thumbnail.bottomAnchor, constant: -10),
            durationLabel.leadingAnchor.constraint(greaterThanOrEqualTo: thumbnail.leadingAnchor, constant: 10),
            durationLabel.heightAnchor.constraint(equalToConstant: 32),
            titleLabel.topAnchor.constraint(equalTo: thumbnail.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            subtitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            metadataLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 6),
            metadataLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            metadataLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func prepareForReuse() {
        super.prepareForReuse()
        imageToken?.cancel()
        thumbnail.image = nil
        durationLabel.text = nil
        durationLabel.isHidden = true
        metadataLabel.text = nil
        transform = .identity
    }
    func configure(_ item: TVItem) {
        imageToken?.cancel()
        titleLabel.text = item.title
        subtitleLabel.text = item.subtitle
        durationLabel.text = nil
        durationLabel.isHidden = true
        metadataLabel.text = nil
        if case .video(let video) = item {
            metadataLabel.text = [
                video.viewCount.map(VideoFormatters.formatViewCount),
                video.publishedAt.map(VideoFormatters.formatRelativeDate)
            ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • ")
            let duration = video.isLive ? "● LIVE" : video.duration
            if let duration, !duration.isEmpty {
                durationLabel.text = " \(duration) "
                durationLabel.isHidden = false
            }
        }
        accessibilityLabel = [item.title, item.subtitle, metadataLabel.text, durationLabel.text]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        thumbnail.image = UIImage(systemName: "play.rectangle")
        guard let string = item.imageURL, let url = URL(string: string) else { return }
        imageToken = ThumbnailLoader.shared.load(url: url, maxPixelSize: 640) { [weak self] result in
            if case .success(let image) = result { self?.thumbnail.image = image.image }
        }
    }
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations {
            self.transform = self.isFocused ? CGAffineTransform(scaleX: 1.06, y: 1.06) : .identity
            self.titleLabel.textColor = self.isFocused ? .systemYellow : .label
        }
    }
}

/// Text actions occupy a compact row so suggestions never bury video results.
final class TVActionCell: UICollectionViewCell {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 28, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        contentView.layer.cornerRadius = 14
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String) {
        label.text = title
        accessibilityLabel = title
        updateAppearance()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations { self.updateAppearance() }
    }

    private func updateAppearance() {
        contentView.backgroundColor = isFocused ? .white : UIColor.secondaryLabel.withAlphaComponent(0.15)
        label.textColor = isFocused ? .black : .label
    }
}

final class TVShelfHeader: UICollectionReusableView {
    let label = UILabel()
    private let refreshButton = UIButton(type: .system)
    var onRefresh: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 34, weight: .semibold)
        label.frame = bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(label)
        refreshButton.setTitle("TV.refresh".tvLocalized, for: .normal)
        refreshButton.addAction(UIAction { [weak self] _ in self?.onRefresh?() }, for: .primaryActionTriggered)
        addSubview(refreshButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let buttonWidth: CGFloat = refreshButton.isHidden ? 0 : 210
        label.frame = bounds
        label.frame.size.width = max(0, bounds.width - buttonWidth - 24)
        refreshButton.frame = CGRect(x: bounds.width - buttonWidth, y: 0, width: buttonWidth, height: bounds.height)
    }
    func configure(title: String?, onRefresh: (() -> Void)?) {
        label.text = title
        self.onRefresh = onRefresh
        refreshButton.isHidden = onRefresh == nil
        setNeedsLayout()
    }
}

class TVGridController: UICollectionViewController {
    typealias Completion = (Result<TVBrowsePage, Error>) -> Void
    var loader: ((String?, @escaping Completion) -> Void)?
    var leadingSectionsLoader: ((@escaping (Result<[TVSection], Error>) -> Void) -> Void)?
    var selection: ((TVItem, UIViewController) -> Void)?
    var requiresAccount = false
    var onRefresh: (() -> Void)?
    var contentHeading: String?
    var sections: [TVSection] {
        var content = contentSections
        if let contentHeading, let firstVideoSection = content.firstIndex(where: { section in
            section.items.contains { if case .video = $0 { return true }; return false }
        }) {
            content[firstVideoSection].title = contentHeading
        }
        return leadingSections + content
    }
    private var leadingSections: [TVSection] = []
    private var contentSections: [TVSection] = []
    private(set) var continuation: String?
    private var shelfContinuations: [ShelfContinuation] = []
    private var loading = false
    private var failed = false
    private var generation = 0
    private var didLoad = false
    private let status = UILabel()

    init(title: String) {
        super.init(collectionViewLayout: UICollectionViewFlowLayout())
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        edgesForExtendedLayout = []
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        collectionView.backgroundColor = TVPalette.background
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.register(TVCardCell.self, forCellWithReuseIdentifier: "card")
        collectionView.register(TVActionCell.self, forCellWithReuseIdentifier: "action")
        collectionView.register(TVShelfHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: "header")
        status.textAlignment = .center
        status.numberOfLines = 3
        status.font = .systemFont(ofSize: 30)
        collectionView.backgroundView = status
    }
    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self else { return nil }
            let section = self.sections.indices.contains(index)
                ? self.sections[index] : TVSection(title: nil, items: [])
            let width = max(240, (environment.container.effectiveContentSize.width - 220) / 3)
            let actionsOnly = section.items.allSatisfy { if case .action = $0 { return true }; return false }
            let height: CGFloat = actionsOnly ? 80 : width * 9 / 16 + 150
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                widthDimension: .absolute(width), heightDimension: .absolute(height)))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: NSCollectionLayoutSize(
                widthDimension: section.scrollsHorizontally ? .absolute(width) : .fractionalWidth(1),
                heightDimension: .absolute(height)), subitems: [item])
            group.interItemSpacing = .fixed(40)
            let layout = NSCollectionLayoutSection(group: group)
            layout.interGroupSpacing = section.scrollsHorizontally ? 40 : 50
            layout.contentInsets = NSDirectionalEdgeInsets(top: 24, leading: 70, bottom: 40, trailing: 70)
            if section.scrollsHorizontally { layout.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary }
            if section.title != nil || index == 0 {
                layout.boundarySupplementaryItems = [NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(index == 0 ? 80 : 65)),
                    elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)]
            }
            return layout
        }
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let root = navigationController?.viewControllers.first
        navigationController?.setNavigationBarHidden(root === self || root === parent, animated: animated)
        if requiresAccount && !OAuthClient.shared.isSignedIn {
            showSignIn()
        } else if !didLoad && loader != nil { refresh() }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // A pushed screen or another tab must start with its own title and actions visible.
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    func showSignIn() {
        generation += 1
        loading = false
        failed = false
        didLoad = false
        continuation = nil
        shelfContinuations = []
        leadingSections = []
        contentSections = [TVSection(title: nil, items: [.action("account.signIn".localized, { [weak self] in
            let auth = TVAuthController()
            auth.onComplete = { [weak auth, weak self] in
                auth?.dismiss(animated: true) { self?.refresh() }
            }
            self?.present(auth, animated: true)
        })])]
        status.text = nil
        collectionView.reloadData()
    }
    @objc func refresh() {
        if requiresAccount && !OAuthClient.shared.isSignedIn { showSignIn(); return }
        onRefresh?()
        generation += 1
        loading = false
        failed = false
        didLoad = true
        continuation = nil
        shelfContinuations = []
        contentSections = []
        if let leadingSectionsLoader {
            leadingSections = []
            let requestGeneration = generation
            leadingSectionsLoader { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.generation == requestGeneration,
                          let sections = try? result.get() else { return }
                    self.setLeadingSections(sections)
                }
            }
        }
        collectionView.reloadData()
        loadMore()
    }
    func replace(_ sections: [TVSection]) {
        generation += 1
        loading = false
        failed = false
        continuation = nil
        shelfContinuations = []
        self.contentSections = sections
        status.text = nil
        collectionView.reloadData()
    }
    /// Suggestions are independent of paged results and must not reset their generation or continuation.
    func setLeadingSections(_ sections: [TVSection]) {
        leadingSections = sections.filter { !$0.items.isEmpty }
        collectionView.reloadData()
    }

    private func loadMore() {
        guard let loader, !loading, !failed else { return }
        loading = true
        if contentSections.isEmpty { status.text = "TV.loading".tvLocalized }
        let requestGeneration = generation
        let token = continuation ?? shelfContinuations.first?.token
        loader(token) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.generation == requestGeneration else { return }
                self.loading = false
                switch result {
                case .success(let page):
                    if self.continuation == nil, token != nil, !self.shelfContinuations.isEmpty {
                        self.shelfContinuations.removeFirst()
                    }
                    self.continuation = page.continuation == token ? nil : page.continuation
                    if token == nil { self.shelfContinuations = page.shelfContinuations }
                    self.append(page)
                    self.status.text = self.contentSections.allSatisfy({ $0.items.isEmpty }) ? "TV.empty".tvLocalized : nil
                    self.collectionView.reloadData()
                    // Empty/Shorts-only pages must not strand a still-valid continuation.
                    if page.sections.allSatisfy({ $0.items.isEmpty }),
                       self.continuation != token,
                       self.continuation != nil || !self.shelfContinuations.isEmpty { self.loadMore() }
                case .failure:
                    self.failed = true
                    let retry = TVItem.action("TV.retry".tvLocalized) { [weak self] in
                        guard let self else { return }
                        self.contentSections.removeAll { $0.title == "TV.loadFailed".tvLocalized }
                        self.collectionView.reloadData()
                        self.failed = false
                        self.loadMore()
                    }
                    self.contentSections.append(TVSection(title: "TV.loadFailed".tvLocalized, items: [retry]))
                    self.status.text = nil
                    self.collectionView.reloadData()
                }
            }
        }
    }
    private func append(_ page: TVBrowsePage) {
        func identity(_ item: TVItem) -> String? {
            switch item {
            case .video(let video): return "video:" + video.id
            case .channel(let id, _, _): return "channel:" + id
            case .playlist(let playlist): return "playlist:" + playlist.id
            case .action: return nil
            }
        }
        var known = Set(contentSections.flatMap(\.items).compactMap(identity))
        for section in page.sections {
            let items = section.items.filter { item in
                guard let id = identity(item) else { return true }
                return known.insert(id).inserted
            }
            if !items.isEmpty {
                contentSections.append(TVSection(title: section.title, items: items,
                                                 scrollsHorizontally: section.scrollsHorizontally))
            }
        }
    }
    override func numberOfSections(in collectionView: UICollectionView) -> Int { max(1, sections.count) }
    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections.indices.contains(section) ? sections[section].items.count : 0
    }
    override func collectionView(_ collectionView: UICollectionView, cellForItemAt path: IndexPath) -> UICollectionViewCell {
        let item = sections[path.section].items[path.item]
        if case .action(let title, _) = item {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "action", for: path) as! TVActionCell
            cell.configure(title: title)
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "card", for: path) as! TVCardCell
        cell.configure(item)
        return cell
    }
    override func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                                 at path: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "header", for: path) as! TVShelfHeader
        let sectionTitle = sections.indices.contains(path.section) ? sections[path.section].title : nil
        header.configure(title: sectionTitle, onRefresh: path.section == 0 ? { [weak self] in self?.refresh() } : nil)
        return header
    }
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt path: IndexPath) {
        let item = sections[path.section].items[path.item]
        if case .action(_, let action) = item { action() } else { selection?(item, self) }
    }
    override func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt path: IndexPath) {
        if path.section == sections.count - 1,
           path.item >= sections[path.section].items.count - 3,
           continuation != nil || !shelfContinuations.isEmpty { loadMore() }
    }
}

