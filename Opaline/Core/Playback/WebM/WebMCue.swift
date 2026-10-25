import Foundation

extension WebMCue {
    /// Takes a complete Cues element (e.g. YouTube's indexRange). Offsets are
    /// checked and converted to absolute file positions, not MP4/SIDX offsets.
    static func parse(
        _ data: Data, initialization: WebMInitialization, contentLength: Int64
    ) throws -> [WebMCue] {
        var root = try EBMLReader(data)
        let cues = try root.element()
        guard cues.id == 0x1C53_BB6B, root.isAtEnd, contentLength > 0 else {
            throw WebMError.invalidElement
        }
        var reader = try EBMLReader(data, range: cues.payload)
        var result: [WebMCue] = []
        while !reader.isAtEnd {
            let element = try reader.element()
            guard element.id == 0xBB else { continue }
            let parsed = try point(data, range: element.payload, initialization: initialization)
            guard let cue = parsed else {
                continue
            }
            guard cue.clusterOffset >= initialization.segmentDataOffset,
                  cue.clusterOffset < contentLength else {
                throw WebMError.invalidElement
            }
            if let previous = result.last,
               cue.timeNanoseconds < previous.timeNanoseconds
                || cue.clusterOffset < previous.clusterOffset {
                throw WebMError.invalidElement
            }
            result.append(cue)
        }
        return result
    }

    private static func point(
        _ data: Data, range: Range<Int>, initialization: WebMInitialization
    ) throws -> WebMCue? {
        var reader = try EBMLReader(data, range: range)
        var time: UInt64?
        var position: [UInt64: UInt64]?
        while !reader.isAtEnd {
            let element = try reader.element()
            switch element.id {
            case 0xB3:
                time = try reader.unsigned(element)
            case 0xB7:
                let candidate = try trackPosition(data, range: element.payload)
                if candidate[0xF7] == initialization.video.number {
                    guard position == nil else { throw WebMError.invalidElement }
                    position = candidate
                }
            default:
                break
            }
        }
        return try cue(time: time, position: position, initialization: initialization)
    }

    private static func cue(
        time: UInt64?, position: [UInt64: UInt64]?, initialization: WebMInitialization
    ) throws -> WebMCue? {
        guard let position else {
            return nil
        }
        guard let time, let offset = position[0xF1], offset <= UInt64(Int64.max) else {
            throw WebMError.invalidElement
        }
        let (absolute, overflow) = initialization.segmentDataOffset
            .addingReportingOverflow(Int64(offset))
        guard !overflow else { throw WebMError.invalidElement }
        return WebMCue(
            timeNanoseconds: try WebMTime.nanoseconds(time, scale: initialization.timecodeScale),
            clusterOffset: absolute,
            relativeBlockOffset: position[0xF0]
        )
    }

    private static func trackPosition(_ data: Data, range: Range<Int>) throws -> [UInt64: UInt64] {
        var reader = try EBMLReader(data, range: range)
        var values: [UInt64: UInt64] = [:]
        while !reader.isAtEnd {
            let element = try reader.element()
            values[element.id] = try reader.unsigned(element)
        }
        return values
    }
}
