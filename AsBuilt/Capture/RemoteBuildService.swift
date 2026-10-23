import Foundation
import AsBuiltCore
#if canImport(UIKit)
import UIKit
#endif

/// Full-detail Object Capture builds on the owner's Mac (MacRecon/API.md, asbuilt-recon v1).
///
/// After an Object Capture finishes, the photos are zipped, cut into chunks and uploaded to the Mac;
/// the Mac runs PhotogrammetrySession at the most detail Apple allows (250k triangles, 8K photo
/// texture + normal map) and the phone downloads `model-full.usdz` into the capture, where it
/// replaces the on-device preview in the 3D tab. Everything resumes from the IDs persisted in the
/// capture record (`Capture.remoteBuild`): kill the app, lose the network, or change the tunnel URL
/// and the next launch / foreground carries on where it stopped. Nothing here throws to the UI.
@MainActor
final class RemoteBuildService: ObservableObject {
    static let shared = RemoteBuildService()

    let config: ReconConfig?
    var isConfigured: Bool { config != nil }

    private weak var store: JobStore?
    private var runs: [UUID: Task<Void, Never>] = [:]
    private var resolvedBase: URL?
    private let session: URLSession
    private static let chunkSize = 16 * 1024 * 1024

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        config = ReconConfig(info: info)
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 90
        c.timeoutIntervalForResource = 60 * 60
        c.httpMaximumConnectionsPerHost = 4
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        session = URLSession(configuration: c)
    }

    func attach(_ store: JobStore) {
        self.store = store
    }

    func isRunning(_ captureID: UUID) -> Bool { runs[captureID] != nil }

    /// Starts (or resumes) the Mac build of an Object Capture. `restart` throws away a failed,
    /// cancelled or finished build and sends the photos again.
    func start(job jobID: UUID, capture captureID: UUID, restart: Bool = false) {
        guard config != nil, let store, let capture = store.capture(job: jobID, capture: captureID),
              capture.kind == .object, capture.origin != .sample else { return }
        if restart {
            runs[captureID]?.cancel()
            runs[captureID] = nil
            Self.removeWorkDirectory(captureID)
            persist(RemoteBuild(photoCount: capture.imageCount), job: jobID, capture: captureID)
        } else if let existing = capture.remoteBuild, !existing.isActive {
            return
        }
        guard runs[captureID] == nil else { return }
        if capture.remoteBuild == nil {
            persist(RemoteBuild(photoCount: capture.imageCount), job: jobID, capture: captureID)
        }
        runs[captureID] = Task { [weak self] in
            await self?.run(job: jobID, capture: captureID)
            self?.runs[captureID] = nil
        }
    }

    func cancel(job jobID: UUID, capture captureID: UUID) {
        runs[captureID]?.cancel()
        runs[captureID] = nil
        guard var build = store?.capture(job: jobID, capture: captureID)?.remoteBuild else { return }
        let uploadID = build.jobID == nil ? build.uploadID : nil
        let remoteJob = build.phase == .done ? nil : build.jobID
        build.phase = .cancelled
        build.message = "Cancelled. The photos are still on this iPhone."
        build.finishedAt = Date()
        persist(build, job: jobID, capture: captureID)
        Self.removeWorkDirectory(captureID)
        // Free the Mac's queue and disk; best effort.
        if let config, let base = resolvedBase ?? config.baseURL {
            let key = config.apiKey
            let s = session
            Task.detached {
                if let uploadID { _ = try? await s.data(for: ReconRequests.deleteUpload(base: base, key: key, uploadID: uploadID)) }
                if let remoteJob { _ = try? await s.data(for: ReconRequests.deleteJob(base: base, key: key, jobID: remoteJob)) }
            }
        }
    }

    /// Picks up every unfinished build (app launch and every return to the foreground).
    func resumeActive() {
        guard config != nil, let store else { return }
        for job in store.jobs {
            for capture in job.captures where capture.kind == .object && (capture.remoteBuild?.isActive ?? false) {
                start(job: job.id, capture: capture.id)
            }
        }
    }

    // MARK: - Pipeline

    private struct Offline: Error { var message: String? }
    private struct Fatal: Error { var message: String }

    private func run(job jobID: UUID, capture captureID: UUID) async {
        guard let config else { return }
        #if canImport(UIKit)
        // Keep going for the extra ~30 s iOS allows when the user locks the phone mid-upload.
        var bgTask = UIBackgroundTaskIdentifier.invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "Mac build") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        defer { if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) } }
        #endif
        var delay: UInt64 = 2
        while !Task.isCancelled {
            guard var build = current(jobID, captureID), build.isActive else { return }
            do {
                let base = try await baseURL()
                if build.jobID == nil {
                    build = try await upload(build, base: base, key: config.apiKey, job: jobID, capture: captureID)
                }
                build = try await waitForMac(build, base: base, key: config.apiKey, job: jobID, capture: captureID)
                if build.phase == .failed {
                    persist(build, job: jobID, capture: captureID)
                    return
                }
                try await download(build, base: base, key: config.apiKey, job: jobID, capture: captureID)
                Self.removeWorkDirectory(captureID)
                return
            } catch is CancellationError {
                return
            } catch let fatal as Fatal {
                guard var b = current(jobID, captureID) else { return }
                b.phase = .failed
                b.message = fatal.message
                b.finishedAt = Date()
                persist(b, job: jobID, capture: captureID)
                return
            } catch let api as ReconAPIError where api.code == "unauthorized" {
                guard var b = current(jobID, captureID) else { return }
                b.phase = .failed
                b.message = "This copy of AsBuilt has the wrong key for your Mac's build server."
                b.finishedAt = Date()
                persist(b, job: jobID, capture: captureID)
                return
            } catch let api as ReconAPIError where api.code == "upload_too_large" {
                guard var b = current(jobID, captureID) else { return }
                b.phase = .failed
                b.message = "This capture is too large for the Mac build (8 GB max)."
                b.finishedAt = Date()
                persist(b, job: jobID, capture: captureID)
                return
            } catch {
                // Offline, tunnel URL changed, Mac asleep, Cloudflare error page, Mac out of space…
                resolvedBase = nil
                guard var b = current(jobID, captureID), b.isActive else { return }
                var wait = delay
                if let api = error as? ReconAPIError {
                    if api.code == "rate_limited" { wait = UInt64(max(5, api.retryAfterSeconds ?? 60)) }
                    if api.code == "insufficient_storage" { wait = 120 }
                }
                b.failureCount += 1
                if b.phase == .preparing || b.phase == .uploading || b.phase == .waitingForMac || b.jobID == nil {
                    b.phase = .waitingForMac
                }
                b.message = Self.waitingMessage(error)
                persist(b, job: jobID, capture: captureID)
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
                delay = min(60, delay * 2)
            }
        }
    }

    /// Zip → chunks → create upload → send missing chunks → job ID (the server auto-completes).
    private func upload(_ start: RemoteBuild, base: URL, key: String, job jobID: UUID, capture captureID: UUID) async throws -> RemoteBuild {
        guard let store, let capture = store.capture(job: jobID, capture: captureID) else { throw CancellationError() }
        var build = start
        let work = Self.workDirectory(captureID)
        var plan = Self.loadPlan(captureID)
        // Chunk files gone (caches purged, re-pack after a corrupt upload): start a fresh upload.
        if plan == nil { build.uploadID = nil }

        // Server-side upload still there? Otherwise (expired, or chunks we already deleted are needed) start over.
        if let uploadID = build.uploadID, plan != nil {
            let (data, code) = try await send(ReconRequests.upload(base: base, key: key, uploadID: uploadID))
            if code == 200, let up = try? JSONDecoder().decode(ReconUpload.self, from: data) {
                build.apply(upload: up)
                if let jid = up.jobID { build.jobID = jid; return build }
            } else if code == 404 {
                build.uploadID = nil
            } else {
                try fail(data, code)
            }
        }
        if let p = plan, build.uploadID != nil {
            let have = Set(build.receivedChunks)
            let missingFiles = p.chunks.filter { !have.contains($0.index) && !FileManager.default.fileExists(atPath: work.appendingPathComponent($0.fileName).path) }
            if !missingFiles.isEmpty { plan = nil; build.uploadID = nil }
        }
        if build.uploadID == nil {
            build.receivedChunks = []
            if plan == nil {
                build.phase = .preparing
                build.phaseProgress = 0
                build.message = nil
                persist(build, job: jobID, capture: captureID)
                plan = try await prepare(capture: capture, job: jobID)
            }
            guard let p = plan else { throw Fatal(message: "Couldn't pack the photos.") }
            let body = ReconCreateUpload(captureID: captureID.uuidString, totalBytes: p.totalBytes, sha256: p.sha256,
                                         title: capture.title, chunkSize: p.chunkSize)
            let (data, code) = try await send(try ReconRequests.createUpload(base: base, key: key, body: body))
            guard code == 201, let up = try? JSONDecoder().decode(ReconUpload.self, from: data) else { try fail(data, code); throw Offline() }
            build.chunks = p.chunks
            build.apply(upload: up)
        }
        guard let p = plan else { throw Fatal(message: "Couldn't pack the photos.") }
        build.chunks = p.chunks
        build.totalBytes = p.totalBytes
        build.phase = .uploading
        build.message = nil
        persist(build, job: jobID, capture: captureID)

        // Up to 3 chunks in flight.
        guard let uploadID = build.uploadID else { throw Offline() }
        var pending = p.chunks.filter { !Set(build.receivedChunks).contains($0.index) }
        var completedJob: String?
        try await withThrowingTaskGroup(of: (ReconChunk, Data, Int).self) { group in
            let s = session
            func launch(_ chunk: ReconChunk) {
                let file = work.appendingPathComponent(chunk.fileName)
                let req = ReconRequests.chunk(base: base, key: key, uploadID: uploadID, index: chunk.index,
                                              byteCount: chunk.bytes, sha256: chunk.sha256)
                group.addTask {
                    let (data, resp) = try await s.upload(for: req, fromFile: file)
                    return (chunk, data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
                }
            }
            for _ in 0..<min(3, pending.count) { launch(pending.removeFirst()) }
            while let result = try await group.next() {
                let (chunk, data, code) = result
                if code == 200, let receipt = try? JSONDecoder().decode(ReconChunkReceipt.self, from: data) {
                    build.markChunkReceived(receipt)
                    try? FileManager.default.removeItem(at: work.appendingPathComponent(chunk.fileName))
                    if var latest = current(jobID, captureID), latest.isActive {
                        latest.receivedChunks = build.receivedChunks
                        latest.phase = build.phase == .queued ? .queued : .uploading
                        latest.chunks = build.chunks
                        latest.totalBytes = build.totalBytes
                        latest.message = nil
                        persist(latest, job: jobID, capture: captureID)
                    } else {
                        throw CancellationError()
                    }
                } else if code == 409, let e = ReconAPIError.parse(data), e.code == "upload_completed" {
                    completedJob = e.jobID
                    group.cancelAll()
                    break
                } else if code == 400, let e = ReconAPIError.parse(data), e.code == "chunk_sha256_mismatch" {
                    pending.append(chunk)   // re-send (transport corruption)
                } else {
                    try fail(data, code)
                    throw Offline()
                }
                if !pending.isEmpty { launch(pending.removeFirst()) }
            }
        }
        if let completedJob {
            build.jobID = completedJob
            build.phase = .queued
            return build
        }
        // All chunks in: the server auto-completes; fall back to an explicit /complete.
        for attempt in 0..<8 {
            let (data, code) = try await send(ReconRequests.upload(base: base, key: key, uploadID: uploadID))
            if code == 200, let up = try? JSONDecoder().decode(ReconUpload.self, from: data) {
                build.apply(upload: up)
                if let jid = up.jobID { build.jobID = jid; break }
                if !build.missingChunks.isEmpty { throw Offline(message: "Some photos didn't arrive. Sending them again.") }
            } else {
                try fail(data, code)
            }
            if attempt >= 2 {
                let (cdata, ccode) = try await send(ReconRequests.complete(base: base, key: key, uploadID: uploadID))
                if (ccode == 200 || ccode == 201), let done = try? JSONDecoder().decode(ReconComplete.self, from: cdata) {
                    build.jobID = done.jobID
                    break
                }
                if ccode == 422 {
                    // Whole-file hash mismatch: the server discarded everything. Pack again.
                    Self.removeWorkDirectory(captureID)
                    build.uploadID = nil
                    build.receivedChunks = []
                    persist(build, job: jobID, capture: captureID)
                    throw Offline(message: "The photo upload got corrupted. Sending it again.")
                }
                if ccode == 409 { throw Offline(message: "Some photos didn't arrive. Sending them again.") }
                try fail(cdata, ccode)
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard build.jobID != nil else { throw Offline() }
        build.phase = .queued
        build.phaseProgress = 0
        persist(build, job: jobID, capture: captureID)
        return build
    }

    /// Polls the Mac every 5 s until the model is ready or the build failed.
    private func waitForMac(_ start: RemoteBuild, base: URL, key: String, job jobID: UUID, capture captureID: UUID) async throws -> RemoteBuild {
        guard let remoteJob = start.jobID else { throw Offline() }
        while true {
            try Task.checkCancellation()
            let (data, code) = try await send(ReconRequests.job(base: base, key: key, jobID: remoteJob))
            if code == 404 {
                // Job expired on the Mac (7 days) before we downloaded it: build again from the photos.
                guard var b = current(jobID, captureID) else { throw CancellationError() }
                b.jobID = nil
                b.uploadID = nil
                b.receivedChunks = []
                Self.removeWorkDirectory(captureID)
                persist(b, job: jobID, capture: captureID)
                throw Offline(message: "Your Mac no longer had this build. Sending the photos again.")
            }
            guard code == 200, let job = try? JSONDecoder().decode(ReconJob.self, from: data) else { try fail(data, code); throw Offline() }
            guard var b = current(jobID, captureID), b.isActive else { throw CancellationError() }
            b.apply(job: job)
            b.failureCount = 0
            if job.state != "failed" { b.message = nil }
            persist(b, job: jobID, capture: captureID)
            if job.state == "done" || job.state == "failed" { return b }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func download(_ start: RemoteBuild, base: URL, key: String, job jobID: UUID, capture captureID: UUID) async throws {
        guard let store, let remoteJob = start.jobID else { throw Offline() }
        let (jdata, jcode) = try await send(ReconRequests.job(base: base, key: key, jobID: remoteJob))
        guard jcode == 200, let job = try? JSONDecoder().decode(ReconJob.self, from: jdata),
              let file = job.file(named: "model.usdz"), let request = ReconRequests.file(base: base, key: key, relativeURL: file.url) else {
            try fail(jdata, jcode)
            throw Offline()
        }
        var b = start
        b.phase = .downloading
        b.phaseProgress = 0.1
        persist(b, job: jobID, capture: captureID)

        let (tmp, resp) = try await session.download(for: request)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw Offline(message: "Download interrupted. Trying again.")
        }
        let expected = file.sha256
        let actual = try await Task.detached(priority: .utility) { try ReconChunker.sha256(of: tmp) }.value
        if let expected, expected != actual {
            try? FileManager.default.removeItem(at: tmp)
            throw Offline(message: "The model download got corrupted. Trying again.")
        }
        let dir = store.captureDirectory(job: jobID, capture: captureID)
        let dest = dir.appendingPathComponent(CaptureFile.fullModelUSDZ)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)

        // Build log next to the model (best effort).
        if let log = job.file(named: "recon-log.txt"), let logRequest = ReconRequests.file(base: base, key: key, relativeURL: log.url),
           let (ldata, lresp) = try? await session.data(for: logRequest), (lresp as? HTTPURLResponse)?.statusCode == 200 {
            try? ldata.write(to: dir.appendingPathComponent(CaptureFile.fullModelLog), options: .atomic)
        }

        guard var done = current(jobID, captureID) else { return }
        done.apply(job: job)
        done.phase = .done
        done.phaseProgress = 1
        done.modelBytes = file.bytes ?? done.modelBytes
        done.finishedAt = Date()
        done.message = nil
        done.chunks = nil
        persist(done, job: jobID, capture: captureID)
        if var capture = store.capture(job: jobID, capture: captureID), capture.status != .complete {
            // The Mac model also rescues captures whose on-device build failed.
            capture.status = .complete
            capture.statusMessage = nil
            store.updateCapture(capture, in: jobID)
        }
        store.touchExports()
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        // Free the Mac's disk; the model now lives on the phone.
        let s = session
        Task.detached { _ = try? await s.data(for: ReconRequests.deleteJob(base: base, key: key, jobID: remoteJob)) }
    }

    /// Zips the capture's Images folder (streamed) and cuts it into upload chunks, off the main thread.
    private func prepare(capture: Capture, job jobID: UUID) async throws -> ReconChunkPlan {
        guard let store else { throw CancellationError() }
        let captureDir = store.captureDirectory(job: jobID, capture: capture.id)
        let title = capture.title
        let captureID = capture.id
        let work = Self.workDirectory(captureID)
        let chunkSize = Self.chunkSize
        do {
            return try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            try? fm.removeItem(at: work)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = try ExportService.makePhotoZip(captureDirectory: captureDir, title: title)
            let local = work.appendingPathComponent("Images.zip")
            try? fm.removeItem(at: local)
            try fm.moveItem(at: zip, to: local)
            let plan = try ReconChunker.split(zip: local, into: work, chunkSize: chunkSize)
            let data = try JSONEncoder().encode(plan)
            try data.write(to: work.appendingPathComponent("plan.json"), options: .atomic)
            return plan
            }.value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // No photos, disk full, unreadable file: retrying won't help, so say what happened.
            throw Fatal(message: "Couldn't pack the photos: \(error.localizedDescription)")
        }
    }

    // MARK: - Networking helpers

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, resp) = try await session.data(for: request)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw Offline(message: error.code == .notConnectedToInternet ? "This iPhone is offline. AsBuilt keeps trying." : nil)
        }
    }

    /// Turns a non-success response into a typed error (our JSON) or Offline (Cloudflare HTML, 5xx).
    private func fail(_ data: Data, _ code: Int) throws {
        if (200..<300).contains(code) { return }
        if let e = ReconAPIError.parse(data) { throw e }
        throw Offline()
    }

    /// Discovery first (the tunnel URL changes when the Mac restarts), then the URL baked into the build.
    private func baseURL() async throws -> URL {
        if let resolvedBase { return resolvedBase }
        guard let config else { throw Fatal(message: "Mac builds aren't set up in this copy of AsBuilt.") }
        var candidates: [URL] = []
        if let discovery = config.discoveryURL {
            var r = URLRequest(url: discovery, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            r.setValue("AsBuilt-iOS", forHTTPHeaderField: "User-Agent")
            if let (data, resp) = try? await session.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
               let found = ReconDiscovery.baseURL(fromGist: data) {
                candidates.append(found)
            }
        }
        if let b = config.baseURL, !candidates.contains(b) { candidates.append(b) }
        for candidate in candidates {
            if let (data, resp) = try? await session.data(for: ReconRequests.health(base: candidate)),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let health = try? JSONDecoder().decode(ReconHealth.self, from: data), health.ok, (health.apiVersion ?? 1) == 1 {
                resolvedBase = candidate
                return candidate
            }
        }
        throw Offline(message: "Your Mac isn't reachable right now. AsBuilt keeps trying.")
    }

    private static func waitingMessage(_ error: Error) -> String {
        if let offline = error as? Offline, let m = offline.message { return m }
        if let api = error as? ReconAPIError {
            switch api.code {
            case "insufficient_storage": return "Your Mac is out of disk space. Free some up; AsBuilt keeps trying."
            case "rate_limited": return "Your Mac asked AsBuilt to slow down. Trying again shortly."
            default: return api.message ?? "Your Mac had a problem (\(api.code)). Trying again."
            }
        }
        return "Your Mac isn't reachable right now. AsBuilt keeps trying."
    }

    // MARK: - State

    private func current(_ jobID: UUID, _ captureID: UUID) -> RemoteBuild? {
        store?.capture(job: jobID, capture: captureID)?.remoteBuild
    }

    private func persist(_ build: RemoteBuild, job jobID: UUID, capture captureID: UUID) {
        guard let store, var capture = store.capture(job: jobID, capture: captureID) else { return }
        var b = build
        b.updatedAt = Date()
        capture.remoteBuild = b
        store.updateCapture(capture, in: jobID)
    }

    private static func workDirectory(_ captureID: UUID) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recon", isDirectory: true)
            .appendingPathComponent(captureID.uuidString, isDirectory: true)
    }

    private static func removeWorkDirectory(_ captureID: UUID) {
        try? FileManager.default.removeItem(at: workDirectory(captureID))
    }

    private static func loadPlan(_ captureID: UUID) -> ReconChunkPlan? {
        guard let data = try? Data(contentsOf: workDirectory(captureID).appendingPathComponent("plan.json")) else { return nil }
        return try? JSONDecoder().decode(ReconChunkPlan.self, from: data)
    }
}
