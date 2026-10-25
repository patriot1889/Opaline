import Foundation

struct WatchService {}
struct PlaybackStep {
    let id: String
    let deliveryPreference: PlaybackDeliveryPreference
    let make: (WatchService) -> VideoSource
}

enum AutoDubPreference {
    static var isEnabled = true
    static func autoDubTrack(in tracks: [AudioTrack]) -> AudioTrack? { tracks.first }
}
extension Notification.Name {
    static let sourceAudioTracksDidChange = Notification.Name("fixture.tracks")
}

enum PlaybackProgress { static func step(_ text: String) {} }
