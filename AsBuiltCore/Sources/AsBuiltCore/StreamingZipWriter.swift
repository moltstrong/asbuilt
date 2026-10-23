import Foundation

/// Streaming ZIP writer (STORE method) for large archives such as an Object Capture photo set.
///
/// Files are copied in fixed-size chunks through a `FileHandle` with a running CRC-32, so memory
/// stays flat no matter how big the photos are. Local headers carry the sizes and CRC (no data
/// descriptors): each entry's header is written with placeholders and patched in place once the
/// entry is done. Archives or entries past 4 GiB / 65,535 entries get Zip64 records automatically.
///
///     let zip = try StreamingZipWriter(url: out)
///     try zip.addFile(at: photo, path: "Images/IMG_0001.HEIC")
///     try zip.addData(logData, path: "reconstruction-log.txt")
///     try zip.finish()
public final class StreamingZipWriter {
    public enum ZipError: Error, LocalizedError, Equatable {
        case alreadyFinished
        case unreadableFile(String)
        case pathTooLong(String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .alreadyFinished: return "The archive was already finished."
            case .unreadableFile(let path): return "Could not read \(path)."
            case .pathTooLong(let path): return "File name too long for ZIP: \(path)"
            case .cancelled: return "Export cancelled."
            }
        }
    }

    struct CentralRecord {
        var name: Data
        var crc: UInt32
        var size: UInt64
        var offset: UInt64
        var time: UInt16
        var date: UInt16
        var zip64: Bool
    }

    public let url: URL
    public let chunkSize: Int
    /// Entries at or above this size get a Zip64 local header (tests lower it to exercise Zip64).
    let zip64Threshold: UInt64
    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var records: [CentralRecord] = []
    private var finished = false
    /// Total bytes of file data written so far.
    public private(set) var bytesWritten: UInt64 = 0
    /// Set from another thread to stop between chunks (`ZipError.cancelled`).
    public var isCancelled: () -> Bool = { false }

    public init(url: URL, chunkSize: Int = 1 << 20, zip64Threshold: UInt64 = 0xFFFF_FFFF) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        self.url = url
        self.chunkSize = max(4096, chunkSize)
        self.zip64Threshold = zip64Threshold
    }

    deinit {
        if !finished { try? handle.close() }
    }

    public var entryCount: Int { records.count }

    /// Streams the file at `fileURL` into the archive as `path`.
    public func addFile(at fileURL: URL, path: String, modified: Date? = nil) throws {
        guard let input = try? FileHandle(forReadingFrom: fileURL) else { throw ZipError.unreadableFile(fileURL.lastPathComponent) }
        defer { try? input.close() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let expected = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let date = modified ?? (attributes?[.modificationDate] as? Date) ?? Date()
        try addEntry(path: path, expectedSize: expected, modified: date) { sink in
            while true {
                if self.isCancelled() { throw ZipError.cancelled }
                let chunk = try autoreleasepool { () throws -> Data? in try input.read(upToCount: self.chunkSize) }
                guard let chunk, !chunk.isEmpty else { break }
                try sink(chunk)
            }
        }
    }

    /// Adds in-memory bytes (small files such as logs).
    public func addData(_ data: Data, path: String, modified: Date = Date()) throws {
        try addEntry(path: path, expectedSize: UInt64(data.count), modified: modified) { sink in
            var start = 0
            while start < data.count {
                let end = min(data.count, start + self.chunkSize)
                try sink(data.subdata(in: start..<end))
                start = end
            }
        }
    }

    /// Adds every regular file under `directory` (sorted, recursive) with paths prefixed by `prefix`.
    /// `progress` gets (bytes so far, total bytes).
    public func addDirectory(_ directory: URL, prefix: String, progress: ((UInt64, UInt64) -> Void)? = nil) throws {
        let files = Self.regularFiles(in: directory)
        let total = files.reduce(UInt64(0)) { $0 + $1.size }
        var done: UInt64 = 0
        // "Images" and "Images/" both mean the folder Images (no "ImagesIMG_1.HEIC" entries).
        let folder = prefix.isEmpty || prefix.hasSuffix("/") ? prefix : prefix + "/"
        for file in files {
            try addFile(at: file.url, path: folder + file.relativePath)
            done += file.size
            progress?(done, total)
        }
    }

    /// Regular files under `directory`, sorted by relative path.
    public static func regularFiles(in directory: URL) -> [(url: URL, relativePath: String, size: UInt64)] {
        let base = directory.standardizedFileURL.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return [] }
        var out: [(URL, String, UInt64)] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            var relative = full.hasPrefix(base) ? String(full.dropFirst(base.count)) : url.lastPathComponent
            while relative.hasPrefix("/") { relative.removeFirst() }
            out.append((url, relative, UInt64(values?.fileSize ?? 0)))
        }
        return out.sorted { $0.1 < $1.1 }
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    private func addEntry(path: String, expectedSize: UInt64, modified: Date, body: (_ sink: (Data) throws -> Void) throws -> Void) throws {
        guard !finished else { throw ZipError.alreadyFinished }
        let name = Data(path.utf8)
        guard name.count <= 0xFFFF else { throw ZipError.pathTooLong(path) }
        let (time, date) = ZipWriter.dosDateTime(modified)
        let headerOffset = offset
        // Zip64 up front when the entry may not fit 32 bits (the local header can't grow later).
        let zip64 = expectedSize >= zip64Threshold || headerOffset >= 0xFFFF_FFFF
        var header = Data()
        header.appendLE(UInt32(0x04034b50))
        header.appendLE(UInt16(zip64 ? 45 : 20))
        header.appendLE(UInt16(1 << 11)) // UTF-8 names
        header.appendLE(UInt16(0))       // store
        header.appendLE(time)
        header.appendLE(date)
        header.appendLE(UInt32(0))       // crc (patched)
        header.appendLE(zip64 ? UInt32.max : 0) // compressed size (patched)
        header.appendLE(zip64 ? UInt32.max : 0) // size (patched)
        header.appendLE(UInt16(name.count))
        header.appendLE(UInt16(zip64 ? 20 : 0))
        header.append(name)
        if zip64 {
            header.appendLE(UInt16(0x0001))
            header.appendLE(UInt16(16))
            header.appendLE(UInt64(0)) // size (patched)
            header.appendLE(UInt64(0)) // compressed size (patched)
        }
        try write(header)

        var crc: UInt32 = 0xFFFF_FFFF
        var size: UInt64 = 0
        try body { chunk in
            crc = CRC32.update(crc, chunk)
            size += UInt64(chunk.count)
            try self.write(chunk)
        }
        crc ^= 0xFFFF_FFFF
        bytesWritten += size
        if size >= 0xFFFF_FFFF && !zip64 {
            // Grew past 4 GiB after the header was written without Zip64 room: refuse rather than corrupt.
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "\(path) grew past 4 GB while being archived."])
        }

        // Patch CRC and sizes in the local header.
        let end = offset
        try handle.seek(toOffset: headerOffset + 14)
        var patch = Data()
        patch.appendLE(crc)
        if zip64 {
            patch.appendLE(UInt32.max)
            patch.appendLE(UInt32.max)
        } else {
            patch.appendLE(UInt32(size))
            patch.appendLE(UInt32(size))
        }
        try handle.write(contentsOf: patch)
        if zip64 {
            try handle.seek(toOffset: headerOffset + 30 + UInt64(name.count) + 4)
            var sizes = Data()
            sizes.appendLE(size)
            sizes.appendLE(size)
            try handle.write(contentsOf: sizes)
        }
        try handle.seek(toOffset: end)
        records.append(CentralRecord(name: name, crc: crc, size: size, offset: headerOffset, time: time, date: date,
                                     zip64: zip64 || headerOffset >= 0xFFFF_FFFF))
    }

    /// Writes the central directory (and Zip64 end records when needed) and closes the file.
    public func finish() throws {
        guard !finished else { throw ZipError.alreadyFinished }
        let centralStart = offset
        for r in records {
            let needs64 = r.zip64 || r.size >= 0xFFFF_FFFF || r.offset >= 0xFFFF_FFFF
            var c = Data()
            c.appendLE(UInt32(0x02014b50))
            c.appendLE(UInt16(0x032D))          // made by: UNIX, 4.5
            c.appendLE(UInt16(needs64 ? 45 : 20))
            c.appendLE(UInt16(1 << 11))
            c.appendLE(UInt16(0))
            c.appendLE(r.time)
            c.appendLE(r.date)
            c.appendLE(r.crc)
            c.appendLE(needs64 ? UInt32.max : UInt32(r.size))
            c.appendLE(needs64 ? UInt32.max : UInt32(r.size))
            c.appendLE(UInt16(r.name.count))
            c.appendLE(UInt16(needs64 ? 28 : 0))
            c.appendLE(UInt16(0))               // comment
            c.appendLE(UInt16(0))               // disk
            c.appendLE(UInt16(0))               // internal attrs
            c.appendLE(UInt32(0o100644) << 16)  // -rw-r--r--
            c.appendLE(needs64 ? UInt32.max : UInt32(r.offset))
            c.append(r.name)
            if needs64 {
                c.appendLE(UInt16(0x0001))
                c.appendLE(UInt16(24))
                c.appendLE(r.size)
                c.appendLE(r.size)
                c.appendLE(r.offset)
            }
            try write(c)
        }
        let centralSize = offset - centralStart
        let count = UInt64(records.count)
        let needsEnd64 = count >= 0xFFFF || centralStart >= 0xFFFF_FFFF || centralSize >= 0xFFFF_FFFF || records.contains { $0.zip64 }
        if needsEnd64 {
            let end64Offset = offset
            var e = Data()
            e.appendLE(UInt32(0x06064b50))
            e.appendLE(UInt64(44))
            e.appendLE(UInt16(0x032D))
            e.appendLE(UInt16(45))
            e.appendLE(UInt32(0))
            e.appendLE(UInt32(0))
            e.appendLE(count)
            e.appendLE(count)
            e.appendLE(centralSize)
            e.appendLE(centralStart)
            // Locator.
            e.appendLE(UInt32(0x07064b50))
            e.appendLE(UInt32(0))
            e.appendLE(end64Offset)
            e.appendLE(UInt32(1))
            try write(e)
        }
        var end = Data()
        end.appendLE(UInt32(0x06054b50))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(min(count, 0xFFFF)))
        end.appendLE(UInt16(min(count, 0xFFFF)))
        end.appendLE(UInt32(min(centralSize, 0xFFFF_FFFF)))
        end.appendLE(UInt32(min(centralStart, 0xFFFF_FFFF)))
        end.appendLE(UInt16(0))
        try write(end)
        try handle.synchronize()
        try handle.close()
        finished = true
    }
}

extension CRC32 {
    /// Continues a running (pre-inverted) CRC-32 over `data`. Start with 0xFFFFFFFF, finish with ^ 0xFFFFFFFF.
    public static func update(_ crc: UInt32, _ data: Data) -> UInt32 {
        var c = crc
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            table.withUnsafeBufferPointer { t in
                for byte in buffer {
                    c = t[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
                }
            }
        }
        return c
    }
}
