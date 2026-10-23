import Foundation

/// Appends to recon-log.txt as it goes (so a crash still leaves a log) and echoes to the console.
public final class ReconLog: @unchecked Sendable {
    public let url: URL?
    private var handle: FileHandle?
    private let lock = NSLock()
    public var echo: Bool
    public private(set) var lines: [String] = []

    public init(url: URL?, echo: Bool = true) {
        self.url = url
        self.echo = echo
        if let url {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
        }
    }

    public func add(_ s: String, console: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        lines.append(s)
        handle?.write(Data((s + "\n").utf8))
        if echo && console { print(s); fflush(stdout) }
    }

    public func section(_ title: String) { add(""); add("== \(title)") }

    public func close() { try? handle?.close(); handle = nil }
}

/// Machine-readable live status (the server polls this file).
public struct LiveStatus: Codable {
    public var state: String = "starting" // starting|extracting|processing|inspecting|done|failed
    public var attempt: Int = 0
    public var fraction: Double = 0
    public var etaSeconds: Double?
    public var stage: String?
    public var message: String = ""
    public var updatedAt: String = Fmt.timestamp()
    public var pid: Int32 = ProcessInfo.processInfo.processIdentifier
}

public final class StatusWriter: @unchecked Sendable {
    let url: URL?
    var status = LiveStatus()
    var lastWrite = Date.distantPast
    public init(url: URL?) { self.url = url }

    public func update(force: Bool = false, _ f: (inout LiveStatus) -> Void) {
        f(&status)
        guard let url else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastWrite) >= 1 else { return }
        lastWrite = now
        status.updatedAt = Fmt.timestamp(now)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let d = try? enc.encode(status) {
            try? d.write(to: url, options: .atomic)
        }
    }
}

/// Final result of one `build`, also written as result.json next to the model.
public struct BuildResult: Codable {
    public struct FileInfo: Codable { public var name: String; public var bytes: Int64 }
    public struct Texture: Codable { public var name: String; public var width: Int; public var height: Int; public var bytes: Int64 }
    public var ok: Bool = false
    public var detail: String = ""
    public var config: String = ""
    public var imageCount: Int = 0
    public var attempts: Int = 0
    public var winningAttempt: String?
    public var totalSeconds: Double = 0
    public var reconstructionSeconds: Double = 0
    public var stageSeconds: [String: Double] = [:]
    public var polygons: Int?
    public var triangles: Int?
    public var vertices: Int?
    public var objPolygons: Int?
    public var sizeMeters: [Double]?
    public var textures: [Texture] = []
    public var objTextures: [Texture] = []
    public var files: [FileInfo] = []
    public var usdcheckerPassed: Bool?
    public var usdcheckerOutput: String?
    public var peakMemoryBytes: Int64?
    public var errorTechnical: String?
    public var errorMessage: String?
    public var invalidSamples: Int = 0
    public var skippedSamples: Int = 0
    public var automaticDownsampling: Bool = false
    public var notes: [String] = []
}

public func peakRSS() -> Int64 {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Int64(u.ru_maxrss) // bytes on macOS
}

public func machineSummary() -> String {
    func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }
    let mem = ProcessInfo.processInfo.physicalMemory
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(sysctlString("hw.model")) \(sysctlString("machdep.cpu.brand_string")), \(mem / 1_073_741_824) GB RAM, macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion), \(ProcessInfo.processInfo.activeProcessorCount) cores"
}

public func freeDiskBytes(at url: URL) -> Int64? {
    let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
    if let x = v?.volumeAvailableCapacityForImportantUsage, x > 0 { return x }
    return v?.volumeAvailableCapacity.map(Int64.init)
}
