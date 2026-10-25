import AVFoundation
import XCTest
@testable import OpalineTV

final class PlaybackIntegrationTests: XCTestCase {
    func testHigherQualityPreferencesIncludeHardwareVP9WithoutAV1() {
        XCTAssertTrue(VideoQualityStore.options(supportsAV1: false, supportsVP9: true).contains("2160p"))
        XCTAssertTrue(VideoQualityStore.options(supportsAV1: true, supportsVP9: false).contains("1440p"))
        XCTAssertFalse(VideoQualityStore.options(supportsAV1: false, supportsVP9: false).contains("1440p"))
    }

    func testTVRegistryPreservesOptInAndSignInEligibility() {
        withPlaybackPreferences {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: UserDefaultsKeys.Debug.playbackChainOrder)
            defaults.removeObject(forKey: UserDefaultsKeys.Debug.playbackChainEnabled)
            let registry = PlaybackStepRegistry.default
            XCTAssertEqual(registry.steps.map(\.id), PlaybackChainSettings.defaultOrder)
            XCTAssertEqual(registry.step(id: "visionos.hls")?.deliveryPreference, .native)
            XCTAssertEqual(registry.step(id: "visionos.webm")?.deliveryPreference, .remuxedWebM)
            XCTAssertFalse(PlaybackChainSettings.enabled.contains("visionos.webm"))
            XCTAssertFalse(PlaybackChainSettings.activeSteps(isSignedIn: false).contains { $0.id == "tv.sabr" })
            XCTAssertTrue(PlaybackChainSettings.activeSteps(isSignedIn: true).contains { $0.id == "tv.sabr" })
            PlaybackChainSettings.enabled.insert("visionos.webm")
            XCTAssertTrue(PlaybackChainSettings.activeSteps(isSignedIn: false).contains { $0.id == "visionos.webm" })
            PlaybackChainSettings.order = ["progressive", "visionos.range"]
            XCTAssertEqual(Array(PlaybackChainSettings.order.prefix(2)), ["progressive", "visionos.range"])
            XCTAssertTrue(PlaybackChainSettings.order.contains("visionos.hls"))
        }
    }

    func testTVChainStopsAtSelectedResolutionAndDiscoversRecoverySourcesOnDemand() {
        withPlaybackPreferences {
            VideoQualityStore.wifi = "2160p"
            let low = RankedTVSource(height: 720)
            let remux = RankedTVSource(height: 2160)
            let native = RankedTVSource(height: 2160)
            let sources = [low, remux, native]
            let deliveries: [PlaybackDeliveryPreference] = [.native, .remuxedWebM, .native]
            let steps = sources.enumerated().map { index, source in
                PlaybackStep(id: "fixture\(index)", title: "Fixture", requiresSignIn: false,
                             deliveryPreference: deliveries[index]) { _ in source }
            }
            let chain = FallbackChainSource(steps: steps, apiClient: InnertubeClient())
            defer { chain.releaseResources() }
            let loaded = expectation(description: "First source meeting selected resolution")
            chain.loadPlayback(videoId: "fixture", cancellation: nil) { result in
                XCTAssertNotNil(try? result.get())
                XCTAssertTrue(chain.active === remux)
                XCTAssertEqual(native.probes, 0)
                XCTAssertEqual(low.loads, 0)
                loaded.fulfill()
            }
            wait(for: [loaded], timeout: 2)
            for source in [native, low] {
                let recovered = expectation(description: "Remaining candidate")
                chain.advance(videoId: "fixture", cancellation: nil) { result in
                    XCTAssertNotNil(try? result.get())
                    XCTAssertTrue(chain.active === source)
                    recovered.fulfill()
                }
                wait(for: [recovered], timeout: 2)
            }
            XCTAssertFalse(chain.hasNextCandidate)
        }
    }

    private func withPlaybackPreferences(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let keys = [UserDefaultsKeys.Debug.playbackChainOrder, UserDefaultsKeys.Debug.playbackChainEnabled,
                    UserDefaultsKeys.VideoQuality.selected]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        body()
    }
}

private final class RankedTVSource: VideoSource {
    let name = "fixture"
    let supportsQualitySelection = true
    let availableQualities: [VideoQuality]
    var currentQuality: VideoQuality?
    var loads = 0
    var probes = 0
    init(height: Int) {
        availableQualities = [VideoQuality(id: "\(height)", label: "\(height)p", height: height, fps: 30)]
    }
    func probeQualities(videoId: String, completion: @escaping ([VideoQuality]) -> Void) {
        probes += 1
        completion(availableQualities)
    }
    func loadPlayback(videoId: String, cancellation: CancellationToken?,
                      completion: @escaping (Result<PreparedPlayback, Error>) -> Void) {
        loads += 1
        currentQuality = availableQualities.first
        completion(.success(PreparedPlayback(item: AVPlayerItem(url: URL(fileURLWithPath: "/fixture.mp4")))))
    }
    func selectQuality(_ quality: VideoQuality, resumeAt: Double?,
                       completion: @escaping (Result<PreparedPlayback, Error>) -> Void) {
        currentQuality = quality
        completion(.success(PreparedPlayback(item: AVPlayerItem(url: URL(fileURLWithPath: "/fixture.mp4")))))
    }
}
