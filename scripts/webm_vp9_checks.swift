// Configuration tests shared by the Foundation-only and Apple harnesses.
func vp9Track(privateBytes: Data = Data(), colour: [UInt64: UInt64] = [:], width: Int = 32,
              duration: UInt64? = 100_000_000) -> WebMVideoTrack {
    WebMVideoTrack(number: 1, width: width, height: 32, defaultDurationNanoseconds: duration,
                   codecPrivate: privateBytes, colour: colour)
}
let vp9Config = try WebMVP9Configuration.parse(track: realInit.video, keyframe: realPackets[0])
check(vp9Config.record == Data([1, 0, 0, 0, 0, 0, 0x82, 2, 2, 2, 0, 0]), "Unspecified colour and level remain unspecified")
let privateFeatures = Data([1, 1, 0, 2, 1, 10, 3, 1, 8, 4, 1, 1])
let explicitVP9 = try WebMVP9Configuration.parse(track: vp9Track(privateBytes: privateFeatures), keyframe: realPackets[0])
check(explicitVP9.record[5] == 10, "CodecPrivate level must survive vpcC conversion")
let slicedKeyframe = WebMPacket(data: (Data([0]) + realPackets[0].data).dropFirst(), timestampNanoseconds: 0,
                              durationNanoseconds: nil, isKeyframe: true, isInvisible: false)
check(try WebMVP9Configuration.parse(track: realInit.video, keyframe: slicedKeyframe) == vp9Config,
      "VP9 bit reader supports nonzero Data startIndex")
for bytes in [Data([1]), Data([1, 2, 0]), Data([1, 1, 0, 1, 1, 0]), Data([0x81, 1, 0]),
              Data([1, 1, 2]), Data([3, 1, 10]), Data([4, 1, 3]), Data([2, 1, 99])] {
    rejects("Malformed or unsupported CodecPrivate must fail") {
        _ = try WebMVP9Configuration.parse(track: vp9Track(privateBytes: bytes), keyframe: realPackets[0])
    }
}
rejects("Container dimensions must agree with keyframe") {
    _ = try WebMVP9Configuration.parse(track: vp9Track(width: 64), keyframe: realPackets[0])
}
for colour in [[UInt64(0x55BA): UInt64(16)], [0x55BA: 18], [0x55B2: 10], [0x55BB: 9],
               [0x55B9: 2], [0x55B3: 1]] {
    rejects("HDR, conflicting range and unimplemented colour fields must fail") {
        _ = try WebMVP9Configuration.parse(track: vp9Track(colour: colour), keyframe: realPackets[0])
    }
}
for id: UInt64 in [0x54B0, 0x54BA, 0x54B2, 0x54AA, 0x53B8, 0x53C0] {
    rejects("Presentation changes must not be silently discarded") {
        _ = try WebMInitialization.parse(initialization(videoExtras: number(id, 1)))
    }
}
check(try WebMInitialization.parse(initialization(videoExtras: number(0x54B0, 32) + number(0x54BA, 32))) == config,
      "Explicit matching display geometry remains compatible")

rejects("Duplicate colour scalars must not overwrite HDR signalling") {
    let duplicate = element(0x55B0, number(0x55BA, 16) + number(0x55BA, 2))
    _ = try WebMInitialization.parse(initialization(videoExtras: duplicate))
}
print("WebM VP9 configuration checks passed (\(checks) total assertions)")
