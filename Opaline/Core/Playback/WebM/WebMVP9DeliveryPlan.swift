import Foundation

enum WebMDeliveryError: Error, Equatable {
    case invalidPlan
    case invalidTimeline
    case notFound
    case cancelled
    case timeout
    case capacity
    case configurationChanged
}

/// A finite VOD timeline. Exact next-cue/file-end boundaries prevent each
/// independent writer's final DefaultDuration from accumulating rounding drift.
struct WebMVP9DeliveryPlan: Sendable {
    struct Segment: Sendable {
        let entry: WebMClusterIndex.Entry
        let endNanoseconds: Int64
        var startNanoseconds: Int64 { entry.timeNanoseconds }
        var durationNanoseconds: Int64 { endNanoseconds - startNanoseconds }
        /// Publishing enforces this budget, so a master playlist can advertise
        /// an upper bitrate before downloading/remuxing every cue in the file.
        var maximumRemuxBytes: Int64 { min(entry.range.count, 16_777_216) + 1_048_576 }
    }

    let segments: [Segment]

    init(index: WebMClusterIndex, durationNanoseconds: Int64) throws {
        guard durationNanoseconds > 0, index.entries.first?.timeNanoseconds == 0,
              index.entries.count <= 32_768 else { throw WebMDeliveryError.invalidPlan }
        segments = try index.entries.enumerated().map { position, entry in
            let end = position + 1 < index.entries.count
                ? index.entries[position + 1].timeNanoseconds : durationNanoseconds
            guard end > entry.timeNanoseconds, end <= durationNanoseconds else {
                throw WebMDeliveryError.invalidPlan
            }
            return Segment(entry: entry, endNanoseconds: end)
        }
    }

    /// Each cue is independently remuxed, so give it its own initialization map.
    /// Callers serve audio separately on the same zero-based media timeline.
    func playlist(basePath: String, startAt: Double? = nil) throws -> String {
        let characters = "/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
        let allowed = CharacterSet(charactersIn: characters)
        guard basePath.hasPrefix("/"), !basePath.hasSuffix("/"), !basePath.contains("//"),
              basePath.unicodeScalars.allSatisfy(allowed.contains) else {
            throw WebMDeliveryError.invalidPlan
        }
        let longest = segments.map(\.durationNanoseconds).max() ?? 0
        let target = longest / 1_000_000_000 + (longest.isMultiple(of: 1_000_000_000) ? 0 : 1)
        var lines = [
            "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-INDEPENDENT-SEGMENTS"
        ]
        if let startAt {
            guard startAt.isFinite, startAt >= 0,
                  startAt < Double(segments.last?.endNanoseconds ?? 0) / 1e9 else {
                throw WebMError.invalidTimestamp
            }
            if startAt > 0 {
                lines.append(String(format: "#EXT-X-START:TIME-OFFSET=%.9f,PRECISE=YES", startAt))
            }
        }
        for (index, segment) in segments.enumerated() {
            lines.append("#EXT-X-MAP:URI=\"\(basePath)/\(index)/init\"")
            let duration = segment.durationNanoseconds
            let fraction = String(format: "%09lld", duration % 1_000_000_000)
            lines.append("#EXTINF:\(duration / 1_000_000_000).\(fraction),")
            lines.append("\(basePath)/\(index)/media")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}
