// In-process transport can pause replies to make cancellation/generation tests deterministic.
final class DeliveryTransport: HTTPTransport, @unchecked Sendable {
    private struct Pending {
        let request: HTTPRequest
        let token: CancellationToken?
        let completion: (Result<HTTPResponse, Error>) -> Void
    }
    private let lock = NSLock()
    private let data: Data
    private let automatic: Bool
    private var pending: [Int: Pending] = [:]
    private var requests: [HTTPRequest] = []
    let requested = DispatchSemaphore(value: 0)
    init(data: Data = deliveryData, automatic: Bool = true) { self.data = data; self.automatic = automatic }
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    func isCancelled(_ index: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return pending[index]?.token?.isCancelled == true }
    func send(_ request: HTTPRequest, cancellationToken: CancellationToken?, completion: @escaping (Result<HTTPResponse, Error>) -> Void) {
        lock.lock()
        let index = requests.count
        requests.append(request)
        pending[index] = Pending(request: request, token: cancellationToken, completion: completion)
        lock.unlock()
        requested.signal()
        if automatic { release(index) }
    }
    func release(_ index: Int) {
        lock.lock(); let item = pending.removeValue(forKey: index); lock.unlock()
        guard let item else { return }
        let range = item.request.headers[HTTPHeader.range]!.dropFirst(6).split(separator: "-").map { Int($0)! }
        item.completion(.success(HTTPResponse(status: 206,
            headers: ["Content-Range": "bytes \(range[0])-\(range[1])/\(data.count)", "Content-Length": "\(range[1] - range[0] + 1)"],
            data: data.subdata(in: range[0]..<(range[1] + 1)))))
    }
}
final class DeliveryBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var count = 0
    let ready = DispatchSemaphore(value: 0)
    func complete(_ result: Result<T, Error>) { lock.lock(); count += 1; self.result = result; lock.unlock(); ready.signal() }
    func get() throws -> T { lock.lock(); defer { lock.unlock() }; precondition(count == 1); return try result!.get() }
    func wait() throws -> T { precondition(ready.wait(timeout: .now() + 10) == .success); return try get() }
}
func awaitDelivery<T: Sendable>(_ start: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void) throws -> T {
    let box = DeliveryBox<T>(); start { box.complete($0) }; return try box.wait()
}
func expectDeliveryError<T>(_ error: WebMDeliveryError, _ body: () throws -> T) {
    checks += 1
    do { _ = try body(); preconditionFailure("Expected \(error)") } catch let actual as WebMDeliveryError { precondition(actual == error) } catch { preconditionFailure("Unexpected error: \(error)") }
}
func deliveryOwner(_ transport: DeliveryTransport, limits: WebMVP9Delivery.Limits = .init(), stream: WebMRangeFetcher.OpenedStream = deliveryStream) throws -> WebMVP9Delivery {
    let fetcher = try WebMRangeFetcher(transport: transport, url: URL(string: "https://fixture.invalid/video.webm")!, contentLength: Int64(deliveryData.count))
    return try WebMVP9Delivery(fetcher: fetcher, stream: stream, durationNanoseconds: 6_000_000_000, limits: limits)
}
let deliveryTransport = DeliveryTransport()
let owner = try deliveryOwner(deliveryTransport)
let playlistResource: WebMVP9Delivery.Resource = try awaitDelivery { owner.resource(forPath: owner.playlistPath, completion: $0) }
check(playlistResource.contentType == "application/vnd.apple.mpegurl" && deliveryTransport.count == 0, "Serving metadata does not fetch video")
var delivered: [WebMVP9DeliverySegment] = []
for index in 0..<3 {
    let segment: WebMVP9DeliverySegment = try awaitDelivery { owner.loadSegment(at: index, completion: $0) }
    check(segment.startNanoseconds == Int64(index) * 2_000_000_000 && segment.endNanoseconds == Int64(index + 1) * 2_000_000_000, "Each ranged remux covers its exact source interval")
    let initResource: WebMVP9Delivery.Resource = try awaitDelivery { owner.resource(forPath: owner.basePath + "/\(index)/init", completion: $0) }
    let mediaResource: WebMVP9Delivery.Resource = try awaitDelivery { owner.resource(forPath: owner.basePath + "/\(index)/media", completion: $0) }
    check(initResource.data == segment.initialization && mediaResource.data == segment.media && mediaResource.contentType == "video/mp4", "Init/media routes reuse the same cached remux")
    delivered.append(segment)
}
check(deliveryTransport.count == 3, "Sequential cue resources need only one request each")
let lastFile = file.deletingLastPathComponent().appendingPathComponent("delivered-last.mp4")
try (delivered[2].initialization + delivered[2].media).write(to: lastFile)
let deliveredTfdt = boxPayload(delivered[2].media, path: ["moof", "traf", "tfdt"])
check(deliveredTfdt.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } == 4_000_000_000, "A seek-selected cue's decode time stays absolute")
let bounded = try WebMVP9Samples(track: altrefInit.video, packets: Array(altrefPackets[0..<60]), endTimeNanoseconds: 2_000_000_000)
check(CMSampleBufferGetDuration(bounded.buffers.last!) == CMTime(value: 33_000_000, timescale: 1_000_000_000), "Last quantized frame uses next cue rather than nominal duration")
remuxRejects("End boundary may not precede final display") { _ = try WebMVP9Samples(track: altrefInit.video, packets: altrefPackets, endTimeNanoseconds: 5_966_000_000) }
let explicitEndConflict = WebMPacket(data: realPackets[0].data, timestampNanoseconds: 0, durationNanoseconds: 100_000_000, isKeyframe: true, isInvisible: false)
remuxRejects("Explicit duration cannot be silently stretched to a cue") { _ = try WebMVP9Samples(track: realInit.video, packets: [explicitEndConflict], endTimeNanoseconds: 200_000_000) }
for suffix in ["/00/init", "/-1/media", "/3/media", "/0/unknown", "/0/media/extra", "/0//init"] {
    expectDeliveryError(.notFound) { let _: WebMVP9Delivery.Resource = try awaitDelivery { owner.resource(forPath: owner.basePath + suffix, completion: $0) } }
}
check(deliveryTransport.count == 3, "Invalid routes do not start transport work")
// Budget eviction is deterministic: cache only one cue.
var oneCache = WebMVP9Delivery.Limits(); oneCache.cacheEntries = 1
let evictionTransport = DeliveryTransport(); let evictionOwner = try deliveryOwner(evictionTransport, limits: oneCache)
for index in [0, 1, 0] { let _: WebMVP9DeliverySegment = try awaitDelivery { evictionOwner.loadSegment(at: index, completion: $0) } }
check(evictionTransport.count == 3, "Evicted cue is fetched again rather than retained outside budget")
evictionOwner.close()
// Pause one request, enqueue coalesced and later requests, then release in order.
let pausedTransport = DeliveryTransport(automatic: false); let pausedOwner = try deliveryOwner(pausedTransport)
let firstBox = DeliveryBox<WebMVP9DeliverySegment>(); let duplicateBox = DeliveryBox<WebMVP9DeliverySegment>(); let laterBox = DeliveryBox<WebMVP9DeliverySegment>()
pausedOwner.loadSegment(at: 0) { firstBox.complete($0) }
check(pausedTransport.requested.wait(timeout: .now() + 2) == .success, "First range starts")
pausedOwner.loadSegment(at: 0) { duplicateBox.complete($0) }; pausedOwner.loadSegment(at: 1) { laterBox.complete($0) }
let _: WebMVP9Delivery.Resource = try awaitDelivery { pausedOwner.resource(forPath: pausedOwner.playlistPath, completion: $0) }
check(pausedTransport.count == 1, "One active range; duplicate requests coalesce")
pausedTransport.release(0)
let firstValue = try firstBox.wait(); let duplicateValue = try duplicateBox.wait()
check(firstValue.media == duplicateValue.media, "Coalesced callers receive the identical remux")
check(pausedTransport.requested.wait(timeout: .now() + 2) == .success, "Next range starts only after remux completion")
pausedTransport.release(1); _ = try laterBox.wait(); pausedOwner.close()
// Reset before an old response arrives; a new seek must not receive old media.
let staleTransport = DeliveryTransport(automatic: false); let staleOwner = try deliveryOwner(staleTransport)
let cancelledBox0 = DeliveryBox<WebMVP9DeliverySegment>(); let cancelledBox1 = DeliveryBox<WebMVP9DeliverySegment>(); let seekBox2 = DeliveryBox<WebMVP9DeliverySegment>()
staleOwner.loadSegment(at: 0) { cancelledBox0.complete($0) }
check(staleTransport.requested.wait(timeout: .now() + 2) == .success, "Cancellable range started")
staleOwner.loadSegment(at: 1) { cancelledBox1.complete($0) }; staleOwner.cancelPendingRequests()
expectDeliveryError(.cancelled) { try cancelledBox0.wait() }; expectDeliveryError(.cancelled) { try cancelledBox1.wait() }
check(staleTransport.isCancelled(0), "Reset cancels transport token")
staleOwner.loadSegment(at: 2) { seekBox2.complete($0) }
check(staleTransport.requested.wait(timeout: .now() + 2) == .success, "Seek generation can restart immediately")
staleTransport.release(0); staleTransport.release(1)
check(try seekBox2.wait().startNanoseconds == 4_000_000_000, "Late old response cannot replace the new cue")
check(cancelledBox0.ready.wait(timeout: .now() + 0.05) == .timedOut, "Cancelled request completes exactly once")
staleOwner.close()
// Capacity and deadline failures release all owner state.
var narrow = WebMVP9Delivery.Limits(); narrow.maximumRequests = 1
let capacityTransport = DeliveryTransport(automatic: false); let capacityOwner = try deliveryOwner(capacityTransport, limits: narrow)
let capacityBox = DeliveryBox<WebMVP9DeliverySegment>(); capacityOwner.loadSegment(at: 0) { capacityBox.complete($0) }
check(capacityTransport.requested.wait(timeout: .now() + 2) == .success, "Capacity check holds one active request")
expectDeliveryError(.capacity) { let _: WebMVP9DeliverySegment = try awaitDelivery { capacityOwner.loadSegment(at: 1, completion: $0) } }
capacityOwner.close(); expectDeliveryError(.cancelled) { try capacityBox.wait() }
expectDeliveryError(.cancelled) { let _: WebMVP9DeliverySegment = try awaitDelivery { capacityOwner.loadSegment(at: 0, completion: $0) } }
var shortDeadline = WebMVP9Delivery.Limits(); shortDeadline.operationTimeout = 0.05
let timeoutTransport = DeliveryTransport(automatic: false); let timeoutOwner = try deliveryOwner(timeoutTransport, limits: shortDeadline)
expectDeliveryError(.timeout) { let _: WebMVP9DeliverySegment = try awaitDelivery { timeoutOwner.loadSegment(at: 0, completion: $0) } }
check(timeoutTransport.isCancelled(0), "Deadline cancels abandoned transport work")
timeoutOwner.close()
var tinyCache = WebMVP9Delivery.Limits(); tinyCache.cacheBytes = 1
let tinyOwner = try deliveryOwner(DeliveryTransport(), limits: tinyCache)
expectDeliveryError(.capacity) { let _: WebMVP9DeliverySegment = try awaitDelivery { tinyOwner.loadSegment(at: 0, completion: $0) } }; tinyOwner.close()
owner.close()
print("WebM delivery checks passed (\(checks) total assertions; exact cue timelines, cache, cancellation, coalescing, deadline)")
// Reject cue timestamp lies before producing a fragment.
let shiftedCues = deliveryCues.enumerated().map { index, cue in WebMCue(timeNanoseconds: index == 1 ? 1_500_000_000 : cue.timeNanoseconds, clusterOffset: cue.clusterOffset, relativeBlockOffset: nil) }
let shiftedIndex = try WebMClusterIndex(cues: shiftedCues, contentLength: Int64(deliveryData.count))
let shiftedStream = WebMRangeFetcher.OpenedStream(initialization: altrefInit, index: shiftedIndex)
let shiftedOwner = try deliveryOwner(DeliveryTransport(), stream: shiftedStream)
expectDeliveryError(.invalidTimeline) { let _: WebMVP9DeliverySegment = try awaitDelivery { shiftedOwner.loadSegment(at: 1, completion: $0) } }; shiftedOwner.close()
// A later independent writer cannot quietly change the decoder configuration.
var changedColourData = deliveryData
let secondKey = deliveryData.range(of: altrefPackets[60].data)!
changedColourData[secondKey.lowerBound + 4] |= 0x40 // keyframe colour_space: unknown -> BT.709
let colourOwner = try deliveryOwner(DeliveryTransport(data: changedColourData))
let _: WebMVP9DeliverySegment = try awaitDelivery { colourOwner.loadSegment(at: 0, completion: $0) }
expectDeliveryError(.configurationChanged) { let _: WebMVP9DeliverySegment = try awaitDelivery { colourOwner.loadSegment(at: 1, completion: $0) } }; colourOwner.close()
let invalidFragments = WebMVP9Fragments(initialization: Data([0]), media: [WebMVP9Fragment(
    data: Data([1]), start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 1, timescale: 1))])
deliveryRejects("Writer reports must exactly cover the planned interval") {
    _ = try WebMVP9DeliverySegment(fragments: invalidFragments, interval: deliveryPlan.segments[0])
}
// Stable ownership identity prevents one session's URL from addressing another.
let foreignOwner = try deliveryOwner(DeliveryTransport())
expectDeliveryError(.notFound) { let _: WebMVP9Delivery.Resource = try awaitDelivery { foreignOwner.resource(forPath: owner.playlistPath, completion: $0) } }; foreignOwner.close()
print("WebM delivery validation checks passed (\(checks) total assertions)")
// The owner keeps its own input cap even if a caller configures a larger fetcher.
let hugeIndex = try WebMClusterIndex(cues: [WebMCue(timeNanoseconds: 0, clusterOffset: 0, relativeBlockOffset: nil)], contentLength: 100_000_000)
let hugeTransport = DeliveryTransport()
let hugeFetcher = try WebMRangeFetcher(transport: hugeTransport, url: URL(string: "https://fixture.invalid/huge")!, contentLength: 100_000_000, maximumRangeBytes: 100_000_000)
let hugeStream = WebMRangeFetcher.OpenedStream(initialization: altrefInit, index: hugeIndex)
let hugeOwner = try WebMVP9Delivery(fetcher: hugeFetcher, stream: hugeStream, durationNanoseconds: 6_000_000_000)
expectDeliveryError(.capacity) { let _: WebMVP9DeliverySegment = try awaitDelivery { hugeOwner.loadSegment(at: 0, completion: $0) } }
check(hugeTransport.count == 0, "Oversized cue fails before transport allocation")
hugeOwner.close()
print("WebM delivery bounds checks passed (\(checks) total assertions)")
