import Foundation

/// SDR profile-0 configuration, independently checked against a real keyframe.
struct WebMVP9Configuration: Equatable, Sendable {
    private struct Colour {
        let primaries: UInt8
        let transfer: UInt8
        let matrix: UInt8
        let range: UInt8
    }

    let width: Int
    let height: Int
    let record: Data

    static func parse(track: WebMVideoTrack, keyframe: WebMPacket) throws -> WebMVP9Configuration {
        let header = try WebMVP9Header.parse(keyframe.data)
        guard keyframe.isKeyframe, !keyframe.isInvisible, header.isKeyframe,
              header.width == track.width, header.height == track.height else {
            throw WebMError.unsupported("VP9 keyframe or dimensions disagree with WebM")
        }
        let features = try features(track.codecPrivate)
        guard features[1, default: 0] == 0, features[3, default: 8] == 8,
              features[4, default: 1] <= 1 else {
            throw WebMError.unsupported("VP9 profile, bit depth or chroma")
        }
        let level = features[2, default: 0]
        guard [0, 10, 11, 20, 21, 30, 31, 40, 41, 50, 51, 52, 60, 61, 62].contains(level) else {
            throw WebMError.unsupported("VP9 level")
        }
        let colour = try colourRecord(track.colour, header: header)
        let packed = UInt8(8 << 4) | (features[4, default: 1] << 1) | colour.range
        // vpcC is a FullBox, version 1. VP9 has no initialization payload.
        let record = Data([
            1, 0, 0, 0, 0, level, packed, colour.primaries, colour.transfer, colour.matrix, 0, 0
        ])
        return WebMVP9Configuration(width: track.width, height: track.height, record: record)
    }

    private static func features(_ data: Data) throws -> [UInt8: UInt8] {
        let bytes = Array(data)
        var position = 0
        var values: [UInt8: UInt8] = [:]
        var seen = Set<UInt8>()
        while position < bytes.count {
            guard bytes.count - position >= 2 else { throw WebMError.truncated }
            let key = bytes[position]
            let count = Int(bytes[position + 1])
            position += 2
            guard key & 0x80 == 0, seen.insert(key).inserted, count <= bytes.count - position else {
                throw WebMError.invalidElement
            }
            if (1...4).contains(key) {
                guard count == 1 else { throw WebMError.invalidElement }
                values[key] = bytes[position]
            }
            position += count
        }
        return values
    }

    private static func colourRecord(
        _ values: [UInt64: UInt64], header: WebMVP9Header
    ) throws -> Colour {
        guard let colourSpace = header.colourSpace else { throw WebMError.invalidElement }
        let matrix = UInt64([2, 6, 1, 6, 7][colourSpace])
        let range: UInt64 = header.fullRange ? 2 : 1
        guard values[0x55B2, default: 8] == 8,
              [0, range].contains(values[0x55B9, default: 0]),
              matrix == 2 || [2, matrix].contains(values[0x55B1, default: 2]) else {
            throw WebMError.unsupported("VP9 colour metadata disagrees with bitstream")
        }
        // Unknown scalar fields may describe chroma siting, subsampling or HDR.
        guard Set(values.keys).isSubset(of: [0x55B1, 0x55B2, 0x55B9, 0x55BA, 0x55BB]),
              [1, 2, 4, 5, 6, 7].contains(values[0x55BB, default: 2]),
              [1, 2, 4, 5, 6, 7, 8, 13].contains(values[0x55BA, default: 2]),
              [1, 2, 5, 6, 7].contains(values[0x55B1, default: matrix]) else {
            throw WebMError.unsupported("VP9 non-SDR or unimplemented colour metadata")
        }
        let signalledMatrix = values[0x55B1, default: matrix]
        return Colour(
            primaries: UInt8(values[0x55BB, default: 2]),
            transfer: UInt8(values[0x55BA, default: 2]),
            matrix: UInt8(signalledMatrix == 2 ? matrix : signalledMatrix),
            range: UInt8(range - 1)
        )
    }
}
