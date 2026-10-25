import Foundation

enum WebMCluster {
    enum Sync {
        case fromFlags, keyframe, delta
    }

    struct Block {
        let element: EBMLReader.Element
        let sync: Sync
        let durationTicks: UInt64?
        var hasUnsupportedFeatures = false
    }

    /// Takes exactly one Cluster, bounded by its declared size or by the
    /// caller's cue-derived byte range for an unknown-sized Cluster. Returns
    /// compressed VP9 packets; no decoder, transport or UI is involved.
    static func parse(_ data: Data, initialization: WebMInitialization) throws -> [WebMPacket] {
        var reader = try clusterReader(data)
        let (timecode, blocks) = try contents(data, reader: &reader)
        return try blocks.compactMap {
            try packet(data, block: $0, timecode: timecode, initialization: initialization)
        }
    }

    private static func clusterReader(_ data: Data) throws -> EBMLReader {
        var root = try EBMLReader(data)
        let header = try root.header()
        guard header.id == 0x1F43_B675 else { throw WebMError.invalidElement }
        let available = root.end - header.payloadStart
        if let size = header.size, size != UInt64(available) {
            throw size > UInt64(available) ? WebMError.truncated : WebMError.invalidElement
        }
        return try EBMLReader(data, range: header.payloadStart..<data.count)
    }

    private static func contents(
        _ data: Data, reader: inout EBMLReader
    ) throws -> (Int64, [Block]) {
        var timecode: UInt64?
        var blocks: [Block] = []
        while !reader.isAtEnd {
            let element = try reader.element()
            switch element.id {
            case 0xE7:
                guard timecode == nil else { throw WebMError.invalidElement }
                timecode = try reader.unsigned(element)
            case 0xA3:
                blocks.append(Block(element: element, sync: .fromFlags, durationTicks: nil))
            case 0xA0:
                blocks.append(try blockGroup(data, range: element.payload))
            case 0x1F43_B675:
                throw WebMError.invalidElement
            default:
                break
            }
        }
        guard let timecode, timecode <= UInt64(Int64.max) else {
            throw WebMError.invalidTimestamp
        }
        return (Int64(timecode), blocks)
    }

    private static func blockGroup(_ data: Data, range: Range<Int>) throws -> Block {
        var reader = try EBMLReader(data, range: range)
        var block: EBMLReader.Element?
        var duration: UInt64?
        var reference = false
        var unsupported = false
        while !reader.isAtEnd {
            let element = try reader.element()
            switch element.id {
            case 0xA1:
                guard block == nil else { throw WebMError.invalidElement }
                block = element
            case 0x9B:
                duration = try reader.unsigned(element)
            case 0xFB:
                reference = true
            case 0xA4, 0x75A1:
                unsupported = true
            default:
                break
            }
        }
        guard let block else { throw WebMError.invalidElement }
        return Block(
            element: block,
            sync: reference ? .delta : .keyframe,
            durationTicks: duration,
            hasUnsupportedFeatures: unsupported
        )
    }

    private static func packet(
        _ data: Data, block: Block, timecode: Int64, initialization: WebMInitialization
    ) throws -> WebMPacket? {
        var reader = try EBMLReader(data, range: block.element.payload)
        let track = try reader.trackNumber()
        // Other tracks must not be interpreted as VP9, including audio lacing.
        guard track == initialization.video.number else {
            return nil
        }
        guard !block.hasUnsupportedFeatures else {
            throw WebMError.unsupported("codec state or block additions")
        }
        let high = UInt16(try reader.byte())
        let low = UInt16(try reader.byte())
        let relativeTime = Int64(Int16(bitPattern: high << 8 | low))
        let flags = try reader.byte()
        guard flags & 0x06 == 0 else { throw WebMError.unsupported("video block lacing") }
        guard !reader.isAtEnd else { throw WebMError.invalidElement }
        let (ticks, overflow) = timecode.addingReportingOverflow(relativeTime)
        guard !overflow, ticks >= 0 else { throw WebMError.invalidTimestamp }
        let timestamp = try WebMTime.nanoseconds(UInt64(ticks), scale: initialization.timecodeScale)
        let invisible = flags & 0x08 != 0
        let duration = try block.durationTicks.map {
            UInt64(try WebMTime.nanoseconds($0, scale: initialization.timecodeScale))
        }
        let bytes = EBMLReader.Element(id: block.element.id, payload: reader.position..<reader.end)
        return WebMPacket(
            data: reader.bytes(bytes),
            timestampNanoseconds: timestamp,
            durationNanoseconds: invisible ? 0 : duration,
            isKeyframe: block.sync == .fromFlags ? flags & 0x80 != 0 : block.sync == .keyframe,
            isInvisible: invisible
        )
    }
}
