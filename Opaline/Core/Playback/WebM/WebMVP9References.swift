import Foundation

/// Only availability and fixed dimensions are tracked here. The decoder owns
/// pixels, entropy contexts and compressed-header validation.
struct WebMVP9References {
    private var populated = Array(repeating: false, count: 8)

    mutating func consume(_ header: WebMVP9Header, configuration: WebMVP9Configuration) throws {
        guard header.references.allSatisfy({ populated[$0] }) else {
            throw WebMError.unsupported("VP9 reference before keyframe")
        }
        if let width = header.width, let height = header.height {
            guard width == configuration.width, height == configuration.height else {
                throw WebMError.unsupported("VP9 resolution change")
            }
        }
        if !header.isKeyframe, let colourSpace = header.colourSpace {
            let matrix = UInt8([2, 6, 1, 6, 7][colourSpace])
            guard [2, matrix].contains(configuration.record[9]),
                  (configuration.record[6] & 1 != 0) == header.fullRange else {
                throw WebMError.unsupported("VP9 intra-only colour change")
            }
        }
        for index in 0..<8 where header.refreshMask & (1 << index) != 0 {
            populated[index] = true
        }
    }
}
