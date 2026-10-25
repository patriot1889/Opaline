import CoreMedia
import Foundation

struct WebMVP9DeliverySegment: Sendable {
    let initialization: Data
    let media: Data
    let startNanoseconds: Int64
    let endNanoseconds: Int64
    let configuration: WebMVP9Configuration?
    var byteCount: Int { initialization.count + media.count }

    init(
        fragments: WebMVP9Fragments,
        interval: WebMVP9DeliveryPlan.Segment,
        configuration: WebMVP9Configuration? = nil
    ) throws {
        guard !fragments.initialization.isEmpty, !fragments.media.isEmpty else {
            throw WebMDeliveryError.invalidTimeline
        }
        var cursor = interval.startNanoseconds
        for fragment in fragments.media {
            let start = try Self.nanoseconds(fragment.start)
            let duration = try Self.nanoseconds(fragment.duration)
            let (end, overflow) = cursor.addingReportingOverflow(duration)
            guard !fragment.data.isEmpty, start == cursor, duration > 0,
                  !overflow, end <= interval.endNanoseconds else {
                throw WebMDeliveryError.invalidTimeline
            }
            cursor = end
        }
        guard cursor == interval.endNanoseconds else { throw WebMDeliveryError.invalidTimeline }
        initialization = fragments.initialization
        media = fragments.media.reduce(into: Data()) { $0.append($1.data) }
        startNanoseconds = interval.startNanoseconds
        endNanoseconds = interval.endNanoseconds
        self.configuration = configuration
    }

    private static func nanoseconds(_ time: CMTime) throws -> Int64 {
        let converted = CMTimeConvertScale(time, timescale: 1_000_000_000, method: .default)
        guard time.isNumeric, time.epoch == 0, converted.isNumeric,
              CMTimeCompare(time, converted) == 0, converted.value >= 0 else {
            throw WebMDeliveryError.invalidTimeline
        }
        return converted.value
    }
}
