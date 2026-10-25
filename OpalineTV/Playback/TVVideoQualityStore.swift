import Foundation

enum VideoQualityStore {
    /// Higher tiers require a hardware-supported AV1 or VP9 delivery.
    static var options: [String] {
        options(supportsAV1: AV1Support.isHardwareSupported,
                supportsVP9: NativeHLSCodecs.isVP9HardwareSupported)
    }

    static func options(supportsAV1: Bool, supportsVP9: Bool) -> [String] {
        var opts = ["Auto", "1080p", "720p", "480p", "360p"]
        if supportsAV1 || supportsVP9 {
            opts.insert(contentsOf: ["2160p", "1440p"], at: 1)
        }
        return opts
    }
    /// What playback should use right now. Wi-Fi and cellular each keep
    /// their own choice, as in the official app: one setting either wasted
    /// mobile data or made every video on Wi-Fi start at a low tier (#108).
    static var selected: String {
        NetworkType.isCellular ? cellular : wifi
    }
    static var wifi: String {
        get { stored(UserDefaultsKeys.VideoQuality.selected) }
        set { store(newValue, forKey: UserDefaultsKeys.VideoQuality.selected) }
    }
    static var cellular: String {
        get { stored(UserDefaultsKeys.VideoQuality.selectedCellular) }
        set { store(newValue, forKey: UserDefaultsKeys.VideoQuality.selectedCellular) }
    }
    /// Returns the maximum height for the selected quality. "Auto" caps at
    /// 1080p — the pre-AV1 behavior; higher tiers are explicit opt-in.
    static var maxHeight: Int? {
        [
            "2160p": 2_160, "1440p": 1_440, "1080p": 1_080,
            "720p": 720, "480p": 480, "360p": 360
        ][selected] ?? 1_080
    }

    /// Display text for a stored value — "Auto" is a stored constant
    /// (never localized in UserDefaults), only its display is translated.
    static func displayName(_ quality: String) -> String {
        quality == "Auto"
            ? "settings.quality.auto".localized : quality
    }

    private static func stored(_ key: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? "Auto"
    }

    private static func store(_ quality: String, forKey key: String) {
        UserDefaults.standard.set(quality, forKey: key)
    }
}
