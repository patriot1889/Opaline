import UIKit

extension TVPlayerTimeline {
    /// Gaps only affect drawing; remote scrubbing keeps a continuous timeline.
    func chapterTrackPath() -> UIBezierPath {
        let width = bounds.width
        let path = UIBezierPath()
        guard width > 0 else {
            return path
        }
        let breaks: [Double]
        if duration.isFinite, duration > 0 {
            breaks = Array(Set(chapters.map { $0.startTime / duration }.filter {
                $0.isFinite && $0 > 0 && $0 < 1
            })).sorted()
        } else {
            breaks = []
        }
        let edges = [CGFloat(0)] + breaks.map { CGFloat($0) * width } + [width]
        let gaps = edges.indices.dropFirst().dropLast().map { index in
            min(4, min(edges[index] - edges[index - 1], edges[index + 1] - edges[index]) / 2)
        }
        for index in 0..<(edges.count - 1) {
            let start = edges[index] + (index == 0 ? 0 : gaps[index - 1] / 2)
            let end = edges[index + 1] - (index == gaps.count ? 0 : gaps[index] / 2)
            path.append(UIBezierPath(
                roundedRect: CGRect(x: start, y: bounds.midY - 4, width: end - start, height: 8),
                cornerRadius: 4
            ))
        }
        return path
    }
}
