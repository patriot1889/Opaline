import Foundation

/// Never part of the enabled chain by default. Reuses the normal adaptive
/// source's quality/dub selection while keeping WebM out of MP4/SABR ladders.
struct WebMVP9DeliveryFactory: StreamDeliveryFactory {
    let label = "webm"
    private let supportsVP9: () -> Bool

    init(supportsVP9: @escaping () -> Bool = { NativeHLSCodecs.isVP9HardwareSupported }) {
        self.supportsVP9 = supportsVP9
    }

    func playbackInfo(_ info: DirectPlaybackInfo) -> DirectPlaybackInfo {
        WebMVP9Formats.selecting(in: info, supported: supportsVP9())
    }

    func canServe(_ info: DirectPlaybackInfo) -> Bool {
        supportsVP9() && info.dashVideoFormat.map(WebMVP9Formats.isVideo) == true
            && info.dashAudioFormat.map(WebMVP9Formats.isAudio) == true
    }

    func make(client: PlaybackClient, transport: HTTPTransport, poToken: Data?) -> StreamDelivery {
        WebMStreamDelivery(client: client, transport: transport)
    }
}
