import Foundation

/// Uncompressed profile-0 syntax through reference selection and render size.
/// Compressed headers and pixels remain the decoder's responsibility.
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
    let isVisible: Bool
    let existingFrameIndex: Int?
    let refreshMask: Int
    let references: [Int]
    let sizeReference: Int?
    let width: Int?
    let height: Int?
    let colourSpace: Int?
    let fullRange: Bool

    /// Accepts one elementary frame, after removing any superframe index.
    static func parse(_ data: Data) throws -> WebMVP9Header {
        var bits = Bits(data: Array(data.prefix(32)))
        guard try bits.read(2) == 2 else { throw WebMError.invalidElement }
        let low = try bits.read(1)
        let profile = try low | (bits.read(1) << 1)
        guard profile == 0 else { throw WebMError.unsupported("VP9 profile other than 0") }
        if try bits.read(1) == 1 {
            let index = try bits.read(3)
            guard data.count == 1 else { throw WebMError.invalidElement }
            return WebMVP9Header(
                isKeyframe: false,
                isVisible: true,
                existingFrameIndex: index,
                refreshMask: 0,
                references: [index],
                sizeReference: index,
                width: nil,
                height: nil,
                colourSpace: nil,
                fullRange: false
            )
        }
        let keyframe = try bits.read(1) == 0
        let visible = try bits.read(1) == 1
        let resilient = try bits.read(1) == 1
        if keyframe {
            return try keyframeHeader(&bits, visible: visible)
        }
        return try interHeader(&bits, visible: visible, resilient: resilient)
    }

    private static func keyframeHeader(_ bits: inout Bits, visible: Bool) throws -> WebMVP9Header {
        guard try bits.read(24) == 0x49_8342 else { throw WebMError.invalidElement }
        let colourSpace = try bits.read(3)
        guard colourSpace < 5 else {
            throw WebMError.unsupported("VP9 wide gamut, reserved or RGB colour")
        }
        let fullRange = try bits.read(1) == 1
        let dimensions = try dimensions(&bits)
        try renderSize(&bits, dimensions: dimensions)
        return WebMVP9Header(
            isKeyframe: true,
            isVisible: visible,
            existingFrameIndex: nil,
            refreshMask: 255,
            references: [],
            sizeReference: nil,
            width: dimensions.0,
            height: dimensions.1,
            colourSpace: colourSpace,
            fullRange: fullRange
        )
    }

    private static func interHeader(
        _ bits: inout Bits, visible: Bool, resilient: Bool
    ) throws -> WebMVP9Header {
        let intraOnly = try !visible && bits.read(1) == 1
        if !resilient { _ = try bits.read(2) } // reset_frame_context
        if intraOnly {
            return try intraHeader(&bits)
        }
        let refreshMask = try bits.read(8)
        var references: [Int] = []
        for _ in 0..<3 {
            references.append(try bits.read(3))
            _ = try bits.read(1) // ref_frame_sign_bias
        }
        var sizeReference: Int?
        for reference in references where sizeReference == nil {
            if try bits.read(1) == 1 { sizeReference = reference }
        }
        let dimensions = try sizeReference == nil ? dimensions(&bits) : nil
        try renderSize(&bits, dimensions: dimensions)
        return WebMVP9Header(
            isKeyframe: false,
            isVisible: visible,
            existingFrameIndex: nil,
            refreshMask: refreshMask,
            references: references,
            sizeReference: sizeReference,
            width: dimensions?.0,
            height: dimensions?.1,
            colourSpace: nil,
            fullRange: false
        )
    }

    private static func intraHeader(_ bits: inout Bits) throws -> WebMVP9Header {
        guard try bits.read(24) == 0x49_8342 else { throw WebMError.invalidElement }
        let refreshMask = try bits.read(8)
        let dimensions = try dimensions(&bits)
        try renderSize(&bits, dimensions: dimensions)
        // Profile-0 intra-only syntax implies 8-bit studio-range BT.601.
        return WebMVP9Header(
            isKeyframe: false,
            isVisible: false,
            existingFrameIndex: nil,
            refreshMask: refreshMask,
            references: [],
            sizeReference: nil,
            width: dimensions.0,
            height: dimensions.1,
            colourSpace: 1,
            fullRange: false
        )
    }

    private static func dimensions(_ bits: inout Bits) throws -> (Int, Int) {
        let width = try bits.read(16) + 1
        let height = try bits.read(16) + 1
        return (width, height)
    }

    private static func renderSize(_ bits: inout Bits, dimensions: (Int, Int)?) throws {
        if try bits.read(1) == 1 {
            let render = try self.dimensions(&bits)
            guard let dimensions, render == dimensions else {
                throw WebMError.unsupported("VP9 render dimensions")
            }
        }
    }
}
