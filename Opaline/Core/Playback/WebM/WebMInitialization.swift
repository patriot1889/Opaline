import Foundation

extension WebMInitialization {
    private struct SegmentMetadata {
        var scale: UInt64 = 1_000_000
        var duration: Double?
        var video: WebMVideoTrack?
        var hasInfo = false
        var hasTracks = false
    }

    private struct VideoMetadata {
        let width: Int
        let height: Int
        let colour: [UInt64: UInt64]
    }

    /// Parses a file prefix containing EBML, Segment, Info and Tracks. The
    /// Segment may be unknown-sized or larger than the available init range.
    static func parse(_ data: Data) throws -> WebMInitialization {
        var reader = try segmentReader(data)
        let segmentOffset = reader.position
        let metadata = try metadata(data, reader: &reader)
        guard metadata.hasInfo, let video = metadata.video,
              metadata.scale > 0, metadata.scale <= UInt64(Int64.max) else {
            throw WebMError.unsupported("missing VP9 video track, Info or invalid timecode scale")
        }
        let seconds = metadata.duration.map { $0 * Double(metadata.scale) / 1_000_000_000 }
        guard seconds.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw WebMError.invalidTimestamp
        }
        return WebMInitialization(
            segmentDataOffset: Int64(segmentOffset),
            timecodeScale: metadata.scale,
            durationSeconds: seconds,
            video: video
        )
    }

    private static func segmentReader(_ data: Data) throws -> EBMLReader {
        var root = try EBMLReader(data)
        let ebml = try root.element()
        guard ebml.id == 0x1A45_DFA3 else {
            throw WebMError.invalidElement
        }
        try validateDocType(data, range: ebml.payload)
        let segment = try root.header()
        guard segment.id == 0x1853_8067 else {
            throw WebMError.invalidElement
        }
        let available = root.end - segment.payloadStart
        let length = Int(min(segment.size ?? UInt64(available), UInt64(available)))
        let range = segment.payloadStart..<(segment.payloadStart + length)
        return try EBMLReader(data, range: range)
    }

    private static func metadata(_ data: Data, reader: inout EBMLReader) throws -> SegmentMetadata {
        var metadata = SegmentMetadata()
        while !reader.isAtEnd {
            let header = try reader.header()
            if header.id == 0x1F43_B675 { break }
            let element = try reader.element(after: header)
            switch element.id {
            case 0x1549_A966:
                guard !metadata.hasInfo else { throw WebMError.invalidElement }
                (metadata.scale, metadata.duration) = try info(data, range: element.payload)
                metadata.hasInfo = true
            case 0x1654_AE6B:
                guard !metadata.hasTracks else { throw WebMError.invalidElement }
                metadata.video = try videoTrack(data, range: element.payload)
                metadata.hasTracks = true
            default:
                break
            }
        }
        return metadata
    }

    private static func validateDocType(_ data: Data, range: Range<Int>) throws {
        var reader = try EBMLReader(data, range: range)
        var docType: String?
        while !reader.isAtEnd {
            let element = try reader.element()
            if element.id == 0x4282 { docType = try reader.string(element) }
        }
        guard docType == "webm" else {
            throw WebMError.unsupported("DocType must be webm")
        }
    }

    private static func info(_ data: Data, range: Range<Int>) throws -> (UInt64, Double?) {
        var reader = try EBMLReader(data, range: range)
        var scale: UInt64 = 1_000_000
        var duration: Double?
        while !reader.isAtEnd {
            let element = try reader.element()
            switch element.id {
            case 0x002A_D7B1:
                scale = try reader.unsigned(element)
            case 0x4489:
                duration = try reader.floatingPoint(element)
            default:
                break
            }
        }
        return (scale, duration)
    }

    private static func videoTrack(_ data: Data, range: Range<Int>) throws -> WebMVideoTrack? {
        var reader = try EBMLReader(data, range: range)
        var video: WebMVideoTrack?
        var numbers = Set<UInt64>()
        while !reader.isAtEnd {
            let element = try reader.element()
            guard element.id == 0xAE else { continue }
            if let candidate = try track(data, range: element.payload, numbers: &numbers) {
                guard video == nil else {
                    throw WebMError.unsupported("multiple VP9 video tracks")
                }
                video = candidate
            }
        }
        return video
    }

    private static func track(
        _ data: Data, range: Range<Int>, numbers: inout Set<UInt64>
    ) throws -> WebMVideoTrack? {
        let reader = try EBMLReader(data, range: range)
        let fields = try trackFields(reader)
        guard let number = fields[0xD7] else { throw WebMError.invalidElement }
        let trackNumber = try reader.unsigned(number)
        guard trackNumber > 0, numbers.insert(trackNumber).inserted else {
            throw WebMError.invalidElement
        }
        guard let type = fields[0x83], try reader.unsigned(type) == 1,
              let codec = fields[0x86], try reader.string(codec) == "V_VP9" else {
            return nil
        }
        try validateTrack(reader, fields: fields)
        guard let video = fields[0xE0] else {
            throw WebMError.invalidElement
        }
        let dimensions = try videoMetadata(data, range: video.payload)
        let duration = try fields[0x0023_E383].map { try reader.unsigned($0) }
        guard duration.map({ $0 > 0 && $0 <= UInt64(Int64.max) }) ?? true else {
            throw WebMError.invalidElement
        }
        return WebMVideoTrack(
            number: trackNumber,
            width: dimensions.width,
            height: dimensions.height,
            defaultDurationNanoseconds: duration,
            codecPrivate: fields[0x63A2].map(reader.bytes) ?? Data(),
            colour: dimensions.colour
        )
    }

    private static func trackFields(_ source: EBMLReader) throws -> [UInt64: EBMLReader.Element] {
        var reader = source
        var fields: [UInt64: EBMLReader.Element] = [:]
        while !reader.isAtEnd {
            let element = try reader.element()
            guard fields.updateValue(element, forKey: element.id) == nil else {
                throw WebMError.invalidElement
            }
        }
        return fields
    }

    private static func validateTrack(
        _ reader: EBMLReader, fields: [UInt64: EBMLReader.Element]
    ) throws {
        guard fields[0x6D80] == nil, fields[0x537F] == nil, fields[0x56AA] == nil else {
            throw WebMError.unsupported("encoded track, track offset or codec delay")
        }
        if let scale = fields[0x0023_314F], try reader.floatingPoint(scale) != 1 {
            throw WebMError.unsupported("track timestamp scale")
        }
    }

    private static func videoMetadata(
        _ data: Data, range: Range<Int>
    ) throws -> VideoMetadata {
        var reader = try EBMLReader(data, range: range)
        var width: UInt64 = 0
        var height: UInt64 = 0
        var colour: [UInt64: UInt64] = [:]
        var presentation: [UInt64: UInt64] = [:]
        while !reader.isAtEnd {
            let element = try reader.element()
            switch element.id {
            case 0xB0:
                width = try reader.unsigned(element)
            case 0xBA:
                height = try reader.unsigned(element)
            case 0x55B0:
                colour = try colourValues(data, range: element.payload)
            case 0x54B0, 0x54BA, 0x54B2, 0x54B3, 0x54AA, 0x54BB, 0x54CC, 0x54DD, 0x53B8, 0x53C0:
                presentation[element.id] = try reader.unsigned(element)
            default:
                break
            }
        }
        guard width > 0, height > 0, width <= UInt64(Int32.max), height <= UInt64(Int32.max) else {
            throw WebMError.invalidElement
        }
        try validatePresentation(presentation, width: width, height: height)
        return VideoMetadata(width: Int(width), height: Int(height), colour: colour)
    }

    private static func validatePresentation(
        _ values: [UInt64: UInt64], width: UInt64, height: UInt64
    ) throws {
        let otherValues = values.filter { $0.key != 0x54B0 && $0.key != 0x54BA }.values
        guard values[0x54B0, default: width] == width, values[0x54BA, default: height] == height,
              otherValues.allSatisfy({ $0 == 0 }) else {
            throw WebMError.unsupported("video crop, display geometry, stereo or alpha")
        }
    }

    private static func colourValues(_ data: Data, range: Range<Int>) throws -> [UInt64: UInt64] {
        var reader = try EBMLReader(data, range: range)
        var values: [UInt64: UInt64] = [:]
        while !reader.isAtEnd {
            let element = try reader.element()
            // MasteringMetadata is nested, not an unsigned scalar. Reject it
            // until it can be preserved by the future format adapter.
            guard element.id != 0x55D0 else {
                throw WebMError.unsupported("HDR mastering metadata")
            }
            guard values.updateValue(try reader.unsigned(element), forKey: element.id) == nil else {
                throw WebMError.invalidElement
            }
        }
        return values
    }
}
