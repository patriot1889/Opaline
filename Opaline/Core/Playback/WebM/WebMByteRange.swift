import Foundation

enum WebMRangeError: Error, Equatable {
    case invalidRange
    case rangeTooLarge
    case invalidResponse
    case unexpectedStatus(Int)
    case emptyIndex
}

/// Inclusive file offsets, matching HTTP Range and YouTube's range metadata.
struct WebMByteRange: Equatable, Sendable {
    let start: Int64
    let end: Int64
    var count: Int64 { end - start + 1 }

    init(start: Int64, end: Int64) throws {
        guard start >= 0, end >= start, end - start < Int64.max else {
            throw WebMRangeError.invalidRange
        }
        self.start = start
        self.end = end
    }
}
