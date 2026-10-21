import UIKit
import XCTest
@testable import OpalineTV

@MainActor
final class PlayerControlsTests: XCTestCase {
    func testTimelineCentrePressActivatesOnReleaseAndCancellationDoesNotActivate() {
        let timeline = TVPlayerTimeline()
        let press: Set<UIPress> = [TimelineCentrePress()]
        var activations = 0
        timeline.addAction(UIAction { _ in activations += 1 }, for: .primaryActionTriggered)
        timeline.pressesBegan(press, with: nil)
        XCTAssertEqual(activations, 0)
        timeline.pressesEnded(press, with: nil)
        XCTAssertEqual(activations, 1)
        timeline.pressesBegan(press, with: nil)
        timeline.pressesCancelled(press, with: nil)
        XCTAssertEqual(activations, 1)
        timeline.isEnabled = false
        timeline.pressesEnded(press, with: nil)
        XCTAssertEqual(activations, 1)
    }

    func testTimelineScrubsContinuouslyAndCommitsOnlyOnRelease() {
        let timeline = TVPlayerTimeline(frame: CGRect(x: 0, y: 0, width: 1000, height: 30))
        timeline.duration = 200
        timeline.fraction = 0.25
        var seeks: [Double] = []
        var scrubbing: [Bool] = []
        timeline.onSeekTo = { seeks.append($0) }
        timeline.onScrubbingChanged = { scrubbing.append($0) }

        timeline.beginScrubbing()
        timeline.updateScrubbing(translation: 100)
        XCTAssertEqual(timeline.fraction, 0.275, accuracy: 0.001)
        timeline.updateScrubbing(translation: 300)
        XCTAssertEqual(timeline.fraction, 0.325, accuracy: 0.001)
        XCTAssertTrue(seeks.isEmpty)
        timeline.endScrubbing(cancelled: false)
        timeline.endScrubbing(cancelled: false)
        XCTAssertEqual(seeks.count, 1)
        XCTAssertEqual(seeks.first ?? 0, 65, accuracy: 0.001)
        XCTAssertEqual(scrubbing, [true, false])

        timeline.beginScrubbing()
        timeline.updateScrubbing(translation: 8000)
        XCTAssertEqual(timeline.fraction, 1)
        timeline.updateScrubbing(translation: -8000)
        XCTAssertEqual(timeline.fraction, 0)
        timeline.endScrubbing(cancelled: false)
        XCTAssertEqual(seeks.last, 0)
    }

    func testScrubPreviewIgnoresPlaybackTicksAndCancellationRestoresPosition() {
        let chrome = TVPlayerChrome(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        chrome.layoutIfNeeded()
        chrome.updateTime(seconds: 60, total: 600, playing: true)
        var seeks: [Double] = []
        chrome.timeline.onSeekTo = { seeks.append($0) }
        chrome.timeline.beginScrubbing()
        chrome.timeline.updateScrubbing(translation: chrome.timeline.bounds.width / 2)
        XCTAssertEqual(chrome.elapsed.text, "2:15")
        chrome.updateTime(seconds: 61, total: 600, playing: false)
        XCTAssertEqual(chrome.elapsed.text, "2:15")
        XCTAssertEqual(chrome.timeline.fraction, 0.225, accuracy: 0.001)
        chrome.timeline.endScrubbing(cancelled: true)
        XCTAssertEqual(chrome.elapsed.text, "1:00")
        XCTAssertEqual(chrome.timeline.fraction, 0.1, accuracy: 0.001)
        XCTAssertFalse(chrome.timeline.isScrubbing)
        XCTAssertTrue(seeks.isEmpty)
    }

    func testTimelineStepsClampAndUnavailableDurationsCannotScrub() {
        let timeline = TVPlayerTimeline()
        timeline.duration = 100
        timeline.fraction = 0.95
        var seeks: [Double] = []
        timeline.onSeekTo = { seeks.append($0) }
        timeline.step(by: 10)
        timeline.step(by: -200)
        XCTAssertEqual(seeks, [100, 0])
        for duration in [0, -1, Double.nan, .infinity] {
            timeline.duration = duration
            timeline.beginScrubbing()
            timeline.step(by: 10)
            XCTAssertFalse(timeline.isScrubbing)
        }
        timeline.duration = 100
        timeline.isEnabled = false
        timeline.beginScrubbing()
        timeline.step(by: 10)
        XCTAssertFalse(timeline.isScrubbing)
        XCTAssertEqual(seeks, [100, 0])
    }

    func testPlayerChromeLayoutAndTransportState() {
        let chrome = TVPlayerChrome(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let video = Video(id: "fixture", title: "A journey through the mountains", channelId: "channel",
                          channelName: "Opaline Travel", channelAvatarURL: nil, thumbnailURL: "",
                          viewCount: "721K views", publishedAt: "18 hours ago", duration: "12:00")
        chrome.update(video: video)
        chrome.updateTime(seconds: 65, total: 720, playing: false)
        chrome.layoutIfNeeded()
        XCTAssertEqual(chrome.elapsed.text, "1:05")
        XCTAssertEqual(chrome.duration.text, "12:00")
        XCTAssertEqual(chrome.play.accessibilityLabel, "Play")
        XCTAssertEqual(chrome.timeline.fraction, 65.0 / 720, accuracy: 0.001)
        XCTAssertFalse(chrome.descriptionButton.frame.intersects(chrome.previous.frame))
        XCTAssertFalse(chrome.nextButton.frame.intersects(chrome.comments.frame))
        let controls = [chrome.channel, chrome.descriptionButton, chrome.previous, chrome.play,
                        chrome.nextButton, chrome.like, chrome.dislike, chrome.subscribe, chrome.comments, chrome.captions, chrome.settings]
        for control in controls {
            XCTAssertTrue(chrome.bounds.contains(control.convert(control.bounds, to: chrome)))
        }
        savePreview(chrome, name: "player-controls")
        chrome.updateTime(seconds: 0, total: .nan, playing: true)
        XCTAssertFalse(chrome.timeline.isEnabled)
        XCTAssertEqual(chrome.duration.text, "LIVE")
    }

    func testPlayerPanelCardsWrapAndRemainReachable() throws {
        let controller = TVPlayerPanel(style: .plain)
        controller.panelTitle = "Comments 722"
        var selected = false
        controller.cards = [
            .init(title: "@Opaline · 19 hours ago", body: String(repeating: "A thoughtful comment about this video. ", count: 8), footer: "♡ 37    ▢ 4"),
            .init(title: "Load more comments", body: "", action: { selected = true })
        ]
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 630, height: 1000)
        controller.view.layoutIfNeeded()
        let cell = try XCTUnwrap(controller.tableView.cellForRow(at: IndexPath(row: 0, section: 0)))
        XCTAssertFalse(cell.contentView.hasAmbiguousLayout)
        XCTAssertLessThan(controller.tableView.rectForRow(at: IndexPath(row: 0, section: 0)).height, 800)
        controller.tableView(controller.tableView, didSelectRowAt: IndexPath(row: 1, section: 0))
        XCTAssertTrue(selected)
        savePreview(controller.view, name: "player-comments")
    }

    private func savePreview(_ view: UIView, name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { view.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/opaline-\(name).png"))
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

private final class TimelineCentrePress: UIPress {
    override var type: UIPress.PressType { .select }
}
