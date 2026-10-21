import Foundation

/// A named point on a video's timeline; the next chapter or video duration defines its end.
struct VideoChapter: Codable, Equatable {
    let title: String
    let startTime: Double
}
