import AVFoundation
import Foundation

struct WebMVP9Fragment: Sendable {
    let data: Data
    let start: CMTime
    let duration: CMTime
}

struct WebMVP9Fragments: Sendable {
    let initialization: Data
    let media: [WebMVP9Fragment]
}

/// AVAssetWriter can invoke its delegate on a private queue. Only this locked
/// collector crosses that boundary; the job's writer/input stay on its own queue.
final class WebMVP9FragmentCollector: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var initialization: Data?
    private var media: [WebMVP9Fragment] = []
    private var byteCount = 0
    private var error: Error?

    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData data: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard error == nil else {
            return
        }
        guard data.count <= 33_554_432 - byteCount, media.count < 4_096 else {
            error = WebMRemuxError.capacity
            return
        }
        byteCount += data.count
        if segmentType == .initialization, initialization == nil, media.isEmpty {
            initialization = data
        } else if segmentType == .separable, initialization != nil,
                  let report = segmentReport?.trackReports.first,
                  report.earliestPresentationTimeStamp.isNumeric, report.duration.isNumeric,
                  report.duration > .zero {
            media.append(WebMVP9Fragment(
                data: data,
                start: report.earliestPresentationTimeStamp,
                duration: report.duration
            ))
        } else {
            error = WebMRemuxError.writer("invalid segment order or report")
        }
    }

    func snapshot() throws -> WebMVP9Fragments {
        lock.lock()
        defer { lock.unlock() }
        if let error { throw error }
        guard let initialization, !media.isEmpty else {
            throw WebMRemuxError.writer("missing initialization or media")
        }
        return WebMVP9Fragments(initialization: initialization, media: media)
    }

    func discard() {
        lock.lock()
        defer { lock.unlock() }
        error = WebMRemuxError.cancelled
        initialization = nil
        media.removeAll()
    }
}
