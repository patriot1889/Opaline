import Foundation

private var checks = 0
func check(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
func rejects(_ message: String, _ body: () throws -> Void) {
    checks += 1
    do { try body(); preconditionFailure(message) } catch {}
}
let fixtureRoot = URL(fileURLWithPath: CommandLine.arguments[1])
let videoData = try Data(contentsOf: fixtureRoot.appendingPathComponent("vp9-altref.webm"))
let audioData = try Data(contentsOf: fixtureRoot.appendingPathComponent("aac-sync.m4a"))
var videoRoot = try EBMLReader(videoData)
_ = try videoRoot.element(); let segmentHeader = try videoRoot.header()
var children = try EBMLReader(videoData, range: segmentHeader.payloadStart..<videoData.count)
var cueStart = 0; var cueEnd = 0
while !children.isAtEnd {
    let start = children.position; let element = try children.element()
    if element.id == 0x1C53_BB6B { cueStart = start; cueEnd = children.position - 1 }
}
var audioIndexStart = 0; var audioIndexEnd = 0
while audioIndexStart + 8 <= audioData.count {
    let count = Int(audioData.readBigUInt32(at: audioIndexStart))
    if audioData.readFourCC(at: audioIndexStart + 4) == "sidx" { audioIndexEnd = audioIndexStart + count - 1; break }
    audioIndexStart += count
}
func videoJSON(mime: String = "video/webm; codecs=\"vp9\"", url: String = "https://fixture.invalid/video.webm", itag: Int = 243) -> [String: Any] {
    ["url": url, "itag": itag, "mimeType": mime, "bitrate": 400_000, "contentLength": "\(videoData.count)",
     "initRange": ["start": "0", "end": "\(cueStart - 1)"], "indexRange": ["start": "\(cueStart)", "end": "\(cueEnd)"],
     "width": 640, "height": 360, "fps": 30, "qualityLabel": "360p", "approxDurationMs": "6000"]
}
func audioJSON() -> [String: Any] {
    ["url": "https://fixture.invalid/audio.m4a", "itag": 140, "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"", "bitrate": 96_000,
     "contentLength": "\(audioData.count)", "initRange": ["start": "0", "end": "\(audioIndexStart - 1)"],
     "indexRange": ["start": "\(audioIndexStart)", "end": "\(audioIndexEnd)"], "approxDurationMs": "6021"]
}
func playerJSON(_ videos: [[String: Any]], audio: [String: Any] = audioJSON()) -> [String: Any] {
    ["streamingData": ["adaptiveFormats": videos + [audio]], "responseContext": ["visitorData": "fixture-visitor"]]
}
let webMOnly = InnertubeClient.parseDirectPlaybackInfo(playerJSON([videoJSON()]))!
check(webMOnly.dashVideoFormat == nil && webMOnly.webMVideoFormats.count == 1, "Parser preserves WebM separately without enabling it in MP4/SABR selection")
let legacy = videoJSON(mime: "video/mp4; codecs=\"avc1.640028\"", itag: 299)
let mixed = InnertubeClient.parseDirectPlaybackInfo(playerJSON([legacy, videoJSON(), videoJSON(mime: "video/webm; codecs=\"vp09.02.51.10\"", itag: 337)]))!
check(mixed.dashVideoFormat?.itag == 299 && mixed.allDashVideoFormats.map(\.itag) == [299], "Existing MP4 ladder excludes all WebM formats")
check(mixed.webMVideoFormats.count == 2, "Separate catalog retains HDR metadata for explicit eligibility filtering")
check(ByteRangeDeliveryFactory().playbackInfo(mixed).dashVideoFormat?.itag == 299, "Existing delivery policy is identity")
check(SABRDeliveryFactory().playbackInfo(mixed).allDashVideoFormats.map(\.itag) == [299], "SABR policy remains MP4-only")
let factory = WebMVP9DeliveryFactory(supportsVP9: { true })
let selected = factory.playbackInfo(mixed)
check(selected.dashVideoFormat?.itag == 243 && selected.allDashVideoFormats.map(\.itag) == [243], "Opt-in policy selects only SDR VP9, including WebM-only responses")
check(factory.canServe(selected), "Supported direct VP9/AAC pair is servable")
check(WebMVP9DeliveryFactory(supportsVP9: { false }).playbackInfo(mixed).dashVideoFormat == nil, "Hardware gate suppresses WebM on unsupported devices")
for codec in ["vp09.02.51.10", "vp09.00.xx.08", "vp09.00.51.10", "vp09.00.21.08.01.09.16.09.01", "av01.0.08M.08", "vp9,opus"] {
    check(WebMVP9Formats.hlsCodec(codec) == nil, "Unsupported/HDR/ambiguous codec must fail: \(codec)")
}
check(WebMVP9Formats.hlsCodec("vp9") == "vp09.00.00.08", "Legacy VP9 token maps to profile-0 MP4 codec with unspecified level")
for (key, value): (String, Any) in [("url", "file:///video.webm"), ("ytliteSigChallenge", "cipher"), ("approxDurationMs", "0"), ("approxDurationMs", "9223372036854775807")] {
    var raw = videoJSON(); raw[key] = value
    let parsed = InnertubeClient.parseDirectPlaybackInfo(playerJSON([legacy, raw]))!
    check(factory.playbackInfo(parsed).dashVideoFormat == nil, "Invalid direct metadata cannot enter WebM playback")
}
var missingURL = videoJSON(); missingURL.removeValue(forKey: "url")
let noURL = InnertubeClient.parseDirectPlaybackInfo(playerJSON([legacy, missingURL]))!
check(factory.playbackInfo(noURL).dashVideoFormat == nil, "SABR-only WebM descriptors cannot enter HTTP delivery")
let chosen = factory.playbackInfo(webMOnly)
let videoFormat = chosen.dashVideoFormat!; let audioFormat = chosen.dashAudioFormat!
let audioIndexBytes = audioData.subdata(in: audioIndexStart..<(audioIndexEnd + 1))
let audioIndex = try WebMAudioIndex(data: audioIndexBytes, format: audioFormat)
check(audioIndex.segments.count == 1, "Companion AAC index uses shared HLS/SIDX parser")
for offset in [20, 28] { // version-1 earliest presentation time and first_offset
    var invalid = audioIndexBytes; invalid[offset + 7] = 1
    rejects("Nonzero audio origin/offset cannot be silently misaligned") { _ = try WebMAudioIndex(data: invalid, format: audioFormat) }
}
for length in 0..<audioIndexBytes.count {
    rejects("Truncated AAC SIDX must fail") { _ = try WebMAudioIndex(data: Data(audioIndexBytes.prefix(length)), format: audioFormat) }
}
func levelFormat(width: Int, height: Int, fps: Int, bitrate: Int, codec: String = "vp9") -> DashFormatInfo {
    var raw = videoJSON(mime: "video/webm; codecs=\"\(codec)\"")
    raw["width"] = width; raw["height"] = height; raw["fps"] = fps; raw["bitrate"] = bitrate
    return InnertubeClient.parseDirectPlaybackInfo(playerJSON([legacy, raw]))!.webMVideoFormats[0]
}
check(WebMVP9Level.codec(format: videoFormat, configuration: nil) == "vp09.00.21.08", "Level inference uses declared geometry, rate and bitrate")
let fourK = levelFormat(width: 3840, height: 2160, fps: 60, bitrate: 40_000_000)
check(WebMVP9Level.codec(format: fourK, configuration: nil) == "vp09.00.51.08", "4K60 level hint is derived without claiming 4K playback validation")
let badRate = levelFormat(width: 640, height: 360, fps: Int.max, bitrate: 400_000)
check(WebMVP9Level.codec(format: badRate, configuration: nil) == nil && !WebMVP9Formats.isVideo(badRate), "Unrepresentable rate cannot produce a misleading codec hint")
let declared = levelFormat(width: 640, height: 360, fps: 30, bitrate: 400_000, codec: "vp09.00.31.08")
check(WebMVP9Level.codec(format: declared, configuration: nil) == "vp09.00.31.08", "A declared level takes precedence over estimation")
var levelRecord = Data([1, 0, 0, 0, 0, 40, 0x82, 2, 2, 2, 0, 0])
let containerConfiguration = WebMVP9Configuration(width: 640, height: 360, record: levelRecord)
check(WebMVP9Level.codec(format: declared, configuration: containerConfiguration) == "vp09.00.40.08", "Actual container level wins over response metadata")
final class FixtureTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [HTTPRequest] = []
    private var held: [(HTTPRequest, CancellationToken?, (Result<HTTPResponse, Error>) -> Void)] = []
    let pause: Bool
    init(pause: Bool = false) { self.pause = pause }
    var requests: [HTTPRequest] { lock.lock(); defer { lock.unlock() }; return sent }
    func send(_ request: HTTPRequest, cancellationToken: CancellationToken?, completion: @escaping (Result<HTTPResponse, Error>) -> Void) {
        lock.lock(); sent.append(request)
        if pause { held.append((request, cancellationToken, completion)); lock.unlock(); return }
        lock.unlock(); reply(request, completion)
    }
    func release() {
        lock.lock(); let callbacks = held; held.removeAll(); lock.unlock()
        for (request, _, callback) in callbacks { reply(request, callback) }
    }
    private func reply(_ request: HTTPRequest, _ completion: (Result<HTTPResponse, Error>) -> Void) {
        let data = request.url.path == "/video.webm" ? videoData : audioData
        let range = request.headers["Range"]!.dropFirst(6).split(separator: "-").map { Int($0)! }
        completion(.success(HTTPResponse(status: 206, headers: ["Content-Range": "bytes \(range[0])-\(range[1])/\(data.count)"], data: data.subdata(in: range[0]..<(range[1] + 1)))))
    }
}
final class ReplyBox<T>: @unchecked Sendable {
    private let lock = NSLock(); private var result: Result<T, Error>?
    func complete(_ value: Result<T, Error>) { lock.lock(); result = value; lock.unlock() }
    var done: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }
    func get() throws -> T { lock.lock(); defer { lock.unlock() }; return try result!.get() }
}
func spin(until condition: () -> Bool, timeout: TimeInterval = 10) {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    precondition(condition(), "Source check timed out")
}
func prepare(_ delivery: WebMStreamDelivery, start: Double? = nil) throws -> PreparedPlayback {
    let box = ReplyBox<PreparedPlayback>()
    delivery.prepare(DeliveryRequest(info: chosen, video: videoFormat, audio: audioFormat, resumeAt: start)) { box.complete($0) }
    spin(until: { box.done }); return try box.get()
}
func get(_ url: URL) throws -> Data {
    let box = ReplyBox<HTTPResponse>()
    URLSessionTransport().send(HTTPRequest(method: .get, url: url, timeout: 1, sendsCookies: false), cancellationToken: nil) { box.complete($0) }
    spin(until: { box.done }); let response = try box.get(); precondition(response.status == 200); return response.data
}
let transport = FixtureTransport()
var delivery: WebMStreamDelivery? = WebMStreamDelivery(client: VisionOSClient(), transport: transport)
let prepared = try prepare(delivery!)
check(prepared.duration == 6 && prepared.resourceLoader is WebMPlaybackSession, "Prepared item retains session lifetime and video duration")
let entry = (prepared.item.asset as! AVURLAsset).url
let main = String(data: try get(entry), encoding: .utf8)!
check(main.contains("vp09.00.21.08,mp4a.40.2") && main.contains("AUDIO=\"audio\""), "Unknown VP9 level is estimated from format metadata instead of advertising Apple-incompatible level 00")
check(transport.requests.count == 4, "Preparation fetches AAC index, WebM init/cues and only the initial cue")
check(transport.requests.allSatisfy { !$0.sendsCookies && $0.headers["X-Goog-Visitor-Id"] == "fixture-visitor" && $0.url.query?.contains("cver=1.02") == true }, "Resolver preserves client identity and visitor headers")
let videoPath = main.split(separator: "\n").last!.description
let videoPlaylist = String(data: try get(URL(string: videoPath, relativeTo: entry)!), encoding: .utf8)!
check(videoPlaylist.components(separatedBy: "#EXT-X-MAP:").count == 4, "Source serves independently remuxed cue maps")
let resumeTransport = FixtureTransport(); var resumed: WebMStreamDelivery? = WebMStreamDelivery(client: VisionOSClient(), transport: resumeTransport)
let resumedItem = try prepare(resumed!, start: 2.5)
let resumedEntry = (resumedItem.item.asset as! AVURLAsset).url
let resumedMain = String(data: try get(resumedEntry), encoding: .utf8)!
let resumedVideo = String(data: try get(URL(string: resumedMain.split(separator: "\n").last!.description, relativeTo: resumedEntry)!), encoding: .utf8)!
check(resumedVideo.contains("#EXT-X-START:TIME-OFFSET=2.500000000,PRECISE=YES"), "Resume position reaches video playlist")
let selectedRange = resumeTransport.requests.last!.headers["Range"]!
let firstMetadataRange = resumeTransport.requests.filter { $0.url.path == "/video.webm" }.first!.headers["Range"]!
let initialization = try WebMInitialization.parse(videoData)
let cues = try WebMCue.parse(videoData.subdata(in: cueStart..<(cueEnd + 1)), initialization: initialization, contentLength: Int64(videoData.count))
let index = try WebMClusterIndex(cues: cues, contentLength: Int64(videoData.count))
let resumedRange = try index.entry(forTimeNanoseconds: 2_500_000_000).range
check(selectedRange == "bytes=\(resumedRange.start)-\(resumedRange.end)"
      && resumeTransport.requests.count == 4, "Resuming warms the exact preceding cue without sequential media")
AudioOnlyMode.isEnabled = true
let audioTransport = FixtureTransport(); var audioOnly: WebMStreamDelivery? = WebMStreamDelivery(client: VisionOSClient(), transport: audioTransport)
let audioItem = try prepare(audioOnly!)
let audioMain = String(data: try get((audioItem.item.asset as! AVURLAsset).url), encoding: .utf8)!
check(!audioMain.contains("vp09") && audioMain.contains("mp4a.40.2"), "Audio-only entry omits video")
check(audioTransport.requests.count == 1 && audioTransport.requests[0].url.path == "/audio.m4a", "Audio-only preparation never fetches WebM")
AudioOnlyMode.isEnabled = false
audioOnly = nil; resumed = nil; delivery = nil
let pauseTransport = FixtureTransport(pause: true)
var abandoned: WebMStreamDelivery? = WebMStreamDelivery(client: VisionOSClient(), transport: pauseTransport)
let abandonedReply = ReplyBox<PreparedPlayback>()
abandoned!.prepare(DeliveryRequest(info: chosen, video: videoFormat, audio: audioFormat, resumeAt: nil)) { abandonedReply.complete($0) }
spin(until: { pauseTransport.requests.count == 1 }); abandoned = nil; pauseTransport.release()
let settle = Date().addingTimeInterval(0.1)
while Date() < settle { _ = RunLoop.current.run(mode: .default, before: settle) }
check(!abandonedReply.done, "Released preparation cannot publish a late item")
rejects("Releasing delivery stops server even while prepared result retains lease") { _ = try get(entry) }
// Superseded failures are just as stale as superseded success callbacks.
var cipherRaw = videoJSON(); cipherRaw["ytliteSigChallenge"] = "unsolved"
let cipherInfo = InnertubeClient.parseDirectPlaybackInfo(playerJSON([legacy, cipherRaw]))!
let cipherFormat = cipherInfo.webMVideoFormats[0]
var replacement: WebMStreamDelivery? = WebMStreamDelivery(client: VisionOSClient(), transport: FixtureTransport())
let obsoleteFailure = ReplyBox<PreparedPlayback>()
replacement!.prepare(DeliveryRequest(info: chosen, video: cipherFormat, audio: audioFormat, resumeAt: nil)) { obsoleteFailure.complete($0) }
let replacementItem = try prepare(replacement!)
check(replacementItem.duration == 6 && !obsoleteFailure.done, "Superseded metadata failure cannot publish into a newer preparation")
replacement = nil
let retainedTransport = FixtureTransport(pause: true)
let retainedDelivery = WebMStreamDelivery(client: VisionOSClient(), transport: retainedTransport)
let retainedReply = ReplyBox<PreparedPlayback>()
retainedDelivery.prepare(DeliveryRequest(info: chosen, video: videoFormat, audio: audioFormat, resumeAt: nil)) { [retainedDelivery] result in
    _ = retainedDelivery.label
    retainedReply.complete(result)
}
spin(until: { retainedTransport.requests.count == 1 })
retainedDelivery.releaseResources()
retainedTransport.release()
let releaseDeadline = Date().addingTimeInterval(0.1)
while Date() < releaseDeadline { _ = RunLoop.current.run(mode: .default, before: releaseDeadline) }
check(!retainedReply.done, "Explicit release cancels preparation even when its callback retains the delivery")
print("WebM playback checks passed (\(checks) assertions; parser isolation, eligibility, VP9/AAC preparation, resume, audio-only, teardown)")
