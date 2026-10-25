import Foundation

/// Stateless range operations over the shared transport. Each request has its
/// own bounded buffer and cancellation token; no player or platform is owned.
final class WebMRangeFetcher {
    struct OpenedStream: Sendable {
        let initialization: WebMInitialization
        let index: WebMClusterIndex
    }

    let contentLength: Int64
    private let transport: HTTPTransport
    private let url: URL
    private let headers: [String: String]
    private let maximumRangeBytes: Int

    init(
        transport: HTTPTransport,
        url: URL,
        contentLength: Int64,
        headers: [String: String] = [:],
        maximumRangeBytes: Int = 16 * 1_024 * 1_024
    ) throws {
        guard contentLength > 0, maximumRangeBytes > 0,
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            throw WebMRangeError.invalidRange
        }
        self.transport = transport
        self.url = url
        self.contentLength = contentLength
        self.headers = headers
        self.maximumRangeBytes = maximumRangeBytes
    }

    /// Loads metadata only. Media bytes are fetched later, at a selected cue.
    func open(
        initializationRange: WebMByteRange,
        indexRange: WebMByteRange,
        cancellation: CancellationToken?,
        completion: @escaping (Result<OpenedStream, Error>) -> Void
    ) {
        guard cancellation?.isCancelled != true else {
            return
        }
        guard initializationRange.start == 0, indexRange.start > initializationRange.end else {
            completion(.failure(WebMRangeError.invalidRange))
            return
        }
        if let error = rangeError(initializationRange) ?? rangeError(indexRange) {
            completion(.failure(error))
            return
        }
        fetch(range: initializationRange, cancellation: cancellation) { result in
            let parsed = result.flatMap { bytes in Result { try WebMInitialization.parse(bytes) } }
            guard cancellation?.isCancelled != true else {
                return
            }
            switch parsed {
            case .failure(let error):
                completion(.failure(error))
            case .success(let initialization):
                self.loadIndex(
                    range: indexRange,
                    initialization: initialization,
                    cancellation: cancellation,
                    completion: completion
                )
            }
        }
    }

    func fetchPackets(
        entry: WebMClusterIndex.Entry,
        initialization: WebMInitialization,
        cancellation: CancellationToken?,
        completion: @escaping (Result<[WebMPacket], Error>) -> Void
    ) {
        fetch(range: entry.range, cancellation: cancellation) { result in
            let parsed = result.flatMap { bytes in
                Result { try WebMClusterSequence.parse(bytes, initialization: initialization) }
            }
            guard cancellation?.isCancelled != true else {
                return
            }
            completion(parsed)
        }
    }

    func fetch(
        range: WebMByteRange,
        cancellation: CancellationToken?,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        guard cancellation?.isCancelled != true else {
            return
        }
        if let error = rangeError(range) {
            completion(.failure(error))
            return
        }
        let request = request(for: range)
        let buffer = RangeBuffer(limit: Int(range.count))
        transport.stream(request, cancellationToken: cancellation) { chunk in
            guard cancellation?.isCancelled != true else {
                return false
            }
            return buffer.append(chunk)
        } completion: { result in
            guard let collected = buffer.finish(result) else {
                return
            }
            let validated = collected.flatMap { response, bytes in
                Result { try self.validate(response, bytes: bytes, range: range) }
            }
            guard cancellation?.isCancelled != true else {
                return
            }
            completion(validated)
        }
    }

    private func rangeError(_ range: WebMByteRange) -> WebMRangeError? {
        if range.end >= contentLength {
            return .invalidRange
        }
        return range.count > Int64(maximumRangeBytes) ? .rangeTooLarge : nil
    }

    private func request(for range: WebMByteRange) -> HTTPRequest {
        let replaced = [HTTPHeader.range.lowercased(), HTTPHeader.acceptEncoding.lowercased()]
        var fields = headers.filter { !replaced.contains($0.key.lowercased()) }
        fields[HTTPHeader.range] = "bytes=\(range.start)-\(range.end)"
        fields[HTTPHeader.acceptEncoding] = "identity"
        return HTTPRequest(
            method: .get,
            url: url,
            headers: fields,
            timeout: 30,
            sendsCookies: false,
            isPlayback: true
        )
    }

    private func loadIndex(
        range: WebMByteRange,
        initialization: WebMInitialization,
        cancellation: CancellationToken?,
        completion: @escaping (Result<OpenedStream, Error>) -> Void
    ) {
        fetch(range: range, cancellation: cancellation) { result in
            let parsed = result.flatMap { bytes in
                Result {
                    let cues = try WebMCue.parse(
                        bytes, initialization: initialization, contentLength: self.contentLength
                    )
                    return OpenedStream(
                        initialization: initialization,
                        index: try WebMClusterIndex(cues: cues, contentLength: self.contentLength)
                    )
                }
            }
            guard cancellation?.isCancelled != true else {
                return
            }
            completion(parsed)
        }
    }
}
