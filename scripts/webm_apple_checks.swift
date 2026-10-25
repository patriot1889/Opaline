// This file is concatenated after the shared fixture parser checks.
let vp9 = try WebMVP9Configuration.parse(track: realInit.video, keyframe: realPackets[0])
check(vp9.width == 32 && vp9.height == 32 && vp9.record.count == 12, "vpcC dimensions and FullBox payload")
let batch = try WebMVP9Samples(track: realInit.video, packets: realPackets)
check(batch.buffers.count == realPackets.count, "One CoreMedia sample per supported VP9 packet")
for (sample, packet) in zip(batch.buffers, realPackets) {
    check(CMSampleBufferGetPresentationTimeStamp(sample) == CMTime(value: packet.timestampNanoseconds, timescale: 1_000_000_000), "PTS survives conversion")
    check(CMSampleBufferGetDuration(sample) == CMTime(value: 1, timescale: 10), "Known frame duration survives conversion")
    let block = CMSampleBufferGetDataBuffer(sample)!
    var copy = Data(count: packet.data.count)
    let status = copy.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
    check(status == noErr && copy == packet.data, "CoreMedia owns a byte-exact copy")
    let flags = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)! as! [[String: Any]]
    check(flags[0][kCMSampleAttachmentKey_NotSync as String] as? Bool == !packet.isKeyframe, "Keyframe attachment survives")
}
func packet(_ original: WebMPacket, time: Int64? = nil, bytes: Data? = nil, invisible: Bool = false) -> WebMPacket {
    WebMPacket(data: bytes ?? original.data, timestampNanoseconds: time ?? original.timestampNanoseconds,
               durationNanoseconds: original.durationNanoseconds, isKeyframe: original.isKeyframe, isInvisible: invisible)
}
func remuxRejects(_ message: String, _ body: () throws -> Void) {
    checks += 1
    do { try body(); preconditionFailure(message) } catch is WebMError {} catch is WebMRemuxError {} catch { preconditionFailure("Unexpected error: \(error)") }
}
remuxRejects("Empty batch") { _ = try WebMVP9Samples(track: realInit.video, packets: []) }
remuxRejects("Start must be a keyframe") { _ = try WebMVP9Samples(track: realInit.video, packets: Array(realPackets.dropFirst())) }
remuxRejects("Negative timestamps") { _ = try WebMVP9Samples(track: realInit.video, packets: [packet(realPackets[0], time: -1)]) }
remuxRejects("Equal timestamps") { _ = try WebMVP9Samples(track: realInit.video, packets: [realPackets[0], packet(realPackets[1], time: 0)]) }
remuxRejects("Container invisibility must agree with the bitstream") { _ = try WebMVP9Samples(track: realInit.video, packets: [packet(realPackets[0], invisible: true)]) }
remuxRejects("Truncated keyframe header") { _ = try WebMVP9Header.parse(Data([0x82])) }
remuxRejects("Profile 2 must not silently become SDR") { _ = try WebMVP9Header.parse(Data([0x92])) }
check(try WebMVP9Header.parse(Data([0x88])).existingFrameIndex == 0, "Show-existing header retains its slot")
remuxRejects("Malformed superframe lengths") { _ = try WebMVP9Superframe.split(realPackets[0].data + Data([0xC0, 1, 0xC0])) }

final class RemuxResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<WebMVP9Fragments, Error>?
    private var calls = 0
    let semaphore = DispatchSemaphore(value: 0)
    func complete(_ value: Result<WebMVP9Fragments, Error>) {
        lock.lock(); calls += 1; self.value = value; lock.unlock()
        semaphore.signal()
    }
    func get() throws -> WebMVP9Fragments {
        lock.lock(); defer { lock.unlock() }
        precondition(calls == 1)
        return try value!.get()
    }
}
let resultBox = RemuxResultBox()
let job = WebMVP9FragmentWriter.write(track: realInit.video, packets: realPackets) { resultBox.complete($0) }
check(resultBox.semaphore.wait(timeout: .now() + 35) == .success, "Writer must finish before its deadline")
let fragments = try resultBox.get()
check(!fragments.initialization.isEmpty && fragments.media.count >= 1, "Writer must emit init and media")
check(abs(fragments.media.reduce(0) { $0 + $1.duration.seconds } - 3) < 0.001, "Reports cover three seconds")
let movie = fragments.media.reduce(fragments.initialization) { $0 + $1.data }
let file = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("remux.mp4")
try movie.write(to: file)
// Independent Apple demuxer validates packet identity, timing and sync after writing.
let asset = AVURLAsset(url: file)
let track = asset.tracks(withMediaType: .video).first!
let reader = try AVAssetReader(asset: asset)
let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
reader.add(output)
check(reader.startReading(), "Apple must read generated fragmented MP4")
var reread = 0
while let sample = output.copyNextSampleBuffer() {
    guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
    check(reread < realPackets.count, "Writer must not introduce samples")
    let original = realPackets[reread]
    let block = CMSampleBufferGetDataBuffer(sample)!
    var copy = Data(count: CMBlockBufferGetDataLength(block))
    _ = copy.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
    check(copy == original.data, "MP4 passthrough must preserve compressed bytes")
    check(CMSampleBufferGetPresentationTimeStamp(sample) == CMTime(value: original.timestampNanoseconds, timescale: 1_000_000_000), "MP4 passthrough must preserve PTS")
    let syncFlags = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
    check((syncFlags?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false) == !original.isKeyframe, "MP4 readback preserves sync flags")
    reread += 1
}
check(reader.status == .completed && reread == 30, "All 30 packets must survive MP4 readback")
print("WebM Apple checks passed (\(checks) total assertions; \(fragments.media.count) fragments, \(reread) exact packets)")

remuxRejects("Final duration must be known") {
    let frame = WebMPacket(data: realPackets[0].data, timestampNanoseconds: 0, durationNanoseconds: nil, isKeyframe: true, isInvisible: false)
    _ = try WebMVP9Samples(track: vp9Track(duration: nil), packets: [frame])
}
remuxRejects("Sample end must not overflow") {
    _ = try WebMVP9Samples(track: realInit.video, packets: [packet(realPackets[0], time: Int64.max)])
}
remuxRejects("Sample count is bounded") {
    _ = try WebMVP9Samples(track: realInit.video, packets: Array(repeating: realPackets[0], count: 4_097))
}
let cancelledBox = RemuxResultBox()
let cancelledJob = WebMVP9FragmentWriter.write(track: realInit.video, packets: realPackets) { cancelledBox.complete($0) }
cancelledJob.cancel()
check(cancelledBox.semaphore.wait(timeout: .now() + 5) == .success, "Cancellation must complete promptly")
do {
    _ = try cancelledBox.get()
    // Completion may win the race with cancellation on a fast writer.
    check(true, "A completed job remains terminal when cancelled")
} catch WebMRemuxError.cancelled {}
cancelledJob.cancel() // Terminal cancellation is idempotent.
check(cancelledBox.semaphore.wait(timeout: .now() + 0.1) == .timedOut, "Completion is delivered exactly once")

let seekBox = RemuxResultBox()
_ = WebMVP9FragmentWriter.write(track: realInit.video, packets: Array(realPackets[10..<20])) { seekBox.complete($0) }
check(seekBox.semaphore.wait(timeout: .now() + 35) == .success, "Nonzero-start cue batch completes")
let seekFragments = try seekBox.get()
check(seekFragments.media.first!.start == CMTime(value: 1, timescale: 1), "Fragment reports preserve nonzero cue start")
print("WebM Apple lifecycle checks passed (\(checks) total assertions)")
let seekFile = file.deletingLastPathComponent().appendingPathComponent("seek.mp4")
try seekFragments.media.reduce(seekFragments.initialization) { $0 + $1.data }.write(to: seekFile)
let seekAsset = AVURLAsset(url: seekFile)
let seekReader = try AVAssetReader(asset: seekAsset)
let seekOutput = AVAssetReaderTrackOutput(track: seekAsset.tracks(withMediaType: .video).first!, outputSettings: nil)
seekReader.add(seekOutput)
check(seekReader.startReading(), "Nonzero cue fragment is readable")
var seekTimes: [CMTime] = []
while let sample = seekOutput.copyNextSampleBuffer() {
    guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
    seekTimes.append(CMSampleBufferGetPresentationTimeStamp(sample))
}
check(seekReader.status == .completed && seekTimes.count == 10, "Nonzero cue contains ten visible samples")
// AVURLAsset normalizes a standalone fragment's origin. Inspect tfdt/mdhd
// structurally to verify the actual HLS fragment timeline instead.
func boxPayload(_ data: Data, path: [String]) -> Data {
    guard let name = path.first else { return data }
    var position = 0
    while position < data.count {
        precondition(data.count - position >= 8)
        let size = data[position..<(position + 4)].reduce(0) { ($0 << 8) | Int($1) }
        precondition(size >= 8 && size <= data.count - position)
        if String(data: data[(position + 4)..<(position + 8)], encoding: .ascii) == name {
            return boxPayload(data.subdata(in: (position + 8)..<(position + size)), path: Array(path.dropFirst()))
        }
        position += size
    }
    preconditionFailure("Missing box \(name)")
}
let tfdt = boxPayload(seekFragments.media[0].data, path: ["moof", "traf", "tfdt"])
check(tfdt.count == 12 && tfdt[0] == 1, "Writer emits version-1 decode time")
let decodeTime = tfdt.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
let mdhd = boxPayload(seekFragments.initialization, path: ["moov", "trak", "mdia", "mdhd"])
let scaleStart = mdhd[0] == 1 ? 20 : 12
let scale = mdhd[scaleStart..<(scaleStart + 4)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
check(scale == 1_000_000_000 && decodeTime == scale, "HLS fragment retains absolute one-second decode time")
check(zip(seekTimes, seekTimes.dropFirst()).allSatisfy { $1 - $0 == CMTime(value: 1, timescale: 10) },
      "Reader-normalized cue retains frame spacing")
print("WebM Apple seek checks passed (\(checks) total assertions)")
// Exercise the same normal-size fixture used in the physical-device HLS spike.
let playbackData = try Data(contentsOf: fixtureRoot.appendingPathComponent("vp9-sdr-playback.webm"))
let playbackInit = try WebMInitialization.parse(playbackData)
var playbackRoot = try EBMLReader(playbackData)
_ = try playbackRoot.element()
let playbackSegment = try playbackRoot.header()
var playbackChildren = try EBMLReader(playbackData, range: playbackSegment.payloadStart..<playbackData.count)
var playbackPackets: [WebMPacket] = []
while !playbackChildren.isAtEnd {
    let start = playbackChildren.position
    let child = try playbackChildren.element()
    if child.id == 0x1F43_B675 {
        playbackPackets += try WebMCluster.parse(playbackData.subdata(in: start..<playbackChildren.position), initialization: playbackInit)
    }
}
check(playbackInit.video.width == 640 && playbackInit.video.height == 360 && playbackPackets.count == 30,
      "Hardware fixture remains a normal-size three-second clip")
let playbackBox = RemuxResultBox()
_ = WebMVP9FragmentWriter.write(track: playbackInit.video, packets: playbackPackets) { playbackBox.complete($0) }
check(playbackBox.semaphore.wait(timeout: .now() + 35) == .success, "Hardware fixture remux completes")
let playbackFragments = try playbackBox.get()
check(playbackFragments.media.count == 2 && playbackFragments.media.reduce(0) { $0 + $1.duration.seconds } == 3,
      "Hardware fixture covers a fragment boundary and three seconds")
print("WebM Apple checks complete (\(checks) total assertions)")
// Pass real hidden references through the Apple writer, then independently
// demux its MP4. Some Apple readers split superframes; compare elementary bytes.
let referenceSamples = try WebMVP9Samples(track: altrefInit.video, packets: separatedAltref)
check(referenceSamples.buffers.count == 180, "192 elementary frames become 180 displayed MP4 samples")
for index in 0..<179 {
    check(CMSampleBufferGetDuration(referenceSamples.buffers[index]) == CMTime(
        value: altrefPackets[index + 1].timestampNanoseconds - altrefPackets[index].timestampNanoseconds,
        timescale: 1_000_000_000), "30fps quantized PTS determines adjacent duration")
}
let referenceBox = RemuxResultBox()
_ = WebMVP9FragmentWriter.write(track: altrefInit.video, packets: separatedAltref) { referenceBox.complete($0) }
check(referenceBox.semaphore.wait(timeout: .now() + 35) == .success, "Reference-frame remux completes")
let referenceFragments = try referenceBox.get()
check(referenceFragments.media.count == 3, "Six-second reference clip crosses two fragment boundaries")
let referenceFile = file.deletingLastPathComponent().appendingPathComponent("altref.mp4")
try referenceFragments.media.reduce(referenceFragments.initialization) { $0 + $1.data }.write(to: referenceFile)
let referenceAsset = AVURLAsset(url: referenceFile)
let referenceReader = try AVAssetReader(asset: referenceAsset)
let referenceOutput = AVAssetReaderTrackOutput(track: referenceAsset.tracks(withMediaType: .video).first!, outputSettings: nil)
referenceReader.add(referenceOutput)
check(referenceReader.startReading(), "Apple reads the reference-frame MP4")
var referenceFrames: [Data] = []
var referenceDisplays = 0
while let sample = referenceOutput.copyNextSampleBuffer() {
    guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
    let block = CMSampleBufferGetDataBuffer(sample)!
    var bytes = Data(count: CMBlockBufferGetDataLength(block))
    let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
    check(status == noErr, "Reference sample data is readable")
    let frames = try WebMVP9Superframe.split(bytes)
    let displays = try frames.map(WebMVP9Header.parse).filter(\.isVisible)
    if !displays.isEmpty {
        check(CMSampleBufferGetPresentationTimeStamp(sample) == CMTime(value: altrefPackets[referenceDisplays].timestampNanoseconds, timescale: 1_000_000_000), "Displayed alt-ref PTS survives writer/readback")
        referenceDisplays += 1
    }
    referenceFrames += frames
}
check(referenceReader.status == .completed && referenceDisplays == 180, "All 180 displays survive writer/readback")
check(referenceFrames == altrefFrames, "All 192 elementary frames retain bytes and decode order after MP4")
let showSample = try WebMVP9Samples(track: realInit.video, packets: [realPackets[0], existing])
check(showSample.buffers.count == 2, "Show-existing becomes a displayed CoreMedia sample")
let showBox = RemuxResultBox()
_ = WebMVP9FragmentWriter.write(track: realInit.video, packets: [realPackets[0], existing]) { showBox.complete($0) }
check(showBox.semaphore.wait(timeout: .now() + 35) == .success, "Show-existing remux completes")
check(try showBox.get().media.count == 1, "Show-existing writes a real media fragment")
print("WebM Apple reference checks passed (\(checks) total assertions; 192 exact frames, 180 displays)")
