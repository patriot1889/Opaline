import Foundation

/// Transport preference only: every candidate must already pass its source's
/// codec/hardware checks. Remuxing does not imply software decoding.
enum PlaybackDeliveryPreference: Int {
    case native = 0
    case generatedHLS = 1
    case remuxedWebM = 2
}

struct PlaybackCandidate {
    let stepIndex: Int
    let quality: VideoQuality?
    let delivery: PlaybackDeliveryPreference

    static func ranked(_ candidates: [Self], maximumHeight: Int) -> [Self] {
        candidates.filter {
            guard let height = $0.quality?.height else {
                return $0.quality == nil
            }
            return height > 0 && height <= maximumHeight
        }
        .sorted { lhs, rhs in
            let left = [
                lhs.quality?.height ?? 0, lhs.quality?.fps ?? 0,
                -lhs.delivery.rawValue, -lhs.stepIndex
            ]
            let right = [
                rhs.quality?.height ?? 0, rhs.quality?.fps ?? 0,
                -rhs.delivery.rawValue, -rhs.stepIndex
            ]
            return right.lexicographicallyPrecedes(left)
        }
    }
}
