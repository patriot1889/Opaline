import UIKit
import XCTest
@testable import OpalineTV

@MainActor
final class PlayerControlsTests: XCTestCase {
    func testRemoteSeekingClampsAndAccumulates() {
        let bar = TVSeekBar()
        bar.duration = 100
        bar.position = 95
        var positions: [Double] = []
        bar.onSeek = { positions.append($0) }
        bar.accessibilityIncrement()
        bar.accessibilityDecrement()
        bar.accessibilityDecrement()
        XCTAssertEqual(positions, [100, 90, 80])
        bar.position = 4
        bar.accessibilityDecrement()
        XCTAssertEqual(positions.last, 0)
        bar.duration = .infinity
        bar.accessibilityIncrement()
        XCTAssertEqual(positions.count, 4)
    }

    func testTimelinePreservesCategoryColoursBeforeAndAfterPlayhead() {
        let bar = TVSeekBar(frame: CGRect(x: 0, y: 0, width: 432, height: 64))
        bar.duration = 100
        bar.position = 50
        bar.segments = [
            SponsorBlockSegment(uuid: "a", category: .sponsor, startTime: 10, endTime: 20, actionType: "skip"),
            SponsorBlockSegment(uuid: "b", category: .intro, startTime: 70, endTime: 80, actionType: "skip")
        ]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: bar.bounds, format: format).image { _ in
            bar.draw(bar.bounds)
        }
        // Read known interior points, away from antialiased edges and the thumb.
        func pixel(_ x: Int) -> [UInt8] {
            let cgImage = image.cgImage!
            let data = cgImage.dataProvider!.data! as Data
            let offset = 32 * cgImage.bytesPerRow + x * 4
            return Array(data[offset..<offset + 3])
        }
        XCTAssertNotEqual(pixel(76), pixel(136))
        XCTAssertNotEqual(pixel(316), pixel(356))
        XCTAssertNotEqual(pixel(76), pixel(316))
    }

    func testTransportLayout() {
        let view = TVTransportView(frame: CGRect(x: 0, y: 0, width: 1728, height: 300))
        view.titleLabel.text = "Opaline · SponsorBlock timeline"
        view.update(position: 135, duration: 600, buffered: 240, playing: false)
        view.setSegments([
            SponsorBlockSegment(uuid: "a", category: .sponsor, startTime: 20, endTime: 70, actionType: "skip"),
            SponsorBlockSegment(uuid: "b", category: .intro, startTime: 190, endTime: 220, actionType: "skip")
        ])
        view.layoutIfNeeded()
        XCTAssertFalse(view.hasAmbiguousLayout)
        XCTAssertGreaterThan(view.seekBar.bounds.width, 1500)
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { view.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "TV SponsorBlock transport"
        attachment.lifetime = .keepAlways
        add(attachment)
        try? image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/opaline-transport-preview.png"))
    }

    func testUpNextUsesElapsedTimeAndCompletesOnlyOnce() {
        var time: TimeInterval = 100
        let controller = TVUpNextController(video: Video(id: "fixture"), now: { time })
        controller.loadViewIfNeeded()
        var plays = 0
        var cancels = 0
        controller.onPlay = { plays += 1 }
        controller.onCancel = { cancels += 1 }
        controller.startCountdown()
        time = 104.9
        controller.updateCountdown()
        XCTAssertEqual(plays, 0)
        time = 107 // A delayed timer must still finish immediately at the deadline.
        controller.updateCountdown()
        controller.playNow()
        controller.cancel()
        XCTAssertEqual(plays, 1)
        XCTAssertEqual(cancels, 0)
    }

    func testUpNextCancelAndDismissalPreventAutoplay() {
        for cancel in [true, false] {
            var time: TimeInterval = 0
            let controller = TVUpNextController(video: Video(id: "fixture"), now: { time })
            controller.loadViewIfNeeded()
            var plays = 0
            var cancels = 0
            controller.onPlay = { plays += 1 }
            controller.onCancel = { cancels += 1 }
            controller.startCountdown()
            if cancel { controller.cancel() } else { controller.viewWillDisappear(false) }
            time = 10
            controller.updateCountdown()
            controller.startCountdown()
            controller.playNow()
            XCTAssertEqual(plays, 0)
            XCTAssertEqual(cancels, cancel ? 1 : 0)
        }
    }

    func testUpNextPlayNowAndLayout() {
        let video = Video(id: "fixture", title: "A journey through the mountains — the next adventure",
                          channelId: nil, channelName: "Opaline Travel", channelAvatarURL: nil,
                          thumbnailURL: "", viewCount: nil, publishedAt: nil, duration: nil)
        let controller = TVUpNextController(video: video)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        controller.view.layoutIfNeeded()
        XCTAssertFalse(controller.view.hasAmbiguousLayout)
        var plays = 0
        controller.onPlay = { plays += 1 }
        let play = controller.preferredFocusEnvironments.first as? UIButton
        XCTAssertEqual(play?.accessibilityIdentifier, "TV.upNextPlay")
        play?.sendActions(for: .primaryActionTriggered)
        controller.playNow()
        XCTAssertEqual(plays, 1)
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image {
            controller.view.layer.render(in: $0.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "TV Up Next"
        attachment.lifetime = .keepAlways
        add(attachment)
        try? image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/opaline-up-next-preview.png"))
    }
}
