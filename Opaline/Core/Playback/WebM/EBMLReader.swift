import Foundation

/// A bounded reader whose offsets are relative to the supplied buffer, even
/// when Data is a slice with a nonzero startIndex. No recursion or I/O.
struct EBMLReader {
    struct Header {
        let id: UInt64
        let size: UInt64?
        let payloadStart: Int
    }

    struct Element {
        let id: UInt64
        let payload: Range<Int>
    }

    let data: Data
    let end: Int
    private(set) var position: Int
    var isAtEnd: Bool { position == end }

    init(_ data: Data, range: Range<Int>? = nil) throws {
        let range = range ?? 0..<data.count
        guard range.lowerBound >= 0, range.upperBound <= data.count else {
            throw WebMError.truncated
        }
        self.data = data
        position = range.lowerBound
        end = range.upperBound
    }

    mutating func header() throws -> Header {
        let id = try variableInteger(maxBytes: 4, keepingMarker: true)
        let size = try variableInteger(maxBytes: 8, keepingMarker: false)
        return Header(id: id.value, size: size.isUnknown ? nil : size.value, payloadStart: position)
    }

    mutating func element() throws -> Element {
        let header = try header()
        return try element(after: header)
    }

    mutating func element(after header: Header) throws -> Element {
        guard position == header.payloadStart else {
            throw WebMError.invalidElement
        }
        guard let size = header.size else {
            throw WebMError.unsupported("unknown-sized child element")
        }
        guard size <= UInt64(end - position) else {
            throw WebMError.truncated
        }
        let start = position
        position += Int(size)
        return Element(id: header.id, payload: start..<position)
    }

    mutating func trackNumber() throws -> UInt64 {
        let value = try variableInteger(maxBytes: 8, keepingMarker: false)
        guard !value.isUnknown, value.value > 0 else {
            throw WebMError.invalidElement
        }
        return value.value
    }

    mutating func byte() throws -> UInt8 {
        guard position < end else {
            throw WebMError.truncated
        }
        defer { position += 1 }
        return data[data.startIndex + position]
    }

    func bytes(_ element: Element) -> Data {
        let start = data.startIndex + element.payload.lowerBound
        let end = data.startIndex + element.payload.upperBound
        return Data(data[start..<end])
    }

    func unsigned(_ element: Element) throws -> UInt64 {
        guard (1...8).contains(element.payload.count) else {
            throw WebMError.invalidElement
        }
        return element.payload.reduce(UInt64(0)) { value, offset in
            value << 8 | UInt64(data[data.startIndex + offset])
        }
    }

    func floatingPoint(_ element: Element) throws -> Double {
        let bits = try unsigned(element)
        let value: Double
        switch element.payload.count {
        case 4:
            value = Double(Float(bitPattern: UInt32(bits)))
        case 8:
            value = Double(bitPattern: bits)
        default:
            throw WebMError.invalidElement
        }
        guard value.isFinite else {
            throw WebMError.invalidElement
        }
        return value
    }

    func string(_ element: Element) throws -> String {
        guard let value = String(data: bytes(element), encoding: .utf8) else {
            throw WebMError.invalidElement
        }
        return value.trimmingCharacters(in: .init(charactersIn: "\0"))
    }

    private mutating func variableInteger(
        maxBytes: Int, keepingMarker: Bool
    ) throws -> (value: UInt64, isUnknown: Bool) {
        let first = try byte()
        guard first != 0 else {
            throw WebMError.invalidVariableInteger
        }
        let width = first.leadingZeroBitCount + 1
        guard width <= maxBytes else {
            throw WebMError.invalidVariableInteger
        }
        let marker = UInt8(1 << (8 - width))
        var value = UInt64(keepingMarker ? first : first & (marker - 1))
        for _ in 1..<width {
            value = value << 8 | UInt64(try byte())
        }
        let unknown = !keepingMarker && value == (UInt64(1) << (7 * width)) - 1
        return (value, unknown)
    }
}
