import Foundation

/// One fetch/remux operation. All mutable state belongs to the supplied owner
/// queue; only immutable packet/results cross transport and writer callbacks.
final class WebMVP9DeliveryJob: @unchecked Sendable {
    struct Request {
        let fetcher: WebMRangeFetcher
        let track: WebMVideoTrack
        let interval: WebMVP9DeliveryPlan.Segment
        let expectedConfiguration: WebMVP9Configuration?
        let timeout: TimeInterval
    }

    struct Output: Sendable {
        let segment: WebMVP9DeliverySegment
        let configuration: WebMVP9Configuration
    }

    private let queue: DispatchQueue
    private let request: Request
    private let completion: @Sendable (Result<Output, Error>) -> Void
    private let cancellation = CancellationToken()
    private var writer: WebMVP9FragmentWriter?
    private var deadline: DispatchWorkItem?
    private var configuration: WebMVP9Configuration?
    private var done = false

    init(
        queue: DispatchQueue,
        request: Request,
        completion: @escaping @Sendable (Result<Output, Error>) -> Void
    ) {
        self.queue = queue
        self.request = request
        self.completion = completion
    }

    func start(initialization: WebMInitialization) {
        guard request.interval.entry.range.count <= 16_777_216 else {
            finish(.failure(WebMDeliveryError.capacity))
            return
        }
        let deadline = DispatchWorkItem { [weak self] in
            self?.finish(.failure(WebMDeliveryError.timeout))
        }
        self.deadline = deadline
        queue.asyncAfter(deadline: .now() + request.timeout, execute: deadline)
        request.fetcher.fetchPackets(
            entry: request.interval.entry,
            initialization: initialization,
            cancellation: cancellation
        ) { [weak self] result in
            guard let self else {
                return
            }
            self.queue.async { self.received(result) }
        }
    }

    /// Owner-queue operation; its terminal callback can be ignored by a reset
    /// owner because each active job also has a unique identity there.
    func cancel() {
        finish(.failure(WebMDeliveryError.cancelled))
    }

    private func received(_ result: Result<[WebMPacket], Error>) {
        guard !done, writer == nil else {
            return
        }
        do {
            let packets = try result.get()
            let configuration = try validate(packets)
            self.configuration = configuration
            writer = WebMVP9FragmentWriter.write(
                track: request.track,
                packets: packets,
                endTimeNanoseconds: request.interval.endNanoseconds
            ) { [weak self] result in
                guard let self else {
                    return
                }
                self.queue.async { self.written(result) }
            }
        } catch {
            finish(.failure(error))
        }
    }

    private func validate(_ packets: [WebMPacket]) throws -> WebMVP9Configuration {
        let end = request.interval.endNanoseconds
        guard let first = packets.first,
              first.timestampNanoseconds == request.interval.startNanoseconds,
              packets.allSatisfy({ $0.timestampNanoseconds < end }) else {
            throw WebMDeliveryError.invalidTimeline
        }
        let configuration = try WebMVP9Configuration.parse(track: request.track, keyframe: first)
        guard request.expectedConfiguration.map({ $0 == configuration }) ?? true else {
            throw WebMDeliveryError.configurationChanged
        }
        return configuration
    }

    private func written(_ result: Result<WebMVP9Fragments, Error>) {
        guard !done, let configuration else {
            return
        }
        finish(result.flatMap { fragments in
            Result {
                Output(
                    segment: try WebMVP9DeliverySegment(
                        fragments: fragments, interval: request.interval
                    ),
                    configuration: configuration
                )
            }
        })
    }

    private func finish(_ result: Result<Output, Error>) {
        guard !done else {
            return
        }
        done = true
        deadline?.cancel()
        deadline = nil
        cancellation.cancel()
        writer?.cancel()
        writer = nil
        completion(result)
    }

    deinit {
        // Outstanding queue blocks retain the job. With no remaining owner or
        // queued block, weak transport/delegate callbacks cannot access state.
        deadline?.cancel()
        cancellation.cancel()
        writer?.cancel()
    }
}
