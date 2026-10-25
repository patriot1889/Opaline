import Foundation

/// VP9's optional trailing index. Offsets remain count-relative for Data slices.
/// Only a matching pair of markers identifies an index; a marker-like final
/// compressed byte alone is legal. An identified index must cover every byte.
enum WebMVP9Superframe {
    static func split(_ data: Data) throws -> [Data] {
        guard !data.isEmpty else { throw WebMError.truncated }
        guard let marker = data.last, marker & 0xE0 == 0xC0 else {
            return [data]
        }
        let count = Int(marker & 7) + 1
        let width = Int((marker >> 3) & 3) + 1
        let indexSize = 2 + count * width
        guard data.count >= indexSize else {
            return [data]
        }
        let index = data.count - indexSize
        guard byte(data, at: index) == marker else {
            return [data]
        }
        var position = 0
        var frames: [Data] = []
        for frame in 0..<count {
            var size: UInt64 = 0
            for offset in 0..<width {
                size |= UInt64(byte(data, at: index + 1 + frame * width + offset)) << (8 * offset)
            }
            guard size > 0, size <= UInt64(index - position) else { throw WebMError.invalidElement }
            let end = position + Int(size)
            let startIndex = data.index(data.startIndex, offsetBy: position)
            let endIndex = data.index(data.startIndex, offsetBy: end)
            frames.append(Data(data[startIndex..<endIndex]))
            position = end
        }
        guard position == index else { throw WebMError.invalidElement }
        return frames
    }

    static func join(_ frames: [Data]) throws -> Data {
        guard !frames.isEmpty, frames.count <= 8, frames.allSatisfy({ !$0.isEmpty }),
              frames.reduce(0, { $0 + min($1.count, 16_777_217) }) <= 16_777_216 else {
            throw WebMError.unsupported("VP9 superframe capacity")
        }
        guard frames.count > 1 else {
            return frames[0]
        }
        let maximum = frames.map(\.count).max() ?? 0
        let width = maximum <= 0xFF ? 1 : maximum <= 0xFFFF ? 2 : 3
        let marker = UInt8(0xC0 | ((width - 1) << 3) | (frames.count - 1))
        var data = frames.reduce(into: Data()) { $0.append($1) }
        data.append(marker)
        for frame in frames {
            for offset in 0..<width {
                data.append(UInt8(truncatingIfNeeded: frame.count >> (8 * offset)))
            }
        }
        data.append(marker)
        return data
    }

    private static func byte(_ data: Data, at offset: Int) -> UInt8 {
        data[data.index(data.startIndex, offsetBy: offset)]
    }
}
