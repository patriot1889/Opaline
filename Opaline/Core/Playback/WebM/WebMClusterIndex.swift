import Foundation

/// Groups cues sharing one Cluster and maps seek times to bounded file ranges.
/// A range may contain additional, unindexed Clusters before the next cue.
struct WebMClusterIndex: Sendable {
    struct Entry: Equatable, Sendable {
        let timeNanoseconds: Int64
        let range: WebMByteRange
    }

    let entries: [Entry]

    init(cues: [WebMCue], contentLength: Int64) throws {
        guard contentLength > 0, !cues.isEmpty else { throw WebMRangeError.emptyIndex }
        let unique = try Self.uniqueClusters(cues, contentLength: contentLength)
        entries = try unique.enumerated().map { index, cue in
            let next = index + 1 < unique.count ? unique[index + 1].clusterOffset : contentLength
            return Entry(
                timeNanoseconds: cue.timeNanoseconds,
                range: try WebMByteRange(start: cue.clusterOffset, end: next - 1)
            )
        }
    }

    /// Starts at the preceding cue, so decoding begins with a random-access
    /// point. The caller still retains the requested presentation position.
    func entry(forTimeNanoseconds time: Int64) throws -> Entry {
        guard time >= 0 else { throw WebMError.invalidTimestamp }
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if entries[middle].timeNanoseconds <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return entries[max(0, lower - 1)]
    }
}

private extension WebMClusterIndex {
    static func uniqueClusters(_ cues: [WebMCue], contentLength: Int64) throws -> [WebMCue] {
        var result: [WebMCue] = []
        var previous: WebMCue?
        for cue in cues {
            guard cue.timeNanoseconds >= 0, cue.clusterOffset >= 0,
                  cue.clusterOffset < contentLength else { throw WebMRangeError.invalidRange }
            if let previous,
               cue.timeNanoseconds < previous.timeNanoseconds
                || cue.clusterOffset < previous.clusterOffset {
                throw WebMRangeError.invalidRange
            }
            if result.last?.clusterOffset != cue.clusterOffset { result.append(cue) }
            previous = cue
        }
        return result
    }
}
