import Foundation
import ImageIO

public enum InputError: Error, CustomStringConvertible {
    case notFound(String)
    case noImages(String)
    case extractFailed(String)
    public var description: String {
        switch self {
        case .notFound(let p): return "Input not found: \(p)"
        case .noImages(let p): return "No HEIC/JPEG/PNG/TIFF photos found in \(p)"
        case .extractFailed(let m): return "Couldn't unzip the input: \(m)"
        }
    }
}

/// A resolved photo folder: either the user's folder or a temp folder extracted from a zip.
public struct ResolvedInput {
    public var original: URL
    public var imagesFolder: URL
    public var images: [URL]
    public var isZip: Bool
    /// Temp root to delete afterwards (zip inputs only).
    public var tempRoot: URL?
    public var extractSeconds: Double = 0

    public func cleanup() {
        if let t = tempRoot { try? FileManager.default.removeItem(at: t) }
    }
}

public enum InputResolver {
    public static let imageExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff"]

    public static func isImage(_ url: URL) -> Bool {
        let n = url.lastPathComponent
        return !n.hasPrefix(".") && imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Images directly inside `folder` (PhotogrammetrySession reads one level), sorted by name.
    public static func images(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { isImage($0) && ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// The folder (at or below `root`) holding the most images. AsBuilt exports may put photos in
    /// `Images/`, a capture folder, or the zip root; Finder zips add `__MACOSX/`, which is skipped.
    public static func bestImageFolder(under root: URL) -> (URL, [URL])? {
        var best: (URL, [URL])?
        func consider(_ dir: URL) {
            let imgs = images(in: dir)
            if !imgs.isEmpty, imgs.count > (best?.1.count ?? 0) { best = (dir, imgs) }
        }
        consider(root)
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let u as URL in e {
                if u.lastPathComponent == "__MACOSX" { e.skipDescendants(); continue }
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { consider(u) }
            }
        }
        return best
    }

    public static func isZip(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "zip" { return true }
        guard let h = FileHandle(forReadingAtPath: url.path) else { return false }
        defer { try? h.close() }
        let magic = h.readData(ofLength: 4)
        return magic == Data([0x50, 0x4B, 0x03, 0x04])
    }

    public static func resolve(_ path: String, scratch: URL? = nil) throws -> ResolvedInput {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw InputError.notFound(url.path) }
        if isDir.boolValue {
            guard let (folder, imgs) = bestImageFolder(under: url) else { throw InputError.noImages(url.path) }
            return ResolvedInput(original: url, imagesFolder: folder, images: imgs, isZip: false, tempRoot: nil)
        }
        guard isZip(url) else { throw InputError.noImages(url.path + " (not a folder or .zip)") }
        let base = scratch ?? FileManager.default.temporaryDirectory
        let tmp = base.appendingPathComponent("asbuilt-recon-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let t0 = Date()
        // ditto handles both deflate and STORE zips (and Finder's resource forks); unzip is the fallback.
        var r = try Shell.run("/usr/bin/ditto", ["-x", "-k", url.path, tmp.path])
        if r.status != 0 {
            let first = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            r = try Shell.run("/usr/bin/unzip", ["-q", "-o", url.path, "-d", tmp.path])
            if r.status != 0 {
                try? FileManager.default.removeItem(at: tmp)
                throw InputError.extractFailed("ditto: \(first); unzip: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        let secs = Date().timeIntervalSince(t0)
        guard let (folder, imgs) = bestImageFolder(under: tmp) else {
            try? FileManager.default.removeItem(at: tmp)
            throw InputError.noImages(url.path)
        }
        return ResolvedInput(original: url, imagesFolder: folder, images: imgs, isZip: true, tempRoot: tmp, extractSeconds: secs)
    }
}

/// What ImageIO can tell about one photo without decoding pixels.
public struct ImageFacts {
    public var url: URL
    public var width: Int
    public var height: Int
    public var type: String
    public var bytes: Int64
    public var make: String?
    public var model: String?
    public var hasDepth: Bool
    public var hasDisparity: Bool
    public var auxTypes: [String]
    public var hasObjectCapture: Bool { auxTypes.contains { $0.contains("ObjectCapture") } }

    public static func read(_ url: URL) -> ImageFacts? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let depth = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeDepth) != nil
        let disparity = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeDisparity) != nil
        var aux: [String] = []
        if let container = CGImageSourceCopyProperties(src, nil) as? [CFString: Any],
           let contents = container[kCGImagePropertyFileContentsDictionary] as? [CFString: Any],
           let images = contents[kCGImagePropertyImages] as? [[CFString: Any]] {
            for img in images {
                for a in img[kCGImagePropertyAuxiliaryData] as? [[CFString: Any]] ?? [] {
                    if let t = a[kCGImagePropertyAuxiliaryDataType] as? String, !aux.contains(t) { aux.append(t) }
                }
            }
        }
        return ImageFacts(url: url, width: w, height: h,
                          type: (CGImageSourceGetType(src) as String?) ?? url.pathExtension,
                          bytes: Fmt.fileSize(url),
                          make: tiff?[kCGImagePropertyTIFFMake] as? String,
                          model: tiff?[kCGImagePropertyTIFFModel] as? String,
                          hasDepth: depth, hasDisparity: disparity, auxTypes: aux)
    }
}

public struct ImageSetSummary {
    public var count: Int
    public var unreadable: [String]
    public var resolutions: [(String, Int)]
    public var types: [(String, Int)]
    public var cameras: [(String, Int)]
    public var withDepth: Int
    public var withObjectCapture: Int
    public var auxTypes: [(String, Int)]
    public var totalBytes: Int64

    public static func summarize(_ urls: [URL]) -> ImageSetSummary {
        var res: [String: Int] = [:], types: [String: Int] = [:], cams: [String: Int] = [:], aux: [String: Int] = [:]
        var depth = 0, oc = 0, total: Int64 = 0
        var bad: [String] = []
        for u in urls {
            guard let f = ImageFacts.read(u) else { bad.append(u.lastPathComponent); continue }
            res["\(f.width)x\(f.height)", default: 0] += 1
            types[f.type, default: 0] += 1
            let cam = [f.make, f.model].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            cams[cam.isEmpty ? "unknown" : cam, default: 0] += 1
            if f.hasDepth || f.hasDisparity { depth += 1 }
            if f.hasObjectCapture { oc += 1 }
            for t in f.auxTypes { aux[t, default: 0] += 1 }
            total += f.bytes
        }
        func sorted(_ d: [String: Int]) -> [(String, Int)] { d.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key } }
        return ImageSetSummary(count: urls.count, unreadable: bad, resolutions: sorted(res), types: sorted(types), cameras: sorted(cams),
                               withDepth: depth, withObjectCapture: oc, auxTypes: sorted(aux), totalBytes: total)
    }

    public var lines: [String] {
        var l = ["images: \(count) (\(Fmt.bytes(totalBytes)))"]
        l.append("resolution: " + resolutions.map { "\($0.0) x\($0.1)" }.joined(separator: ", "))
        l.append("format: " + types.map { "\($0.0) x\($0.1)" }.joined(separator: ", "))
        l.append("camera: " + cameras.map { "\($0.0) x\($0.1)" }.joined(separator: ", "))
        l.append("depth map (LiDAR/stereo): \(withDepth)/\(count)")
        l.append("Object Capture metadata: \(withObjectCapture)/\(count)")
        if !auxTypes.isEmpty {
            l.append("auxiliary data:")
            for (t, n) in auxTypes { l.append("  \(t) x\(n)") }
        }
        if !unreadable.isEmpty { l.append("unreadable: \(unreadable.count): \(unreadable.prefix(10).joined(separator: ", "))") }
        return l
    }
}
