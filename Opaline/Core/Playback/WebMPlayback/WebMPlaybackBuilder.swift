import Foundation

/// One preparation and its resources. State is confined to queue; immutable
/// values cross callbacks. close() silences preparation and stops its session.
final class WebMPlaybackBuilder: @unchecked Sendable {
    struct Ready: Sendable {
        let url: URL
        let session: WebMPlaybackSession
        let duration: Double
        let headers: [String: String]
    }

    private let queue = DispatchQueue(label: "co.uk.opaline.webm-prepare")
    let input: WebMPlaybackInput
    let transport: HTTPTransport
    let cancellation = CancellationToken()
    var videoFetcher: WebMRangeFetcher?
    var video: WebMVP9Delivery?
    var session: WebMPlaybackSession?
    var audioIndex: WebMAudioIndex?
    var videoCodec: String?
    var deadline: DispatchWorkItem?
    var completion: (@Sendable (Result<Ready, Error>) -> Void)?
    var finished = false

    init(input: WebMPlaybackInput, transport: HTTPTransport) {
        self.input = input
        self.transport = transport
    }

    func prepare(completion: @escaping @Sendable (Result<Ready, Error>) -> Void) {
        queue.async { [self] in
            guard !self.finished, self.completion == nil else {
                return
            }
            self.completion = completion
            let timeout = DispatchWorkItem { [weak self] in
                self?.finish(.failure(WebMDeliveryError.timeout))
            }
            self.deadline = timeout
            self.queue.asyncAfter(deadline: .now() + 60, execute: timeout)
            self.loadAudio()
        }
    }

    func close() {
        queue.async {
            self.finished = true
            self.completion = nil
            self.cleanUp()
        }
    }

    private func loadAudio() {
        do {
            let fetcher = try WebMRangeFetcher(
                transport: transport,
                url: input.audioURL,
                contentLength: input.audio.contentLength,
                headers: input.headers,
                maximumRangeBytes: 1_048_576
            )
            let range = try WebMByteRange(
                start: Int64(input.audio.indexRangeStart),
                end: Int64(input.audio.indexRangeEnd)
            )
            fetcher.fetch(range: range, cancellation: cancellation) { [weak self] result in
                guard let self else {
                    return
                }
                self.queue.async { self.receivedAudio(result) }
            }
        } catch { finish(.failure(error)) }
    }

    private func receivedAudio(_ result: Result<Data, Error>) {
        guard !finished else {
            return
        }
        do {
            audioIndex = try WebMAudioIndex(data: result.get(), format: input.audio)
            if input.audioOnly {
                try serve(duration: input.duration(initialization: nil))
            } else {
                loadVideo()
            }
        } catch { finish(.failure(error)) }
    }

    private func loadVideo() {
        do {
            let fetcher = try WebMRangeFetcher(
                transport: transport,
                url: input.videoURL,
                contentLength: input.video.contentLength,
                headers: input.headers
            )
            let initRange = try WebMByteRange(start: 0, end: Int64(input.video.initRangeEnd))
            let indexRange = try WebMByteRange(
                start: Int64(input.video.indexRangeStart),
                end: Int64(input.video.indexRangeEnd)
            )
            videoFetcher = fetcher
            fetcher.open(
                initializationRange: initRange,
                indexRange: indexRange,
                cancellation: cancellation
            ) { [weak self] result in
                guard let self else {
                    return
                }
                self.queue.async { self.receivedVideo(result) }
            }
        } catch { finish(.failure(error)) }
    }

    private func receivedVideo(_ result: Result<WebMRangeFetcher.OpenedStream, Error>) {
        guard !finished else {
            return
        }
        do { try opened(result.get()) } catch { finish(.failure(error)) }
    }

    private func opened(_ stream: WebMRangeFetcher.OpenedStream) throws {
        guard let fetcher = videoFetcher, stream.initialization.video.width == input.video.width,
            stream.initialization.video.height == input.video.height
        else {
            throw WebMDeliveryError.invalidPlan
        }
        let duration = try input.duration(initialization: stream.initialization)
        let start = input.startAt ?? 0
        guard let time = Int64(exactly: (start * 1e9).rounded()), time < duration else {
            throw WebMError.invalidTimestamp
        }
        let video = try WebMVP9Delivery(
            fetcher: fetcher,
            stream: stream,
            durationNanoseconds: duration
        )
        self.video = video
        let index = video.plan.segments.lastIndex { $0.startNanoseconds <= time } ?? 0
        video.loadSegment(at: index) { [weak self] result in
            guard let self else {
                return
            }
            self.queue.async { self.warmed(result, duration: duration) }
        }
    }

    private func warmed(_ result: Result<WebMVP9DeliverySegment, Error>, duration: Int64) {
        guard !finished else {
            return
        }
        do {
            // The actual starting keyframe/remux must validate before success.
            let segment = try result.get()
            videoCodec = WebMVP9Level.codec(
                format: input.video, configuration: segment.configuration
            )
            guard videoCodec != nil else { throw WebMDeliveryError.invalidPlan }
            try serve(duration: duration)
        } catch { finish(.failure(error)) }
    }

    func finish(_ result: Result<Ready, Error>) {
        guard !finished, let completion else {
            return
        }
        finished = true
        self.completion = nil
        deadline?.cancel()
        deadline = nil
        cancellation.cancel()
        if case .failure = result { cleanUp() }
        completion(result)
    }

    private func cleanUp() {
        deadline?.cancel()
        deadline = nil
        cancellation.cancel()
        video?.close()
        video = nil
        session?.stop()
        session = nil
    }

    /// Listener callbacks can arrive on its queue; re-enter the builder queue.
    func attach(_ session: WebMPlaybackSession, duration: Int64) {
        self.session = session
        session.start { [weak self] url in
            guard let self else {
                return
            }
            self.queue.async {
                guard !self.finished else {
                    return
                }
                guard let url else {
                    self.finish(.failure(StreamDeliveryError.noStream))
                    return
                }
                self.finish(
                    .success(
                        Ready(
                            url: url,
                            session: session,
                            duration: Double(duration) / 1e9,
                            headers: self.input.headers
                        )
                    )
                )
            }
        }
    }
}
