import Foundation

/// HLS codec discovery cannot use VP9's undefined level 00 on the tested Apple
/// player. Prefer an actual container/format level; otherwise estimate from
/// declared dimensions, frame rate and bitrate, as MP4 muxers do. This estimate
/// is not a complete bitstream-level conformance or hardware-resolution test.
/// Limits: https://www.webmproject.org/vp9/levels/
enum WebMVP9Level {
    private struct Limit: Sendable {
        let level: Int
        let sampleRate: Double
        let pictureSize: Double
        let breadth: Double
        let bitrate: Double
    }

    private static let limits: [Limit] = [
        Limit(level: 10, sampleRate: 829_440, pictureSize: 36_864, breadth: 512, bitrate: 200_000),
        Limit(
            level: 11,
            sampleRate: 2_764_800,
            pictureSize: 73_728,
            breadth: 768,
            bitrate: 800_000
        ),
        Limit(
            level: 20,
            sampleRate: 4_608_000,
            pictureSize: 122_880,
            breadth: 960,
            bitrate: 1_800_000
        ),
        Limit(
            level: 21,
            sampleRate: 9_216_000,
            pictureSize: 245_760,
            breadth: 1_344,
            bitrate: 3_600_000
        ),
        Limit(
            level: 30,
            sampleRate: 20_736_000,
            pictureSize: 552_960,
            breadth: 2_048,
            bitrate: 7_200_000
        ),
        Limit(
            level: 31,
            sampleRate: 36_864_000,
            pictureSize: 983_040,
            breadth: 2_752,
            bitrate: 12_000_000
        ),
        Limit(
            level: 40,
            sampleRate: 83_558_400,
            pictureSize: 2_228_224,
            breadth: 4_160,
            bitrate: 18_000_000
        ),
        Limit(
            level: 41,
            sampleRate: 160_432_128,
            pictureSize: 2_228_224,
            breadth: 4_160,
            bitrate: 30_000_000
        ),
        Limit(
            level: 50,
            sampleRate: 311_951_360,
            pictureSize: 8_912_896,
            breadth: 8_384,
            bitrate: 60_000_000
        ),
        Limit(
            level: 51,
            sampleRate: 588_251_136,
            pictureSize: 8_912_896,
            breadth: 8_384,
            bitrate: 120_000_000
        ),
        Limit(
            level: 52,
            sampleRate: 1_176_502_272,
            pictureSize: 8_912_896,
            breadth: 8_384,
            bitrate: 180_000_000
        ),
        Limit(
            level: 60,
            sampleRate: 1_176_502_272,
            pictureSize: 35_651_584,
            breadth: 16_832,
            bitrate: 180_000_000
        ),
        Limit(
            level: 61,
            sampleRate: 2_353_004_544,
            pictureSize: 35_651_584,
            breadth: 16_832,
            bitrate: 240_000_000
        ),
        Limit(
            level: 62,
            sampleRate: 4_706_009_088,
            pictureSize: 35_651_584,
            breadth: 16_832,
            bitrate: 480_000_000
        )
    ]

    static func codec(format: DashFormatInfo, configuration: WebMVP9Configuration?) -> String? {
        guard let normalized = WebMVP9Formats.hlsCodec(format.codecs) else {
            return nil
        }
        let fields = normalized.split(separator: ".")
        let containerLevel = configuration.map { Int($0.record[5]) } ?? 0
        let declaredLevel = Int(fields[2]) ?? 0
        let declared = containerLevel > 0 ? containerLevel : declaredLevel
        let level = declared > 0 ? declared : estimate(format)
        guard let level, level > 0 else {
            return nil
        }
        return String(format: "vp09.00.%02d.08", level)
    }

    private static func estimate(_ format: DashFormatInfo) -> Int? {
        guard let width = format.width, let height = format.height, let fps = format.fps,
            width > 0, height > 0, fps > 0, format.bitrate > 0
        else { return nil }
        let pixels = Double(width) * Double(height)
        let samples = pixels * Double(fps)
        return limits.first {
            samples <= $0.sampleRate && pixels <= $0.pictureSize
                && Double(max(width, height)) <= $0.breadth && Double(format.bitrate) <= $0.bitrate
        }?
        .level
    }
}
