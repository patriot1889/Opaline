import CoreMedia
import Foundation

enum WebMRemuxError: Error {
    case coreMedia(OSStatus)
    case capacity
    case writer(String)
    case cancelled
    case timeout
}

/// Finite, bounded batch. Each packet must be one visible profile-0 frame.
/// No decoding, reordering, inferred reference frames or timestamp rebasing.
struct WebMVP9Samples {
    let format: CMVideoFormatDescription
    let buffers: [CMSampleBuffer]

    init(track: WebMVideoTrack, packets: [WebMPacket]) throws {
        guard !packets.isEmpty, packets.count <= 4_096,
              packets.reduce(0, { $0 + min($1.data.count, 16_777_217) }) <= 16_777_216 else {
            throw WebMRemuxError.capacity
        }
        let configuration = try WebMVP9Configuration.parse(track: track, keyframe: packets[0])
        let format = try Self.format(configuration)
        self.format = format
        buffers = try packets.indices.map { index in
            try Self.validate(packets[index], track: track, configuration: configuration)
            let duration = try Self.duration(at: index, packets: packets, track: track)
            return try Self.sample(packets[index], duration: duration, format: format)
        }
    }

    private static func validate(
        _ packet: WebMPacket,
        track: WebMVideoTrack,
        configuration: WebMVP9Configuration
    ) throws {
        let header = try WebMVP9Header.parse(packet.data)
        guard packet.timestampNanoseconds >= 0, !packet.isInvisible,
              packet.isKeyframe == header.isKeyframe else {
            throw WebMError.unsupported("VP9 packet flags or timestamp")
        }
        if header.isKeyframe,
           try WebMVP9Configuration.parse(track: track, keyframe: packet) != configuration {
            throw WebMError.unsupported("VP9 configuration change")
        }
    }

    private static func duration(
        at index: Int, packets: [WebMPacket], track: WebMVideoTrack
    ) throws -> Int64 {
        let packet = packets[index]
        let next = index + 1 < packets.count ? packets[index + 1].timestampNanoseconds : nil
        let delta = next.map { $0.subtractingReportingOverflow(packet.timestampNanoseconds) }
        guard delta.map({ !$0.overflow && $0.partialValue > 0 }) ?? true else {
            throw WebMError.invalidTimestamp
        }
        let duration = packet.durationNanoseconds ?? delta.map { UInt64($0.partialValue) }
            ?? track.defaultDurationNanoseconds ?? 0
        guard duration > 0, duration <= UInt64(Int64.max),
              duration <= UInt64(Int64.max - packet.timestampNanoseconds),
              delta.map({ duration <= UInt64($0.partialValue) }) ?? true else {
            throw WebMError.invalidTimestamp
        }
        return Int64(duration)
    }

    private static func format(
        _ configuration: WebMVP9Configuration
    ) throws -> CMVideoFormatDescription {
        let extensions = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: [
                "vpcC": configuration.record
            ]
        ]
        var description: CMVideoFormatDescription?
        try checked(CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_VP9,
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        ))
        guard let description else { throw WebMError.invalidElement }
        return description
    }

    private static func sample(
        _ packet: WebMPacket,
        duration: Int64,
        format: CMVideoFormatDescription
    ) throws -> CMSampleBuffer {
        let block = try block(packet.data)
        let time = CMTime(value: packet.timestampNanoseconds, timescale: 1_000_000_000)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: duration, timescale: 1_000_000_000),
            presentationTimeStamp: time,
            decodeTimeStamp: time
        )
        var size = packet.data.count
        var sample: CMSampleBuffer?
        try checked(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        ))
        guard let sample else { throw WebMError.invalidElement }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample,
            createIfNecessary: true
        ) as? [NSMutableDictionary], let flags = attachments.first else {
            throw WebMError.invalidElement
        }
        flags[kCMSampleAttachmentKey_NotSync] = !packet.isKeyframe
        return sample
    }

    private static func block(_ data: Data) throws -> CMBlockBuffer {
        var buffer: CMBlockBuffer?
        try checked(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &buffer
        ))
        guard let buffer else { throw WebMError.invalidElement }
        try data.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { throw WebMError.truncated }
            try checked(CMBlockBufferReplaceDataBytes(
                with: address,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            ))
        }
        return buffer
    }

    private static func checked(_ status: OSStatus) throws {
        guard status == noErr else { throw WebMRemuxError.coreMedia(status) }
    }
}
