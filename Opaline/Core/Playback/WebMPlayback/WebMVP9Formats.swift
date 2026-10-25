import Foundation

/// Eligibility for the opt-in direct-URL, profile-0 SDR WebM path. Packet
/// headers and actual container metadata are checked again before playback.
enum WebMVP9Formats {
    static func isVideo(_ format: DashFormatInfo) -> Bool {
        mime(format) == "video/webm"
            && WebMVP9Level.codec(format: format, configuration: nil) != nil
            && validRangeMetadata(format) && (format.width ?? 0) > 0 && (format.height ?? 0) > 0
            && (format.fps ?? 0) > 0 && durationNanoseconds(format) != nil
    }

    static func isAudio(_ format: DashFormatInfo) -> Bool {
        mime(format) == "audio/mp4" && format.codecs.lowercased() == "mp4a.40.2"
            && validRangeMetadata(format)
    }

    static func hlsCodec(_ codec: String) -> String? {
        let codec = codec.lowercased()
        if codec == "vp9" {
            return "vp09.00.00.08"
        }
        let fields = codec.split(separator: ".", omittingEmptySubsequences: false)
        guard [4, 9].contains(fields.count), fields[0] == "vp09", fields[1] == "00",
            fields[3] == "08",
            [
                "00", "10", "11", "20", "21", "30", "31", "40", "41", "50", "51", "52", "60", "61",
                "62"
            ]
            .contains(fields[2])
        else { return nil }
        if fields.count == 9 {
            guard ["00", "01"].contains(fields[4]),
                ["01", "02", "04", "05", "06", "07"].contains(fields[5]),
                ["01", "02", "04", "05", "06", "07", "08", "13"].contains(fields[6]),
                ["01", "02", "05", "06", "07"].contains(fields[7]), ["00", "01"].contains(fields[8])
            else { return nil }
        }
        return codec
    }

    private static func mime(_ format: DashFormatInfo) -> String {
        format.mimeType
            .lowercased()
            .split(separator: ";")
            .first
            .map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? ""
    }

    static func durationNanoseconds(_ format: DashFormatInfo) -> Int64? {
        guard let milliseconds = format.approxDurationMs, milliseconds > 0,
            let value = Int64(exactly: milliseconds)
        else { return nil }
        let (nanoseconds, overflow) = value.multipliedReportingOverflow(by: 1_000_000)
        return overflow ? nil : nanoseconds
    }

    static func selecting(in info: DirectPlaybackInfo, supported: Bool) -> DirectPlaybackInfo {
        let formats = supported ? info.webMVideoFormats.filter(isVideo) : []
        let audio = info.allDashAudioFormats.filter(isAudio)
        let selectedAudio = preferredAudio(in: info, catalog: audio)
        let cap = VideoQualityStore.maxHeight ?? Int.max
        let selected = formats.first { ($0.height ?? Int.max) <= cap }
        return DirectPlaybackInfo(
            hlsManifestURL: nil,
            dashManifestURL: nil,
            progressiveURL: nil,
            videoURL: selected?.url,
            audioURL: selectedAudio?.url,
            serverAbrStreamingURL: info.serverAbrStreamingURL,
            videoPlaybackUstreamerConfig: info.videoPlaybackUstreamerConfig,
            onesieUstreamerConfig: info.onesieUstreamerConfig,
            sabrVideoFormat: info.sabrVideoFormat,
            sabrAudioFormat: info.sabrAudioFormat,
            videoItag: selected?.itag,
            audioItag: selectedAudio?.itag,
            qualityLabel: selected?.qualityLabel,
            visitorData: info.visitorData,
            hasPlaybackUstreamerConfig: info.hasPlaybackUstreamerConfig,
            dashVideoFormat: selected,
            dashAudioFormat: selectedAudio,
            allDashVideoFormats: formats,
            allDashAudioFormats: audio,
            duration: selected.flatMap(durationNanoseconds).map { Double($0) / 1e9 },
            playbackTrackingURLs: info.playbackTrackingURLs,
            captionTracks: info.captionTracks,
            webMVideoFormats: info.webMVideoFormats
        )
    }

    private static func preferredAudio(
        in info: DirectPlaybackInfo, catalog: [DashFormatInfo]
    ) -> DashFormatInfo? {
        info.dashAudioFormat.flatMap { isAudio($0) ? $0 : nil }
            ?? catalog.first(where: \.audioIsOriginal) ?? catalog.first
    }

    private static func validRangeMetadata(_ format: DashFormatInfo) -> Bool {
        format.hasDirectURL && format.url.host?.isEmpty == false
            && ["https", "http"].contains(format.url.scheme?.lowercased() ?? "")
            && format.sigChallenge == nil && format.contentLength > 0
            && format.initRangeEnd >= 0 && format.indexRangeStart > format.initRangeEnd
            && format.indexRangeEnd >= format.indexRangeStart
            && Int64(format.indexRangeEnd) < format.contentLength
            && (1...1_000_000_000).contains(format.bitrate)
    }
}
