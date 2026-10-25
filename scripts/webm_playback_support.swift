// Composition stubs for standalone source/SDK checks. Shared parser, models,
// transport, HLS helpers, WebM core and new playback adapter are real files.
import AVFoundation
import Foundation

enum APIError: Error { case transport(Error), invalidResponse }
enum AppLog {
    static func hls(_ text: String) {}
    static func player(_ text: String) {}
    static func innertube(_ text: String) {}
}
enum VideoQualityStore { nonisolated(unsafe) static var maxHeight: Int? = 4_320 }
enum AudioOnlyMode { nonisolated(unsafe) static var isEnabled = false }
enum PlaybackBufferPolicy { static func configure(item: AVPlayerItem) {} }
final class InnertubeClient {
    static let sigChallengeKey = "ytliteSigChallenge"
    static let sigParamKey = "ytliteSigParam"
    static func extractCaptionTracks(_ json: [String: Any]) -> [SubtitleTrack] { [] }
}
enum HLSStreamResolver {
    static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
// These existing delivery implementations are outside this adapter's tests.
// Their real protocol and factory definitions compile unchanged here.
enum HLSPlaybackBuilder {
    struct BuildInput {
        let videoURL: URL; let audioURL: URL; let videoFormat: DashFormatInfo; let audioFormat: DashFormatInfo
        let headers: [String: String]; let startAt: Double?
    }
    struct Result { let playerItem: AVPlayerItem; let loader: HLSPlaylistLoader }
    static func build(input: BuildInput, completion: (Result?) -> Void) { completion(nil) }
}
final class SABRDelivery: StreamDelivery {
    let label = "sabr"
    init(transport: HTTPTransport, client: PlaybackClient, poToken: Data?) {}
    static func canServe(_ info: DirectPlaybackInfo) -> Bool { info.serverAbrStreamingURL != nil && info.videoPlaybackUstreamerConfig != nil }
    func prepare(_ request: DeliveryRequest, completion: @escaping (Result<PreparedPlayback, Error>) -> Void) { completion(.failure(StreamDeliveryError.noStream)) }
}

protocol LocalePreferences { var hl: String { get }; var gl: String { get } }
struct DefaultLocalePreferences: LocalePreferences { let hl = "en"; let gl = "US" }
