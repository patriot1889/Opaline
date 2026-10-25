import UIKit

extension UIButton {
    /// Uses configuration padding while retaining the caller's title font,
    /// state-specific titles/colors, and layer-based background styling.
    func setContentPadding(_ insets: NSDirectionalEdgeInsets) {
        let font = titleLabel?.font
        let cornerRadius = layer.cornerRadius
        var padded = configuration ?? .plain()
        padded.contentInsets = insets
        padded.background = .clear()
        padded.background.cornerRadius = cornerRadius
        padded.cornerStyle = .fixed
        padded.titleTextAttributesTransformer = .init { incoming in
            var attributes = incoming
            attributes.font = font
            return attributes
        }
        configuration = padded
        layer.cornerRadius = cornerRadius
    }
}
