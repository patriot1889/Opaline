import Foundation

/// Reads chapter metadata from watch-page responses, independently of media delivery.
enum VideoChapterParser {
    static func parse(_ json: [String: Any]) -> [VideoChapter] {
        let overlay = dictionary(json["playerOverlays"])
        let renderer = dictionary(overlay["playerOverlayRenderer"])
        let decorated = dictionary(renderer["decoratedPlayerBarRenderer"])
        let inner = dictionary(decorated["decoratedPlayerBarRenderer"])
        let bar = dictionary(inner["playerBar"])
        let chapters = playerBarChapters(bar)
        if !chapters.isEmpty {
            return chapters
        }
        return engagementChapters(json["engagementPanels"] as? [[String: Any]] ?? [])
    }

    private static func playerBarChapters(_ bar: [String: Any]) -> [VideoChapter] {
        let multi = dictionary(bar["multiMarkersPlayerBarRenderer"])
        let markers = multi["markersMap"] as? [[String: Any]] ?? []
        for marker in markers {
            let value = dictionary(marker["value"])
            let chapters = normalized(rendererChapters(value["chapters"]))
            if !chapters.isEmpty {
                return chapters
            }
        }
        let legacy = dictionary(bar["chapteredPlayerBarRenderer"])
        return normalized(rendererChapters(legacy["chapters"]))
    }

    private static func rendererChapters(_ value: Any?) -> [VideoChapter] {
        (value as? [[String: Any]] ?? []).compactMap { entry in
            let renderer = dictionary(entry["chapterRenderer"])
            guard let millis = number(renderer["timeRangeStartMillis"]),
                  let title = text(renderer["title"]) else {
                return nil
            }
            return chapter(title: title, seconds: millis / 1_000)
        }
    }

    private static func engagementChapters(_ panels: [[String: Any]]) -> [VideoChapter] {
        for panel in panels {
            let section = dictionary(panel["engagementPanelSectionListRenderer"])
            let content = dictionary(section["content"])
            let list = dictionary(content["macroMarkersListRenderer"])
            let entries = list["contents"] as? [[String: Any]] ?? []
            let chapters = normalized(entries.compactMap { entry -> VideoChapter? in
                let renderer = dictionary(entry["macroMarkersListItemRenderer"])
                guard let title = text(renderer["title"]),
                      let seconds = markerSeconds(renderer) else {
                    return nil
                }
                return chapter(title: title, seconds: seconds)
            })
            if !chapters.isEmpty {
                return chapters
            }
        }
        return []
    }

    private static func markerSeconds(_ renderer: [String: Any]) -> Double? {
        let tap = dictionary(renderer["onTap"])
        let command = dictionary(tap["innertubeCommand"])
        let navigation = dictionary(renderer["navigationEndpoint"])
        for endpoint in [tap, command, navigation] {
            let watch = dictionary(endpoint["watchEndpoint"])
            if let seconds = number(watch["startTimeSeconds"]) {
                return seconds
            }
        }
        guard let time = text(renderer["timeDescription"]) else {
            return nil
        }
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else {
            return nil
        }
        var seconds: Double = 0
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Double(part), index == 0 || value < 60 else {
                return nil
            }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    private static func chapter(title: String, seconds: Double) -> VideoChapter? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, seconds.isFinite, seconds >= 0 else {
            return nil
        }
        return VideoChapter(title: title, startTime: seconds)
    }

    private static func normalized(_ chapters: [VideoChapter]) -> [VideoChapter] {
        var starts = Set<Double>()
        return chapters.filter { starts.insert($0.startTime).inserted }
            .sorted { $0.startTime < $1.startTime }
    }

    private static func dictionary(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private static func number(_ value: Any?) -> Double? {
        if let string = value as? String {
            return Double(string)
        }
        guard let value, CFGetTypeID(value as AnyObject) != CFBooleanGetTypeID() else {
            return nil
        }
        return (value as? Double) ?? (value as? Int).map(Double.init)
    }

    private static func text(_ value: Any?) -> String? {
        let value = dictionary(value)
        if let text = value["simpleText"] as? String {
            return text
        }
        guard let runs = value["runs"] as? [[String: Any]] else {
            return nil
        }
        return runs.compactMap { $0["text"] as? String }.joined()
    }
}
