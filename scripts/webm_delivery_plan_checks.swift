func deliveryRejects(_ message: String, _ body: () throws -> Void) {
    checks += 1
    do { try body(); preconditionFailure(message) } catch is WebMDeliveryError {} catch { preconditionFailure("Unexpected error: \(error)") }
}
let deliveryData = try Data(contentsOf: fixtureRoot.appendingPathComponent("vp9-altref.webm"))
var deliveryRoot = try EBMLReader(deliveryData)
_ = try deliveryRoot.element()
let deliverySegmentHeader = try deliveryRoot.header()
var deliveryChildren = try EBMLReader(deliveryData, range: deliverySegmentHeader.payloadStart..<deliveryData.count)
var deliveryCues: [WebMCue] = []
var deliveryIndexRange: WebMByteRange?
while !deliveryChildren.isAtEnd {
    let start = deliveryChildren.position
    let element = try deliveryChildren.element()
    if element.id == 0x1C53_BB6B {
        deliveryIndexRange = try WebMByteRange(start: Int64(start), end: Int64(deliveryChildren.position - 1))
        deliveryCues = try WebMCue.parse(deliveryData.subdata(in: start..<deliveryChildren.position), initialization: altrefInit, contentLength: Int64(deliveryData.count))
    }
}
let deliveryIndex = try WebMClusterIndex(cues: deliveryCues, contentLength: Int64(deliveryData.count))
let deliveryStream = WebMRangeFetcher.OpenedStream(initialization: altrefInit, index: deliveryIndex)
let deliveryPlan = try WebMVP9DeliveryPlan(index: deliveryIndex, durationNanoseconds: 6_000_000_000)
check(deliveryPlan.segments.count == 3, "Three independently remuxable cue intervals")
check(deliveryPlan.segments.map(\.durationNanoseconds) == [2_000_000_000, 2_000_000_000, 2_000_000_000], "Cue intervals cover exactly six seconds without nominal frame-duration drift")
let deliveryPlaylist = try deliveryPlan.playlist(basePath: "/fixture/video")
check(deliveryPlaylist.components(separatedBy: "#EXT-X-MAP:").count == 4, "Each independent cue remux has its own initialization map")
check(deliveryPlaylist.contains("#EXT-X-TARGETDURATION:2\n") && deliveryPlaylist.contains("#EXTINF:2.000000000,\n/fixture/video/2/media"), "Playlist durations come from exact cue boundaries")
for base in ["relative", "/bad\npath", "/bad\"path", "/bad/../path", "/bad//path", "/bad/", "/bad?query"] {
    deliveryRejects("Unsafe playlist paths are rejected") { _ = try deliveryPlan.playlist(basePath: base) }
}
for end: Int64 in [0, -1, 3_999_999_999, 4_000_000_000] {
    deliveryRejects("Missing, nonpositive or too-short VOD end time") { _ = try WebMVP9DeliveryPlan(index: deliveryIndex, durationNanoseconds: end) }
}
let nonzeroIndex = try WebMClusterIndex(cues: Array(deliveryCues.dropFirst()), contentLength: Int64(deliveryData.count))
deliveryRejects("VOD/audio timeline must start at zero") { _ = try WebMVP9DeliveryPlan(index: nonzeroIndex, durationNanoseconds: 6_000_000_000) }
let ambiguousCues = deliveryCues.enumerated().map { index, cue in WebMCue(timeNanoseconds: index == 1 ? 0 : cue.timeNanoseconds, clusterOffset: cue.clusterOffset, relativeBlockOffset: nil) }
let ambiguousIndex = try WebMClusterIndex(cues: ambiguousCues, contentLength: Int64(deliveryData.count))
deliveryRejects("Distinct cue clusters cannot share a display time") { _ = try WebMVP9DeliveryPlan(index: ambiguousIndex, durationNanoseconds: 6_000_000_000) }
print("WebM delivery plan checks passed (\(checks) total assertions)")
