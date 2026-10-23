import UIKit

/// Cuts matching chapter gaps through every timeline fill, without masking the thumb.
final class ChapterTrackMask {
    private var breaks: [Double] = []
    private var layoutWidth: CGFloat = -1

    func setBreaks(_ values: [Double]) -> Bool {
        let normalized = Array(Set(values.filter {
            $0.isFinite && $0 > 0 && $0 < 1
        })).sorted()
        guard normalized != breaks else {
            return false
        }
        breaks = normalized
        layoutWidth = -1
        return true
    }

    func layout(width: CGFloat, views: [UIView]) {
        guard width > 0, width != layoutWidth else {
            return
        }
        layoutWidth = width
        guard !breaks.isEmpty else {
            views.forEach { $0.layer.mask = nil }
            return
        }
        let path = chapterPath(width: width)
        for view in views {
            let mask = CAShapeLayer()
            // The mask stays in full timeline coordinates even when a fill
            // grows or shrinks. Only chapter/width changes rebuild its path.
            mask.frame = CGRect(x: 0, y: 0, width: width, height: 4)
            mask.path = path.cgPath
            view.layer.mask = mask
        }
    }

    private func chapterPath(width: CGFloat) -> UIBezierPath {
        let edges = [CGFloat(0)] + breaks.map { CGFloat($0) * width } + [width]
        // Reduce the two-point gap for short chapters so they remain visible.
        let gaps = edges.indices.dropFirst().dropLast().map { index in
            min(
                2,
                min(
                    edges[index] - edges[index - 1],
                    edges[index + 1] - edges[index]
                ) / 2
            )
        }
        let path = UIBezierPath()
        for index in 0..<(edges.count - 1) {
            let start = edges[index] + (index == 0 ? 0 : gaps[index - 1] / 2)
            let end = edges[index + 1] - (index == gaps.count ? 0 : gaps[index] / 2)
            path.append(UIBezierPath(rect: CGRect(x: start, y: 0, width: end - start, height: 4)))
        }
        return path
    }
}
