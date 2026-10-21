import UIKit

/// Focusable TV presentation; playback and queue decisions stay in the player host.
final class TVUpNextController: UIViewController {
    var onPlay: (() -> Void)?
    var onCancel: (() -> Void)?
    private let video: Video
    private let now: () -> TimeInterval
    private let countdownDuration: TimeInterval
    private var deadline: TimeInterval?
    private var timer: Timer?
    private var resolved = false
    private var imageToken: CancellationToken?
    private let thumbnail = UIImageView()
    private let countdownLabel = UILabel()
    private let ring = CAShapeLayer()
    private let ringTrack = CAShapeLayer()
    private let ringView = UIView()
    private let playButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    init(video: Video, countdownDuration: TimeInterval = 5,
         now: @escaping () -> TimeInterval = { CACurrentMediaTime() }) {
        self.video = video
        self.countdownDuration = max(0, countdownDuration)
        self.now = now
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var preferredFocusEnvironments: [UIFocusEnvironment] { [playButton] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.9)
        let card = UIView()
        card.backgroundColor = UIColor(white: 0.12, alpha: 1)
        card.layer.cornerRadius = 32
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        thumbnail.contentMode = .scaleAspectFill
        thumbnail.clipsToBounds = true
        thumbnail.layer.cornerRadius = 20
        thumbnail.backgroundColor = UIColor(white: 0.2, alpha: 1)
        thumbnail.image = UIImage(systemName: "play.rectangle")
        thumbnail.tintColor = .white.withAlphaComponent(0.35)
        let heading = label("TV.upNextHeading".tvLocalized, style: .headline)
        let title = label(video.title, style: .title2)
        title.numberOfLines = 3
        let channel = label(video.channelName, style: .body)
        channel.textColor = .lightGray
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 36, weight: .semibold)
        countdownLabel.textColor = .white
        countdownLabel.textAlignment = .center
        countdownLabel.isAccessibilityElement = false
        ringView.isAccessibilityElement = true
        ringView.accessibilityLabel = "TV.upNextHeading".tvLocalized
        ringView.accessibilityIdentifier = "TV.upNextCountdown"
        ringView.layer.addSublayer(ringTrack)
        ringView.layer.addSublayer(ring)
        for shape in [ringTrack, ring] {
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = 6
        }
        ringTrack.strokeColor = UIColor.white.withAlphaComponent(0.2).cgColor
        ring.strokeColor = UIColor.white.cgColor
        ring.lineCap = .round
        playButton.setTitle("TV.playNow".tvLocalized, for: .normal)
        cancelButton.setTitle("TV.cancel".tvLocalized, for: .normal)
        playButton.accessibilityIdentifier = "TV.upNextPlay"
        cancelButton.accessibilityIdentifier = "TV.upNextCancel"
        playButton.addAction(UIAction { [weak self] _ in self?.playNow() }, for: .primaryActionTriggered)
        cancelButton.addAction(UIAction { [weak self] _ in self?.cancel() }, for: .primaryActionTriggered)
        let buttons = UIStackView(arrangedSubviews: [playButton, cancelButton])
        buttons.axis = .horizontal
        buttons.spacing = 32
        buttons.distribution = .fillEqually

        for child in [thumbnail, heading, title, channel, ringView, buttons] {
            child.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(child)
        }
        countdownLabel.translatesAutoresizingMaskIntoConstraints = false
        ringView.addSubview(countdownLabel)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 1320),
            card.heightAnchor.constraint(equalToConstant: 540),
            thumbnail.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 40),
            thumbnail.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 560),
            thumbnail.heightAnchor.constraint(equalToConstant: 315),
            heading.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 48),
            heading.topAnchor.constraint(equalTo: card.topAnchor, constant: 48),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: ringView.leadingAnchor, constant: -24),
            ringView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -40),
            ringView.topAnchor.constraint(equalTo: card.topAnchor, constant: 32),
            ringView.widthAnchor.constraint(equalToConstant: 88),
            ringView.heightAnchor.constraint(equalToConstant: 88),
            countdownLabel.centerXAnchor.constraint(equalTo: ringView.centerXAnchor),
            countdownLabel.centerYAnchor.constraint(equalTo: ringView.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -40),
            title.topAnchor.constraint(equalTo: ringView.bottomAnchor, constant: 24),
            channel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            channel.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            channel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            channel.bottomAnchor.constraint(lessThanOrEqualTo: buttons.topAnchor, constant: -24),
            buttons.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -48),
            buttons.heightAnchor.constraint(equalToConstant: 72)
        ])
        if let url = URL(string: video.thumbnailURL), !video.thumbnailURL.isEmpty {
            imageToken = ThumbnailLoader.shared.load(url: url, maxPixelSize: 1120) { [weak self] result in
                guard let self, !self.resolved else { return }
                if case .success(let image) = result { self.thumbnail.image = image.image }
            }
        }
        updateCountdownLabel(remaining: countdownDuration)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let path = UIBezierPath(arcCenter: CGPoint(x: 44, y: 44), radius: 38,
                                startAngle: -.pi / 2, endAngle: 3 * .pi / 2, clockwise: true).cgPath
        ringTrack.frame = ringView.bounds
        ring.frame = ringView.bounds
        ringTrack.path = path
        ring.path = path
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startCountdown()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCountdown()
    }

    func startCountdown() {
        guard !resolved, deadline == nil else { return }
        deadline = now() + countdownDuration
        updateCountdown()
        guard !resolved else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateCountdown()
        }
    }

    /// Uses elapsed time rather than counting timer firings, so the ring and number agree.
    func updateCountdown() {
        guard !resolved, let deadline else { return }
        let remaining = max(0, deadline - now())
        updateCountdownLabel(remaining: remaining)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeEnd = countdownDuration > 0 ? remaining / countdownDuration : 0
        CATransaction.commit()
        if remaining <= 0 { playNow() }
    }

    func playNow() { finish(play: true) }
    func cancel() { finish(play: false) }

    func stopCountdown() {
        resolved = true
        timer?.invalidate()
        timer = nil
        imageToken?.cancel()
        imageToken = nil
    }

    private func finish(play: Bool) {
        guard !resolved else { return }
        stopCountdown()
        if play { onPlay?() } else { onCancel?() }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { cancel() }
        else if presses.contains(where: { $0.type == .playPause }) { playNow() }
        else { super.pressesBegan(presses, with: event) }
    }

    private func updateCountdownLabel(remaining: TimeInterval) {
        let text = String(Int(ceil(remaining)))
        countdownLabel.text = text
        ringView.accessibilityValue = text
    }

    private func label(_ text: String, style: UIFont.TextStyle) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.textColor = .white
        return label
    }

    deinit { timer?.invalidate(); imageToken?.cancel() }
}
