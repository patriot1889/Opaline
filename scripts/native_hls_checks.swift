// Fixtures replace only the app's composition root, API and HTTP transport.
protocol LocalePreferences { var hl: String { get }; var gl: String { get } }
struct DefaultLocalePreferences: LocalePreferences { let hl = "en"; let gl = "US" }
enum AppLog {
    static func innertube(_ text: String) {}
    static func player(_ text: String) {}
    static func hls(_ text: String) {}
}
enum VideoQualityStore { static var maxHeight: Int? = 720 }
enum PlaybackBufferPolicy { static func configure(item: AVPlayerItem) {} }
enum ServiceContainer { static let mediaTransport: HTTPTransport = FixtureTransport() }
enum HLSStreamResolver {
    static func firstMatch(in text: String, pattern: String) -> String? {
        let regex = try! NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
protocol WatchService: AnyObject {
    func fetchDirectPlayback(videoId: String, client: PlaybackClient, poToken: String?,
                             cancellationToken: CancellationToken?,
                             completion: @escaping (Result<DirectPlaybackInfo, Error>) -> Void)
}
final class InnertubeClient {
    static let sigChallengeKey = "ytliteSigChallenge"
    static let sigParamKey = "ytliteSigParam"
    static func extractCaptionTracks(_ json: [String: Any]) -> [SubtitleTrack] { [] }
}
final class FixtureAPI: WatchService {
    var response = playbackInfo(hls: "https://example.com/hls/master.m3u8")
    var deferred: ((Result<DirectPlaybackInfo, Error>) -> Void)?
    var delays = false
    func fetchDirectPlayback(videoId: String, client: PlaybackClient, poToken: String?,
                             cancellationToken: CancellationToken?,
                             completion: @escaping (Result<DirectPlaybackInfo, Error>) -> Void) {
        check(client.name == "VISIONOS" && poToken == nil, "Native HLS must use anonymous visionOS")
        if delays { deferred = completion } else { completion(.success(response)) }
    }
}
final class FixtureTransport: HTTPTransport {
    var requests: [HTTPRequest] = []
    var response = HTTPResponse(status: 200, headers: [:], data: Data(master.utf8))
    func send(_ request: HTTPRequest, cancellationToken: CancellationToken?,
              completion: @escaping (Result<HTTPResponse, Error>) -> Void) {
        requests.append(request)
        completion(.success(response))
    }
}
func playbackInfo(hls: String?) -> DirectPlaybackInfo {
    var data: [String: Any] = ["serverAbrStreamingUrl": "https://example.com/sabr"]
    data["hlsManifestUrl"] = hls
    return InnertubeClient.parseDirectPlaybackInfo(["streamingData": data])!
}
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(condition(), message)
}
func awaitCallback<T>(_ body: (@escaping (T) -> Void) -> Void) -> T {
    var result: T?
    body { result = $0 }
    let deadline = Date().addingTimeInterval(3)
    while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    return result!
}
let master = """
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="Main, original",DEFAULT=YES,URI="audio/main.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="../subs/en.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=1000000,CODECS="avc1.64001f,mp4a.40.2",RESOLUTION=1280x720,FRAME-RATE=30,AUDIO="aac"
avc720.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1920x1080,FRAME-RATE=30,AUDIO="aac"
avc1080.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,CODECS="vp09.00.40.08,mp4a.40.2",RESOLUTION=1920x1080,FRAME-RATE=30,AUDIO="aac"
vp91080.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=10000000,CODECS="vp09.00.51.08,mp4a.40.2",RESOLUTION=3840x2160,FRAME-RATE=60,AUDIO="aac"
vp92160.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1500000,CODECS="av01.0.08M.08,mp4a.40.2",RESOLUTION=1920x1080,FRAME-RATE=30,AUDIO="aac"
av11080.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=1920x1080,FRAME-RATE=30
unknown.m3u8
"""
let base = URL(string: "https://example.com/hls/master.m3u8")!
let vp9 = NativeHLSCodecs.variants(playlist: master, baseURL: base) { !$0.isEmpty && !$0.contains("av01") }
check(vp9.map(\.quality.label) == ["2160p60", "1080p", "720p"], "Playable tiers must be sorted and deduplicated")
check(vp9[1].uri.hasSuffix("vp91080.m3u8"), "VP9 must beat higher-bitrate AVC at the same tier")
let avc = NativeHLSCodecs.variants(playlist: master, baseURL: base) { $0.contains("avc1") }
check(avc.count == 2 && avc[0].uri.hasSuffix("avc1080.m3u8"), "Unsupported VP9 must not hide AVC")
check(avc[0].bandwidth == 5_000_000, "First BANDWIDTH attribute must be parsed")
let filtered = LiveHLSVariants.manifest(keeping: vp9[1], playlist: master, baseURL: base)
check(filtered.contains("URI=\"https://example.com/hls/audio/main.m3u8\""), "Relative audio must keep its original base")
check(filtered.contains("URI=\"https://example.com/subs/en.m3u8\""), "Relative subtitles must keep their original base")
check(filtered.components(separatedBy: "#EXT-X-STREAM-INF:").count == 2, "Pinned playlist must keep only the chosen variant")
check(!NativeHLSCodecs.isPlayable("vp8,opus") && !NativeHLSCodecs.isPlayable(""), "Unknown/missing video codecs must be rejected")

let api = FixtureAPI()
let transport = FixtureTransport()
let source = NativeHLSSource(apiClient: api, transport: transport)
let loaded: Result<PreparedPlayback, Error> = awaitCallback { source.loadPlayback(videoId: "fixture", cancellation: nil, completion: $0) }
let playback = try loaded.get()
check(source.currentQuality?.height == 720 && playback.resourceLoader != nil, "Initial playback must pin the quality cap")
check(source.currentCodecs?.contains("avc1") == true, "Stats must describe native HLS's actual codec")
check(transport.requests.count == 1 && !transport.requests[0].sendsCookies && transport.requests[0].isPlayback,
      "Manifest fetch must use the cookieless playback transport")
check(transport.requests[0].headers[HTTPHeader.userAgent] == UserAgent.visionOS, "Manifest headers must match the client")
let chosen = source.availableQualities.first { $0.height == 1080 }!
let switched: Result<PreparedPlayback, Error> = awaitCallback { source.selectQuality(chosen, resumeAt: 12, completion: $0) }
check((try? switched.get()) != nil && source.currentQuality == chosen, "Quality switching must rebuild native HLS")
let invalid = VideoQuality(id: "missing", label: "missing", height: nil, fps: nil)
let invalidQuality: Result<PreparedPlayback, Error> = awaitCallback { source.selectQuality(invalid, resumeAt: nil, completion: $0) }
check((try? invalidQuality.get()) == nil && source.currentQuality == chosen, "Unknown quality must leave the active choice intact")
let probed: [VideoQuality] = awaitCallback { source.probeQualities(videoId: "probe", completion: $0) }
check(!probed.isEmpty && source.currentQuality == chosen, "Quality probe must not mutate active playback")

transport.response = HTTPResponse(status: 503, headers: [:], data: Data(master.utf8))
let httpFailure: Result<PreparedPlayback, Error> = awaitCallback { source.loadPlayback(videoId: "bad", cancellation: nil, completion: $0) }
check((try? httpFailure.get()) == nil && source.availableQualities.isEmpty, "HTTP failure must return to the chain")
transport.response = HTTPResponse(status: 200, headers: [:], data: Data("#EXTM3U\n#EXT-X-ENDLIST\n".utf8))
let empty: Result<PreparedPlayback, Error> = awaitCallback { source.loadPlayback(videoId: "empty", cancellation: nil, completion: $0) }
check((try? empty.get()) == nil, "A manifest with no playable variants must return to the chain")
api.response = playbackInfo(hls: nil)
let missing: Result<PreparedPlayback, Error> = awaitCallback { source.loadPlayback(videoId: "no-hls", cancellation: nil, completion: $0) }
check((try? missing.get()) == nil, "Missing HLS must fail rather than silently selecting SABR")

api.delays = true
var staleCompleted = false
source.loadPlayback(videoId: "stale", cancellation: nil) { _ in staleCompleted = true }
source.releaseResources()
api.deferred?(.success(playbackInfo(hls: "https://example.com/master.m3u8")))
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
check(!staleCompleted && source.availableQualities.isEmpty, "Released source must ignore stale callbacks")
let cancellation = CancellationToken()
source.loadPlayback(videoId: "cancelled", cancellation: cancellation) { _ in staleCompleted = true }
cancellation.cancel()
api.deferred?(.success(playbackInfo(hls: "https://example.com/master.m3u8")))
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
check(!staleCompleted && source.availableQualities.isEmpty, "Cancelled source must not publish playback")
print("Native HLS checks passed (\(checks) assertions)")
