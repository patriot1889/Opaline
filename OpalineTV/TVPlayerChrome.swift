import UIKit

/// tvOS-owned presentation; stream preparation and page models remain shared with iOS.
final class TVPlayerChrome: UIView {
    let heading = UILabel()
    let metadata = UILabel()
    let elapsed = UILabel()
    let duration = UILabel()
    let timeline = TVPlayerTimeline()
    let play = UIButton(type: .system)
    let previous = UIButton(type: .system)
    let nextButton = UIButton(type: .system)
    let channel = UIButton(type: .system)
    let descriptionButton = UIButton(type: .system)
    let subscribe = UIButton(type: .system)
    let like = UIButton(type: .system)
    let dislike = UIButton(type: .system)
    let comments = UIButton(type: .system)
    let captions = UIButton(type: .system)
    let settings = UIButton(type: .system)
    private let gradient = CAGradientLayer()
    private let topGradient = CAGradientLayer()
    private var imageTokens: [CancellationToken] = []
    var onInteraction: (() -> Void)?
    private let titleBlock = UIStackView()
    private let controls = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        topGradient.colors = [UIColor.black.withAlphaComponent(0.6).cgColor, UIColor.clear.cgColor]
        gradient.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.8).cgColor]
        layer.addSublayer(topGradient)
        layer.addSublayer(gradient)
        heading.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: 40, weight: .bold))
        heading.numberOfLines = 2
        metadata.font = .preferredFont(forTextStyle: .caption1)
        metadata.textColor = .lightGray
        titleBlock.axis = .vertical
        titleBlock.spacing = 12
        titleBlock.addArrangedSubview(heading)
        titleBlock.addArrangedSubview(metadata)
        addSubview(titleBlock)
        addSubview(controls)
        [elapsed, duration].forEach {
            $0.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
            controls.addSubview($0)
        }
        duration.textAlignment = .right
        controls.addSubview(timeline)
        timeline.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.elapsed.text = Self.time(self.timeline.fraction * self.timeline.duration)
        }, for: .valueChanged)
        configure(channel, title: nil, symbol: "person.crop.circle", label: "Channel")
        configure(descriptionButton, title: "TV.player.description".tvLocalized, symbol: nil, label: "Description")
        configure(previous, title: nil, symbol: "backward.end.fill", label: "Previous video")
        configure(play, title: nil, symbol: "pause.fill", label: "Pause")
        configure(nextButton, title: nil, symbol: "forward.end.fill", label: "Next video")
        configure(subscribe, title: nil, symbol: "bell", label: "Subscribe")
        configure(like, title: nil, symbol: "hand.thumbsup", label: "Like")
        configure(dislike, title: nil, symbol: "hand.thumbsdown", label: "Dislike")
        configure(comments, title: nil, symbol: "text.bubble", label: "Comments")
        configure(captions, title: nil, symbol: "captions.bubble", label: "Captions")
        configure(settings, title: nil, symbol: "gearshape", label: "Settings")
        captions.showsMenuAsPrimaryAction = true
        settings.showsMenuAsPrimaryAction = true
        accessibilityIdentifier = "TV.playerControls"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure(_ button: UIButton, title: String?, symbol: String?, label: String) {
        var config = UIButton.Configuration.tinted()
        config.title = title
        config.image = symbol.flatMap { UIImage(systemName: $0) }
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor(white: 0.35, alpha: 0.8)
        config.cornerStyle = .capsule
        button.configuration = config
        button.accessibilityLabel = label
        button.accessibilityIdentifier = "TV.player.\(label)"
        controls.addSubview(button)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 80
        let width = bounds.width - inset * 2
        topGradient.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height * 0.35)
        gradient.frame = CGRect(x: 0, y: bounds.height * 0.48, width: bounds.width, height: bounds.height * 0.52)
        titleBlock.frame = CGRect(x: inset, y: 75, width: width * 0.8, height: 150)
        controls.frame = CGRect(x: inset, y: bounds.height - 235, width: width, height: 180)
        elapsed.frame = CGRect(x: 0, y: 0, width: width / 2, height: 30)
        duration.frame = CGRect(x: width / 2, y: 0, width: width / 2, height: 30)
        timeline.frame = CGRect(x: 0, y: 36, width: width, height: 30)
        channel.frame = CGRect(x: 0, y: 85, width: 72, height: 72)
        descriptionButton.frame = CGRect(x: 88, y: 85, width: 210, height: 72)
        play.frame = CGRect(x: width / 2 - 46, y: 75, width: 92, height: 92)
        previous.frame = CGRect(x: width / 2 - 138, y: 85, width: 72, height: 72)
        nextButton.frame = CGRect(x: width / 2 + 66, y: 85, width: 72, height: 72)
        subscribe.frame = CGRect(x: 316, y: 85, width: 72, height: 72)
        like.frame = CGRect(x: width - 444, y: 85, width: 72, height: 72)
        dislike.frame = CGRect(x: width - 351, y: 85, width: 72, height: 72)
        comments.frame = CGRect(x: width - 258, y: 85, width: 72, height: 72)
        captions.frame = CGRect(x: width - 165, y: 85, width: 72, height: 72)
        settings.frame = CGRect(x: width - 72, y: 85, width: 72, height: 72)
    }

    func update(video: Video) {
        heading.text = video.title
        metadata.text = [video.channelName, video.viewCount, video.publishedAt].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        imageTokens.forEach { $0.cancel() }
        imageTokens = []
        if let raw = video.channelAvatarURL, let url = URL(string: raw) {
            imageTokens.append(ThumbnailLoader.shared.load(url: url, maxPixelSize: 120, completion: { [weak self] result in
                guard case .success(let loaded) = result else { return }
                self?.channel.configuration?.image = loaded.image.preparingThumbnail(of: CGSize(width: 48, height: 48))
            }))
        } else { channel.configuration?.image = UIImage(systemName: "person.crop.circle") }
        setNeedsLayout()
    }

    func updateTime(seconds: Double, total: Double, playing: Bool) {
        if !timeline.isScrubbing { elapsed.text = Self.time(seconds) }
        duration.text = total.isFinite && total > 0 ? Self.time(total) : "LIVE"
        timeline.duration = total
        if !timeline.isScrubbing { timeline.fraction = total.isFinite && total > 0 ? seconds / total : 0 }
        timeline.isEnabled = total.isFinite && total > 0
        play.configuration?.image = UIImage(systemName: playing ? "pause.fill" : "play.fill")
        play.accessibilityLabel = playing ? "Pause" : "Play"
    }
    static func time(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let seconds = Int(value)
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        onInteraction?()
    }
    deinit { imageTokens.forEach { $0.cancel() } }
}

final class TVPlayerTimeline: UIControl, UIGestureRecognizerDelegate {
    var fraction: Double = 0 { didSet { setNeedsDisplay() } }
    var duration: Double = 0
    var onSeekTo: ((Double) -> Void)?
    var onScrubbingChanged: ((Bool) -> Void)?
    private(set) var isScrubbing = false
    private var scrubStartFraction: Double = 0
    override var canBecomeFocused: Bool { isEnabled }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        accessibilityLabel = "Playback position"
        accessibilityIdentifier = "TV.player.timeline"
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        let y = bounds.midY - 4
        UIColor.white.withAlphaComponent(0.35).setFill()
        UIBezierPath(roundedRect: CGRect(x: 0, y: y, width: bounds.width, height: 8), cornerRadius: 4).fill()
        let x = bounds.width * min(1, max(0, fraction))
        UIColor.white.setFill()
        UIBezierPath(roundedRect: CGRect(x: 0, y: y, width: x, height: 8), cornerRadius: 4).fill()
        let radius: CGFloat = isFocused ? 14 : 9
        UIBezierPath(ovalIn: CGRect(x: max(radius, min(bounds.width - radius, x)) - radius,
                                  y: bounds.midY - radius, width: radius * 2, height: radius * 2)).fill()
    }
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if !isFocused { endScrubbing(cancelled: true) }
        setNeedsDisplay()
    }

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        // Horizontal remote motion moves the playhead, rather than leaving this control.
        if isFocused, context.focusHeading.contains(.left) || context.focusHeading.contains(.right) { return false }
        return super.shouldUpdateFocus(in: context)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isFocused, isEnabled, duration.isFinite, duration > 0,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            beginScrubbing()
            updateScrubbing(translation: pan.translation(in: self).x)
        case .changed:
            updateScrubbing(translation: pan.translation(in: self).x)
        case .ended:
            updateScrubbing(translation: pan.translation(in: self).x)
            endScrubbing(cancelled: false)
        case .cancelled, .failed:
            endScrubbing(cancelled: true)
        default: break
        }
    }

    func beginScrubbing() {
        guard !isScrubbing, isEnabled, duration.isFinite, duration > 0 else { return }
        scrubStartFraction = fraction
        isScrubbing = true
        onScrubbingChanged?(true)
    }

    func updateScrubbing(translation: CGFloat) {
        guard isScrubbing, translation.isFinite, bounds.width > 0 else { return }
        fraction = min(1, max(0, scrubStartFraction + Double(translation / bounds.width) * 0.25))
        sendActions(for: .valueChanged)
    }

    func endScrubbing(cancelled: Bool) {
        guard isScrubbing else { return }
        if cancelled { fraction = scrubStartFraction }
        else { onSeekTo?(fraction * duration) }
        isScrubbing = false
        sendActions(for: .valueChanged)
        onScrubbingChanged?(false)
    }

    func step(by seconds: Double) {
        guard !isScrubbing, isEnabled, duration.isFinite, duration > 0, seconds.isFinite else { return }
        fraction = min(1, max(0, fraction + seconds / duration))
        sendActions(for: .valueChanged)
        onSeekTo?(fraction * duration)
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) {
            // Activate on release, so a cancelled centre press does not toggle playback.
        } else if presses.contains(where: { $0.type == .leftArrow || $0.type == .rightArrow }) {
            step(by: presses.contains(where: { $0.type == .rightArrow }) ? 10 : -10)
        } else { super.pressesBegan(presses, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if isEnabled, presses.contains(where: { $0.type == .select }) {
            endScrubbing(cancelled: false)
            sendActions(for: .primaryActionTriggered)
        }
        let remaining = presses.filter { $0.type != .leftArrow && $0.type != .rightArrow && $0.type != .select }
        if !remaining.isEmpty { super.pressesEnded(remaining, with: event) }
    }
    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { $0.type != .leftArrow && $0.type != .rightArrow && $0.type != .select }
        if !remaining.isEmpty { super.pressesChanged(remaining, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { $0.type != .leftArrow && $0.type != .rightArrow && $0.type != .select }
        if !remaining.isEmpty { super.pressesCancelled(remaining, with: event) }
    }

}

/// Focusable cards keep long descriptions and comments readable with the Siri Remote.
final class TVPlayerPanel: UITableViewController {
    struct Card {
        let title: String
        let body: String
        var footer: String = ""
        var avatarURL: String?
        var action: (() -> Void)?
    }
    var cards: [Card] = [] { didSet { if isViewLoaded { tableView.reloadData() } } }
    private let heading = UILabel()
    var panelTitle: String = "" { didSet { heading.text = panelTitle } }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        tableView.backgroundColor = .clear
        tableView.contentInset = UIEdgeInsets(top: 0, left: 8, bottom: 45, right: 8)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 240
        tableView.register(TVPlayerCardCell.self, forCellReuseIdentifier: "card")
        heading.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: 36, weight: .bold))
        heading.numberOfLines = 3
        heading.text = panelTitle
        heading.frame = CGRect(x: 24, y: 0, width: 560, height: 140)
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 600, height: 150))
        header.addSubview(heading)
        tableView.tableHeaderView = header
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        heading.frame.size.width = tableView.bounds.width - 48
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { cards.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "card", for: indexPath) as! TVPlayerCardCell
        cell.configure(cards[indexPath.row])
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { cards[indexPath.row].action?() }
}

private final class TVPlayerCardCell: UITableViewCell {
    private let card = UIView()
    private let avatar = UIImageView()
    private let heading = UILabel()
    private let bodyLabel = UILabel()
    private let footer = UILabel()
    private var footerText = ""
    private var token: CancellationToken?
    private var avatarWidth: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        focusStyle = .custom
        card.layer.cornerRadius = 20
        card.backgroundColor = UIColor(white: 0.17, alpha: 1)
        heading.font = .preferredFont(forTextStyle: .caption1)
        heading.numberOfLines = 2
        bodyLabel.font = .preferredFont(forTextStyle: .caption1)
        bodyLabel.numberOfLines = 0
        footer.font = .preferredFont(forTextStyle: .caption2)
        avatar.contentMode = .scaleAspectFill
        avatar.clipsToBounds = true
        avatar.layer.cornerRadius = 24
        let author = UIStackView(arrangedSubviews: [avatar, heading])
        author.spacing = 16
        author.alignment = .center
        let stack = UIStackView(arrangedSubviews: [author, bodyLabel, footer])
        stack.axis = .vertical
        stack.spacing = 20
        contentView.addSubview(card)
        card.addSubview(stack)
        card.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        avatarWidth = avatar.widthAnchor.constraint(equalToConstant: 48)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -26),
            avatarWidth, avatar.heightAnchor.constraint(equalToConstant: 48)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ model: TVPlayerPanel.Card) {
        token?.cancel()
        avatar.image = nil
        avatar.isHidden = model.avatarURL == nil
        heading.text = model.title
        heading.isHidden = model.title.isEmpty
        bodyLabel.text = model.body
        bodyLabel.isHidden = model.body.isEmpty
        footerText = model.footer
        footer.text = model.footer
        footer.isHidden = model.footer.isEmpty
        if let raw = model.avatarURL, let url = URL(string: raw) {
            token = ThumbnailLoader.shared.load(url: url, maxPixelSize: 120, completion: { [weak self] result in
                if case .success(let loaded) = result { self?.avatar.image = loaded.image }
            })
        }
        updateColors()
    }
    private func updateColors() {
        card.backgroundColor = isFocused ? UIColor(white: 0.88, alpha: 1) : UIColor(white: 0.17, alpha: 1)
        let color: UIColor = isFocused ? .black : .white
        [heading, bodyLabel, footer].forEach { $0.textColor = color }
        let text = NSMutableAttributedString(string: footerText)
        for (marker, symbol) in [("♡", "hand.thumbsup"), ("▢", "text.bubble")] {
            let range = (text.string as NSString).range(of: marker)
            guard range.location != NSNotFound else { continue }
            let attachment = NSTextAttachment()
            attachment.image = UIImage(systemName: symbol)?.withTintColor(color, renderingMode: .alwaysOriginal)
            attachment.bounds = CGRect(x: 0, y: -3, width: 22, height: 22)
            text.replaceCharacters(in: range, with: NSAttributedString(attachment: attachment))
        }
        footer.attributedText = text
    }
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations { self.updateColors() }
    }
    override func prepareForReuse() { super.prepareForReuse(); token?.cancel(); token = nil }
    deinit { token?.cancel() }
}
