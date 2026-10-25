import Foundation

/// The subset of the uncompressed header needed before passthrough. This does
/// not decode pixels. Alternate reference frames/superframes need a later adapter.
struct WebMVP9Header {
    private struct Bits {
        let data: [UInt8]
        var position = 0

        mutating func read(_ count: Int) throws -> Int {
            guard count <= data.count * 8 - position else { throw WebMError.truncated }
            var result = 0
            for _ in 0..<count {
                result = (result << 1) | Int((data[position / 8] >> (7 - position % 8)) & 1)
                position += 1
            }
            return result
        }
    }

    let isKeyframe: Bool
    let width: Int?
    let height: Int?
    let colourSpace: Int?
    let fullRange: Bool

    static func parse(_ data: Data) throws -> WebMVP9Header {
        guard !data.isEmpty else { throw WebMError.truncated }
        try rejectSuperframe(data)
        var bits = Bits(data: Array(data.prefix(16)))
        guard try bits.read(2) == 2 else { throw WebMError.invalidElement }
        let low = try bits.read(1)
        let profile = try low | (bits.read(1) << 1)
        guard profile == 0 else { throw WebMError.unsupported("VP9 profile other than 0") }
        guard try bits.read(1) == 0 else { throw WebMError.unsupported("VP9 show-existing frame") }
        let keyframe = try bits.read(1) == 0
        guard try bits.read(1) == 1 else { throw WebMError.unsupported("VP9 invisible frame") }
        _ = try bits.read(1) // error_resilient_mode
        guard keyframe else {
            return WebMVP9Header(
                isKeyframe: false, width: nil, height: nil, colourSpace: nil, fullRange: false
            )
        }
        return try keyframeHeader(&bits)
    }

    private static func keyframeHeader(_ bits: inout Bits) throws -> WebMVP9Header {
        guard try bits.read(24) == 0x49_8342 else { throw WebMError.invalidElement }
        let colourSpace = try bits.read(3)
        guard colourSpace < 5 else {
            throw WebMError.unsupported("VP9 wide gamut, reserved or RGB colour")
        }
        let fullRange = try bits.read(1) == 1
        let width = try bits.read(16) + 1
        let height = try bits.read(16) + 1
        if try bits.read(1) == 1 {
            let renderWidth = try bits.read(16) + 1
            let renderHeight = try bits.read(16) + 1
            guard renderWidth == width, renderHeight == height else {
                throw WebMError.unsupported("VP9 render dimensions")
            }
        }
        return WebMVP9Header(
            isKeyframe: true,
            width: width,
            height: height,
            colourSpace: colourSpace,
            fullRange: fullRange
        )
    }

    private static func rejectSuperframe(_ data: Data) throws {
        guard let marker = data.last, marker & 0xE0 == 0xC0 else {
            return
        }
        let frames = Int(marker & 7) + 1
        let magnitude = Int((marker >> 3) & 3) + 1
        let size = 2 + frames * magnitude
        if data.count >= size, data[data.index(data.endIndex, offsetBy: -size)] == marker {
            throw WebMError.unsupported("VP9 superframe index")
        }
    }
}
