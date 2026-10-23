import Foundation
import ImageIO

/// Minimal reader for a zip's central directory (USDZ is an uncompressed zip).
public struct ZipEntry {
    public var name: String
    public var method: UInt16
    public var compressedSize: UInt64
    public var size: UInt64
    public var localHeaderOffset: UInt64
}

public enum ZipReader {
    static func u16(_ d: Data, _ o: Int) -> UInt16 { d.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt16.self)) } }
    static func u32(_ d: Data, _ o: Int) -> UInt32 { d.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) } }
    static func u64(_ d: Data, _ o: Int) -> UInt64 { d.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt64.self)) } }

    public static func entries(_ url: URL) -> [ZipEntry] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let tailLen = min(size, 66_000 + 22)
        try? h.seek(toOffset: size - tailLen)
        guard let tail = try? h.read(upToCount: Int(tailLen)), tail.count >= 22 else { return [] }
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 { if u32(tail, i) == 0x06054b50 { eocd = i; break }; i -= 1 }
        guard eocd >= 0 else { return [] }
        var count = UInt64(u16(tail, eocd + 10))
        var cdSize = UInt64(u32(tail, eocd + 12))
        var cdOffset = UInt64(u32(tail, eocd + 16))
        // Zip64 end of central directory locator sits just before the EOCD.
        if (cdOffset == 0xFFFF_FFFF || count == 0xFFFF) && eocd >= 20 && u32(tail, eocd - 20) == 0x07064b50 {
            let z64 = u64(tail, eocd - 20 + 8)
            try? h.seek(toOffset: z64)
            if let rec = try? h.read(upToCount: 56), rec.count == 56, u32(rec, 0) == 0x06064b50 {
                count = u64(rec, 32); cdSize = u64(rec, 40); cdOffset = u64(rec, 48)
            }
        }
        try? h.seek(toOffset: cdOffset)
        guard let cd = try? h.read(upToCount: Int(cdSize)) else { return [] }
        var out: [ZipEntry] = []
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, u32(cd, p) == 0x02014b50 else { break }
            let method = u16(cd, p + 10)
            var csize = UInt64(u32(cd, p + 20)), usize = UInt64(u32(cd, p + 24))
            let nlen = Int(u16(cd, p + 28)), xlen = Int(u16(cd, p + 30)), clen = Int(u16(cd, p + 32))
            var off = UInt64(u32(cd, p + 42))
            let name = String(decoding: cd[(p + 46)..<(p + 46 + nlen)], as: UTF8.self)
            // Zip64 extra field
            var x = p + 46 + nlen
            let xend = x + xlen
            while x + 4 <= xend {
                let id = u16(cd, x), len = Int(u16(cd, x + 2))
                if id == 0x0001 {
                    var q = x + 4
                    if usize == 0xFFFF_FFFF { usize = u64(cd, q); q += 8 }
                    if csize == 0xFFFF_FFFF { csize = u64(cd, q); q += 8 }
                    if off == 0xFFFF_FFFF { off = u64(cd, q) }
                }
                x += 4 + len
            }
            out.append(ZipEntry(name: name, method: method, compressedSize: csize, size: usize, localHeaderOffset: off))
            p += 46 + nlen + xlen + clen
        }
        return out
    }

    /// Raw bytes of a STORED entry.
    public static func storedData(_ url: URL, _ e: ZipEntry) -> Data? {
        guard e.method == 0, let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        try? h.seek(toOffset: e.localHeaderOffset)
        guard let lh = try? h.read(upToCount: 30), lh.count == 30, u32(lh, 0) == 0x04034b50 else { return nil }
        let start = e.localHeaderOffset + 30 + UInt64(u16(lh, 26)) + UInt64(u16(lh, 28))
        try? h.seek(toOffset: start)
        return try? h.read(upToCount: Int(e.size))
    }
}

public struct TextureInfo: CustomStringConvertible {
    public var name: String
    public var width: Int
    public var height: Int
    public var bytes: Int64
    public var description: String { "\(name) \(width)x\(height) \(Fmt.bytes(bytes))" }
}

public struct MeshStats {
    public var faces: Int = 0
    public var triangles: Int = 0
    public var points: Int = 0
    public var meshes: Int = 0
    public var metersPerUnit: Double?
    public var extent: [Double] = [] // minx miny minz maxx maxy maxz (stage units)
    public var source: String = ""

    public var sizeMeters: (Double, Double, Double)? {
        guard extent.count == 6 else { return nil }
        let m = metersPerUnit ?? 1
        return ((extent[3] - extent[0]) * m, (extent[4] - extent[1]) * m, (extent[5] - extent[2]) * m)
    }
}

public enum ModelInspector {
    /// Streams `usdcat <usdz>` (USDA text) and counts faceVertexCounts entries. Works for
    /// multi-million polygon raw models without holding the text in memory.
    public static func usdStats(_ usdz: URL, usdcat: String = "/usr/bin/usdcat") -> (MeshStats, String?) {
        guard Shell.exists(usdcat) else { return (MeshStats(), "usdcat not found at \(usdcat)") }
        var s = MeshStats()
        s.source = "usdcat"
        let fvc = Array("faceVertexCounts = [".utf8)
        let pts = Array("point3f[] points = [".utf8)
        let mpu = Array("metersPerUnit = ".utf8)
        let ext = Array("extent = [".utf8)
        enum Mode { case scan, inFVC, inPoints, inMPU, inExtent }
        var mode = Mode.scan
        // Rolling matchers for each keyword
        var mF = 0, mP = 0, mM = 0, mE = 0
        var number: Int = 0
        var haveNumber = false
        var depth = 0
        var commas = 0
        var nonEmpty = false
        var text: [UInt8] = []
        var extentDone = false

        func flushFace() {
            if haveNumber { s.faces += 1; s.triangles += max(number - 2, 0) }
            number = 0; haveNumber = false
        }

        let r: (status: Int32, stderr: String)
        do {
            r = try Shell.stream(usdcat, [usdz.path]) { chunk in
                chunk.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                    for b in buf {
                        switch mode {
                        case .scan:
                            mF = (b == fvc[mF]) ? mF + 1 : (b == fvc[0] ? 1 : 0)
                            mP = (b == pts[mP]) ? mP + 1 : (b == pts[0] ? 1 : 0)
                            mM = (b == mpu[mM]) ? mM + 1 : (b == mpu[0] ? 1 : 0)
                            mE = (b == ext[mE]) ? mE + 1 : (b == ext[0] ? 1 : 0)
                            if mF == fvc.count { mode = .inFVC; mF = 0; s.meshes += 1; number = 0; haveNumber = false }
                            else if mP == pts.count { mode = .inPoints; mP = 0; depth = 0; commas = 0; nonEmpty = false }
                            else if mM == mpu.count { mode = .inMPU; mM = 0; text = [] }
                            else if mE == ext.count && !extentDone { mode = .inExtent; mE = 0; text = [] }
                        case .inFVC:
                            if b >= 48 && b <= 57 { number = number * 10 + Int(b - 48); haveNumber = true }
                            else if b == 44 { flushFace() } // ,
                            else if b == 93 { flushFace(); mode = .scan } // ]
                        case .inPoints:
                            if b == 40 { depth += 1; nonEmpty = true } // (
                            else if b == 41 { depth -= 1 }
                            else if b == 44 && depth == 0 { commas += 1 }
                            else if b == 93 && depth == 0 { s.points += nonEmpty ? commas + 1 : 0; mode = .scan }
                        case .inMPU:
                            if b == 10 || b == 13 { s.metersPerUnit = Double(String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespaces)); mode = .scan }
                            else { text.append(b) }
                        case .inExtent:
                            if b == 93 {
                                let nums = String(decoding: text, as: UTF8.self)
                                    .split(whereSeparator: { "(), ".contains($0) }).compactMap { Double($0) }
                                if nums.count == 6 { s.extent = nums; extentDone = true }
                                mode = .scan
                            } else { text.append(b) }
                        }
                    }
                }
            }
        } catch {
            return (s, "usdcat failed to start: \(error)")
        }
        if r.status != 0 { return (s, "usdcat exit \(r.status): \(r.stderr.suffix(400))") }
        return (s, nil)
    }

    /// Textures inside a USDZ, with pixel dimensions read from their headers.
    public static func usdzTextures(_ usdz: URL) -> [TextureInfo] {
        ZipReader.entries(usdz).compactMap { e in
            let ext = (e.name as NSString).pathExtension.lowercased()
            guard ["png", "jpg", "jpeg", "exr", "heic", "ktx", "tif", "tiff"].contains(ext) else { return nil }
            var w = 0, h = 0
            if let d = ZipReader.storedData(usdz, e), let src = CGImageSourceCreateWithData(d as CFData, nil),
               let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
                h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            }
            return TextureInfo(name: e.name, width: w, height: h, bytes: Int64(e.size))
        }
    }

    public static func imageDims(_ url: URL) -> (Int, Int) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (0, 0) }
        return ((p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0, (p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0)
    }

    /// Counts `f` and `v` lines in an OBJ by streaming it.
    public static func objStats(_ obj: URL) -> MeshStats {
        var s = MeshStats()
        s.source = "obj"
        guard let h = try? FileHandle(forReadingFrom: obj) else { return s }
        defer { try? h.close() }
        var atLineStart = true
        var prev: UInt8 = 0
        var inFace = false
        var verts = 0
        var inToken = false
        var mn = [Double.infinity, .infinity, .infinity], mx = [-Double.infinity, -.infinity, -.infinity]
        var vline: [UInt8] = []
        var inV = false
        while let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty {
            for b in chunk {
                if atLineStart {
                    if b == 102 { inFace = true; verts = 0; inToken = false } // f
                    else if b == 118 { inV = true; vline = [] } // v (could be vt/vn; checked on next byte)
                    atLineStart = false
                    prev = b
                    continue
                }
                if inV && prev == 118 && vline.isEmpty && b != 32 && b != 9 { inV = false } // vt / vn / vp
                if b == 10 {
                    if inFace {
                        if inToken { verts += 1 }
                        s.faces += 1; s.triangles += max(verts - 2, 0)
                        inFace = false
                    }
                    if inV {
                        s.points += 1
                        let n = String(decoding: vline, as: UTF8.self).split(separator: " ").prefix(3).compactMap { Double($0) }
                        if n.count == 3 { for k in 0..<3 { mn[k] = min(mn[k], n[k]); mx[k] = max(mx[k], n[k]) } }
                        inV = false
                    }
                    atLineStart = true
                } else if inFace {
                    let ws = (b == 32 || b == 9 || b == 13)
                    if ws { if inToken { verts += 1; inToken = false } } else { inToken = true }
                } else if inV {
                    vline.append(b)
                }
                prev = b
            }
        }
        if inFace { if inToken { verts += 1 }; s.faces += 1; s.triangles += max(verts - 2, 0) }
        if mn[0].isFinite { s.extent = mn + mx }
        s.meshes = 1
        return s
    }

    public struct CheckResult {
        public var passed: Bool
        public var exitCode: Int32
        public var output: String
        public var noiseLines: Int
    }

    /// `usdchecker --arkit`, with the harmless "Coding Error ... RegisterBehaviorForPrimTypeId" noise removed.
    public static func usdcheck(_ usdz: URL, usdchecker: String = "/usr/bin/usdchecker") -> CheckResult {
        guard Shell.exists(usdchecker) else { return CheckResult(passed: false, exitCode: -1, output: "usdchecker not found", noiseLines: 0) }
        guard let r = try? Shell.run(usdchecker, ["--arkit", usdz.path]) else {
            return CheckResult(passed: false, exitCode: -1, output: "usdchecker failed to start", noiseLines: 0)
        }
        let all = (r.stdout + "\n" + r.stderr).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let noise = all.filter { $0.contains("RegisterBehaviorForPrimTypeId") || $0.contains("Coding Error") }
        let kept = all.filter { !($0.contains("RegisterBehaviorForPrimTypeId") || $0.contains("Coding Error")) }
        let passed = r.status == 0 && kept.contains { $0.hasPrefix("Success") }
        return CheckResult(passed: passed, exitCode: r.status, output: kept.joined(separator: "\n"), noiseLines: noise.count)
    }
}
