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
var probes: [String] = []
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
        probes.append(name)
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
let chain = FallbackChainSource(steps: [step(native, .native), step(mp4, .generatedHLS),
                                      step(webm, .remuxedWebM)], apiClient: WatchService())
var done = false
chain.loadPlayback(videoId: "fixture", cancellation: nil) { result in
    check((try? result.get()) != nil, "load should succeed")
    done = true
}
waitFor { done }
check(attempts == ["mp4:2160p30", "webm:2160p30"], "try requested resolution in source order before lowering quality")
check(probes == ["native", "mp4", "webm"], "sources are checked in saved order")
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
probes = []
done = false
chain.loadPlayback(videoId: "fixture", cancellation: nil) { _ in done = true }
waitFor { done }
check(chain.hasNextCandidate, "unvisited sources remain available for runtime recovery")
check(probes == ["native"], "target success skips every later source probe")
check(attempts == ["native:1080p30"], "quality cap excludes higher tiers")

// Within a source choose the highest frame rate, then stop at the selected resolution.
let preferred = FakeSource("preferred", [tier(1080, 30), tier(1080, 60)])
let laterNative = FakeSource("later-native", [tier(1080, 120)])
let ordered = FallbackChainSource(steps: [step(preferred, .generatedHLS), step(laterNative, .native)],
                                  apiClient: WatchService())
attempts = []; probes = []; done = false
ordered.loadPlayback(videoId: "fixture", cancellation: nil) { _ in done = true }
waitFor { done }
check(attempts == ["preferred:1080p60"], "selected resolution uses best frame rate within first source")
check(probes == ["preferred"], "later native delivery or higher fps does not override saved order")
done = false
ordered.advance(videoId: "fixture", cancellation: nil) { _ in done = true }
waitFor { done }
check(attempts.last == "preferred:1080p30", "recovery can try another target tier on the same source")
done = false
ordered.advance(videoId: "fixture", cancellation: nil) { _ in done = true }
waitFor { done }
check(probes == ["preferred", "later-native"], "recovery discovers the next source on demand")
check(attempts.last == "later-native:1080p120", "recovery prepares the next source")
check(!ordered.hasNextCandidate, "recovery stops after every candidate and source is exhausted")

// YouTube's named resolution also applies to cropped/wide-aspect formats.
let wide = FakeSource("wide", [VideoQuality(id: "wide", label: "1080p", height: 1012, fps: 30)])
let wideChain = FallbackChainSource(steps: [step(wide, .generatedHLS), step(laterNative, .native)],
                                    apiClient: WatchService())
attempts = []; probes = []; done = false
wideChain.loadPlayback(videoId: "fixture", cancellation: nil) { _ in done = true }
waitFor { done }
check(attempts == ["wide:1080p"] && probes == ["wide"], "named resolution satisfies target for cropped video")

// If nobody meets the target, compare all retained lower tiers before playing.
VideoQualityStore.maxHeight = 2160
let fallbackLow = FakeSource("fallback-low", [tier(720)])
let fallbackHD = FakeSource("fallback-hd", [tier(1080)])
let lowerChain = FallbackChainSource(steps: [step(fallbackLow, .native), step(fallbackHD, .generatedHLS)],
                                     apiClient: WatchService())
attempts = []; probes = []; done = false
lowerChain.loadPlayback(videoId: "fixture", cancellation: nil) { _ in done = true }
waitFor { done }
check(probes == ["fallback-low", "fallback-hd"], "below-target source does not prevent later discovery")
check(attempts == ["fallback-hd:1080p30"], "best retained fallback wins when target is unavailable")

// A hanging first probe cannot start the second in parallel.
let held = FakeSource("held", [])
held.hangs = true
let ready = FakeSource("ready", [tier(2160)])
let serial = FallbackChainSource(steps: [step(held, .native), step(ready, .native)],
                                 apiClient: WatchService(), probeTimeout: 0.05)
attempts = []; probes = []; done = false
serial.loadPlayback(videoId: "fixture", cancellation: nil) { _ in done = true }
check(probes == ["held"], "next source waits for the first probe to finish or time out")
waitFor { done }
check(probes == ["held", "ready"] && attempts == ["ready:2160p30"], "probe deadline moves to next source")
held.deferredProbe?([tier(2160)])
RunLoop.main.run(until: Date().addingTimeInterval(0.01))
check(attempts.count == 1, "late earlier source cannot replace selected playback")

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
