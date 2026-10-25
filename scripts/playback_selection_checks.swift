// Composition stubs; VideoSource, candidate policy and fallback chain are real.
struct SubtitleTrack {}
enum VideoQualityStore { static var maxHeight: Int? = 2160 }
enum AudioOnlyMode { static var isEnabled = false }
enum AppLog { static func player(_ text: String) {} }

var assertions = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    precondition(value(), message)
}
func tier(_ height: Int, _ fps: Int = 30) -> VideoQuality {
    VideoQuality(id: "\(height)-\(fps)", label: "\(height)p\(fps)", height: height, fps: fps)
}
var attempts: [String] = []
final class FakeSource: VideoSource {
    let name: String
    var supportsQualitySelection: Bool { true }
    var availableQualities: [VideoQuality]
    var currentQuality: VideoQuality?
    var listsAudioTracks: Bool { true }
    var availableAudioTracks: [AudioTrack] = []
    func probeAudioTracks(videoId: String, completion: @escaping ([AudioTrack]) -> Void) {
        completion([AudioTrack(id: "en.3", displayName: "English", isDefault: true)])
    }
    var failing = Set<String>()
    var deferredProbe: (([VideoQuality]) -> Void)?
    var hangs = false
    var releases = 0
    init(_ name: String, _ qualities: [VideoQuality]) {
        self.name = name
        availableQualities = qualities
    }
    func probeQualities(videoId: String, completion: @escaping ([VideoQuality]) -> Void) {
        if hangs { deferredProbe = completion } else { completion(availableQualities) }
    }
    func loadPlayback(videoId: String, cancellation: CancellationToken?,
                      completion: @escaping (Result<PreparedPlayback, Error>) -> Void) {
        attempts.append("\(name):default")
        currentQuality = availableQualities.first
        completion(.success(prepared()))
    }
    func loadPlayback(videoId: String, quality: VideoQuality, cancellation: CancellationToken?,
                      completion: @escaping (Result<PreparedPlayback, Error>) -> Void) {
        attempts.append("\(name):\(quality.label)")
        currentQuality = quality
        if failing.contains(quality.id) {
            completion(.failure(NSError(domain: "fixture", code: 1)))
        } else { completion(.success(prepared())) }
    }
    func selectQuality(_ quality: VideoQuality, resumeAt: Double?,
                       completion: @escaping (Result<PreparedPlayback, Error>) -> Void) {
        currentQuality = quality
        completion(.success(prepared()))
    }
    func releaseResources() { releases += 1; currentQuality = nil }
    private func prepared() -> PreparedPlayback {
        PreparedPlayback(item: AVPlayerItem(url: URL(fileURLWithPath: "/tmp/unused.mp4")))
    }
}
func step(_ source: FakeSource, _ delivery: PlaybackDeliveryPreference) -> PlaybackStep {
    PlaybackStep(id: source.name, deliveryPreference: delivery, make: { _ in source })
}
func waitFor(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(2)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    check(condition(), "asynchronous completion timed out")
}

let native = FakeSource("native", [tier(1080)])
let mp4 = FakeSource("mp4", [tier(2160), tier(1440)])
let webm = FakeSource("webm", [tier(2160)])
mp4.failing.insert(tier(2160).id)
let chain = FallbackChainSource(steps: [step(native, .native), step(webm, .remuxedWebM),
                                      step(mp4, .generatedHLS)], apiClient: WatchService())
var done = false
chain.loadPlayback(videoId: "fixture", cancellation: nil) { result in
    check((try? result.get()) != nil, "load should succeed")
    done = true
}
waitFor { done }
check(attempts == ["mp4:2160p30", "webm:2160p30"], "try every 4K path before lowering quality")
check(chain.hasNextCandidate, "runtime recovery retains remaining ranked candidates")
check(chain.name == "webm", "successful WebM candidate owns the chain")
check(mp4.releases > 0, "failed candidate releases delivery resources")
done = false
chain.advance(videoId: "fixture", cancellation: nil) { _ in done = true }
waitFor { done }
check(attempts.last == "mp4:1440p30", "runtime fallback continues ranked candidates")
check(webm.currentQuality == nil, "advancing releases the previous delivery")

VideoQualityStore.maxHeight = 1080
attempts = []
done = false
chain.loadPlayback(videoId: "fixture", cancellation: nil) { _ in done = true }
waitFor { done }
check(!chain.hasNextCandidate, "runtime recovery stops when the ranked plan is exhausted")
check(attempts == ["native:1080p30"], "quality cap excludes higher tiers")

let ranked = PlaybackCandidate.ranked([
    .init(stepIndex: 0, quality: tier(1080), delivery: .native),
    .init(stepIndex: 1, quality: tier(1080, 60), delivery: .generatedHLS),
    .init(stepIndex: 2, quality: tier(1080, 60), delivery: .native),
    .init(stepIndex: 3, quality: tier(1080, 60), delivery: .native),
    .init(stepIndex: 4, quality: nil, delivery: .native)
], maximumHeight: 1080)
check(ranked.map(\.stepIndex) == [2, 3, 1, 0, 4], "fps, native delivery, manual order, unknown last")

let slow = FakeSource("slow", [])
slow.hangs = true
let timed = FallbackChainSource(steps: [step(slow, .native)], apiClient: WatchService(),
                                probeTimeout: 0.02)
attempts = []
done = false
timed.loadPlayback(videoId: "fixture", cancellation: nil) { _ in done = true }
waitFor { done }
check(attempts == ["slow:default"], "unavailable metadata remains a bounded last resort")
slow.deferredProbe?([tier(1080)])
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
check(attempts.count == 1, "late probe cannot restart playback")

attempts = []
done = false
let cancelled = CancellationToken()
timed.loadPlayback(videoId: "fixture", cancellation: cancelled) { _ in done = true }
cancelled.cancel()
slow.deferredProbe?([tier(1080)])
RunLoop.main.run(until: Date().addingTimeInterval(0.04))
check(!done && attempts.isEmpty, "cancellation silences discovery and playback")

timed.loadPlayback(videoId: "old", cancellation: nil) { _ in done = true }
let stale = slow.deferredProbe
timed.releaseResources()
stale?([tier(1080)])
RunLoop.main.run(until: Date().addingTimeInterval(0.04))
check(!done && attempts.isEmpty, "released chain ignores stale probes")

let empty = FallbackChainSource(steps: [], apiClient: WatchService())
done = false
empty.loadPlayback(videoId: "fixture", cancellation: nil) { result in
    check((try? result.get()) == nil, "empty chain reports failure")
    done = true
}
waitFor { done }
// A preferred dub must not bypass the composite's quality policy.
VideoQualityStore.maxHeight = 2160
let fourK = FakeSource("4k-native", [tier(2160)])
let dubHD = FakeSource("dub-hd", [tier(1080)])
let rankedChain = FallbackChainSource(steps: [step(dubHD, .generatedHLS), step(fourK, .native)],
                                      apiClient: WatchService())
let dubbed = AutoDubSource(wrapping: rankedChain, dubSource: { dubHD })
attempts = []
done = false
dubbed.loadPlayback(videoId: "fixture", cancellation: nil) { _ in done = true }
waitFor { done }
check(attempts == ["4k-native:2160p30"], "automatic dub never bypasses quality-first source")

AudioOnlyMode.isEnabled = true
attempts = []
done = false
rankedChain.loadPlayback(videoId: "fixture", cancellation: nil) { _ in done = true }
waitFor { done }
check(attempts == ["dub-hd:default"], "audio-only preserves existing source order")
AudioOnlyMode.isEnabled = false

print("Playback selection: \(assertions) assertions passed")
