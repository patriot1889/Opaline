// Only the parser's app environment is stubbed; formats pass through the shipping parser.
enum AV1Support { static var isHardwareSupported = true }
enum VideoQualityStore { static var maxHeight: Int? = 1_080 }
enum AppLog { static func innertube(_ text: String) {} }
protocol LocalePreferences { var hl: String { get }; var gl: String { get } }
struct DefaultLocalePreferences: LocalePreferences { let hl = "en"; let gl = "US" }
final class InnertubeClient {
    static let sigChallengeKey = "ytliteSigChallenge"
    static let sigParamKey = "ytliteSigParam"
    static func extractCaptionTracks(_ json: [String: Any]) -> [SubtitleTrack] { [] }
}

func video(_ itag: Int, _ codec: String, _ height: Int, _ fps: Int, _ bitrate: Int) -> [String: Any] {
    [
        "itag": itag, "mimeType": "video/mp4; codecs=\"\(codec)\"",
        "height": height, "fps": fps, "bitrate": bitrate,
        "qualityLabel": fps > 30 ? "\(height)p\(fps)" : "\(height)p",
        "initRange": ["end": "739"], "indexRange": ["start": "740", "end": "1000"],
        "contentLength": "1000000"
    ]
}

func parse(_ formats: [[String: Any]]) -> DirectPlaybackInfo {
    // URL-less adaptive formats also exercise the signed-in TV/SABR path.
    InnertubeClient.parseDirectPlaybackInfo([
        "streamingData": [
            "serverAbrStreamingUrl": "https://example.com/sabr", "adaptiveFormats": formats
        ]
    ])!
}

let avc = video(137, "avc1.640028", 1_080, 30, 5_000_000)
let av1 = video(399, "av01.0.08M.08", 1_080, 30, 2_000_000)
let uhd = video(401, "av01.0.12M.08", 2_160, 30, 9_000_000)
let vp9 = video(313, "vp09.00.50.08", 2_160, 30, 10_000_000)
for formats in [[avc, av1, uhd, vp9], [vp9, uhd, av1, avc]] {
    let info = parse(formats)
    precondition(info.videoItag == 399, "AV1 should win at 1080p despite AVC's higher bitrate")
    precondition(info.allDashVideoFormats.map(\.itag) == [401, 399, 137],
                 "Quality-picker ordering must match initial selection and exclude VP9")
    precondition(info.dashVideoFormat?.hasDirectURL == false, "SABR formats must remain selectable")
}

VideoQualityStore.maxHeight = 2_160
precondition(parse([avc, av1, uhd]).videoItag == 401, "Explicit UHD must still select 2160p")
AV1Support.isHardwareSupported = false
let unsupported = parse([avc, av1, uhd, vp9])
precondition(unsupported.videoItag == 137, "Unsupported hardware must retain AVC playback")
precondition(unsupported.allDashVideoFormats.map(\.itag) == [137], "AV1 must stay out of the picker")

AV1Support.isHardwareSupported = true
VideoQualityStore.maxHeight = 1_080
let avc60 = video(299, "avc1.64002a", 1_080, 60, 6_000_000)
precondition(parse([av1, avc60]).videoItag == 299, "Codec preference must not reduce frame rate")
let lowerAV1 = video(398, "av01.0.05M.08", 720, 60, 1_000_000)
precondition(parse([lowerAV1, avc]).videoItag == 137, "Codec preference must not reduce resolution")
let av1HigherRate = video(400, "av01.0.08M.08", 1_080, 30, 3_000_000)
precondition(parse([av1HigherRate, av1]).videoItag == 400, "Same-codec bitrate ordering must remain")
precondition(!InnertubeClient.videoFormatLess(av1, av1), "Ordering must be strict for equal formats")
print("Video format checks passed")

let vision = VisionOSClient()
let context = vision.innertubeContext["context"] as! [String: Any]
let clientJSON = context["client"] as! [String: Any]
let sabrIdentity = Protobuf.parse(vision.sabrClientInfo())
precondition(clientJSON["deviceModel"] as? String == "RealityDevice17,1",
             "Player requests must advertise the AV1-capable Vision Pro profile")
precondition(clientJSON["osVersion"] as? String == "26.5.23O471",
             "Player requests must use the OS version for the current client profile")
precondition(sabrIdentity.string(13) == clientJSON["deviceModel"] as? String,
             "SABR must advertise the same model as the player request")
precondition(sabrIdentity.string(19) == clientJSON["osVersion"] as? String,
             "SABR must advertise the same OS as the player request")
precondition(sabrIdentity.string(17) == vision.version,
             "SABR and HTTP client versions must agree")
print("VisionOS client identity checks passed")
