import Foundation
import Testing
@testable import AsBuiltCore

/// Drives `ReconChunkUploader` (delegate-based, background-session compatible) against a real
/// local HTTP server so the continuation / delegate plumbing is exercised end to end.
@Suite("Chunk uploader", .serialized)
struct ReconChunkUploaderTests {
    final class TinyServer: @unchecked Sendable {
        let port: UInt16
        private let fd: Int32
        private let queue = DispatchQueue(label: "TinyServer", attributes: .concurrent)
        private let lock = NSLock()
        private(set) var received: [String: Int] = [:]
        var failFirstFor: Set<String> = []

        init() throws {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            var yes: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            listen(s, 16)
            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
            fd = s
            port = UInt16(bigEndian: bound.sin_port)
            queue.async { [self] in acceptLoop() }
        }

        func stop() { close(fd) }

        private func acceptLoop() {
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { return }
                queue.async { [self] in handle(c) }
            }
        }

        private func handle(_ c: Int32) {
            defer { close(c) }
            var buf = [UInt8](repeating: 0, count: 65536)
            var data = Data()
            var headerEnd: Range<Data.Index>?
            while headerEnd == nil {
                let n = read(c, &buf, buf.count)
                if n <= 0 { return }
                data.append(buf, count: n)
                headerEnd = data.range(of: Data("\r\n\r\n".utf8))
            }
            let head = String(decoding: data[..<headerEnd!.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let length = lines.compactMap { l -> Int? in
                let parts = l.split(separator: ":", maxSplits: 1)
                return parts.count == 2 && parts[0].lowercased() == "content-length" ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
            }.first ?? 0
            var body = data[headerEnd!.upperBound...].count
            while body < length {
                let n = read(c, &buf, buf.count)
                if n <= 0 { return }
                body += n
            }
            lock.lock()
            let shouldFail = failFirstFor.remove(path) != nil
            if !shouldFail { received[path] = body }
            lock.unlock()
            let (status, json) = shouldFail ? ("502 Bad Gateway", "<html>bad gateway</html>")
                                            : ("200 OK", #"{"uploadID":"up_t","index":0,"receivedChunks":[0],"chunkCount":1}"#)
            let resp = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)"
            _ = resp.withCString { write(c, $0, strlen($0)) }
        }

        func count(_ path: String) -> Int? { lock.lock(); defer { lock.unlock() }; return received[path] }
    }

    @Test func uploadsFilesAndReturnsStatusAndBody() async throws {
        let server = try TinyServer()
        defer { server.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uploader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 3
        let uploader = ReconChunkUploader(configuration: config)
        let progress = ProgressBox()
        uploader.onProgress = { key, sent in progress.note(key, sent) }

        let base = URL(string: "http://127.0.0.1:\(server.port)")!
        server.failFirstFor = ["/v1/uploads/up_t/chunks/2"]
        let results = try await withThrowingTaskGroup(of: (Int, ReconChunkUploader.Response).self) { group in
            for i in 0..<5 {
                let file = dir.appendingPathComponent("chunk-\(i).bin")
                try Data(repeating: UInt8(i), count: 300_000 + i).write(to: file)
                let req = ReconRequests.chunk(base: base, key: String(repeating: "k", count: 64), uploadID: "up_t", index: i,
                                              byteCount: 300_000 + i, sha256: "00")
                group.addTask { (i, try await uploader.send(req, file: file, key: ReconChunkUploader.key(uploadID: "up_t", index: i))) }
            }
            var out: [Int: ReconChunkUploader.Response] = [:]
            for try await (i, r) in group { out[i] = r }
            return out
        }
        #expect(results.count == 5)
        #expect(results[2]?.status == 502)                       // Cloudflare-style failure surfaces as a status
        #expect(ReconAPIError.parse(results[2]?.body ?? Data()) == nil)
        for i in [0, 1, 3, 4] {
            #expect(results[i]?.status == 200)
            #expect(server.count("/v1/uploads/up_t/chunks/\(i)") == 300_000 + i)
            #expect((try? JSONDecoder().decode(ReconChunkReceipt.self, from: results[i]?.body ?? Data())) != nil)
        }
        // Retry of the failed chunk succeeds with the same key.
        let file = dir.appendingPathComponent("chunk-2.bin")
        let retry = try await uploader.send(ReconRequests.chunk(base: base, key: "k", uploadID: "up_t", index: 2, byteCount: 300_002, sha256: "00"),
                                            file: file, key: ReconChunkUploader.key(uploadID: "up_t", index: 2))
        #expect(retry.status == 200)
        #expect(server.count("/v1/uploads/up_t/chunks/2") == 300_002)
        #expect(progress.maxSent(for: "up_t#4") >= 300_004)
        #expect(await uploader.runningKeys().isEmpty)
    }

    @Test func networkErrorsThrow() async throws {
        let uploader = ReconChunkUploader(configuration: .ephemeral)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("uploader-err-\(UUID().uuidString).bin")
        try Data(repeating: 1, count: 1000).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        // Port 9 on localhost: connection refused.
        let req = ReconRequests.chunk(base: URL(string: "http://127.0.0.1:9")!, key: "k", uploadID: "up_x", index: 0, byteCount: 1000, sha256: "00")
        await #expect(throws: URLError.self) {
            _ = try await uploader.send(req, file: file, key: "up_x#0")
        }
    }

    @Test func cancellingTheCallerCancelsTheTransfer() async throws {
        let uploader = ReconChunkUploader(configuration: .ephemeral)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("uploader-cancel-\(UUID().uuidString).bin")
        try Data(repeating: 1, count: 1000).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        // 10.255.255.1 is unroutable: the connect hangs until cancelled.
        var req = ReconRequests.chunk(base: URL(string: "http://10.255.255.1")!, key: "k", uploadID: "up_c", index: 0, byteCount: 1000, sha256: "00")
        req.timeoutInterval = 30
        let task = Task { try await uploader.send(req, file: file, key: "up_c#0") }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let started = Date()
        let result = await task.result
        #expect(Date().timeIntervalSince(started) < 5)
        if case .success = result { Issue.record("expected cancellation") }
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [String: Int64] = [:]
    func note(_ key: String, _ value: Int64) {
        lock.lock(); defer { lock.unlock() }
        sent[key] = max(sent[key] ?? 0, value)
    }
    func maxSent(for key: String) -> Int64 { lock.lock(); defer { lock.unlock() }; return sent[key] ?? 0 }
}
