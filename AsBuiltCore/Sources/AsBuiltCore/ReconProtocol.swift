import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// Phone side of the asbuilt-recon v1 contract (MacRecon/API.md): the iPhone uploads an Object
// Capture photo set to the owner's Mac, the Mac builds the most detailed model Apple allows, and the
// phone downloads it back into the capture. Everything here is pure Foundation so it is unit tested
// with `swift test`; URLSession plumbing lives in the app (RemoteBuildService).

// MARK: - Configuration

/// Server settings injected into Info.plist by the TestFlight workflow (never committed).
public struct ReconConfig: Equatable, Sendable {
    public var baseURL: URL?
    public var discoveryURL: URL?
    public var apiKey: String

    public init(baseURL: URL?, discoveryURL: URL?, apiKey: String) {
        self.baseURL = baseURL
        self.discoveryURL = discoveryURL
        self.apiKey = apiKey
    }

    /// Reads `ReconAPIKey`, `ReconBaseURL`, `ReconDiscoveryURL`. Returns nil when the key is missing,
    /// blank, or an unexpanded build-setting placeholder like `$(RECON_API_KEY)`, or when there is
    /// no way to find the server (neither URL usable).
    public init?(info: [String: Any]) {
        func clean(_ key: String) -> String? {
            guard let raw = info[key] as? String else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty || value.hasPrefix("$(") { return nil }
            return value
        }
        func https(_ key: String) -> URL? {
            guard let s = clean(key), let url = URL(string: s), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
            return url
        }
        guard let key = clean("ReconAPIKey"), key.count >= 16 else { return nil }
        let base = https("ReconBaseURL")
        let discovery = https("ReconDiscoveryURL")
        guard base != nil || discovery != nil else { return nil }
        self.init(baseURL: base, discoveryURL: discovery, apiKey: key)
    }
}

// MARK: - Wire types

public struct ReconHealth: Decodable, Equatable, Sendable {
    public var ok: Bool
    public var apiVersion: Int?
    public var queueLength: Int?
    public var processing: Bool?
}

public struct ReconCreateUpload: Encodable, Equatable, Sendable {
    public var captureID: String
    public var filename: String
    public var totalBytes: Int64
    public var sha256: String
    public var detail: String
    public var title: String?
    public var notify: Bool
    public var chunkSize: Int
    public var autoComplete: Bool
    public var obj: Bool

    public init(captureID: String, filename: String = "Images.zip", totalBytes: Int64, sha256: String,
                detail: String = ReconDetail.phone, title: String?, notify: Bool = true,
                chunkSize: Int, autoComplete: Bool = true, obj: Bool = false) {
        self.captureID = captureID
        self.filename = filename
        self.totalBytes = totalBytes
        self.sha256 = sha256
        self.detail = detail
        self.title = title.map { String($0.prefix(120)) }
        self.notify = notify
        self.chunkSize = chunkSize
        self.autoComplete = autoComplete
        self.obj = obj
    }
}

/// Server detail presets.
public enum ReconDetail {
    /// Apple's maximum on the Mac, packaged for the phone: 250k triangles + 8K diffuse/normal maps (~30 MB).
    public static let phone = "phone"
    /// Apple's `.full`: ~100-250k triangles with five 8K PNG/EXR maps (~300 MB, too heavy for a phone).
    public static let full = "full"
    /// Every reconstructed triangle (0.5-2 M) with one 8K map, for measurement/CAD on a computer.
    public static let raw = "raw"
}

public struct ReconUpload: Codable, Equatable, Sendable {
    public var uploadID: String
    public var captureID: String?
    public var totalBytes: Int64
    public var sha256: String?
    public var chunkSize: Int
    public var chunkCount: Int
    public var receivedChunks: [Int]
    public var receivedBytes: Int64?
    public var state: String
    public var jobID: String?
    public var detail: String?
    public var autoComplete: Bool?

    public var isCompleted: Bool { state == "completed" }
}

public struct ReconChunkReceipt: Decodable, Equatable, Sendable {
    public var uploadID: String
    public var index: Int
    public var receivedChunks: [Int]
    public var chunkCount: Int
    public var autoCompleting: Bool?
}

public struct ReconComplete: Decodable, Equatable, Sendable {
    public var jobID: String
    public var uploadID: String
    public var alreadyCompleted: Bool?
}

public struct ReconTexture: Codable, Equatable, Sendable {
    public var name: String
    public var width: Int
    public var height: Int
}

public struct ReconJobFile: Codable, Equatable, Sendable {
    public var name: String
    public var bytes: Int64?
    public var sha256: String?
    public var url: String
}

public struct ReconJobError: Codable, Equatable, Sendable {
    public var code: String?
    public var message: String?
    public var exitCode: Int?
    public var technical: String?
}

public struct ReconJob: Codable, Equatable, Sendable {
    public var jobID: String
    public var captureID: String?
    public var title: String?
    public var state: String
    public var queuePosition: Int?
    public var progress: Double?
    public var etaSeconds: Int?
    public var stage: String?
    public var message: String?
    public var detail: String?
    public var polygons: Int?
    public var textures: [ReconTexture]?
    public var error: ReconJobError?
    public var files: [ReconJobFile]?
    public var buildSeconds: Double?
    public var restarts: Int?

    public func file(named name: String) -> ReconJobFile? { files?.first { $0.name == name } }
}

public struct ReconJobList: Decodable, Sendable {
    public var jobs: [ReconJob]
}

/// `{"error": {"code": ..., "message": ...}}` body of every 4xx/5xx.
public struct ReconAPIError: Decodable, Equatable, Sendable, Error {
    public var code: String
    public var message: String?
    public var missingChunks: [Int]?
    public var jobID: String?
    public var retryAfterSeconds: Int?

    private struct Envelope: Decodable { var error: ReconAPIError }

    public init(code: String, message: String? = nil, missingChunks: [Int]? = nil, jobID: String? = nil, retryAfterSeconds: Int? = nil) {
        self.code = code
        self.message = message
        self.missingChunks = missingChunks
        self.jobID = jobID
        self.retryAfterSeconds = retryAfterSeconds
    }

    /// Parses an error body; nil for non-JSON bodies (e.g. Cloudflare's HTML 52x/530 pages).
    public static func parse(_ data: Data) -> ReconAPIError? {
        try? JSONDecoder().decode(Envelope.self, from: data).error
    }
}

// MARK: - Requests

/// Builds every request of the contract. Keys only ever go in the Authorization header.
public enum ReconRequests {
    public static let jsonTimeout: TimeInterval = 30

    static func url(_ base: URL, _ path: String) -> URL {
        // `path` starts with "/v1/..."; keep any path prefix on the base URL.
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s + path)!
    }

    static func request(_ method: String, _ url: URL, key: String?, timeout: TimeInterval = jsonTimeout) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.httpMethod = method
        if let key { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    static func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._"))) ?? id
    }

    public static func health(base: URL) -> URLRequest {
        request("GET", url(base, "/v1/health"), key: nil, timeout: 12)
    }

    public static func createUpload(base: URL, key: String, body: ReconCreateUpload) throws -> URLRequest {
        var r = request("POST", url(base, "/v1/uploads"), key: key)
        r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(body)
        return r
    }

    /// Chunk PUT for `URLSession.uploadTask(with:fromFile:)` (background sessions need file uploads).
    public static func chunk(base: URL, key: String, uploadID: String, index: Int, byteCount: Int, sha256: String) -> URLRequest {
        var r = request("PUT", url(base, "/v1/uploads/\(escape(uploadID))/chunks/\(index)"), key: key, timeout: 600)
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.setValue(String(byteCount), forHTTPHeaderField: "Content-Length")
        r.setValue(sha256, forHTTPHeaderField: "X-Chunk-SHA256")
        return r
    }

    public static func upload(base: URL, key: String, uploadID: String) -> URLRequest {
        request("GET", url(base, "/v1/uploads/\(escape(uploadID))"), key: key)
    }

    public static func deleteUpload(base: URL, key: String, uploadID: String) -> URLRequest {
        request("DELETE", url(base, "/v1/uploads/\(escape(uploadID))"), key: key)
    }

    public static func complete(base: URL, key: String, uploadID: String) -> URLRequest {
        request("POST", url(base, "/v1/uploads/\(escape(uploadID))/complete"), key: key, timeout: 120)
    }

    public static func job(base: URL, key: String, jobID: String) -> URLRequest {
        request("GET", url(base, "/v1/jobs/\(escape(jobID))"), key: key)
    }

    public static func jobs(base: URL, key: String, captureID: String) -> URLRequest {
        request("GET", url(base, "/v1/jobs?captureID=\(escape(captureID))"), key: key)
    }

    public static func deleteJob(base: URL, key: String, jobID: String) -> URLRequest {
        request("DELETE", url(base, "/v1/jobs/\(escape(jobID))"), key: key)
    }

    /// Download of `files[].url` (relative to the base URL). Returns nil for anything that isn't a
    /// `/v1/jobs/<id>/files/<name>` path, so a hostile server can't redirect the key elsewhere.
    /// What went wrong on the phone (upload errors, phase changes), so the Mac's log shows both sides.
    public static func diagnostics(base: URL, key: String, body: ReconDiagnostic) throws -> URLRequest {
        var r = request("POST", url(base, "/v1/diagnostics"), key: key, timeout: 20)
        r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(body)
        return r
    }

    public static func file(base: URL, key: String, relativeURL: String) -> URLRequest? {
        guard relativeURL.hasPrefix("/v1/jobs/"), relativeURL.contains("/files/"), !relativeURL.contains(".."),
              !relativeURL.contains("://") else { return nil }
        return request("GET", url(base, relativeURL), key: key, timeout: 600)
    }
}

/// One phone-side event for `POST /v1/diagnostics` (logged on the Mac, never shown to anyone else).
public struct ReconDiagnostic: Codable, Equatable, Sendable {
    public var captureID: String
    public var uploadID: String?
    public var event: String
    public var phase: String?
    public var message: String?
    public var errorDomain: String?
    public var errorCode: Int?
    public var chunk: Int?
    public var chunkSize: Int?
    public var received: Int?
    public var chunkCount: Int?
    public var appBuild: String?
    public var device: String?
    public var appState: String?

    public init(captureID: String, uploadID: String? = nil, event: String, phase: String? = nil, message: String? = nil,
                errorDomain: String? = nil, errorCode: Int? = nil, chunk: Int? = nil, chunkSize: Int? = nil,
                received: Int? = nil, chunkCount: Int? = nil, appBuild: String? = nil, device: String? = nil,
                appState: String? = nil) {
        self.captureID = captureID
        self.uploadID = uploadID
        self.event = String(event.prefix(64))
        self.phase = phase
        self.message = message.map { String($0.prefix(500)) }
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.chunk = chunk
        self.chunkSize = chunkSize
        self.received = received
        self.chunkCount = chunkCount
        self.appBuild = appBuild
        self.device = device
        self.appState = appState
    }
}

// MARK: - Discovery

public enum ReconDiscovery {
    /// The secret gist (`GET api.github.com/gists/<id>`) holds `files["asbuilt-recon.json"].content`
    /// = `{"baseURL": "https://…trycloudflare.com", "apiVersion": 1, …}`. The Mac rewrites it on
    /// every new tunnel URL.
    public static func baseURL(fromGist data: Data) -> URL? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var content: String?
        if let files = root["files"] as? [String: Any], let file = files["asbuilt-recon.json"] as? [String: Any] {
            content = file["content"] as? String
        } else if root["baseURL"] != nil {
            // Also accept the raw JSON (a plain URL to the file instead of the gist API).
            return url(from: root)
        }
        guard let content, let inner = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any] else { return nil }
        return url(from: inner)
    }

    static func url(from obj: [String: Any]) -> URL? {
        guard let s = obj["baseURL"] as? String, let url = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        if let version = obj["apiVersion"] as? Int, version != 1 { return nil }
        return url
    }
}

// MARK: - Chunking

public struct ReconChunk: Codable, Hashable, Sendable {
    public var index: Int
    public var fileName: String
    public var bytes: Int
    public var sha256: String
}

public struct ReconChunkPlan: Codable, Equatable, Sendable {
    public var totalBytes: Int64
    public var sha256: String
    public var chunkSize: Int
    public var chunks: [ReconChunk]
}

public enum ReconChunker {
    public static let defaultChunkSize = 32 * 1024 * 1024
    /// What the phone uses: small enough that a dropped cellular connection loses seconds, not minutes.
    public static let cellularChunkSize = 8 * 1024 * 1024

    public static func chunkCount(totalBytes: Int64, chunkSize: Int) -> Int {
        guard totalBytes > 0, chunkSize > 0 else { return 0 }
        return Int((totalBytes + Int64(chunkSize) - 1) / Int64(chunkSize))
    }

    public static func range(index: Int, totalBytes: Int64, chunkSize: Int) -> Range<Int64> {
        let start = Int64(index) * Int64(chunkSize)
        return start..<min(start + Int64(chunkSize), totalBytes)
    }

    public static func chunkFileName(_ index: Int) -> String { "chunk-\(index).bin" }

    /// Hashes `zip` (one forward pass), then cuts it into `chunk-<n>.bin` files in `dir`, last chunk
    /// first, truncating the zip after each cut so the extra disk needed is one chunk, not a full
    /// copy of a 1-2 GB photo set. The zip is gone afterwards; the chunks are the upload.
    public static func split(zip: URL, into dir: URL, chunkSize: Int = defaultChunkSize,
                             isCancelled: () -> Bool = { false }) throws -> ReconChunkPlan {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let total = Int64((try fm.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.int64Value ?? 0)
        guard total > 0 else { throw ReconAPIError(code: "empty_zip", message: "The photo archive is empty.") }
        let whole = try sha256(of: zip, isCancelled: isCancelled)
        let count = chunkCount(totalBytes: total, chunkSize: chunkSize)
        var chunks: [ReconChunk] = []
        let handle = try FileHandle(forUpdating: zip)
        defer { try? handle.close() }
        for index in stride(from: count - 1, through: 0, by: -1) {
            if isCancelled() { throw CancellationError() }
            let r = range(index: index, totalBytes: total, chunkSize: chunkSize)
            try handle.seek(toOffset: UInt64(r.lowerBound))
            let out = dir.appendingPathComponent(chunkFileName(index))
            try? fm.removeItem(at: out)
            guard fm.createFile(atPath: out.path, contents: nil) else {
                throw ReconAPIError(code: "disk", message: "Couldn't write the upload file. Free up space on the iPhone.")
            }
            let writer = try FileHandle(forWritingTo: out)
            var hasher = SHA256Stream()
            var left = Int(r.upperBound - r.lowerBound)
            do {
                while left > 0 {
                    let data = try handle.read(upToCount: min(left, 4 * 1024 * 1024)) ?? Data()
                    if data.isEmpty { throw ReconAPIError(code: "short_read", message: "The photo archive ended early.") }
                    hasher.update(data)
                    try writer.write(contentsOf: data)
                    left -= data.count
                }
                try writer.close()
            } catch {
                try? writer.close()
                throw error
            }
            chunks.append(ReconChunk(index: index, fileName: out.lastPathComponent, bytes: Int(r.upperBound - r.lowerBound),
                                     sha256: hasher.finalize()))
            try handle.truncate(atOffset: UInt64(r.lowerBound))
        }
        try? handle.close()
        try? fm.removeItem(at: zip)
        return ReconChunkPlan(totalBytes: total, sha256: whole, chunkSize: chunkSize, chunks: chunks.sorted { $0.index < $1.index })
    }

    public static func sha256(of url: URL, isCancelled: () -> Bool = { false }) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256Stream()
        while true {
            if isCancelled() { throw CancellationError() }
            let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data)
        }
        return hasher.finalize()
    }
}

/// Streaming SHA-256 (CryptoKit), lowercase hex.
public struct SHA256Stream {
    #if canImport(CryptoKit)
    private var hasher = SHA256()
    #endif
    public init() {}
    public mutating func update(_ data: Data) {
        #if canImport(CryptoKit)
        hasher.update(data: data)
        #endif
    }
    public mutating func finalize() -> String {
        #if canImport(CryptoKit)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }
}

// MARK: - Per-capture state

/// The Mac build of one Object Capture, persisted in the capture record (job.json) so uploads and
/// builds resume after the app is killed. Every field is optional on decode.
public struct RemoteBuild: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Hashable, Sendable {
        /// Zipping, hashing and cutting the photos into upload chunks on the phone.
        case preparing
        case uploading
        /// All photos on the Mac, waiting for its builder.
        case queued
        case building
        case downloading
        case done
        case failed
        /// The Mac can't be reached; AsBuilt keeps retrying.
        case waitingForMac
        case cancelled
    }

    public var phase: Phase
    public var detail: String
    public var uploadID: String?
    public var jobID: String?
    public var totalBytes: Int64?
    public var chunkSize: Int?
    public var chunkCount: Int?
    public var chunks: [ReconChunk]?
    public var receivedChunks: [Int]
    /// Fraction of the current phase (0...1).
    public var phaseProgress: Double
    public var etaSeconds: Int?
    public var stage: String?
    public var queuePosition: Int?
    public var message: String?
    public var photoCount: Int?
    public var polygons: Int?
    public var textureSize: Int?
    public var textureCount: Int?
    public var modelBytes: Int64?
    public var startedAt: Date
    public var updatedAt: Date
    public var finishedAt: Date?
    public var buildSeconds: Double?
    public var failureCount: Int

    public init(phase: Phase = .preparing, detail: String = ReconDetail.phone, photoCount: Int? = nil, startedAt: Date = Date()) {
        self.phase = phase
        self.detail = detail
        self.receivedChunks = []
        self.phaseProgress = 0
        self.photoCount = photoCount
        self.startedAt = startedAt
        self.updatedAt = startedAt
        self.failureCount = 0
    }

    private enum CodingKeys: String, CodingKey {
        case phase, detail, uploadID, jobID, totalBytes, chunkSize, chunkCount, chunks, receivedChunks, phaseProgress
        case etaSeconds, stage, queuePosition, message, photoCount, polygons, textureSize, textureCount, modelBytes
        case startedAt, updatedAt, finishedAt, buildSeconds, failureCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent(String.self, forKey: .phase)) ?? nil
        phase = raw.flatMap(Phase.init(rawValue:)) ?? .failed
        detail = (try? c.decodeIfPresent(String.self, forKey: .detail)) ?? nil ?? ReconDetail.phone
        uploadID = (try? c.decodeIfPresent(String.self, forKey: .uploadID)) ?? nil
        jobID = (try? c.decodeIfPresent(String.self, forKey: .jobID)) ?? nil
        totalBytes = (try? c.decodeIfPresent(Int64.self, forKey: .totalBytes)) ?? nil
        chunkSize = (try? c.decodeIfPresent(Int.self, forKey: .chunkSize)) ?? nil
        chunkCount = (try? c.decodeIfPresent(Int.self, forKey: .chunkCount)) ?? nil
        chunks = (try? c.decodeIfPresent([ReconChunk].self, forKey: .chunks)) ?? nil
        receivedChunks = (try? c.decodeIfPresent([Int].self, forKey: .receivedChunks)) ?? nil ?? []
        phaseProgress = (try? c.decodeIfPresent(Double.self, forKey: .phaseProgress)) ?? nil ?? 0
        etaSeconds = (try? c.decodeIfPresent(Int.self, forKey: .etaSeconds)) ?? nil
        stage = (try? c.decodeIfPresent(String.self, forKey: .stage)) ?? nil
        queuePosition = (try? c.decodeIfPresent(Int.self, forKey: .queuePosition)) ?? nil
        message = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? nil
        photoCount = (try? c.decodeIfPresent(Int.self, forKey: .photoCount)) ?? nil
        polygons = (try? c.decodeIfPresent(Int.self, forKey: .polygons)) ?? nil
        textureSize = (try? c.decodeIfPresent(Int.self, forKey: .textureSize)) ?? nil
        textureCount = (try? c.decodeIfPresent(Int.self, forKey: .textureCount)) ?? nil
        modelBytes = (try? c.decodeIfPresent(Int64.self, forKey: .modelBytes)) ?? nil
        startedAt = (try? c.decodeIfPresent(Date.self, forKey: .startedAt)) ?? nil ?? Date(timeIntervalSince1970: 0)
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? nil ?? startedAt
        finishedAt = (try? c.decodeIfPresent(Date.self, forKey: .finishedAt)) ?? nil
        buildSeconds = (try? c.decodeIfPresent(Double.self, forKey: .buildSeconds)) ?? nil
        failureCount = (try? c.decodeIfPresent(Int.self, forKey: .failureCount)) ?? nil ?? 0
    }

    // MARK: Derived

    /// Still moving toward a model (the app should keep uploading/polling).
    public var isActive: Bool {
        switch phase {
        case .preparing, .uploading, .queued, .building, .downloading, .waitingForMac: return true
        case .done, .failed, .cancelled: return false
        }
    }

    public var uploadedBytes: Int64 {
        guard let total = totalBytes, let size = chunkSize, let count = chunkCount, count > 0 else { return 0 }
        var bytes: Int64 = 0
        for i in Set(receivedChunks) where i >= 0 && i < count {
            let r = ReconChunker.range(index: i, totalBytes: total, chunkSize: size)
            bytes += r.upperBound - r.lowerBound
        }
        return bytes
    }

    public var uploadFraction: Double { uploadFraction(inFlightBytes: 0) }

    /// Upload progress counting bytes of chunks still on the wire, so the bar moves smoothly.
    public func uploadFraction(inFlightBytes: Int64) -> Double {
        guard let total = totalBytes, total > 0 else { return 0 }
        return min(1, Double(uploadedBytes + max(0, inFlightBytes)) / Double(total))
    }

    public var missingChunks: [Int] {
        guard let count = chunkCount else { return [] }
        let have = Set(receivedChunks)
        return (0..<count).filter { !have.contains($0) }
    }

    /// One bar across the whole trip: prepare 0-5 %, upload 5-40 %, queue 40 %, build 40-95 %,
    /// download 95-100 %.
    public var overallFraction: Double { overallFraction(inFlightBytes: 0) }

    public func overallFraction(inFlightBytes: Int64) -> Double {
        switch phase {
        case .preparing: return 0.05 * clamp(phaseProgress)
        case .uploading, .waitingForMac: return 0.05 + 0.35 * uploadFraction(inFlightBytes: inFlightBytes)
        case .queued: return 0.40
        case .building: return 0.40 + 0.55 * clamp(phaseProgress)
        case .downloading: return 0.95 + 0.05 * clamp(phaseProgress)
        case .done: return 1
        case .failed, .cancelled: return 0
        }
    }

    /// Step shown as current in the 4-step list (0 pack, 1 upload, 2 build, 3 download, 4 done).
    public var step: Int {
        switch phase {
        case .preparing: return 0
        case .uploading, .waitingForMac: return totalBytes == nil ? 0 : 1
        case .queued, .building: return 2
        case .downloading: return 3
        case .done: return 4
        case .failed, .cancelled: return -1
        }
    }

    public var headline: String {
        switch phase {
        case .preparing: return "Packing photos"
        case .uploading: return "Sending photos to your Mac"
        case .waitingForMac: return "Waiting for your Mac"
        case .queued: return "On your Mac, next in line"
        case .building: return "Building full detail"
        case .downloading: return "Bringing it to your iPhone"
        case .done: return "Full-detail model ready"
        case .failed: return "Mac build didn't finish"
        case .cancelled: return "Mac build cancelled"
        }
    }

    /// Second line: sizes, stage, time left.
    public var detailLine: String { detailLine(inFlightBytes: 0) }

    public func detailLine(inFlightBytes: Int64) -> String {
        switch phase {
        case .preparing:
            return photoCount.map { "\($0) photos" } ?? "Getting photos ready"
        case .uploading:
            guard let total = totalBytes else { return "Starting upload" }
            return "\(ReconFormat.bytes(min(total, uploadedBytes + max(0, inFlightBytes)))) of \(ReconFormat.bytes(total))"
        case .waitingForMac:
            return message ?? "Your Mac isn't reachable right now. AsBuilt keeps trying."
        case .queued:
            if let q = queuePosition, q > 1 { return "\(q - 1) build\(q == 2 ? "" : "s") ahead of yours" }
            return "Starting in a moment"
        case .building:
            var parts = [ReconFormat.stage(stage)]
            if let eta = etaSeconds, eta > 0 { parts.append(ReconFormat.timeLeft(eta)) }
            return parts.joined(separator: " · ")
        case .downloading:
            return modelBytes.map { "\(ReconFormat.bytes($0)) model" } ?? "Downloading"
        case .done:
            var parts: [String] = []
            if let p = polygons { parts.append("\(ReconFormat.count(p)) triangles") }
            if let t = textureSize { parts.append("\(t / 1024)K textures") }
            if let s = buildSeconds { parts.append("built in \(ReconFormat.duration(Int(s)))") }
            return parts.isEmpty ? "Opened in the 3D tab" : parts.joined(separator: " · ")
        case .failed, .cancelled:
            return message ?? "The photos are safe on this iPhone. Try again."
        }
    }

    private func clamp(_ x: Double) -> Double { min(1, max(0, x.isFinite ? x : 0)) }

    // MARK: Transitions

    /// Folds a server job snapshot into the local state (never moves backwards past `downloading`).
    public mutating func apply(job: ReconJob, now: Date = Date()) {
        jobID = job.jobID
        updatedAt = now
        switch job.state {
        case "queued":
            phase = .queued
            queuePosition = job.queuePosition
            phaseProgress = 0
            message = job.message
        case "processing":
            phase = .building
            phaseProgress = min(1, max(phaseProgress, job.progress ?? 0))
            etaSeconds = job.etaSeconds
            stage = job.stage
            queuePosition = 0
            message = job.message
        case "done":
            if phase != .done { phase = .downloading; phaseProgress = 0 }
            polygons = job.polygons ?? polygons
            if let textures = job.textures, !textures.isEmpty {
                textureCount = textures.count
                textureSize = textures.map { max($0.width, $0.height) }.max()
            }
            buildSeconds = job.buildSeconds ?? buildSeconds
            modelBytes = job.file(named: "model.usdz")?.bytes ?? modelBytes
            etaSeconds = nil
        case "failed":
            phase = .failed
            finishedAt = now
            message = job.error?.message ?? job.message ?? "Your Mac couldn't build this model."
        default:
            break
        }
    }

    /// Folds `GET /v1/uploads/{id}` into the local state.
    public mutating func apply(upload: ReconUpload, now: Date = Date()) {
        uploadID = upload.uploadID
        totalBytes = upload.totalBytes
        chunkSize = upload.chunkSize
        chunkCount = upload.chunkCount
        receivedChunks = upload.receivedChunks.sorted()
        updatedAt = now
        if let job = upload.jobID {
            jobID = job
            if phase == .uploading || phase == .waitingForMac || phase == .preparing { phase = .queued; phaseProgress = 0 }
        }
    }

    public mutating func markChunkReceived(_ receipt: ReconChunkReceipt, now: Date = Date()) {
        receivedChunks = Array(Set(receivedChunks).union(receipt.receivedChunks).union([receipt.index])).sorted()
        updatedAt = now
        if missingChunks.isEmpty, phase == .uploading || phase == .waitingForMac { phase = .queued; phaseProgress = 0 }
    }
}

// MARK: - Formatting

public enum ReconFormat {
    public static func bytes(_ n: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, n))
        var i = 0
        while value >= 1000 && i < units.count - 1 { value /= 1000; i += 1 }
        if i == 0 { return "\(Int(value)) bytes" }
        return value >= 100 || i == 1 ? "\(Int(value.rounded())) \(units[i])" : String(format: "%.1f %@", value, units[i])
    }

    public static func count(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return "\(Int((Double(n) / 1000).rounded()))k" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    public static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(max(1, seconds)) s" }
        let m = Int((Double(seconds) / 60).rounded())
        if m < 60 { return "\(m) min" }
        return "\(m / 60) h \(m % 60) min"
    }

    public static func timeLeft(_ seconds: Int) -> String {
        if seconds < 60 { return "under a minute left" }
        return "about \(duration(seconds)) left"
    }

    /// Plain-language name for the server's `stage`.
    public static func stage(_ stage: String?) -> String {
        switch stage {
        case "preProcessing": return "Preparing photos"
        case "imageAlignment": return "Lining up photos"
        case "pointCloudGeneration": return "Building point cloud"
        case "meshGeneration": return "Building mesh"
        case "textureMapping": return "Painting 8K textures"
        case "optimization": return "Optimizing"
        case "extracting", "starting": return "Unpacking photos"
        case "inspecting": return "Checking the model"
        case "waiting": return "Waiting for another build"
        default: return "Working"
        }
    }
}
