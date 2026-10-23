import Foundation

/// Append-only byte buffer for large text exports (USDA, OBJ, CSV) and binary ones (PLY).
///
/// Numbers are formatted by hand into the preallocated buffer: no `String(format:)`, no string
/// interpolation and no per-vertex `String` allocation in the hot loops, so a 300k-triangle scan
/// exports in well under a second in release builds.
public struct ByteBuffer {
    public private(set) var bytes: [UInt8]

    public init(capacity: Int = 0) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    public var count: Int { bytes.count }
    public var data: Data { Data(bytes) }
    public var string: String { String(decoding: bytes, as: UTF8.self) }

    @inline(__always)
    public mutating func append(_ byte: UInt8) { bytes.append(byte) }

    @inline(__always)
    public mutating func append(_ text: StaticString) {
        text.withUTF8Buffer { bytes.append(contentsOf: $0) }
    }

    public mutating func append(_ text: String) {
        var text = text
        text.withUTF8 { bytes.append(contentsOf: $0) }
    }

    /// Decimal integer.
    @inline(__always)
    public mutating func append(int value: Int) {
        if value < 0 {
            bytes.append(UInt8(ascii: "-"))
            appendUnsigned(UInt64(-Int64(value)))
        } else {
            appendUnsigned(UInt64(value))
        }
    }

    @inline(__always)
    public mutating func append(uint value: UInt32) { appendUnsigned(UInt64(value)) }

    @inline(__always)
    mutating func appendUnsigned(_ value: UInt64) {
        if value < 10 {
            bytes.append(UInt8(truncatingIfNeeded: value) &+ 48)
            return
        }
        let start = bytes.count
        var n = value
        while n > 0 {
            bytes.append(UInt8(truncatingIfNeeded: n % 10) &+ 48)
            n /= 10
        }
        bytes[start...].reverse()
    }

    private static let pow10: [Double] = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000]

    /// Fixed-point decimal with up to `decimals` (0...6) places, trailing zeros trimmed, never "-0".
    /// Non-finite values print as 0.
    @inline(__always)
    public mutating func append(fixed value: Double, decimals: Int = 5) {
        let places = min(6, max(0, decimals))
        let scale = Self.pow10[places]
        guard value.isFinite, abs(value) < 9e12 else {
            bytes.append(UInt8(ascii: "0"))
            return
        }
        let scaled = (value * scale).rounded()
        if scaled == 0 {
            bytes.append(UInt8(ascii: "0"))
            return
        }
        let units = UInt64(abs(scaled))
        let divisor = UInt64(scale)
        let whole = units / divisor
        var fraction = units % divisor
        if scaled < 0 { bytes.append(UInt8(ascii: "-")) }
        appendUnsigned(whole)
        guard fraction > 0 else { return }
        // `fraction` has `places` decimal digits; drop trailing zeros, keep leading ones.
        var width = places
        while fraction % 10 == 0 {
            fraction /= 10
            width -= 1
        }
        bytes.append(UInt8(ascii: "."))
        var significant = 1
        var probe = fraction
        while probe >= 10 {
            probe /= 10
            significant += 1
        }
        for _ in 0..<max(0, width - significant) { bytes.append(UInt8(ascii: "0")) }
        appendUnsigned(fraction)
    }

    @inline(__always)
    public mutating func append(fixed value: Float, decimals: Int = 5) {
        append(fixed: Double(value), decimals: decimals)
    }

    // MARK: Binary (little-endian)

    @inline(__always)
    public mutating func appendLE(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    @inline(__always)
    public mutating func appendLE(_ value: Float) { appendLE(value.bitPattern) }
}
