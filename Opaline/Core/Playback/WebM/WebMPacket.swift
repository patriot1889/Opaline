import Foundation

enum WebMError: Error, Equatable {
    case truncated
    case invalidVariableInteger
    case invalidElement
    case invalidTimestamp
    case unsupported(String)
}

/// Container metadata only. The Apple adapter validates this against VP9
/// headers; decoder registration remains the playback owner's responsibility.
struct WebMVideoTrack: Equatable, Sendable {
    let number: UInt64
    let width: Int
    let height: Int
    let defaultDurationNanoseconds: UInt64?
    let codecPrivate: Data
    /// Raw Colour unsigned values, keyed by EBML ID. Keep HDR metadata rather
    /// than assuming SDR while the format-description adapter is developed.
    let colour: [UInt64: UInt64]
}

struct WebMInitialization: Equatable, Sendable {
    /// Absolute file offset of Segment payload, the base for CueClusterPosition.
    let segmentDataOffset: Int64
    let timecodeScale: UInt64
    let durationSeconds: Double?
    let video: WebMVideoTrack
}

struct WebMCue: Equatable, Sendable {
    let timeNanoseconds: Int64
    let clusterOffset: Int64
    let relativeBlockOffset: UInt64?
}

struct WebMPacket: Equatable, Sendable {
    let data: Data
    let timestampNanoseconds: Int64
    let durationNanoseconds: UInt64?
    let isKeyframe: Bool
    let isInvisible: Bool
}

enum WebMTime {
    static func nanoseconds(_ ticks: UInt64, scale: UInt64) throws -> Int64 {
        let (value, overflow) = ticks.multipliedReportingOverflow(by: scale)
        guard !overflow, value <= UInt64(Int64.max) else {
            throw WebMError.invalidTimestamp
        }
        return Int64(value)
    }
}
