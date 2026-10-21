import AVKit
import XCTest
@testable import OpalineTV

@MainActor
final class DisplayModeTests: XCTestCase {
    func testVideoModeSurvivesRebindingAndItemReplacementUntilPlaybackCloses() async throws {
        let previous = try criteria(refreshRate: 60)
        let video = try criteria(refreshRate: 24)
        let destination = DisplayDestination(criteria: previous)
        let mode = TVPlaybackDisplayMode(loadCriteria: { _ in video })

        // Media can become ready before the player has entered its UIWindow.
        await mode.update(for: AVMutableComposition()).value
        mode.bind(to: destination)
        XCTAssertTrue(destination.preferredDisplayCriteria === video)
        XCTAssertEqual(destination.writes, 1)

        // Reappearing after a panel or alert and preparing a replacement item must not reset HDMI.
        mode.bind(to: destination)
        mode.cancelPendingUpdate()
        XCTAssertTrue(destination.preferredDisplayCriteria === video)
        XCTAssertEqual(destination.writes, 1)

        mode.restore()
        XCTAssertTrue(destination.preferredDisplayCriteria === previous)
        XCTAssertEqual(destination.writes, 2)
    }

    func testClosingPlayerRejectsLateCriteriaLoad() async throws {
        let previous = try criteria(refreshRate: 60)
        let video = try criteria(refreshRate: 24)
        let destination = DisplayDestination(criteria: previous)
        let mode = TVPlaybackDisplayMode(loadCriteria: { _ in video })
        mode.bind(to: destination)
        let pending = mode.update(for: AVMutableComposition())
        mode.restore()
        await pending.value
        XCTAssertTrue(destination.preferredDisplayCriteria === previous)
        XCTAssertEqual(destination.writes, 1)
    }

    private func criteria(refreshRate: Float) throws -> AVDisplayCriteria {
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264, width: 1920, height: 1080,
            extensions: nil, formatDescriptionOut: &format), noErr)
        return AVDisplayCriteria(refreshRate: refreshRate, formatDescription: try XCTUnwrap(format))
    }
}

private final class DisplayDestination: TVDisplayCriteriaDestination {
    var writes = 0
    var preferredDisplayCriteria: AVDisplayCriteria? { didSet { writes += 1 } }
    init(criteria: AVDisplayCriteria?) { preferredDisplayCriteria = criteria }
}
