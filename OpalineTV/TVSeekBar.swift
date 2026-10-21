import UIKit

/// Remote-driven timeline. Category colours come from the shared SponsorBlock catalog.
final class TVSeekBar: UIControl {
    var onSeek: ((Double) -> Void)?
    var onPlayPause: (() -> Void)?
    var position: Double = 0 { didSet { setNeedsDisplay(); updateAccessibility() } }
    var duration: Double = 0 { didSet { setNeedsDisplay(); updateAccessibility() } }
    var buffered: Double = 0 { didSet { setNeedsDisplay() } }
    var segments: [SponsorBlockSegment] = [] { didSet { setNeedsDisplay() } }

    override var canBecomeFocused: Bool { duration.isFinite && duration > 0 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = true
        accessibilityLabel = "TV.timeline".tvLocalized
        accessibilityHint = "TV.seekHint".tvLocalized
        accessibilityTraits = [.adjustable]
        accessibilityIdentifier = "TV.seekBar"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        let track = CGRect(x: 16, y: bounds.midY - 4, width: max(0, bounds.width - 32), height: 8)
        UIColor.white.withAlphaComponent(0.25).setFill()
        UIBezierPath(roundedRect: track, cornerRadius: 4).fill()
        guard duration.isFinite, duration > 0 else { return }
        func fill(_ start: Double, _ end: Double, _ color: UIColor) {
            guard start.isFinite, end.isFinite else { return }
            let lower = min(1, max(0, start / duration))
            let upper = min(1, max(0, end / duration))
            guard upper > lower else { return }
            color.setFill()
            UIBezierPath(rect: CGRect(x: track.minX + track.width * lower, y: track.minY,
                                      width: track.width * (upper - lower), height: track.height)).fill()
        }
        fill(0, buffered, .white.withAlphaComponent(0.45))
        fill(0, position, .white)
        // Draw after progress so segments remain visible on both sides of the playhead.
        for segment in segments {
            fill(segment.startTime, segment.endTime, segment.category.seekBarColor)
        }
        let fraction = position.isFinite ? min(1, max(0, position / duration)) : 0
        let diameter: CGFloat = isFocused ? 28 : 16
        UIColor.white.setFill()
        UIBezierPath(ovalIn: CGRect(x: track.minX + track.width * fraction - diameter / 2,
                                   y: bounds.midY - diameter / 2, width: diameter, height: diameter)).fill()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        setNeedsDisplay()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .leftArrow || $0.type == .rightArrow }) {
            adjust(by: presses.contains(where: { $0.type == .leftArrow }) ? -10 : 10)
        } else if presses.contains(where: { $0.type == .select }) {
            onPlayPause?()
        } else {
            super.pressesBegan(presses, with: event)
        }
    }

    override func accessibilityIncrement() { adjust(by: 10) }
    override func accessibilityDecrement() { adjust(by: -10) }

    private func adjust(by seconds: Double) {
        guard duration.isFinite, duration > 0, position.isFinite else { return }
        position = min(duration, max(0, position + seconds))
        onSeek?(position)
    }

    private func updateAccessibility() {
        accessibilityValue = "\(Self.time(position)) / \(Self.time(duration))"
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "--:--" }
        let value = Int(seconds)
        return value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
}
