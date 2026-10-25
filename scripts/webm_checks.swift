import CryptoKit

private var checks = 0
func check(_ condition: Bool, _ message: String) {
    checks += 1
    precondition(condition, message)
}
func rejects(_ message: String, _ body: () throws -> Void) {
    checks += 1
    do { try body(); preconditionFailure(message) } catch is WebMError {} catch { preconditionFailure("Unexpected error: \(error)") }
}
func uint(_ value: UInt64) -> Data {
    var bytes = withUnsafeBytes(of: value.bigEndian) { Data($0) }
    while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
    return bytes
}
func vint(_ value: UInt64) -> Data {
    for width in 1...8 where value < (UInt64(1) << (7 * width)) - 1 {
        let encoded = value | (UInt64(1) << (7 * width))
        return withUnsafeBytes(of: encoded.bigEndian) { Data($0.suffix(width)) }
    }
    preconditionFailure("fixture size too large")
}
func element(_ id: UInt64, _ payload: Data) -> Data { uint(id) + vint(UInt64(payload.count)) + payload }
func number(_ id: UInt64, _ value: UInt64) -> Data { element(id, uint(value)) }
func text(_ id: UInt64, _ value: String) -> Data { element(id, Data(value.utf8)) }
func initialization(docType: String = "webm", trackExtras: Data = Data(), videoExtras: Data = Data(),
                    info: Data = Data(), unknownSize: Bool = false, trackNumber: UInt64 = 1) -> Data {
    let ebml = element(0x1A45_DFA3, text(0x4282, docType))
    let track = number(0xD7, trackNumber) + number(0x83, 1) + text(0x86, "V_VP9")
        + element(0xE0, number(0xB0, 32) + number(0xBA, 32) + videoExtras) + trackExtras
    let body = element(0x1549_A966, info) + element(0x1654_AE6B, element(0xAE, track))
    return ebml + (unknownSize ? uint(0x1853_8067) + Data([0xFF]) + body : element(0x1853_8067, body))
}
func simpleBlock(track: UInt64 = 1, relative: Int16 = 0, flags: UInt8 = 0x80,
                 payload: Data = Data([0x82, 0x49, 0x83])) -> Data {
    vint(track) + withUnsafeBytes(of: relative.bigEndian) { Data($0) } + Data([flags]) + payload
}
func cluster(time: UInt64 = 0, blocks: Data) -> Data {
    element(0x1F43_B675, number(0xE7, time) + blocks)
}
func cuePoint(time: UInt64, position: UInt64, track: UInt64 = 1) -> Data {
    element(0xBB, number(0xB3, time) + element(0xB7, number(0xF7, track) + number(0xF1, position)))
}

let initBytes = initialization(unknownSize: true)
let config = try WebMInitialization.parse(initBytes)
check(config.video.width == 32 && config.video.height == 32, "VP9 dimensions must survive")
check(config.timecodeScale == 1_000_000, "Default timestamp scale is one millisecond")
check(try WebMInitialization.parse(initialization()).video == config.video, "Known-sized Segment must work")
let sliced = (Data([0xFF, 0xEE]) + initBytes).dropFirst(2)
check(try WebMInitialization.parse(sliced) == config, "Data slices must not assume a zero startIndex")
rejects("Matroska must not be admitted as WebM") { _ = try WebMInitialization.parse(initialization(docType: "matroska")) }
rejects("Track encodings must not be silently ignored") { _ = try WebMInitialization.parse(initialization(trackExtras: element(0x6D80, Data()))) }
rejects("Track timestamp scaling must not be silently ignored") {
    _ = try WebMInitialization.parse(initialization(trackExtras: element(0x0023_314F, Data([0x40, 0, 0, 0]))))
}
rejects("Zero timestamp scale must not be admitted") {
    _ = try WebMInitialization.parse(initialization(info: number(0x002A_D7B1, 0)))
}
let colour = element(0x55B0, number(0x55B1, 9) + number(0x55B2, 10) + number(0x55BA, 16) + number(0x55BB, 9))
let colourConfig = try WebMInitialization.parse(initialization(videoExtras: colour))
check(colourConfig.video.colour[0x55BA] == 16 && colourConfig.video.colour[0x55B2] == 10,
      "HDR colour and bit-depth fields must be retained, not assumed SDR")
rejects("Unimplemented mastering metadata must not be discarded") {
    _ = try WebMInitialization.parse(initialization(videoExtras: element(0x55B0, element(0x55D0, Data()))))
}
rejects("Malformed variable integer must be rejected") { var r = try EBMLReader(Data([0])); _ = try r.header() }
rejects("Oversized EBML ID must be rejected") { var r = try EBMLReader(Data([0x08, 0, 0, 0, 1, 0x80])); _ = try r.header() }
rejects("Unknown-sized child must be rejected") { var r = try EBMLReader(Data([0xEC, 0xFF])); _ = try r.element() }
rejects("Truncated element must be rejected") { var r = try EBMLReader(Data([0xEC, 0x82, 0])); _ = try r.element() }
rejects("Timestamp overflow must throw") { _ = try WebMTime.nanoseconds(UInt64.max, scale: 1_000_000) }

let packetBytes = Data([0x82, 0x49, 0x83])
let single = cluster(time: 10, blocks: element(0xA3, simpleBlock(relative: -2)))
let packets = try WebMCluster.parse(single, initialization: config)
check(packets.count == 1 && packets[0].timestampNanoseconds == 8_000_000, "Signed block offsets must be applied before scaling")
check(packets[0].data == packetBytes && packets[0].isKeyframe, "Compressed packet bytes and sync flag must survive")
check(try WebMCluster.parse((Data([0xFF]) + single).dropFirst(), initialization: config) == packets,
      "Cluster parsing must handle Data slices with a nonzero startIndex")
let multiTrack = try WebMInitialization.parse(initialization(trackNumber: 256))
check(try WebMCluster.parse(cluster(blocks: element(0xA3, simpleBlock(track: 256))), initialization: multiTrack).count == 1,
      "Multi-byte track number VINT must work")
let invisible = try WebMCluster.parse(cluster(blocks: element(0xA3, simpleBlock(flags: 0x08))), initialization: config)[0]
check(invisible.isInvisible && invisible.durationNanoseconds == 0 && !invisible.isKeyframe, "Invisible alternate-reference packets must be retained")
let group = element(0xA0, element(0xA1, simpleBlock(flags: 0)) + number(0x9B, 40))
let grouped = try WebMCluster.parse(cluster(blocks: group), initialization: config)[0]
check(grouped.isKeyframe && grouped.durationNanoseconds == 40_000_000, "BlockGroup sync and duration differ from SimpleBlock")
let defaultDuration = try WebMInitialization.parse(initialization(trackExtras: number(0x0023_E383, 100_000_000)))
check(try WebMCluster.parse(single, initialization: defaultDuration)[0].durationNanoseconds == 100_000_000,
      "DefaultDuration uses nanoseconds directly, not timestamp ticks")
let referenced = element(0xA0, element(0xA1, simpleBlock()) + element(0xFB, Data([0xFF])))
check(try !WebMCluster.parse(cluster(blocks: referenced), initialization: config)[0].isKeyframe,
      "A referenced BlockGroup is not a keyframe even if its reserved flag bit is set")
let audioFirst = element(0xA3, simpleBlock(track: 2, flags: 0x06)) + element(0xA3, simpleBlock())
check(try WebMCluster.parse(cluster(blocks: audioFirst), initialization: config).count == 1, "Other tracks must not become VP9 packets")
let otherGroup = element(0xA0, element(0xA1, simpleBlock(track: 2)) + element(0x75A1, Data()))
check(try WebMCluster.parse(cluster(blocks: otherGroup), initialization: config).isEmpty,
      "Unsupported features of ignored tracks must not poison video demuxing")
rejects("Selected video BlockAdditions must not be silently discarded") {
    _ = try WebMCluster.parse(cluster(blocks: element(0xA0, element(0xA1, simpleBlock()) + element(0x75A1, Data()))), initialization: config)
}
let unknownCluster = uint(0x1F43_B675) + Data([0xFF]) + number(0xE7, 10) + element(0xA3, simpleBlock(relative: -2))
check(try WebMCluster.parse(unknownCluster, initialization: config) == packets,
      "Unknown-sized Cluster is allowed when the caller supplies its complete range")
for flags: UInt8 in [0x02, 0x04, 0x06] {
    rejects("Unsupported lacing must throw instead of corrupting packets") {
        _ = try WebMCluster.parse(cluster(blocks: element(0xA3, simpleBlock(flags: flags))), initialization: config)
    }
}
rejects("Negative absolute timestamps must throw") {
    _ = try WebMCluster.parse(cluster(blocks: element(0xA3, simpleBlock(relative: -1))), initialization: config)
}
rejects("Missing Cluster timecode must throw") { _ = try WebMCluster.parse(element(0x1F43_B675, element(0xA3, simpleBlock())), initialization: config) }
rejects("Empty selected packet must throw") { _ = try WebMCluster.parse(cluster(blocks: element(0xA3, simpleBlock(payload: Data()))), initialization: config) }

let cues = element(0x1C53_BB6B, cuePoint(time: 0, position: 100) + cuePoint(time: 10, position: 200))
let parsedCues = try WebMCue.parse(cues, initialization: config, contentLength: 1_000)
check(parsedCues.map(\.clusterOffset) == [config.segmentDataOffset + 100, config.segmentDataOffset + 200],
      "Cue positions are relative to the Segment payload, not to the index buffer")
check(parsedCues[1].timeNanoseconds == 10_000_000, "Cue timestamps use TimecodeScale")
check(try WebMCue.parse((Data([0xFF]) + cues).dropFirst(), initialization: config, contentLength: 1_000) == parsedCues,
      "Cue parsing must handle nonzero Data startIndex")
rejects("Out-of-file cues must throw") { _ = try WebMCue.parse(cues, initialization: config, contentLength: 100) }
rejects("Unsorted cues must throw") {
    _ = try WebMCue.parse(element(0x1C53_BB6B, cuePoint(time: 10, position: 200) + cuePoint(time: 0, position: 100)), initialization: config, contentLength: 1_000)
}
check(try WebMCue.parse(element(0x1C53_BB6B, cuePoint(time: 0, position: 100, track: 2)), initialization: config,
                       contentLength: 1_000).isEmpty, "Cue track selection must match video track")

// Compare a real, locally generated WebM fixture with independent ffprobe output.
let fixtureRoot = URL(fileURLWithPath: CommandLine.arguments[1])
let realData = try Data(contentsOf: fixtureRoot.appendingPathComponent("vp9-sdr.webm"))
let realInit = try WebMInitialization.parse(realData)
var root = try EBMLReader(realData)
_ = try root.element()
let segment = try root.header()
var children = try EBMLReader(realData, range: segment.payloadStart..<realData.count)
var realPackets: [WebMPacket] = []
var clusterOffsets: [Int64] = []
var realCues: [WebMCue] = []
while !children.isAtEnd {
    let start = children.position
    let child = try children.element()
    let bytes = realData.subdata(in: start..<children.position)
    if child.id == 0x1F43_B675 {
        clusterOffsets.append(Int64(start))
        realPackets += try WebMCluster.parse(bytes, initialization: realInit)
    } else if child.id == 0x1C53_BB6B {
        realCues = try WebMCue.parse(bytes, initialization: realInit, contentLength: Int64(realData.count))
    }
}
let golden = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureRoot.appendingPathComponent("vp9-sdr-packets.json"))) as! [String: Any]
let expected = golden["packets"] as! [[String: Any]]
check(realPackets.count == expected.count && realPackets.count == 30, "Real fixture packet count must match ffprobe")
check(realCues.map(\.clusterOffset) == clusterOffsets, "Real cues must point at actual Cluster headers")
for (packet, expected) in zip(realPackets, expected) {
    let digest = "SHA256:" + SHA256.hash(data: packet.data).map { String(format: "%02x", $0) }.joined()
    check(digest == expected["data_hash"] as! String, "Real VP9 packet payload must match ffprobe byte-for-byte")
    let pts = Double(expected["pts_time"] as! String)!
    check(abs(Double(packet.timestampNanoseconds) / 1e9 - pts) < 0.000_001, "Real VP9 PTS must match ffprobe")
    check(packet.isKeyframe == (expected["flags"] as! String).contains("K"), "Real keyframe flags must match ffprobe")
}
// Every truncated prefix must either be a valid smaller init range or throw,
// never trap or read beyond its bounds.
for length in 0..<initBytes.count {
    _ = try? WebMInitialization.parse(Data(initBytes.prefix(length)))
}
for length in 0..<single.count {
    rejects("Every truncated finite Cluster must throw") { _ = try WebMCluster.parse(Data(single.prefix(length)), initialization: config) }
}
for length in 0..<cues.count {
    rejects("Every truncated Cues element must throw") { _ = try WebMCue.parse(Data(cues.prefix(length)), initialization: config, contentLength: 1_000) }
}
// Deterministic malformed-data smoke corpus. Mutations may remain valid, but
// all parser entry points must stay bounded and must never trap.
for offset in stride(from: 0, to: realData.count, by: 17) {
    var mutated = realData
    mutated[offset] ^= 0xFF
    _ = try? WebMInitialization.parse(mutated)
    _ = try? WebMCue.parse(mutated, initialization: config, contentLength: Int64(mutated.count))
    _ = try? WebMCluster.parse(mutated, initialization: config)
}
print("WebM checks passed (\(checks) assertions; \(realPackets.count) ffprobe-verified packets)")
