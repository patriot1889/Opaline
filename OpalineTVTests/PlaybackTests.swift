import AVFoundation
import XCTest
@testable import OpalineTV

final class PlaybackTests: XCTestCase {
    func testSourceFailureFallsBackAndReleasesResources() {
        let failed = FixtureSource(fails: true)
        let success = FixtureSource()
        let chain = makeChain([failed, success])
        let resolved = expectation(description: "Fallback resolves")
        chain.loadPlayback(videoId: "fixture", cancellation: CancellationToken()) { result in
            XCTAssertNotNil(try? result.get())
            XCTAssertEqual(failed.loads, 1)
            XCTAssertEqual(success.loads, 1)
            chain.releaseResources()
            XCTAssertEqual(failed.releases, 1)
            XCTAssertEqual(success.releases, 1)
            resolved.fulfill()
        }
        wait(for: [resolved], timeout: 2)
    }

    func testCancelledResolutionDoesNotStartSource() {
        let source = FixtureSource()
        let chain = makeChain([source])
        let token = CancellationToken()
        token.cancel()
        chain.loadPlayback(videoId: "fixture", cancellation: token) { _ in XCTFail("Cancelled callback") }
        XCTAssertEqual(source.loads, 0)
    }

    func testRecoveryAdvancesAndSwitchesPreserveRequestedPosition() {
        let first = FixtureSource()
        let next = FixtureSource()
        let chain = makeChain([first, next])
        chain.loadPlayback(videoId: "fixture", cancellation: nil) { _ in }
        chain.advance(videoId: "fixture", cancellation: nil) { _ in }
        XCTAssertTrue(chain.active === next)
        let quality = VideoQuality(id: "720", label: "720p", height: 720, fps: 30)
        chain.selectQuality(quality, resumeAt: 123) { result in
            XCTAssertEqual(try? result.get().startsAt, 123)
        }
        let audio = AudioTrack(id: "en.3", displayName: "English", isDefault: false)
        chain.selectAudioTrack(audio, resumeAt: 456) { result in
            XCTAssertEqual(try? result.get().startsAt, 456)
        }
    }

    func testExhaustedSourcesReturnFailure() {
        let chain = makeChain([FixtureSource(fails: true)])
        let finished = expectation(description: "Exhaustion")
        chain.loadPlayback(videoId: "fixture", cancellation: nil) { result in
            if case .success = result { XCTFail("Expected failure") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func testSeekDoesNotReloadAnAlreadyPositionedSABRStream() {
        XCTAssertNil(TVPlaybackPolicy.seekPosition(requested: 60, preparedStart: 60))
        XCTAssertEqual(TVPlaybackPolicy.seekPosition(requested: 60, preparedStart: nil), 60)
        XCTAssertNil(TVPlaybackPolicy.seekPosition(requested: .nan, preparedStart: nil))
        XCTAssertNil(TVPlaybackPolicy.seekPosition(requested: -1, preparedStart: nil))
    }

    func testCaptionBoundariesAndBackwardSeek() {
        let cues = VTTParser.parse("WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nFirst\n\n00:00:03.000 --> 00:00:05.000\nSecond\n")
        XCTAssertNil(TVPlaybackPolicy.caption(at: 0, cues: cues))
        XCTAssertEqual(TVPlaybackPolicy.caption(at: 1, cues: cues), "First")
        XCTAssertEqual(TVPlaybackPolicy.caption(at: 3, cues: cues), "Second")
        XCTAssertNil(TVPlaybackPolicy.caption(at: 5, cues: cues))
        XCTAssertEqual(TVPlaybackPolicy.caption(at: 2, cues: cues), "First")
    }

    func testPlaylistBoundaryWaitsForItsOwnQueueAndDoesNotAutoplayRelatedVideo() {
        let queue = PlaybackQueue.shared
        defer { queue.clear() }
        queue.setQueue([Video(id: "first")], playlistId: "playlist", continuation: "next-page")
        XCTAssertNil(TVPlaybackPolicy.upcomingVideo(in: queue, suggestion: Video(id: "unrelated")))
        queue.appendPage(FeedPage(videos: [Video(id: "second")], continuation: nil))
        XCTAssertEqual(TVPlaybackPolicy.upcomingVideo(in: queue, suggestion: nil)?.id, "second")
        queue.seekTo(videoId: "second")
        XCTAssertNil(TVPlaybackPolicy.upcomingVideo(in: queue, suggestion: Video(id: "unrelated")))
        queue.clear()
        XCTAssertEqual(TVPlaybackPolicy.upcomingVideo(in: queue, suggestion: Video(id: "related"))?.id, "related")
    }

    private func makeChain(_ sources: [FixtureSource]) -> FallbackChainSource {
        let steps = sources.enumerated().map { index, source in
            PlaybackStep(id: "fixture\(index)", title: "Fixture", requiresSignIn: false) { _ in source }
        }
        return FallbackChainSource(steps: steps, apiClient: InnertubeClient())
    }
}

private final class FixtureSource: VideoSource {
    let name = "fixture"
    let supportsQualitySelection = true
    var availableQualities: [VideoQuality] = []
    var currentQuality: VideoQuality?
    let fails: Bool
    var loads = 0
    var releases = 0
    init(fails: Bool = false) { self.fails = fails }
    func loadPlayback(videoId: String, cancellation: CancellationToken?,
                      completion: @escaping (Result<PreparedPlayback, Error>) -> Void) {
        loads += 1
        if fails { completion(.failure(NSError(domain: "fixture", code: 1))) }
        else { completion(.success(prepared(at: nil))) }
    }
    func selectQuality(_ quality: VideoQuality, resumeAt: Double?,
                       completion: @escaping (Result<PreparedPlayback, Error>) -> Void) {
        completion(.success(prepared(at: resumeAt)))
    }
    func selectAudioTrack(_ track: AudioTrack, resumeAt: Double?,
                          completion: @escaping (Result<PreparedPlayback, Error>) -> Void) {
        completion(.success(prepared(at: resumeAt)))
    }
    func releaseResources() { releases += 1 }
    private func prepared(at position: Double?) -> PreparedPlayback {
        PreparedPlayback(item: AVPlayerItem(url: URL(fileURLWithPath: "/fixture.mp4")), startsAt: position)
    }
}
