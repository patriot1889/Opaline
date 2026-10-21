import Foundation

/// Timeline rules shared by the player and deterministic fixture tests.
enum TVPlaybackPolicy {
    static func sponsorMarkerRange(_ segment: SponsorBlockSegment, duration: Double) -> ClosedRange<Double>? {
        guard duration.isFinite, duration > 0,
              segment.startTime.isFinite, segment.endTime.isFinite,
              segment.endTime >= segment.startTime,
              segment.endTime >= 0, segment.startTime <= duration else { return nil }
        let start = max(0, segment.startTime) / duration
        let end = min(duration, segment.endTime) / duration
        guard end > start || segment.actionType == "poi" else { return nil }
        return start...end
    }

    static func upcomingVideo(in queue: PlaybackQueue, suggestion: Video?) -> Video? {
        queue.nextVideo ?? (queue.playlistId == nil ? suggestion : nil)
    }

    static func seekPosition(requested: Double?, preparedStart: Double?) -> Double? {
        guard let requested, requested.isFinite, requested > 0 else { return nil }
        if let preparedStart, abs(preparedStart - requested) <= 0.5 { return nil }
        return requested
    }

    static func caption(at seconds: Double, cues: [SubtitleCue]) -> String? {
        guard seconds.isFinite, !cues.isEmpty else { return nil }
        var low = 0
        var high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].start <= seconds { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        let cue = cues[low - 1]
        return seconds < cue.end ? cue.text : nil
    }
}
