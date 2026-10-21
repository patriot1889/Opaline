import UIKit
import XCTest
@testable import OpalineTV

@MainActor
final class PlayerControlsTests: XCTestCase {
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
