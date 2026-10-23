import Foundation
import Testing
@testable import AsBuiltCore

@Suite("Mac build protocol (asbuilt-recon v1)")
struct ReconProtocolTests {
    @Test func configNeedsKeyAndAnHTTPSURL() {
        let key = String(repeating: "ab", count: 32)
        let ok = ReconConfig(info: ["ReconAPIKey": key, "ReconBaseURL": "https://x.trycloudflare.com",
                                    "ReconDiscoveryURL": "https://api.github.com/gists/abc"])
        #expect(ok?.baseURL?.host == "x.trycloudflare.com")
        #expect(ok?.discoveryURL?.host == "api.github.com")
        // Unexpanded build settings (local builds without the secrets) mean "not configured".
        #expect(ReconConfig(info: ["ReconAPIKey": "$(RECON_API_KEY)", "ReconBaseURL": "https://x.y"]) == nil)
        #expect(ReconConfig(info: ["ReconAPIKey": key]) == nil)
        #expect(ReconConfig(info: ["ReconAPIKey": key, "ReconBaseURL": "http://plain.example"]) == nil)
        #expect(ReconConfig(info: ["ReconAPIKey": "short", "ReconBaseURL": "https://x.y"]) == nil)
        let discoveryOnly = ReconConfig(info: ["ReconAPIKey": key, "ReconBaseURL": "$(RECON_BASE_URL)",
                                               "ReconDiscoveryURL": "https://api.github.com/gists/abc"])
        #expect(discoveryOnly?.baseURL == nil && discoveryOnly?.discoveryURL != nil)
    }

    @Test func discoveryReadsTheGistFile() throws {
        let inner = #"{"baseURL": "https://firms-treatment.trycloudflare.com", "apiVersion": 1}"#
        let gist = try JSONSerialization.data(withJSONObject: ["files": ["asbuilt-recon.json": ["content": inner]]])
        #expect(ReconDiscovery.baseURL(fromGist: gist)?.absoluteString == "https://firms-treatment.trycloudflare.com")
        #expect(ReconDiscovery.baseURL(fromGist: Data(inner.utf8))?.host == "firms-treatment.trycloudflare.com")
        #expect(ReconDiscovery.baseURL(fromGist: Data(#"{"baseURL": "https://a.b", "apiVersion": 2}"#.utf8)) == nil)
        #expect(ReconDiscovery.baseURL(fromGist: Data(#"{"baseURL": "http://a.b"}"#.utf8)) == nil)
        #expect(ReconDiscovery.baseURL(fromGist: Data("<html>".utf8)) == nil)
    }

    @Test func requestsPutTheKeyOnlyInTheHeader() throws {
        let base = URL(string: "https://h.trycloudflare.com/")!
        let key = String(repeating: "c", count: 64)
        let create = try ReconRequests.createUpload(base: base, key: key, body: ReconCreateUpload(
            captureID: "CAP-1", totalBytes: 100, sha256: String(repeating: "0", count: 64), title: "Valve", chunkSize: 8 << 20))
        #expect(create.url?.absoluteString == "https://h.trycloudflare.com/v1/uploads")
        #expect(create.httpMethod == "POST")
        #expect(create.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")
        let body = try JSONSerialization.jsonObject(with: create.httpBody ?? Data()) as? [String: Any]
        #expect(body?["detail"] as? String == "phone")
        #expect(body?["autoComplete"] as? Bool == true)
        #expect(body?["obj"] as? Bool == false)
        #expect(body?["chunkSize"] as? Int == 8 << 20)

        let chunk = ReconRequests.chunk(base: base, key: key, uploadID: "up_1", index: 3, byteCount: 42, sha256: "ff")
        #expect(chunk.url?.path == "/v1/uploads/up_1/chunks/3")
        #expect(chunk.value(forHTTPHeaderField: "Content-Length") == "42")
        #expect(chunk.value(forHTTPHeaderField: "X-Chunk-SHA256") == "ff")
        #expect(!(chunk.url?.absoluteString.contains(key) ?? true))
        #expect(ReconRequests.health(base: base).value(forHTTPHeaderField: "Authorization") == nil)

        #expect(ReconRequests.file(base: base, key: key, relativeURL: "/v1/jobs/job_1/files/model.usdz")?.url?.absoluteString
                == "https://h.trycloudflare.com/v1/jobs/job_1/files/model.usdz")
        #expect(ReconRequests.file(base: base, key: key, relativeURL: "https://evil.example/v1/jobs/x/files/y") == nil)
        #expect(ReconRequests.file(base: base, key: key, relativeURL: "/v1/jobs/../../etc/files/x") == nil)
        #expect(ReconRequests.jobs(base: base, key: key, captureID: "A B").url?.absoluteString.hasSuffix("captureID=A%20B") == true)
    }

    @Test func splitCutsTheZipIntoVerifiableChunks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recon-split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appendingPathComponent("Images.zip")
        var bytes = [UInt8](repeating: 0, count: 2_500_123)
        var seed: UInt32 = 7
        for i in bytes.indices { seed = seed &* 1_664_525 &+ 1_013_904_223; bytes[i] = UInt8(truncatingIfNeeded: seed >> 24) }
        try Data(bytes).write(to: zip)
        let whole = try ReconChunker.sha256(of: zip)

        let plan = try ReconChunker.split(zip: zip, into: dir.appendingPathComponent("chunks"), chunkSize: 1 << 20)
        #expect(plan.totalBytes == 2_500_123)
        #expect(plan.sha256 == whole)
        #expect(plan.chunks.map(\.index) == [0, 1, 2])
        #expect(plan.chunks.map(\.bytes) == [1 << 20, 1 << 20, 2_500_123 - 2 * (1 << 20)])
        #expect(!FileManager.default.fileExists(atPath: zip.path))   // no second full copy left behind

        var joined = Data()
        for chunk in plan.chunks {
            let data = try Data(contentsOf: dir.appendingPathComponent("chunks").appendingPathComponent(chunk.fileName))
            var h = SHA256Stream()
            h.update(data)
            #expect(h.finalize() == chunk.sha256)
            joined.append(data)
        }
        #expect(joined == Data(bytes))
        #expect(ReconChunker.chunkCount(totalBytes: 2_500_123, chunkSize: 1 << 20) == 3)
        #expect(ReconChunker.range(index: 2, totalBytes: 2_500_123, chunkSize: 1 << 20) == Int64(2 << 20)..<2_500_123)
    }

    @Test func remoteBuildFollowsTheServer() throws {
        var b = RemoteBuild(phase: .uploading, photoCount: 120)
        let up = ReconUpload(uploadID: "up_1", captureID: "c", totalBytes: 70 << 20, sha256: nil, chunkSize: 32 << 20,
                             chunkCount: 3, receivedChunks: [0], receivedBytes: nil, state: "open", jobID: nil, detail: "phone",
                             autoComplete: true)
        b.apply(upload: up)
        #expect(b.missingChunks == [1, 2])
        #expect(abs(b.uploadFraction - 32.0 / 70.0) < 1e-9)
        #expect(b.step == 1)
        b.markChunkReceived(ReconChunkReceipt(uploadID: "up_1", index: 2, receivedChunks: [0, 2], chunkCount: 3, autoCompleting: false))
        #expect(b.phase == .uploading && b.missingChunks == [1])
        b.markChunkReceived(ReconChunkReceipt(uploadID: "up_1", index: 1, receivedChunks: [0, 1, 2], chunkCount: 3, autoCompleting: true))
        #expect(b.phase == .queued && b.uploadFraction == 1)

        let decoder = JSONDecoder()
        let processing = try decoder.decode(ReconJob.self, from: Data(#"""
        {"jobID":"job_1","state":"processing","progress":0.42,"etaSeconds":180,"stage":"meshGeneration","queuePosition":0,"files":[]}
        """#.utf8))
        b.apply(job: processing)
        #expect(b.phase == .building && b.step == 2)
        #expect(b.detailLine == "Building mesh · about 3 min left")
        #expect(abs(b.overallFraction - (0.40 + 0.55 * 0.42)) < 1e-9)
        // Progress never runs backwards within the build (Apple's auto-retry can restart it).
        b.apply(job: try decoder.decode(ReconJob.self, from: Data(#"{"jobID":"job_1","state":"processing","progress":0.1}"#.utf8)))
        #expect(b.phaseProgress == 0.42)

        let done = try decoder.decode(ReconJob.self, from: Data(#"""
        {"jobID":"job_1","state":"done","polygons":250000,"buildSeconds":228.2,
         "textures":[{"name":"tex","width":8192,"height":8192},{"name":"norm","width":8192,"height":8192}],
         "files":[{"name":"model.usdz","bytes":34521789,"sha256":"aa","url":"/v1/jobs/job_1/files/model.usdz"}]}
        """#.utf8))
        b.apply(job: done)
        #expect(b.phase == .downloading && b.step == 3)
        #expect(b.polygons == 250_000 && b.textureSize == 8192 && b.textureCount == 2 && b.modelBytes == 34_521_789)
        b.phase = .done
        #expect(b.detailLine == "250k triangles · 8K textures · built in 4 min")

        var f = RemoteBuild(phase: .building)
        f.apply(job: try decoder.decode(ReconJob.self, from: Data(#"""
        {"jobID":"job_2","state":"failed","error":{"code":"build_failed","message":"Apple couldn't line up the photos."}}
        """#.utf8)))
        #expect(f.phase == .failed && f.message == "Apple couldn't line up the photos." && !f.isActive)
    }

    @Test func remoteBuildDecodesTolerantly() throws {
        let decoded = try JSONDecoder().decode(RemoteBuild.self, from: Data(#"{"phase":"warp","jobID":"job_9"}"#.utf8))
        #expect(decoded.phase == .failed && decoded.jobID == "job_9" && decoded.receivedChunks.isEmpty && decoded.detail == "phone")
        var b = RemoteBuild(phase: .building, photoCount: 80)
        b.uploadID = "up_1"
        b.chunks = [ReconChunk(index: 0, fileName: "chunk-0.bin", bytes: 5, sha256: "ab")]
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let round = try dec.decode(RemoteBuild.self, from: enc.encode(b))
        #expect(round.phase == .building && round.uploadID == "up_1" && round.chunks == b.chunks && round.photoCount == 80)
    }

    @Test func apiErrorsParseAndCloudflarePagesDont() {
        let e = ReconAPIError.parse(Data(#"{"error":{"code":"missing_chunks","message":"2 of 6","missingChunks":[3,5]}}"#.utf8))
        #expect(e?.code == "missing_chunks" && e?.missingChunks == [3, 5])
        #expect(ReconAPIError.parse(Data("<html>530</html>".utf8)) == nil)
    }

    @Test func formatting() {
        #expect(ReconFormat.bytes(34_521_789) == "34.5 MB")
        #expect(ReconFormat.bytes(1_260_000_000) == "1.3 GB")
        #expect(ReconFormat.bytes(512) == "512 bytes")
        #expect(ReconFormat.count(250_000) == "250k")
        #expect(ReconFormat.count(1_840_000) == "1.8M")
        #expect(ReconFormat.timeLeft(30) == "under a minute left")
        #expect(ReconFormat.timeLeft(4000) == "about 1 h 7 min left")
        #expect(ReconFormat.stage("textureMapping") == "Painting 8K textures")
    }
}
