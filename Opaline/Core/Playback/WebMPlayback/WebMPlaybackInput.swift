import Foundation

struct WebMPlaybackInput: Sendable {
    let video: DashFormatInfo
    let audio: DashFormatInfo
    let videoURL: URL
    let audioURL: URL
    let headers: [String: String]
    let startAt: Double?
    let audioOnly: Bool

    init(request: DeliveryRequest, client: PlaybackClient) throws {
        guard !client.needsSignatureSolver, WebMVP9Formats.isVideo(request.video),
            WebMVP9Formats.isAudio(request.audio),
            request.resumeAt.map({ $0.isFinite && $0 >= 0 }) ?? true
        else {
            throw WebMDeliveryError.invalidPlan
        }
        video = request.video
        audio = request.audio
        videoURL = client.directURL(baseURL: video.url, poToken: nil)
        audioURL = client.directURL(baseURL: audio.url, poToken: nil)
        headers = client.streamHeaders(visitorData: request.info.visitorData)
        startAt = request.resumeAt
        audioOnly = AudioOnlyMode.isEnabled
    }

    func duration(initialization: WebMInitialization?) throws -> Int64 {
        if let seconds = initialization?.durationSeconds {
            guard let value = Int64(exactly: (seconds * 1e9).rounded()), value > 0 else {
                throw WebMError.invalidTimestamp
            }
            return value
        }
        guard let value = WebMVP9Formats.durationNanoseconds(video) else {
            throw WebMError.invalidTimestamp
        }
        return value
    }
}
