import Foundation

/// Minimal ZIP (PKWARE APPNOTE 6.3) writer using the STORE method (no compression).
/// CAD/estimating files are small and mostly text; the point is a single attachment
/// that unzips everywhere (Finder, Windows Explorer, iOS Files, email clients).
public struct ZipWriter {
    public struct Entry: Sendable {
        public var path: String
        public var data: Data
        public var modified: Date

        public init(path: String, data: Data, modified: Date = Date()) {
            self.path = path
            self.data = data
            self.modified = modified
        }
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    public mutating func add(path: String, data: Data, modified: Date = Date()) {
        entries.append(Entry(path: path, data: data, modified: modified))
    }

    public func archive() -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            let crc = CRC32.checksum(entry.data)
            let size = UInt32(entry.data.count)
            let (time, date) = Self.dosDateTime(entry.modified)
            let offset = UInt32(out.count)
            let utf8Flag: UInt16 = 1 << 11

            // Local file header.
            out.appendLE(UInt32(0x04034b50))
            out.appendLE(UInt16(20))       // version needed
            out.appendLE(utf8Flag)
            out.appendLE(UInt16(0))        // method: store
            out.appendLE(time)
            out.appendLE(date)
            out.appendLE(crc)
            out.appendLE(size)
            out.appendLE(size)
            out.appendLE(UInt16(name.count))
            out.appendLE(UInt16(0))
            out.append(name)
            out.append(entry.data)

            // Central directory header.
            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(0x031E)) // made by: UNIX, 3.0
            central.appendLE(UInt16(20))
            central.appendLE(utf8Flag)
            central.appendLE(UInt16(0))
            central.appendLE(time)
            central.appendLE(date)
            central.appendLE(crc)
            central.appendLE(size)
            central.appendLE(size)
            central.appendLE(UInt16(name.count))
            central.appendLE(UInt16(0)) // extra
            central.appendLE(UInt16(0)) // comment
            central.appendLE(UInt16(0)) // disk
            central.appendLE(UInt16(0)) // internal attrs
            central.appendLE(UInt32(0o100644) << 16) // external attrs: -rw-r--r--
            central.appendLE(offset)
            central.append(name)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        // End of central directory.
        out.appendLE(UInt32(0x06054b50))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt32(central.count))
        out.appendLE(centralOffset)
        out.appendLE(UInt16(0))
        return out
    }

    static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = max(1980, c.year ?? 1980)
        let hour: Int = c.hour ?? 0
        let minute: Int = c.minute ?? 0
        let second: Int = c.second ?? 0
        let month: Int = c.month ?? 1
        let dayOfMonth: Int = c.day ?? 1
        let timeBits: Int = (hour << 11) | (minute << 5) | (second / 2)
        let dateBits: Int = ((year - 1980) << 9) | (month << 5) | dayOfMonth
        return (UInt16(timeBits), UInt16(dateBits))
    }
}

public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size {
            value |= T(self[self.startIndex + offset + i]) << (8 * i)
        }
        return value
    }
}
