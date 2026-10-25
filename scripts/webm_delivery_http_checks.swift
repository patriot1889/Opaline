// Stubs only for app-wide errors/logging; transport, server, HLS and remux are shipping files.
enum APIError: Error { case transport(Error), invalidResponse }
enum AppLog { static func hls(_ text: String) {} }
final class HTTPDeliveryBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    let ready = DispatchSemaphore(value: 0)
    func complete(_ result: Result<T, Error>) { lock.lock(); self.result = result; lock.unlock(); ready.signal() }
    func get() throws -> T { lock.lock(); defer { lock.unlock() }; return try result!.get() }
}
func waitDelivery<T: Sendable>(_ start: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void) throws -> T {
    let box = HTTPDeliveryBox<T>(); start { box.complete($0) }
    precondition(box.ready.wait(timeout: .now() + 15) == .success)
    return try box.get()
}
final class HTTPDeliveryReply: @unchecked Sendable {
    let reply: (Data?, String) -> Void
    init(_ reply: @escaping (Data?, String) -> Void) { self.reply = reply }
    func complete(_ result: Result<WebMVP9Delivery.Resource, Error>) {
        switch result {
        case .success(let resource): reply(resource.data, resource.contentType)
        case .failure: reply(nil, "video/mp4")
        }
    }
}
final class HTTPDeliveryCount: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    func increment() { lock.lock(); requests += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return requests }
}
let fixtureRoot = URL(fileURLWithPath: CommandLine.arguments[1])
let video = try Data(contentsOf: fixtureRoot.appendingPathComponent("vp9-altref.webm"))
let audio = try Data(contentsOf: fixtureRoot.appendingPathComponent("aac-sync.m4a"))
var root = try EBMLReader(video)
_ = try root.element()
let segment = try root.header()
var children = try EBMLReader(video, range: segment.payloadStart..<video.count)
var indexRange: WebMByteRange?
while !children.isAtEnd {
    let start = children.position
    let element = try children.element()
    if element.id == 0x1C53_BB6B { indexRange = try WebMByteRange(start: Int64(start), end: Int64(children.position - 1)) }
}
let sourceRequests = HTTPDeliveryCount()
let upstream = LocalMediaServer { path, done in
    if path == "/video.webm" { sourceRequests.increment(); done(video, "video/webm") }
    else { done(path == "/audio.m4a" ? audio : nil, "audio/mp4") }
}!
let sourceBase: URL = try waitDelivery { completed in upstream.start { completed($0.map(Result.success) ?? .failure(WebMRangeError.invalidResponse)) } }
defer { upstream.stop() }
let transport = URLSessionTransport()
let fetcher = try WebMRangeFetcher(transport: transport, url: sourceBase.appendingPathComponent("video.webm"), contentLength: Int64(video.count))
let opened: WebMRangeFetcher.OpenedStream = try waitDelivery {
    fetcher.open(initializationRange: try! WebMByteRange(start: 0, end: indexRange!.start - 1), indexRange: indexRange!, cancellation: nil, completion: $0)
}
let delivery = try WebMVP9Delivery(fetcher: fetcher, stream: opened, durationNanoseconds: 6_000_000_000)
defer { delivery.close() }
precondition(sourceRequests.value == 2, "Opening metadata must not fetch media")
let audioSegments = HLSGenerator.parseSidx(data: audio)!
var audioEnd = 0
while audioEnd + 8 <= audio.count {
    let count = Int(audio.readBigUInt32(at: audioEnd))
    precondition(count >= 8 && count <= audio.count - audioEnd)
    let kind = audio.readFourCC(at: audioEnd + 4)
    audioEnd += count
    if kind == "sidx" { break }
}
let audioPlaylist = HLSGenerator.mediaPlaylist(url: sourceBase.appendingPathComponent("audio.m4a"), initBytes: audioEnd, dataStartOffset: Int64(audioEnd), segments: audioSegments)
let master = HLSGenerator.mainPlaylist(bandwidth: 2_000_000, codecs: "vp09.00.21.08,mp4a.40.2", resolution: "640x360", uris: .init(video: delivery.playlistPath, audio: "/audio.m3u8"))
let playlistFiles = ["/master.m3u8": Data(master.utf8), "/audio.m3u8": Data(audioPlaylist.utf8)]
let playback = LocalMediaServer { path, done in
    if let body = playlistFiles[path] { done(body, "application/vnd.apple.mpegurl"); return }
    let reply = HTTPDeliveryReply(done)
    delivery.resource(forPath: path) { reply.complete($0) }
}!
let playbackBase: URL = try waitDelivery { completed in playback.start { completed($0.map(Result.success) ?? .failure(WebMRangeError.invalidResponse)) } }
defer { playback.stop() }
func get(_ base: URL, _ path: String, range: String? = nil) throws -> HTTPResponse {
    let box = HTTPDeliveryBox<Data>()
    var fields: [String: String] = [:]
    if let range { fields["Range"] = range }
    var result: HTTPResponse?
    let lock = NSLock()
    transport.send(HTTPRequest(method: .get, url: base.appendingPathComponent(path), headers: fields, sendsCookies: false), cancellationToken: nil) { response in
        lock.lock(); if case .success(let value) = response { result = value }; lock.unlock()
        box.complete(response.map(\.data))
    }
    precondition(box.ready.wait(timeout: .now() + 15) == .success)
    _ = try box.get()
    lock.lock(); defer { lock.unlock() }
    return result!
}
let masterResponse = try get(playbackBase, "master.m3u8")
precondition(masterResponse.status == 200 && masterResponse.data == Data(master.utf8))
let videoPlaylist = try get(playbackBase, delivery.playlistPath)
precondition(videoPlaylist.status == 200 && String(data: videoPlaylist.data, encoding: .utf8)!.components(separatedBy: "#EXT-X-MAP:").count == 4)
for index in 0..<3 {
    let initialization = try get(playbackBase, delivery.basePath + "/\(index)/init")
    let media = try get(playbackBase, delivery.basePath + "/\(index)/media")
    precondition(initialization.status == 200 && media.status == 200 && !media.data.isEmpty)
    let partial = try get(playbackBase, delivery.basePath + "/\(index)/media", range: "bytes=0-15")
    precondition(partial.status == 206 && partial.data == media.data.prefix(16), "Generated fMP4 supports the shipping server's Range handling")
}
precondition(sourceRequests.value == 5, "Init/media/Range probes must coalesce or hit cache: two metadata plus three cue ranges")
let backwards = try get(playbackBase, delivery.basePath + "/0/media")
precondition(backwards.status == 200 && sourceRequests.value == 6, "Backward request remuxes an evicted cue without sequential downloading")
let audioResponse = try get(playbackBase, "audio.m3u8")
precondition(audioResponse.status == 200 && audioResponse.data == Data(audioPlaylist.utf8))
let audioRange = try get(sourceBase, "audio.m4a", range: "bytes=\(audioEnd)-\(audioEnd + 15)")
precondition(audioRange.status == 206 && audioRange.data == audio.subdata(in: audioEnd..<(audioEnd + 16)))
let videoSeconds = Double(delivery.plan.segments.reduce(0) { $0 + $1.durationNanoseconds }) / 1e9
let audioSeconds = audioSegments.reduce(0) { $0 + $1.duration }
precondition(videoSeconds == 6 && abs(audioSeconds - videoSeconds) <= 1024.0 / 48000.0 + 0.000001,
             "Companion AAC ends within one encoded audio frame of the exact video timeline")
print("WebM delivery HTTP checks passed (real 206 fetch/remux/serve, cache, backward cue, companion AAC; video=\(videoSeconds)s audio=\(audioSeconds)s)")
