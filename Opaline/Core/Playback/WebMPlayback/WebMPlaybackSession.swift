import AVFoundation
import Foundation

/// Retained through PreparedPlayback.resourceLoader and the source's builder.
/// No resource-loader interception is needed for HTTP HLS. stop() is thread-safe.
final class WebMPlaybackSession: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private final class Reply: @unchecked Sendable {
        // LocalMediaServer explicitly permits its completion on any queue.
        let complete: (Data?, String) -> Void
        init(_ complete: @escaping (Data?, String) -> Void) { self.complete = complete }
        func receive(_ result: Result<WebMVP9Delivery.Resource, Error>) {
            switch result {
            case .success(let resource):
                complete(resource.data, resource.contentType)
            case .failure(let error):
                AppLog.hls("WebM resource failed: \(error.localizedDescription)")
                complete(nil, "video/mp4")
            }
        }
    }

    struct Playlists: Sendable {
        let files: [String: Data]
        let entryPath: String
        let video: WebMVP9Delivery?
    }

    let entryPath: String
    private let video: WebMVP9Delivery?
    private let server: LocalMediaServer
    private let lock = NSLock()
    private var stopped = false

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    init(playlists: Playlists) throws {
        guard
            let server = LocalMediaServer(handler: { path, done in
                if let body = playlists.files[path] {
                    done(body, "application/vnd.apple.mpegurl")
                } else if let video = playlists.video {
                    let reply = Reply(done)
                    video.resource(forPath: path) { reply.receive($0) }
                } else {
                    done(nil, "video/mp4")
                }
            })
        else { throw StreamDeliveryError.noStream }
        self.server = server
        video = playlists.video
        entryPath = playlists.entryPath
        super.init()
    }

    func start(completion: @escaping @Sendable (URL?) -> Void) {
        server.start { [weak self] base in
            guard let self, !isStopped else {
                completion(nil)
                return
            }
            completion(base?.appendingPathComponent(entryPath))
        }
    }

    func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        lock.unlock()
        guard !wasStopped else {
            return
        }
        video?.close()
        server.stop()
    }

    deinit { stop() }
}
