import Foundation

public enum Shell {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    /// Runs a tool and captures stdout/stderr (both drained concurrently to avoid pipe deadlocks).
    @discardableResult
    public static func run(_ path: String, _ args: [String], cwd: URL? = nil) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.wait()
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self))
    }

    /// Runs a tool and feeds its stdout to `consume` in chunks (for multi-hundred-MB usdcat output).
    public static func stream(_ path: String, _ args: [String], consume: (Data) -> Void) throws -> (status: Int32, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let h = out.fileHandleForReading
        while true {
            let chunk = h.readData(ofLength: 4 << 20)
            if chunk.isEmpty { break }
            consume(chunk)
        }
        group.wait()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: errData, as: UTF8.self))
    }

    public static func exists(_ path: String) -> Bool { FileManager.default.isExecutableFile(atPath: path) }
}

public enum Fmt {
    public static func bytes(_ n: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(n), i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        return i == 0 ? "\(n) B" : String(format: v >= 100 ? "%.0f %@" : "%.1f %@", v, units[i])
    }

    public static func duration(_ s: Double) -> String {
        if s < 60 { return String(format: "%.1fs", s) }
        let t = Int(s.rounded())
        if t < 3600 { return String(format: "%dm%02ds", t / 60, t % 60) }
        return String(format: "%dh%02dm%02ds", t / 3600, (t % 3600) / 60, t % 60)
    }

    public static func count(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    public static func timestamp(_ d: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: d)
    }

    public static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Total size of a file or folder tree.
    public static func treeSize(_ url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return fileSize(url) }
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let f as URL in e {
                if let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true {
                    total += Int64(v.fileSize ?? 0)
                }
            }
        }
        return total
    }
}
