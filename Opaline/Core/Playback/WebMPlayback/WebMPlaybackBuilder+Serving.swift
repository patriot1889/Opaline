import Foundation

extension WebMPlaybackBuilder {
    func serve(duration: Int64) throws {
        guard let audioIndex else { throw WebMDeliveryError.invalidPlan }
        let prefix = "/webm-playback/" + UUID().uuidString.lowercased()
        let audioPath = prefix + "/audio.m3u8"
        let entryPath = prefix + "/master.m3u8"
        var files = [audioPath: audioPlaylist(audioIndex)]
        files[entryPath] = Data(try entryPlaylist(audioPath: audioPath, audio: audioIndex).utf8)
        if let video, !input.audioOnly {
            files[video.playlistPath] = Data(
                try video.plan
                    .playlist(
                        basePath: video.basePath,
                        startAt: input.startAt
                    )
                    .utf8
            )
        }
        let playlists = WebMPlaybackSession.Playlists(
            files: files,
            entryPath: entryPath,
            video: video
        )
        attach(try WebMPlaybackSession(playlists: playlists), duration: duration)
    }

    private func audioPlaylist(_ index: WebMAudioIndex) -> Data {
        Data(
            HLSGenerator.mediaPlaylist(
                url: input.audioURL,
                initBytes: input.audio.initRangeEnd + 1,
                dataStartOffset: Int64(input.audio.indexRangeEnd) + 1,
                segments: index.segments,
                startAt: input.startAt
            )
            .utf8
        )
    }

    private func entryPlaylist(audioPath: String, audio: WebMAudioIndex) throws -> String {
        if input.audioOnly {
            return HLSGenerator.audioOnlyMainPlaylist(
                audioCodecs: input.audio.codecs,
                audioBandwidth: audio.peakBitrate,
                audioPlaylistURI: audioPath
            )
        }
        guard let video, let codecs = videoCodec else {
            throw WebMDeliveryError.invalidPlan
        }
        let peak =
            video.plan.segments
            .map { segment in
                Int(
                    ceil(
                        Double(segment.maximumRemuxBytes) * 8e9
                            / Double(segment.durationNanoseconds)
                    )
                )
            }
            .max() ?? input.video.bitrate
        return HLSGenerator.mainPlaylist(
            bandwidth: peak + audio.peakBitrate,
            codecs: "\(codecs),\(input.audio.codecs)",
            resolution: "\(input.video.width ?? 0)x\(input.video.height ?? 0)",
            uris: .init(video: video.playlistPath, audio: audioPath)
        )
    }
}
