import UIKit

/// TV-owned controls avoid depending on AVKit's private timeline hierarchy.
final class TVTransportView: UIView {
    let seekBar = TVSeekBar()
    let playButton = UIButton(type: .system)
    let settingsButton = UIButton(type: .system)
    let titleLabel = UILabel()
    private let timeLabel = UILabel()
    private let legendLabel = UILabel()
    var onInteraction: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.8)
        layer.cornerRadius = 24
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .white
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 24, weight: .medium)
        timeLabel.textColor = .white
        legendLabel.font = .preferredFont(forTextStyle: .caption2)
        legendLabel.textColor = .white
        legendLabel.numberOfLines = 2
        settingsButton.setImage(UIImage(systemName: "gearshape"), for: .normal)
        settingsButton.accessibilityLabel = "TV.playerSettings".tvLocalized
        settingsButton.showsMenuAsPrimaryAction = true
        playButton.accessibilityIdentifier = "TV.playPause"
        settingsButton.accessibilityIdentifier = "TV.playerSettings"
        [titleLabel, seekBar, timeLabel, legendLabel, playButton, settingsButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            seekBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            seekBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            seekBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            seekBar.heightAnchor.constraint(equalToConstant: 64),
            timeLabel.topAnchor.constraint(equalTo: seekBar.bottomAnchor),
            timeLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            legendLabel.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 12),
            legendLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            legendLabel.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -24),
            legendLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24),
            settingsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            settingsButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            settingsButton.widthAnchor.constraint(equalToConstant: 100),
            settingsButton.heightAnchor.constraint(equalToConstant: 64),
            playButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -24),
            playButton.centerYAnchor.constraint(equalTo: settingsButton.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 100),
            playButton.heightAnchor.constraint(equalToConstant: 64)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(position: Double, duration: Double, buffered: Double, playing: Bool) {
        seekBar.position = position
        seekBar.duration = duration
        seekBar.buffered = buffered
        timeLabel.text = "\(TVSeekBar.time(position)) / \(TVSeekBar.time(duration))"
        playButton.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill"), for: .normal)
        playButton.accessibilityLabel = playing ? "TV.pause".tvLocalized : "TV.play".tvLocalized
    }

    func setSegments(_ segments: [SponsorBlockSegment]) {
        seekBar.segments = segments
        let categories = SBCategory.allCases.filter { category in segments.contains { $0.category == category } }
        let legend = NSMutableAttributedString()
        for category in categories {
            legend.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: category.seekBarColor]))
            legend.append(NSAttributedString(string: category.displayName + "   ", attributes: [.foregroundColor: UIColor.white]))
        }
        legendLabel.attributedText = legend
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        onInteraction?()
    }
}
