import AVFoundation
import Foundation

/// A StreamDelivery adapter. Builder identity is lock-protected; media state
/// lives on the builder queue, and AVPlayerItem/completion are delivered on main.
final class WebMStreamDelivery: StreamDelivery, @unchecked Sendable {
    private final class Reply: @unchecked Sendable {
        // The legacy protocol's callback is transferred to main, invoked once.
        let completion: (Result<PreparedPlayback, Error>) -> Void
        let captions: [SubtitleTrack]
        init(
            request: DeliveryRequest,
            completion: @escaping (Result<PreparedPlayback, Error>) -> Void
        ) {
            self.completion = completion
            captions = request.info.captionTracks
        }
        func receive(
            _ result: Result<WebMPlaybackBuilder.Ready, Error>,
            current: @escaping @Sendable () -> Bool
        ) {
            DispatchQueue.main.async {
                guard current() else {
                    if case .success(let ready) = result { ready.session.stop() }
                    return
                }
                self.completion(
                    result.map { ready in
                        let asset = AVURLAsset(
                            url: ready.url,
                            options: ["AVURLAssetHTTPHeaderFieldsKey": ready.headers]
                        )
                        let item = AVPlayerItem(asset: asset)
                        PlaybackBufferPolicy.configure(item: item)
                        // HTTP HLS uses the shell's normal seek after attachment.
                        return PreparedPlayback(
                            item: item,
                            resourceLoader: ready.session,
                            captions: self.captions,
                            duration: ready.duration
                        )
                    }
                )
            }
        }
    }

    let label = "webm"
    private let client: PlaybackClient
    private let transport: HTTPTransport
    private let lock = NSLock()
    private var builder: WebMPlaybackBuilder?
    private var generation = UUID()

    init(client: PlaybackClient, transport: HTTPTransport) {
        self.client = client
        self.transport = transport
    }

    func prepare(
        _ request: DeliveryRequest,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        let reply = Reply(request: request, completion: completion)
        let id = UUID()
        lock.lock()
        generation = id
        let previous = builder
        builder = nil
        lock.unlock()
        previous?.close()
        do {
            let input = try WebMPlaybackInput(request: request, client: client)
            start(input: input, reply: reply, id: id)
        } catch {
            reply.receive(.failure(error)) { [weak self] in self?.isCurrent(id) == true }
        }
    }

    private func start(input: WebMPlaybackInput, reply: Reply, id: UUID) {
        let builder = WebMPlaybackBuilder(input: input, transport: transport)
        lock.lock()
        guard generation == id else {
            lock.unlock()
            builder.close()
            return
        }
        self.builder = builder
        lock.unlock()
        builder.prepare { [weak self] result in
            reply.receive(result) { [weak self] in self?.isCurrent(id) == true }
        }
    }

    private func isCurrent(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == id
    }

    func releaseResources() {
        lock.lock()
        generation = UUID()
        let previous = builder
        builder = nil
        lock.unlock()
        previous?.close()
    }

    deinit { builder?.close() }
}
