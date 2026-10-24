import AVFoundation
import VideoToolbox

/// Native HLS may carry VP9 in MP4 even when the adaptive ladder is WebM.
/// Registration must happen before asking AVFoundation about those codecs.
enum NativeHLSCodecs {
    static let isVP9HardwareSupported: Bool = {
        guard #available(iOS 26.2, tvOS 26.2, *) else {
            return false
        }
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)
    }()

    static func isPlayable(_ codecs: String) -> Bool {
        let vp9 = isVP9HardwareSupported
        let names = codecs.lowercased().split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard names.contains(where: {
            $0.hasPrefix("avc1") || $0.hasPrefix("avc3")
                || (vp9 && $0.hasPrefix("vp09"))
                || (AV1Support.isHardwareSupported && $0.hasPrefix("av01"))
        }), !names.contains(where: { $0.hasPrefix("vp09") && !vp9 }),
        !names.contains(where: { $0.hasPrefix("av01") && !AV1Support.isHardwareSupported }) else {
            return false
        }
        return AVURLAsset.isPlayableExtendedMIMEType("video/mp4; codecs=\"\(codecs)\"")
    }

    /// Filter before deduplicating: an unsupported rendition must not hide
    /// a playable one at the same resolution and frame rate.
    static func variants(
        playlist: String,
        baseURL: URL,
        accepts: (String) -> Bool = isPlayable
    ) -> [LiveHLSVariant] {
        var seen = Set<String>()
        return LiveHLSVariants.parse(playlist: playlist, baseURL: baseURL, deduplicate: false)
            .filter { accepts($0.codecs) }
            .sorted { lhs, rhs in
                let left = [
                    lhs.quality.height ?? 0, lhs.quality.fps ?? 0,
                    preference(lhs.codecs), lhs.bandwidth
                ]
                let right = [
                    rhs.quality.height ?? 0, rhs.quality.fps ?? 0,
                    preference(rhs.codecs), rhs.bandwidth
                ]
                return right.lexicographicallyPrecedes(left)
            }
            .filter { seen.insert($0.quality.label).inserted }
    }

    private static func preference(_ codecs: String) -> Int {
        if codecs.contains("av01") {
            return 3
        }
        if codecs.contains("vp09") {
            return 2
        }
        return 1
    }
}
