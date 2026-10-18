import Foundation

// Upstream's safe subscript lives in an iOS view-controller file.
extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// TV has no offline library. Shared subtitle and SponsorBlock services can
// still use their normal online paths without copying their implementations.
enum DownloadStore {
    static func cues(language: String, for videoId: String) -> [SubtitleCue]? { nil }
    static func segments(for videoId: String) -> [SponsorBlockSegment]? { nil }
}

extension String {
    func tvLocalized(with args: CVarArg...) -> String {
        String(format: tvLocalized, arguments: args)
    }

    var tvLocalized: String {
        let bundle = LocalizationManager.shared.bundle
        let missing = "\u{0}missing"
        let value = bundle.localizedString(forKey: self, value: missing, table: "TV")
        if value != missing { return value }
        let english = Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
        return english?.localizedString(forKey: self, value: self, table: "TV") ?? self
    }
}
