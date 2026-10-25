// Only the app-wide error/logging composition is stubbed. The HTTP transport,
// streaming session, server, range fetcher and parser are shipping sources.
enum APIError: Error { case transport(Error), invalidResponse }
enum AppLog { static func hls(_ text: String) {} }

final class HTTPCheckResult<T> {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    func store(_ value: Result<T, Error>) { lock.lock(); result = value; lock.unlock() }
    func get() throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try result!.get()
    }
}
func waitHTTP<T>(_ start: (@escaping (Result<T, Error>) -> Void) -> Void) throws -> T {
    let box = HTTPCheckResult<T>()
    let semaphore = DispatchSemaphore(value: 0)
    start { box.store($0); semaphore.signal() }
    precondition(semaphore.wait(timeout: .now() + 10) == .success, "HTTP check timed out")
    return try box.get()
}

let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let initialization = try WebMInitialization.parse(data)
var reader = try EBMLReader(data)
_ = try reader.element()
let segment = try reader.header()
reader = try EBMLReader(data, range: segment.payloadStart..<data.count)
var cueRange: WebMByteRange?
var expected: [WebMPacket] = []
while !reader.isAtEnd {
    let start = reader.position
    let element = try reader.element()
    if element.id == 0x1C53_BB6B {
        cueRange = try WebMByteRange(start: Int64(start), end: Int64(reader.position - 1))
    } else if element.id == 0x1F43_B675 {
        expected += try WebMCluster.parse(data.subdata(in: start..<reader.position), initialization: initialization)
    }
}
let server = LocalMediaServer { path, done in
    done(path == "/video.webm" ? data : nil, "video/webm")
}!
defer { server.stop() }
let base: URL = try waitHTTP { completed in
    server.start { url in
        completed(url.map { .success($0) } ?? .failure(WebMRangeError.invalidResponse))
    }
}
let fetcher = try WebMRangeFetcher(
    transport: URLSessionTransport(), url: base.appendingPathComponent("video.webm"),
    contentLength: Int64(data.count), maximumRangeBytes: 4_096
)
let opened: WebMRangeFetcher.OpenedStream = try waitHTTP {
    fetcher.open(initializationRange: try! WebMByteRange(start: 0, end: cueRange!.start - 1),
                 indexRange: cueRange!, cancellation: nil, completion: $0)
}
var received: [WebMPacket] = []
for entry in opened.index.entries {
    let packets: [WebMPacket] = try waitHTTP {
        fetcher.fetchPackets(entry: entry, initialization: opened.initialization, cancellation: nil, completion: $0)
    }
    received += packets
}
precondition(received == expected && received.count == 30, "Real HTTP transport changed WebM packets")
let seek = try opened.index.entry(forTimeNanoseconds: 1_500_000_000)
let seekPackets: [WebMPacket] = try waitHTTP {
    fetcher.fetchPackets(entry: seek, initialization: opened.initialization, cancellation: nil, completion: $0)
}
precondition(seekPackets.first?.isKeyframe == true && seekPackets.first?.timestampNanoseconds == 1_000_000_000,
             "Real HTTP seek range must start at the preceding keyframe")
let failure: WebMRangeError = try waitHTTP { completed in
    let missing = try! WebMRangeFetcher(transport: URLSessionTransport(), url: base.appendingPathComponent("missing"), contentLength: 1)
    missing.fetch(range: try! WebMByteRange(start: 0, end: 0), cancellation: nil) { result in
        switch result {
        case .failure(let error): completed(.success(error as! WebMRangeError))
        case .success: completed(.failure(WebMRangeError.invalidResponse))
        }
    }
}
precondition(failure == .unexpectedStatus(404), "Actual non-2xx streaming response must report its HTTP status")
print("WebM HTTP checks passed (30 identical packets, cue-based seek, HTTP 404 propagation)")
