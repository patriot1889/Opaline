import VideoToolbox

/// AV1 remains hardware-gated. Native HLS separately checks supplemental VP9.
enum AV1Support {
    static let isHardwareSupported: Bool = {
        guard #available(iOS 17.4, tvOS 17.4, *) else {
            return false
        }
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    }()
}
