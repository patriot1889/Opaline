import Foundation

extension WebMRangeFetcher {
    /// The transport may call from arbitrary queues. Call user code only after
    /// releasing this lock, and release buffered bytes immediately on overflow.
    final class RangeBuffer {
        private let lock = NSLock()
        private let limit: Int
        private var bytes = Data()
        private var overflow = false
        private var finished = false

        init(limit: Int) { self.limit = limit }

        func append(_ chunk: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !finished, !overflow else {
                return false
            }
            guard chunk.count <= limit - bytes.count else {
                overflow = true
                bytes.removeAll()
                return false
            }
            bytes.append(chunk)
            return true
        }

        func finish(
            _ result: Result<HTTPResponse, Error>
        ) -> Result<(HTTPResponse, Data), Error>? {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else {
                return nil
            }
            finished = true
            defer { bytes = Data() }
            if overflow {
                return .failure(WebMRangeError.rangeTooLarge)
            }
            return result.map { ($0, bytes) }
        }
    }

    func validate(_ response: HTTPResponse, bytes: Data, range: WebMByteRange) throws -> Data {
        guard response.status == 206 else {
            throw WebMRangeError.unexpectedStatus(response.status)
        }
        let encoding = try header("Content-Encoding", in: response)
        guard encoding == nil || encoding?.lowercased() == "identity",
              let value = try header("Content-Range", in: response),
              Int64(bytes.count) == range.count else {
            throw WebMRangeError.invalidResponse
        }
        let parsed = try contentRange(value)
        guard parsed.range == range, parsed.total == contentLength else {
            throw WebMRangeError.invalidResponse
        }
        if let length = try header("Content-Length", in: response),
           try integer(length) != range.count {
            throw WebMRangeError.invalidResponse
        }
        return bytes
    }

    private func header(_ name: String, in response: HTTPResponse) throws -> String? {
        let values = response.headers.filter { $0.key.caseInsensitiveCompare(name) == .orderedSame }
        guard values.count <= 1 else { throw WebMRangeError.invalidResponse }
        return values.first?.value.trimmingCharacters(in: .whitespaces)
    }

    private func contentRange(_ value: String) throws -> (range: WebMByteRange, total: Int64) {
        let parts = value.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else {
            throw WebMRangeError.invalidResponse
        }
        let bounds = parts[1].split(separator: "/", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { throw WebMRangeError.invalidResponse }
        let offsets = bounds[0].split(separator: "-", omittingEmptySubsequences: false)
        guard offsets.count == 2 else { throw WebMRangeError.invalidResponse }
        return (
            try WebMByteRange(start: integer(String(offsets[0])), end: integer(String(offsets[1]))),
            try integer(String(bounds[1]))
        )
    }

    private func integer(_ value: String) throws -> Int64 {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let result = Int64(value) else { throw WebMRangeError.invalidResponse }
        return result
    }
}
