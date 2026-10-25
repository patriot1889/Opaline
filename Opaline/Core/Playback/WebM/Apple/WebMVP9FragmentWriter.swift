import AVFoundation
import Foundation

/// A single finite job, separate from playback selection. Mutable job state is
/// confined to queue; the delegate's output has its own lock. The callback is
/// delivered once on queue, including cancellation and the 30-second deadline.
final class WebMVP9FragmentWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "co.uk.opaline.webm-writer")
    private let collector = WebMVP9FragmentCollector()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var buffers: [CMSampleBuffer] = []
    private var position = 0
    private var finishing = false
    private var completion: (@Sendable (Result<WebMVP9Fragments, Error>) -> Void)?
    private var deadline: DispatchWorkItem?

    /// Input is bounded by WebMVP9Samples; accumulated fragment output is capped
    /// at 32 MiB. Segment boundaries await keyframes after the 2-second target.
    static func write(
        track: WebMVideoTrack,
        packets: [WebMPacket],
        endTimeNanoseconds: Int64? = nil,
        completion: @escaping @Sendable (Result<WebMVP9Fragments, Error>) -> Void
    ) -> WebMVP9FragmentWriter {
        let job = WebMVP9FragmentWriter()
        job.queue.async {
            job.completion = completion
            do {
                let samples = try WebMVP9Samples(
                    track: track, packets: packets, endTimeNanoseconds: endTimeNanoseconds
                )
                try job.start(samples)
            } catch {
                job.finish(.failure(error))
            }
        }
        return job
    }

    func cancel() {
        queue.async { self.finish(.failure(WebMRemuxError.cancelled)) }
    }

    private func start(_ samples: WebMVP9Samples) throws {
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        let input = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil, sourceFormatHint: samples.format
        )
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(value: 2, timescale: 1)
        let start = CMSampleBufferGetPresentationTimeStamp(samples.buffers[0])
        writer.initialSegmentStartTime = start
        writer.delegate = collector
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = 1_000_000_000
        guard writer.canAdd(input) else {
            throw WebMRemuxError.writer("VP9 passthrough input rejected")
        }
        writer.add(input)
        self.writer = writer
        self.input = input
        buffers = samples.buffers
        guard writer.startWriting() else {
            throw writer.error ?? WebMRemuxError.writer("start failed")
        }
        // Keep the file timeline origin at zero even for a later cue. Fragment
        // decode times and reports must retain the original source timestamps.
        writer.startSession(atSourceTime: .zero)
        let deadline = DispatchWorkItem { self.finish(.failure(WebMRemuxError.timeout)) }
        self.deadline = deadline
        queue.asyncAfter(deadline: .now() + 30, execute: deadline)
        input.requestMediaDataWhenReady(on: queue) { [weak self] in self?.appendReadySamples() }
    }

    private func appendReadySamples() {
        guard completion != nil, !finishing, let writer, let input else {
            return
        }
        while input.isReadyForMoreMediaData, position < buffers.count {
            guard input.append(buffers[position]) else {
                finish(.failure(writer.error ?? WebMRemuxError.writer("append failed")))
                return
            }
            position += 1
        }
        guard position == buffers.count else {
            return
        }
        finishing = true
        input.markAsFinished()
        writer.finishWriting {
            self.queue.async {
                guard let writer = self.writer, writer.status == .completed else {
                    let error = self.writer?.error ?? WebMRemuxError.writer("finish failed")
                    self.finish(.failure(error))
                    return
                }
                self.finish(Result { try self.collector.snapshot() })
            }
        }
    }

    private func finish(_ result: Result<WebMVP9Fragments, Error>) {
        guard let completion else {
            return
        }
        self.completion = nil
        deadline?.cancel()
        deadline = nil
        if writer?.status == .writing { writer?.cancelWriting() }
        collector.discard()
        buffers.removeAll()
        input = nil
        writer = nil
        completion(result)
    }
}
