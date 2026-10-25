import Foundation

/// Only flat, zero-origin AAC indexes are supported. HLSGenerator supplies the
/// playlist; these checks reject layouts its offset convention cannot express.
struct WebMAudioIndex: Sendable {
    let segments: [SidxSegment]
    let peakBitrate: Int

    init(data: Data, format: DashFormatInfo) throws {
        guard WebMVP9Formats.isAudio(format), data.count >= 32, data.readFourCC(at: 4) == "sidx",
            data.readBigUInt32(at: 0) == data.count, [0, 1].contains(data.byte(at: 8)),
            data.readBigUInt32(at: 16) > 0
        else { throw WebMDeliveryError.invalidPlan }
        let version = data.byte(at: 8)
        let header = version == 0 ? 32 : 40
        guard data.count >= header else { throw WebMDeliveryError.invalidPlan }
        let earliest =
            version == 0 ? UInt64(data.readBigUInt32(at: 20)) : data.readBigUInt64(at: 20)
        let offset = version == 0 ? UInt64(data.readBigUInt32(at: 24)) : data.readBigUInt64(at: 28)
        let count = Int(HLSGenerator.readBigUInt16(data: data, at: header - 2))
        guard earliest == 0, offset == 0, (1...32_768).contains(count),
            data.count == header + count * 12,
            let segments = HLSGenerator.parseSidx(data: data), segments.count == count
        else {
            throw WebMDeliveryError.invalidPlan
        }
        self.segments = segments
        peakBitrate = try Self.validate(segments, data: data, format: format, header: header)
    }

    private static func validate(
        _ segments: [SidxSegment],
        data: Data,
        format: DashFormatInfo,
        header: Int
    ) throws -> Int {
        var remaining = format.contentLength - Int64(format.indexRangeEnd) - 1
        for (index, segment) in segments.enumerated() {
            guard data.readBigUInt32(at: header + index * 12) & 0x8000_0000 == 0,
                segment.size > 0, segment.size <= remaining,
                segment.duration.isFinite, segment.duration >= 0.001
            else {
                throw WebMDeliveryError.invalidPlan
            }
            remaining -= segment.size
        }
        return max(
            format.bitrate,
            segments.map {
                Int(ceil(Double($0.size) * 8 / $0.duration))
            }
            .max() ?? 0
        )
    }
}
