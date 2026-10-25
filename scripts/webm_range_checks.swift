// Uses the independent WebM fixture and helpers loaded by webm_checks.swift.
final class RangeFixtureTransport: HTTPTransport {
    var requests: [HTTPRequest] = []
    var reply: ((HTTPRequest) -> Result<HTTPResponse, Error>)?
    var delays = false
    var pending: (() -> Void)?
    var chunks: [Data]?
    var stopped = false
    var repeatCompletion = false
    var duringChunk: (() -> Void)?
    let media: Data

    init(_ media: Data) { self.media = media }

    func send(_ request: HTTPRequest, cancellationToken: CancellationToken?,
              completion: @escaping (Result<HTTPResponse, Error>) -> Void) {
        completion(.failure(WebMRangeError.invalidResponse))
    }

    func stream(_ request: HTTPRequest, cancellationToken: CancellationToken?,
                onChunk: @escaping (Data) -> Bool,
                completion: @escaping (Result<HTTPResponse, Error>) -> Void) {
        requests.append(request)
        let deliver = {
            let result = self.reply?(request) ?? self.response(request)
            if case .success(let response) = result {
                let chunks = self.chunks ?? stride(from: 0, to: response.data.count, by: 7).map {
                    response.data.subdata(in: $0..<min($0 + 7, response.data.count))
                }
                for chunk in chunks {
                    self.duringChunk?()
                    if !onChunk(chunk) { self.stopped = true; break }
                }
            }
            let completed = result.map { HTTPResponse(status: $0.status, headers: $0.headers, data: Data()) }
            completion(completed)
            if self.repeatCompletion { completion(completed) }
        }
        if delays { pending = deliver } else { deliver() }
    }

    func response(_ request: HTTPRequest) -> Result<HTTPResponse, Error> {
        let bounds = request.headers[HTTPHeader.range]!.dropFirst("bytes=".count).split(separator: "-")
        let start = Int(bounds[0])!
        let end = Int(bounds[1])!
        let body = media.subdata(in: start..<(end + 1))
        return .success(HTTPResponse(status: 206,
            headers: ["content-range": "bytes \(start)-\(end)/\(media.count)", "CONTENT-LENGTH": "\(body.count)"], data: body))
    }
}

// Find metadata and cue byte ranges independently by walking top-level EBML.
var rangeRoot = try EBMLReader(realData)
_ = try rangeRoot.element()
let rangeSegment = try rangeRoot.header()
var rangeChildren = try EBMLReader(realData, range: rangeSegment.payloadStart..<realData.count)
var firstClusterOffset = 0
var indexBytes: WebMByteRange?
while !rangeChildren.isAtEnd {
    let start = rangeChildren.position
    let child = try rangeChildren.element()
    if child.id == 0x1C53_BB6B { indexBytes = try WebMByteRange(start: Int64(start), end: Int64(rangeChildren.position - 1)) }
    if child.id == 0x1F43_B675 && firstClusterOffset == 0 { firstClusterOffset = start }
}
let cueBytes = indexBytes!
let initialBytes = try WebMByteRange(start: 0, end: cueBytes.start - 1)
let rangeTransport = RangeFixtureTransport(realData)
let rangeFetcher = try WebMRangeFetcher(transport: rangeTransport, url: URL(string: "https://example.com/video.webm")!,
    contentLength: Int64(realData.count), headers: ["User-Agent": "fixture", "range": "bytes=9-9", "ACCEPT-ENCODING": "gzip"])
var openedStream: WebMRangeFetcher.OpenedStream?
rangeFetcher.open(initializationRange: initialBytes, indexRange: cueBytes, cancellation: nil) { result in
    openedStream = try! result.get()
}
let opened = openedStream!
check(rangeTransport.requests.count == 2, "Opening must fetch only initialization and cues")
check(opened.index.entries.count == realCues.count, "Index must use cue-derived media ranges")
check(rangeTransport.requests.allSatisfy { $0.isPlayback && !$0.sendsCookies && $0.headers["User-Agent"] == "fixture" },
      "Range requests must use playback transport with client headers and no cookie jar")
check(rangeTransport.requests.allSatisfy { $0.headers["Accept-Encoding"] == "identity" && $0.headers["ACCEPT-ENCODING"] == nil && $0.headers["range"] == nil },
      "Caller Range and compression headers must be overridden case-insensitively")
let middleEntry = try opened.index.entry(forTimeNanoseconds: 1_500_000_000)
check(middleEntry.timeNanoseconds == 1_000_000_000, "Seeking must select the preceding cue")
check(try opened.index.entry(forTimeNanoseconds: 0) == opened.index.entries[0], "Beginning must use the first cue")
check(try opened.index.entry(forTimeNanoseconds: Int64.max) == opened.index.entries.last, "Seeking beyond the timeline must use the last range")
check(opened.index.entries[0].range.start == Int64(firstClusterOffset), "First range must start at an actual Cluster, not at initialization data")
var fetchedPackets: [WebMPacket] = []
for entry in opened.index.entries {
    rangeFetcher.fetchPackets(entry: entry, initialization: opened.initialization, cancellation: nil) { result in
        fetchedPackets += try! result.get()
    }
}
check(fetchedPackets == realPackets, "HTTP range fetch and demux must reproduce all ffprobe-verified packets")
let duplicateCues = [realCues[0], realCues[0]] + Array(realCues.dropFirst())
check(try WebMClusterIndex(cues: duplicateCues, contentLength: Int64(realData.count)).entries == opened.index.entries,
      "Multiple cues in one Cluster must not create empty byte ranges")
rejects("Empty cue index must throw") { _ = try WebMClusterIndex(cues: [], contentLength: 10) }
rejects("Negative seeks must throw") { _ = try opened.index.entry(forTimeNanoseconds: -1) }
rejects("Invalid byte ranges must throw") { _ = try WebMByteRange(start: 2, end: 1) }
rejects("Overflowing byte counts must throw") { _ = try WebMByteRange(start: 0, end: Int64.max) }
rejects("Negative file positions must throw") { _ = try WebMByteRange(start: -1, end: 1) }

// A cue range can span multiple Clusters, including those without a cue.
let clusterA = cluster(blocks: element(0xA3, simpleBlock()))
let clusterB = cluster(time: 10, blocks: element(0xA3, simpleBlock(flags: 0)))
check(try WebMClusterSequence.parse(clusterA + clusterB + element(0x1254_C367, Data()), initialization: config).count == 2,
      "Cue spans must demux all Clusters and skip known trailing tags")
let unknownA = uint(0x1F43_B675) + Data([0xFF]) + number(0xE7, 0) + element(0xA3, simpleBlock())
check(try WebMClusterSequence.parse(unknownA + clusterB, initialization: config).count == 2,
      "Unknown-sized Cluster must stop at the next top-level boundary")
let markerInFrame = cluster(blocks: element(0xA3, simpleBlock(payload: uint(0x1F43_B675))))
check(try WebMClusterSequence.parse(unknownA + markerInFrame, initialization: config).count == 2,
      "Compressed bytes resembling Cluster IDs must not become element boundaries")
rejects("Track changes in a media range must not be silently discarded") {
    _ = try WebMClusterSequence.parse(clusterA + element(0x1654_AE6B, Data()), initialization: config)
}
rejects("A truncated later Cluster must throw") {
    _ = try WebMClusterSequence.parse(clusterA + clusterB.dropLast(), initialization: config)
}

func fetchFailure(_ response: HTTPResponse, chunks: [Data]? = nil) -> Error? {
    let transport = RangeFixtureTransport(Data([1, 2, 3, 4]))
    transport.reply = { _ in .success(response) }
    transport.chunks = chunks
    let fetcher = try! WebMRangeFetcher(transport: transport, url: URL(string: "https://example.com/video")!, contentLength: 4)
    var error: Error?
    fetcher.fetch(range: try! WebMByteRange(start: 1, end: 2), cancellation: nil) { result in
        if case .failure(let failure) = result { error = failure }
    }
    return error
}
let validHeaders = ["Content-Range": "bytes 1-2/4", "Content-Length": "2"]
for status in [200, 403, 416, 500] {
    check(fetchFailure(HTTPResponse(status: status, headers: validHeaders, data: Data([2, 3]))) != nil,
          "Only exact HTTP 206 responses may become media bytes")
}
for badHeader in ["bytes 0-1/4", "bytes 1-2/5", "bytes 1-2/*", "bytes +1-2/4", "bytes 1-2/4,1-2/4", "bytes 1-2/9999999999999999999999", "garbage"] {
    check(fetchFailure(HTTPResponse(status: 206, headers: ["Content-Range": badHeader], data: Data([2, 3]))) != nil,
          "Invalid, shifted or stale Content-Range must be rejected")
}
check(fetchFailure(HTTPResponse(status: 206, headers: [:], data: Data([2, 3]))) != nil, "Missing Content-Range must fail")
check(fetchFailure(HTTPResponse(status: 206, headers: validHeaders, data: Data([2]))) != nil, "Short response must fail")
check(fetchFailure(HTTPResponse(status: 206, headers: validHeaders, data: Data([2, 3, 4]))) != nil, "Oversized response must fail")
check(fetchFailure(HTTPResponse(status: 206, headers: validHeaders.merging(["Content-Encoding": "gzip"]) { _, b in b }, data: Data([2, 3]))) != nil,
      "Compressed range payloads must be rejected")
check(fetchFailure(HTTPResponse(status: 206, headers: validHeaders.merging(["content-range": "bytes 1-2/4"]) { _, b in b }, data: Data([2, 3]))) != nil,
      "Ambiguous duplicate header names must fail")

let limitedTransport = RangeFixtureTransport(Data([1, 2, 3, 4]))
let limited = try WebMRangeFetcher(transport: limitedTransport, url: URL(string: "https://example.com/video")!,
                                  contentLength: 4, maximumRangeBytes: 2)
var limitedResult: Result<Data, Error>?
limited.fetch(range: try WebMByteRange(start: 0, end: 3), cancellation: nil) { limitedResult = $0 }
check((try? limitedResult?.get()) == nil && limitedTransport.requests.isEmpty, "Over-budget requests must fail before networking")
check(limitedResult != nil, "An invalid request must report failure rather than hang")
limitedTransport.chunks = [Data([2]), Data([3, 4]), Data([5])]
limited.fetch(range: try WebMByteRange(start: 1, end: 2), cancellation: nil) { limitedResult = $0 }
check(limitedTransport.stopped && (try? limitedResult?.get()) == nil, "Streaming overflow must stop reading immediately")

let deferredTransport = RangeFixtureTransport(Data([1, 2, 3, 4]))
deferredTransport.delays = true
let deferredFetcher = try WebMRangeFetcher(transport: deferredTransport, url: URL(string: "https://example.com/video")!, contentLength: 4)
let cancelled = CancellationToken()
cancelled.cancel()
var cancelledCalled = false
deferredFetcher.fetch(range: try WebMByteRange(start: 0, end: 0), cancellation: cancelled) { _ in cancelledCalled = true }
check(deferredTransport.requests.isEmpty && !cancelledCalled, "Pre-cancellation must silence work and callbacks")
let midRequest = CancellationToken()
deferredFetcher.fetch(range: try WebMByteRange(start: 0, end: 0), cancellation: midRequest) { _ in cancelledCalled = true }
midRequest.cancel()
deferredTransport.pending?()
check(!cancelledCalled && deferredTransport.stopped, "Cancellation during an outstanding request must stop chunks and silence completion")
deferredTransport.delays = false
deferredTransport.repeatCompletion = true
var completions = 0
deferredFetcher.fetch(range: try WebMByteRange(start: 0, end: 0), cancellation: nil) { _ in completions += 1 }
check(completions == 1, "A transport repeating completion must not publish a range twice")
let partialTransport = RangeFixtureTransport(Data(repeating: 0, count: 20))
let partialFetcher = try WebMRangeFetcher(transport: partialTransport, url: URL(string: "https://example.com/video")!, contentLength: 20)
let partialCancellation = CancellationToken()
var chunkNumber = 0
partialTransport.duringChunk = {
    chunkNumber += 1
    if chunkNumber == 2 { partialCancellation.cancel() }
}
partialFetcher.fetch(range: try WebMByteRange(start: 0, end: 19), cancellation: partialCancellation) { _ in cancelledCalled = true }
check(partialTransport.stopped && chunkNumber == 2 && !cancelledCalled,
      "Cancelling a partially received range must stop chunks and silence its callback")
let badOpenTransport = RangeFixtureTransport(Data(repeating: 0, count: 10))
let badOpen = try WebMRangeFetcher(transport: badOpenTransport, url: URL(string: "https://example.com/video")!, contentLength: 10)
var badOpenReported = false
badOpen.open(initializationRange: try WebMByteRange(start: 0, end: 1), indexRange: try WebMByteRange(start: 2, end: 11),
             cancellation: nil) { result in
    if case .failure = result { badOpenReported = true }
}
check(badOpenReported && badOpenTransport.requests.isEmpty, "Invalid cue range must be checked before fetching initialization")
let transportFailure = NSError(domain: "fixture", code: 73)
badOpenTransport.reply = { _ in .failure(transportFailure) }
var surfacedError: NSError?
badOpen.fetch(range: try WebMByteRange(start: 0, end: 1), cancellation: nil) { result in
    if case .failure(let error) = result { surfacedError = error as NSError }
}
check(surfacedError?.code == 73 && surfacedError?.domain == "fixture", "Underlying transport failure must be preserved")

// A real transport streams into an empty final body. Also exercise the
// protocol's small-response fallback, which supplies a body to onChunk once.
final class SendOnlyRangeTransport: HTTPTransport {
    func send(_ request: HTTPRequest, cancellationToken: CancellationToken?,
              completion: @escaping (Result<HTTPResponse, Error>) -> Void) {
        completion(.success(HTTPResponse(status: 206, headers: ["Content-Range": "bytes 1-2/4"], data: Data([2, 3]))))
    }
}
let fallbackFetcher = try WebMRangeFetcher(transport: SendOnlyRangeTransport(), url: URL(string: "https://example.com/video")!, contentLength: 4)
var fallbackBytes: Data?
fallbackFetcher.fetch(range: try WebMByteRange(start: 1, end: 2), cancellation: nil) { fallbackBytes = try! $0.get() }
check(fallbackBytes == Data([2, 3]), "The HTTPTransport fallback must not duplicate response bytes")
print("WebM range checks passed (\(checks) total assertions)")
