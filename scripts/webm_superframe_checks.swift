// Checked-in, locally encoded alt-ref clip with independent FFmpeg packet/frame hashes.
func demuxFixture(_ name: String) throws -> (WebMInitialization, [WebMPacket]) {
    let data = try Data(contentsOf: fixtureRoot.appendingPathComponent(name))
    let initialization = try WebMInitialization.parse(data)
    var root = try EBMLReader(data)
    _ = try root.element()
    let segment = try root.header()
    var children = try EBMLReader(data, range: segment.payloadStart..<data.count)
    var packets: [WebMPacket] = []
    while !children.isAtEnd {
        let start = children.position
        let element = try children.element()
        if element.id == 0x1F43_B675 {
            packets += try WebMCluster.parse(data.subdata(in: start..<children.position), initialization: initialization)
        }
    }
    return (initialization, packets)
}
let (altrefInit, altrefPackets) = try demuxFixture("vp9-altref.webm")
let altrefGolden = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureRoot.appendingPathComponent("vp9-altref-packets.json"))) as! [String: Any]
let altrefExpected = altrefGolden["packets"] as! [[String: Any]]
check(altrefPackets.count == 180 && altrefPackets.count == altrefExpected.count, "Alt-ref fixture has 180 displayed packets")
for (packet, expected) in zip(altrefPackets, altrefExpected) {
    let digest = "SHA256:" + SHA256.hash(data: packet.data).map { String(format: "%02x", $0) }.joined()
    check(digest == expected["data_hash"] as! String, "Alt-ref packet matches ffprobe hash")
    check(abs(Double(packet.timestampNanoseconds) / 1e9 - Double(expected["pts_time"] as! String)!) < 0.000_001, "Alt-ref PTS matches ffprobe")
    check(packet.isKeyframe == (expected["flags"] as! String).contains("K"), "Alt-ref sync flag matches ffprobe")
}
let altrefFrames = try altrefPackets.flatMap { try WebMVP9Superframe.split($0.data) }
let frameGolden = try String(contentsOf: fixtureRoot.appendingPathComponent("vp9-altref-frames.sha256"), encoding: .utf8)
    .split(separator: "\n").filter { !$0.hasPrefix("#") }.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
check(altrefFrames.count == 192 && frameGolden.count == 192, "Twelve hidden reference frames must survive")
for (frame, expected) in zip(altrefFrames, frameGolden) {
    check(frame.count == Int(expected[4]), "VP9 index sizes match FFmpeg's splitter")
    check(SHA256.hash(data: frame).map { String(format: "%02x", $0) }.joined() == expected[5], "Every elementary VP9 frame matches FFmpeg's independent splitter")
}
let altrefUnits = try WebMVP9AccessUnits(track: altrefInit.video, packets: altrefPackets)
check(altrefUnits.packets == altrefPackets, "Already indexed access units pass through byte-exactly")
var separatedAltref: [WebMPacket] = []
var hiddenCount = 0
for packet in altrefPackets {
    for frame in try WebMVP9Superframe.split(packet.data) {
        let header = try WebMVP9Header.parse(frame)
        hiddenCount += header.isVisible ? 0 : 1
        separatedAltref.append(WebMPacket(data: frame, timestampNanoseconds: packet.timestampNanoseconds,
            durationNanoseconds: header.isVisible ? packet.durationNanoseconds : 0,
            isKeyframe: header.isKeyframe, isInvisible: !header.isVisible))
    }
}
check(hiddenCount == 12, "Real fixture actually exercises invisible references")
let regroupedAltref = try WebMVP9AccessUnits(track: altrefInit.video, packets: separatedAltref)
check(regroupedAltref.packets == altrefUnits.packets, "Separately stored hidden frames regroup to identical MP4 access units")
check(try WebMVP9Superframe.split((Data([0, 0]) + altrefPackets[1].data).dropFirst(2)).count == 2, "Indexed Data slices use count-relative offsets")
for width in 1...4 {
    let marker = UInt8(0xC0 | ((width - 1) << 3) | 1)
    let indexed = Data([0x88, 0x89, marker]) + Data([1] + Array(repeating: UInt8(0), count: width - 1))
        + Data([1] + Array(repeating: UInt8(0), count: width - 1)) + Data([marker])
    check(try WebMVP9Superframe.split(indexed) == [Data([0x88]), Data([0x89])], "All four index-width encodings work")
    rejects("An identified index may not leave unaccounted payload") { _ = try WebMVP9Superframe.split(Data([0]) + indexed) }
}
for indexed in [Data([0x88, 0xC0, 0, 0xC0]), Data([0x88, 0xC0, 2, 0xC0]),
                Data([0x88, 0xD8, 0xFF, 0xFF, 0xFF, 0xFF, 0xD8])] {
    rejects("Zero, overflowing or overrun index sizes must fail") { _ = try WebMVP9Superframe.split(indexed) }
}
check(try WebMVP9Superframe.split(Data([0x82, 0xC1])) == [Data([0x82, 0xC1])], "Marker-like trailing byte without matching leading marker is compressed data")
rejects("Nine-frame access units are not representable") { _ = try WebMVP9Superframe.join(Array(repeating: Data([0x88]), count: 9)) }
let existing = WebMPacket(data: Data([0x88]), timestampNanoseconds: 100_000_000,
                         durationNanoseconds: nil, isKeyframe: false, isInvisible: false)
check(try WebMVP9AccessUnits(track: realInit.video, packets: [realPackets[0], existing]).packets.count == 2,
      "Show-existing keeps its display timestamp and reference slot")
rejects("Show-existing cannot start a random-access batch") { _ = try WebMVP9AccessUnits(track: realInit.video, packets: [existing]) }
var emptyReferences = WebMVP9References()
rejects("Missing show-existing slot cannot be fabricated") {
    try emptyReferences.consume(WebMVP9Header.parse(existing.data), configuration: vp9Config)
}
let firstHidden = separatedAltref.firstIndex(where: \.isInvisible)!
rejects("Trailing reference must not be dropped") {
    _ = try WebMVP9AccessUnits(track: altrefInit.video, packets: Array(separatedAltref[...firstHidden]))
}
let indexedTwice = try WebMVP9Superframe.join([realPackets[0].data, realPackets[1].data])
rejects("Multiple displayed frames in one packet need separate timing") {
    let bad = WebMPacket(data: indexedTwice, timestampNanoseconds: 0, durationNanoseconds: nil, isKeyframe: true, isInvisible: false)
    _ = try WebMVP9AccessUnits(track: realInit.video, packets: [bad])
}
print("WebM superframe checks passed (\(checks) total assertions; 192 FFmpeg-verified elementary frames)")
// A hidden keyframe plus show-existing is still a random-access access unit.
var hiddenKeyBytes = realPackets[0].data
hiddenKeyBytes[hiddenKeyBytes.startIndex] &= ~UInt8(2)
let hiddenKey = WebMPacket(data: hiddenKeyBytes, timestampNanoseconds: 0, durationNanoseconds: 0, isKeyframe: true, isInvisible: true)
let showAtZero = WebMPacket(data: Data([0x88]), timestampNanoseconds: 0, durationNanoseconds: nil, isKeyframe: false, isInvisible: false)
let hiddenKeyUnits = try WebMVP9AccessUnits(track: realInit.video, packets: [hiddenKey, showAtZero])
check(hiddenKeyUnits.packets.count == 1 && hiddenKeyUnits.packets[0].isKeyframe, "Hidden-key/show-existing access unit retains sync status")
check(try WebMVP9Superframe.split(hiddenKeyUnits.packets[0].data) == [hiddenKeyBytes, Data([0x88])], "Hidden keyframe is never discarded")
let hidden = separatedAltref[firstHidden]
let nextDisplay = separatedAltref[firstHidden + 1]
func changedHidden(time: Int64? = nil, duration: UInt64? = 0) -> WebMPacket {
    WebMPacket(data: hidden.data, timestampNanoseconds: time ?? hidden.timestampNanoseconds,
               durationNanoseconds: duration, isKeyframe: false, isInvisible: true)
}
rejects("Hidden frame timestamp must not cross its following display") {
    let prefix = Array(separatedAltref[..<firstHidden])
    _ = try WebMVP9AccessUnits(track: altrefInit.video, packets: prefix + [changedHidden(time: nextDisplay.timestampNanoseconds + 1), nextDisplay])
}
rejects("Hidden duration is zero, not display time") {
    _ = try WebMVP9AccessUnits(track: altrefInit.video, packets: [altrefPackets[0], changedHidden(duration: 1), nextDisplay])
}
rejects("Pending reference count is bounded by VP9's eight-frame limit") {
    _ = try WebMVP9AccessUnits(track: altrefInit.video, packets: [altrefPackets[0]] + Array(repeating: hidden, count: 8) + [nextDisplay])
}
rejects("A display preceding hidden data in a single packet cannot supply two timings") {
    let bytes = try WebMVP9Superframe.join([altrefPackets[0].data, hidden.data])
    let packet = WebMPacket(data: bytes, timestampNanoseconds: 0, durationNanoseconds: nil, isKeyframe: true, isInvisible: false)
    _ = try WebMVP9AccessUnits(track: altrefInit.video, packets: [packet])
}
for length in 0..<9 {
    rejects("Truncated keyframe metadata is bounded") { _ = try WebMVP9Header.parse(Data(realPackets[0].data.prefix(length))) }
}
// Build only uncompressed syntax for malformed-header checks. Pixel validity is
// intentionally left to the native decoder; these exercise size/reference fields.
func vp9Bits(_ fields: [(Int, Int)]) -> Data {
    var bits: [UInt8] = []
    for (value, width) in fields {
        for shift in (0..<width).reversed() { bits.append(UInt8((value >> shift) & 1)) }
    }
    while bits.count % 8 != 0 { bits.append(0) }
    return stride(from: 0, to: bits.count, by: 8).reduce(into: Data()) { data, offset in
        data.append(bits[offset..<(offset + 8)].reduce(0) { ($0 << 1) | $1 })
    }
}
let resizedInter = vp9Bits([(0x86, 8), (0, 2), (1, 8), (0, 12), (0, 3), (63, 16), (31, 16), (0, 1)])
rejects("Interframe size changes cannot escape the fixed format description") {
    let delta = WebMPacket(data: resizedInter, timestampNanoseconds: 100_000_000, durationNanoseconds: nil, isKeyframe: false, isInvisible: false)
    _ = try WebMVP9AccessUnits(track: realInit.video, packets: [realPackets[0], delta])
}
let intraOnly = vp9Bits([(0x84, 8), (1, 1), (0, 2), (0x498342, 24), (1, 8), (31, 16), (31, 16), (0, 1)])
let intraHeader = try WebMVP9Header.parse(intraOnly)
check(!intraHeader.isVisible && intraHeader.references.isEmpty && intraHeader.refreshMask == 1,
      "Profile-0 intra-only frames parse implicit SDR colour, dimensions and refresh mask")
var intraRefs = WebMVP9References()
try intraRefs.consume(intraHeader, configuration: vp9Config)
let slotOne = try WebMVP9Header.parse(Data([0x89]))
rejects("Unrefreshed show-existing slot remains unavailable") { try intraRefs.consume(slotOne, configuration: vp9Config) }
let slotZero = try WebMVP9Header.parse(Data([0x88]))
try intraRefs.consume(slotZero, configuration: vp9Config)
print("WebM reference edge checks passed (\(checks) total assertions)")
