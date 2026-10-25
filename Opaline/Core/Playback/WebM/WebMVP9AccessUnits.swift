import Foundation

/// Normalizes container packets into MP4 access units: hidden reference frames
/// followed by exactly one displayed frame, retaining elementary bytes/order.
struct WebMVP9AccessUnits {
    private struct Pending {
        var frames: [Data] = []
        var startsWithKeyframe = false
        var timestamp: Int64?

        mutating func append(_ frames: [Data], header: WebMVP9Header, time: Int64) throws {
            guard timestamp.map({ time >= $0 }) ?? true else {
                throw WebMError.invalidTimestamp
            }
            guard self.frames.count + frames.count <= 8 else {
                throw WebMError.unsupported("VP9 access unit exceeds eight frames")
            }
            if self.frames.isEmpty { startsWithKeyframe = header.isKeyframe }
            self.frames += frames
            timestamp = time
        }
    }

    let configuration: WebMVP9Configuration
    let packets: [WebMPacket]

    init(track: WebMVideoTrack, packets: [WebMPacket]) throws {
        guard !packets.isEmpty, packets.count <= 4_096,
              packets.reduce(0, { $0 + min($1.data.count, 16_777_217) }) <= 16_777_216 else {
            throw WebMError.unsupported("VP9 batch capacity")
        }
        let configuration = try WebMVP9Configuration.parse(track: track, keyframe: packets[0])
        self.configuration = configuration
        self.packets = try Self.normalize(packets, track: track, configuration: configuration)
    }

    private static func normalize(
        _ packets: [WebMPacket], track: WebMVideoTrack, configuration: WebMVP9Configuration
    ) throws -> [WebMPacket] {
        var pending = Pending()
        var references = WebMVP9References()
        var output: [WebMPacket] = []
        var outputBytes = 0
        for packet in packets {
            let frames = try WebMVP9Superframe.split(packet.data)
            let headers = try frames.map(WebMVP9Header.parse)
            try validate(packet, headers: headers, previous: output.last)
            for (frame, header) in zip(frames, headers) {
                if header.isKeyframe {
                    try validateKeyframe(frame, track: track, configuration: configuration)
                }
                try references.consume(header, configuration: configuration)
            }
            try pending.append(frames, header: headers[0], time: packet.timestampNanoseconds)
            if packet.isInvisible {
                continue
            }
            let result = try accessUnit(packet, pending: pending, originalFrames: frames.count)
            outputBytes += result.data.count
            guard outputBytes <= 16_777_216 else {
                throw WebMError.unsupported("VP9 batch capacity")
            }
            output.append(result)
            pending = Pending()
        }
        guard pending.frames.isEmpty else {
            throw WebMError.unsupported("VP9 trailing hidden reference")
        }
        return output
    }

    private static func validate(
        _ packet: WebMPacket, headers: [WebMVP9Header], previous: WebMPacket?
    ) throws {
        let shown = headers.indices.filter { headers[$0].isVisible }
        guard shown.count <= 1, shown.first.map({ $0 == headers.count - 1 }) ?? true,
              packet.isInvisible == shown.isEmpty, packet.isKeyframe == headers[0].isKeyframe,
              !headers.dropFirst().contains(where: \.isKeyframe) else {
            throw WebMError.unsupported("VP9 packet visibility, sync flags or display count")
        }
        let time = packet.timestampNanoseconds
        let duration = packet.durationNanoseconds
        let followsDisplay = previous.map {
            packet.isInvisible ? time >= $0.timestampNanoseconds : time > $0.timestampNanoseconds
        } ?? true
        guard time >= 0, followsDisplay,
              !packet.isInvisible || duration == nil || duration == 0 else {
            throw WebMError.invalidTimestamp
        }
    }

    private static func validateKeyframe(
        _ frame: Data, track: WebMVideoTrack, configuration: WebMVP9Configuration
    ) throws {
        let packet = WebMPacket(
            data: frame,
            timestampNanoseconds: 0,
            durationNanoseconds: nil,
            isKeyframe: true,
            isInvisible: false
        )
        guard try WebMVP9Configuration.parse(track: track, keyframe: packet) == configuration else {
            throw WebMError.unsupported("VP9 configuration change")
        }
    }

    private static func accessUnit(
        _ packet: WebMPacket, pending: Pending, originalFrames: Int
    ) throws -> WebMPacket {
        let bytes = pending.frames.count == originalFrames
            ? packet.data : try WebMVP9Superframe.join(pending.frames)
        return WebMPacket(
            data: bytes,
            timestampNanoseconds: packet.timestampNanoseconds,
            durationNanoseconds: packet.durationNanoseconds,
            isKeyframe: pending.startsWithKeyframe,
            isInvisible: false
        )
    }
}
