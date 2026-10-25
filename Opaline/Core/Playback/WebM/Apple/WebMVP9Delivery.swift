import Foundation

/// On-demand VOD resources, shared by iOS/tvOS. State, callbacks, cache and job
/// transitions are serialized on queue. A single job bounds network/remux work.
final class WebMVP9Delivery: @unchecked Sendable {
    typealias Completion = @Sendable (Result<WebMVP9DeliverySegment, Error>) -> Void

    struct Limits: Sendable {
        var cacheBytes = 32 * 1_024 * 1_024
        var cacheEntries = 2
        var maximumRequests = 32
        var operationTimeout: TimeInterval = 60
    }

    struct Resource: Sendable {
        let data: Data
        let contentType: String
    }

    private struct Waiting {
        let index: Int
        let completion: Completion
    }

    private struct Cached {
        let index: Int
        let segment: WebMVP9DeliverySegment
    }

    private struct Active {
        let id: UUID
        let index: Int
        let job: WebMVP9DeliveryJob
        var completions: [Completion]
    }

    let plan: WebMVP9DeliveryPlan
    let basePath = "/webm/" + UUID().uuidString.lowercased() + "/video"
    var playlistPath: String { basePath + ".m3u8" }
    private let queue = DispatchQueue(label: "co.uk.opaline.webm-delivery")
    private let fetcher: WebMRangeFetcher
    private let stream: WebMRangeFetcher.OpenedStream
    private let limits: Limits
    private let playlist: Data
    private var active: Active?
    private var waiting: [Waiting] = []
    private var cache: [Cached] = []
    private var cacheBytes = 0
    private var configuration: WebMVP9Configuration?
    private var closed = false

    init(
        fetcher: WebMRangeFetcher,
        stream: WebMRangeFetcher.OpenedStream,
        durationNanoseconds: Int64,
        limits: Limits = Limits()
    ) throws {
        guard limits.cacheBytes > 0, limits.cacheBytes <= 128 * 1_024 * 1_024,
              (1...16).contains(limits.cacheEntries), (1...256).contains(limits.maximumRequests),
              limits.operationTimeout.isFinite, (0...300).contains(limits.operationTimeout),
              limits.operationTimeout > 0 else { throw WebMDeliveryError.capacity }
        plan = try WebMVP9DeliveryPlan(
            index: stream.index, durationNanoseconds: durationNanoseconds
        )
        playlist = Data(try plan.playlist(basePath: basePath).utf8)
        self.fetcher = fetcher
        self.stream = stream
        self.limits = limits
    }

    func loadSegment(at index: Int, completion: @escaping Completion) {
        queue.async { self.enqueue(index, completion: completion) }
    }

    /// Unknown paths fail without networking. Completion runs once on queue.
    /// A loopback server can map a failure to its error response and serve the
    /// returned body as-is, including for its own HEAD/byte-range handling.
    func resource(
        forPath path: String,
        completion: @escaping @Sendable (Result<Resource, Error>) -> Void
    ) {
        queue.async {
            guard !self.closed else {
                completion(.failure(WebMDeliveryError.cancelled))
                return
            }
            if path == self.playlistPath {
                let resource = Resource(
                    data: self.playlist, contentType: "application/vnd.apple.mpegurl"
                )
                completion(.success(resource))
                return
            }
            guard let (index, kind) = self.route(path) else {
                completion(.failure(WebMDeliveryError.notFound))
                return
            }
            self.enqueue(index) { result in
                completion(result.map {
                    let data = kind == "init" ? $0.initialization : $0.media
                    return Resource(data: data, contentType: "video/mp4")
                })
            }
        }
    }

    /// Cancels the current generation while retaining immutable cached media.
    /// A seek can immediately request another cue. Old callbacks cannot publish.
    func cancelPendingRequests() {
        queue.async { self.cancelPending() }
    }

    /// Terminal. Responds to pending callers with cancellation and releases the
    /// cache. The playback owner must call this before stopping/replacing media.
    func close() {
        queue.async {
            self.closed = true
            self.cache.removeAll()
            self.cacheBytes = 0
            self.configuration = nil
            self.cancelPending()
        }
    }
}

private extension WebMVP9Delivery {
    func enqueue(_ index: Int, completion: @escaping Completion) {
        guard !closed else {
            completion(.failure(WebMDeliveryError.cancelled))
            return
        }
        guard plan.segments.indices.contains(index) else {
            completion(.failure(WebMDeliveryError.notFound))
            return
        }
        if let hit = cache.firstIndex(where: { $0.index == index }) {
            let cached = cache.remove(at: hit)
            cache.append(cached)
            completion(.success(cached.segment))
            return
        }
        guard waiting.count + (active?.completions.count ?? 0) < limits.maximumRequests else {
            completion(.failure(WebMDeliveryError.capacity))
            return
        }
        if active?.index == index {
            active?.completions.append(completion)
        } else {
            waiting.append(Waiting(index: index, completion: completion))
        }
        pump()
    }

    func pump() {
        guard active == nil, !closed, let next = waiting.first else {
            return
        }
        let completions = waiting.filter { $0.index == next.index }.map(\.completion)
        waiting.removeAll { $0.index == next.index }
        let id = UUID()
        let request = WebMVP9DeliveryJob.Request(
            fetcher: fetcher,
            track: stream.initialization.video,
            interval: plan.segments[next.index],
            expectedConfiguration: configuration,
            timeout: limits.operationTimeout
        )
        let job = WebMVP9DeliveryJob(queue: queue, request: request) { [weak self] result in
            self?.complete(result, id: id)
        }
        active = Active(id: id, index: next.index, job: job, completions: completions)
        job.start(initialization: stream.initialization)
    }

    func complete(_ result: Result<WebMVP9DeliveryJob.Output, Error>, id: UUID) {
        guard let active, active.id == id else {
            return
        }
        self.active = nil
        let delivered = result.flatMap { output in
            Result {
                try store(output.segment, at: active.index)
                configuration = output.configuration
                return output.segment
            }
        }
        active.completions.forEach { $0(delivered) }
        pump()
    }

    func store(_ segment: WebMVP9DeliverySegment, at index: Int) throws {
        guard segment.byteCount <= limits.cacheBytes else { throw WebMDeliveryError.capacity }
        while cache.count >= limits.cacheEntries
            || segment.byteCount > limits.cacheBytes - cacheBytes {
            cacheBytes -= cache.removeFirst().segment.byteCount
        }
        cache.append(Cached(index: index, segment: segment))
        cacheBytes += segment.byteCount
    }

    func cancelPending() {
        let active = self.active
        let replies = (active?.completions ?? []) + waiting.map(\.completion)
        self.active = nil
        waiting.removeAll()
        active?.job.cancel()
        replies.forEach { $0(.failure(WebMDeliveryError.cancelled)) }
    }

    func route(_ path: String) -> (Int, String)? {
        guard path.hasPrefix(basePath + "/") else {
            return nil
        }
        let suffix = path.dropFirst(basePath.count + 1)
        let parts = suffix.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let index = Int(parts[0]), String(index) == parts[0],
              plan.segments.indices.contains(index), ["init", "media"].contains(parts[1]) else {
            return nil
        }
        return (index, String(parts[1]))
    }
}
