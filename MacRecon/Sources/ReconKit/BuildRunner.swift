import Foundation
import RealityKit

public let toolVersion = "1.0.0"

public enum ExitCode: Int32 {
    case ok = 0, failed = 1, usage = 2, unsupported = 3, cancelled = 130
}

/// The whole `build` command: resolve input, reconstruct (with one automatic retry), inspect the
/// output, write recon-log.txt + result.json.
public final class BuildRunner: @unchecked Sendable {
    public let options: BuildOptions
    public private(set) var reconstructor: Reconstructor?
    public var echo = true

    public init(options: BuildOptions) { self.options = options }

    private let cancelLock = NSLock()
    private var _cancelRequested = false
    var cancelRequested: Bool { cancelLock.withLock { _cancelRequested } }

    public func cancel() {
        cancelLock.withLock { _cancelRequested = true }
        reconstructor?.cancel()
    }

    public static func defaultOutDir(for input: URL, detail: Detail) -> URL {
        var name = input.deletingPathExtension().lastPathComponent
        if name.isEmpty { name = "model" }
        return input.deletingLastPathComponent().appendingPathComponent("\(name)-recon-\(detail.rawValue)", isDirectory: true)
    }

    public func run() async -> (ExitCode, BuildResult) {
        let t0 = Date()
        var result = BuildResult()
        result.detail = options.detail.rawValue
        result.config = options.summary
        let fm = FileManager.default

        let inputURL = URL(fileURLWithPath: (options.input as NSString).expandingTildeInPath).standardizedFileURL
        let outDir = options.outDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL }
            ?? Self.defaultOutDir(for: inputURL, detail: options.detail)
        do {
            try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            print("error: can't create output folder \(outDir.path): \(error.localizedDescription)")
            return (.failed, result)
        }
        let log = ReconLog(url: outDir.appendingPathComponent("recon-log.txt"), echo: echo)
        defer { log.close() }
        let status = StatusWriter(url: options.statusFile.map { URL(fileURLWithPath: $0) })
        status.update(force: true) { $0.state = "starting"; $0.message = "Starting" }

        log.add("asbuilt-recon \(toolVersion) build — \(Fmt.timestamp(t0))")
        if let t = options.title { log.add("capture: \(t)") }
        log.add("machine: \(machineSummary())")
        log.add("PhotogrammetrySession.isSupported: \(PhotogrammetrySession.isSupported)")
        log.add("limits: maximumNumberOfInputImages=\(PhotogrammetrySession.limits.maximumNumberOfInputImages) maximumInputImageDimension=\(PhotogrammetrySession.limits.maximumInputImageDimension)")
        log.add("input: \(inputURL.path)")
        log.add("output: \(outDir.path)")
        log.add("options: \(options.summary)")

        func fail(_ code: ExitCode, technical: String?, message: String) -> (ExitCode, BuildResult) {
            result.ok = false
            result.errorTechnical = technical
            result.errorMessage = message
            result.totalSeconds = Date().timeIntervalSince(t0)
            log.section("FAILED")
            log.add(message)
            if let technical { log.add("technical: \(technical)") }
            log.add("total time: \(Fmt.duration(result.totalSeconds))")
            writeResult(result, outDir)
            status.update(force: true) { $0.state = code == .cancelled ? "cancelled" : "failed"; $0.message = message }
            return (code, result)
        }

        guard PhotogrammetrySession.isSupported else {
            return fail(.unsupported, technical: "PhotogrammetrySession.isSupported == false",
                        message: "This Mac can't run Apple's photogrammetry. It needs an Apple-silicon Mac, or an Intel Mac with an AMD GPU with 4 GB+ VRAM, on macOS 14 or later.")
        }

        // Input
        status.update(force: true) { $0.state = "extracting"; $0.message = "Reading photos" }
        let input: ResolvedInput
        do {
            let scratch = outDir.appendingPathComponent(".input", isDirectory: true)
            input = try InputResolver.resolve(options.input, scratch: scratch)
        } catch {
            return fail(.failed, technical: String(reflecting: error), message: "\(error)")
        }
        defer {
            if !options.keepTemp {
                input.cleanup()
                try? fm.removeItem(at: outDir.appendingPathComponent(".input"))
            }
        }
        if input.isZip { log.add("zip extracted in \(Fmt.duration(input.extractSeconds)) to \(input.imagesFolder.path)") }
        log.add("images folder: \(input.imagesFolder.path)")
        let summary = ImageSetSummary.summarize(input.images)
        for l in summary.lines { log.add(l) }
        result.imageCount = input.images.count
        if input.images.count < ErrorExplainer.minimumImages {
            log.add("warning: only \(input.images.count) photos; Apple recommends 20-200 with good overlap")
        }
        if let free = freeDiskBytes(at: outDir) {
            log.add("free disk at output: \(Fmt.bytes(free))")
            if free < 5_000_000_000 { log.add("warning: under 5 GB free; full/raw builds need several GB of scratch space") }
        }

        // Reconstruct (one PhotogrammetrySession per machine at a time)
        let lock = BuildLock()
        var cancelledWhileWaiting = false
        let gotLock = await lock.lock(waiting: {
            log.add("waiting for another asbuilt-recon build to finish (pid \(lock.holder()))…")
            status.update(force: true) { $0.state = "waiting"; $0.message = "Waiting for another build to finish" }
        }, shouldStop: { [weak self] in
            cancelledWhileWaiting = self?.cancelRequested ?? false
            return cancelledWhileWaiting
        })
        guard gotLock else { return fail(.cancelled, technical: nil, message: "The build was cancelled.") }
        defer { lock.unlock() }
        let tempBefore = SessionTempCleaner.snapshot()
        defer {
            if !options.keepTemp {
                let freed = SessionTempCleaner.clean(since: tempBefore)
                if freed > 0 { log.add("removed \(Fmt.bytes(freed)) of PhotogrammetrySession temp files") }
            }
        }
        // Stale outputs from an earlier run in the same folder would be mistaken for this run's.
        for stale in ["model.usdz", "model-obj.zip", "obj", "thumbnail.png", "result.json"] {
            try? fm.removeItem(at: outDir.appendingPathComponent(stale))
        }
        let rec = Reconstructor(options: options, outDir: outDir, log: log, status: status)
        reconstructor = rec
        let plans = AttemptPlan.plan(for: options)
        var lastError: Error?
        var winner: Reconstructor.AttemptOutcome?
        for plan in plans {
            if plan.number > 1 {
                log.add("")
                log.add("Attempt 1 failed. Retrying once with sequential ordering, high feature sensitivity and object masking off.")
            }
            let o = await rec.runAttempt(plan, imagesFolder: input.imagesFolder, imageCount: input.images.count)
            result.attempts = plan.number
            result.invalidSamples += o.invalid
            result.skippedSamples += o.skipped
            result.automaticDownsampling = result.automaticDownsampling || o.downsampled
            log.add("attempt \(plan.number): \(o.ok ? "OK" : "failed") in \(Fmt.duration(o.seconds))")
            if !o.stageSeconds.isEmpty {
                log.add("stage times: " + o.stageSeconds.sorted { $0.value > $1.value }.map { "\($0.key)=\(Fmt.duration($0.value))" }.joined(separator: " "))
            }
            if o.cancelled {
                return fail(.cancelled, technical: nil, message: "The build was cancelled.")
            }
            if o.ok {
                winner = o
                result.winningAttempt = plan.summary
                result.reconstructionSeconds = o.seconds
                result.stageSeconds = o.stageSeconds
                break
            }
            lastError = o.error
            if let e = o.error {
                let ex = ErrorExplainer.explain(e, imageCount: input.images.count)
                log.add("decoded: \(ex.technical)")
                log.add("plain language: \(ex.message)")
            }
        }
        guard winner != nil else {
            if let e = lastError {
                let ex = ErrorExplainer.explain(e, imageCount: input.images.count)
                return fail(.failed, technical: "\(ex.technical)\n\(ErrorExplainer.technicalDump(e))", message: ex.message)
            }
            return fail(.failed, technical: nil, message: "Apple's photogrammetry finished without producing model.usdz. See recon-log.txt.")
        }

        // Inspect
        status.update(force: true) { $0.state = "inspecting"; $0.fraction = 1; $0.message = "Checking the model" }
        log.section("Output")
        if options.detail == .custom, let clamp = Self.polygonClampMessage(pid: getpid(), since: t0) {
            // CoreOC logs this to the unified log only; e.g. "Clamped max poly count: 2000000 to device limit. 250000 is used."
            log.add("Apple: \(clamp)")
            result.notes.append(clamp)
        }
        let (stats, statErr) = ModelInspector.usdStats(rec.usdzURL)
        if let statErr { log.add("polygon count failed: \(statErr)") }
        else {
            result.polygons = stats.faces
            result.triangles = stats.triangles
            result.vertices = stats.points
            log.add("model.usdz: \(Fmt.count(stats.faces)) polygons (\(Fmt.count(stats.triangles)) triangles), \(Fmt.count(stats.points)) vertices, \(stats.meshes) mesh(es) [usdcat faceVertexCounts]")
            if let (x, y, z) = stats.sizeMeters {
                result.sizeMeters = [x, y, z]
                log.add(String(format: "bounding box: %.3f x %.3f x %.3f m (metersPerUnit=%@)", x, y, z, stats.metersPerUnit.map { "\($0)" } ?? "unset"))
            }
        }
        for t in ModelInspector.usdzTextures(rec.usdzURL) {
            result.textures.append(.init(name: t.name, width: t.width, height: t.height, bytes: t.bytes))
            log.add("texture: \(t)")
        }

        if options.obj {
            dedupeObjFolder(rec.objDir, log: log)
            let objFiles = ((try? fm.contentsOfDirectory(at: rec.objDir, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            log.add("obj/: " + (objFiles.isEmpty ? "EMPTY" : objFiles.map { "\($0.lastPathComponent) (\(Fmt.bytes(Fmt.treeSize($0))))" }.joined(separator: ", ")))
            if let objFile = objFiles.first(where: { $0.pathExtension.lowercased() == "obj" }) {
                let os = ModelInspector.objStats(objFile)
                result.objPolygons = os.faces
                log.add("\(objFile.lastPathComponent): \(Fmt.count(os.faces)) faces, \(Fmt.count(os.points)) vertices [parsed OBJ]")
            } else {
                log.add("warning: no .obj file was written to obj/")
            }
            for f in objFiles where ["png", "jpg", "jpeg", "exr", "tif", "tiff"].contains(f.pathExtension.lowercased()) {
                let (w, h) = ModelInspector.imageDims(f)
                result.objTextures.append(.init(name: f.lastPathComponent, width: w, height: h, bytes: Fmt.fileSize(f)))
            }
            // One-file download for the phone/office.
            let zip = outDir.appendingPathComponent("model-obj.zip")
            try? fm.removeItem(at: zip)
            if let r = try? Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", rec.objDir.path, zip.path]), r.status == 0 {
                log.add("model-obj.zip: \(Fmt.bytes(Fmt.fileSize(zip)))")
            } else {
                log.add("warning: couldn't zip obj/")
            }
        }

        let check = ModelInspector.usdcheck(rec.usdzURL)
        result.usdcheckerPassed = check.passed
        result.usdcheckerOutput = check.output
        log.add("usdchecker --arkit: \(check.passed ? "PASSED" : "FAILED") (exit \(check.exitCode); \(check.noiseLines) harmless RegisterBehaviorForPrimTypeId noise lines filtered)")
        for l in check.output.split(separator: "\n").prefix(40) { log.add("  \(l)") }

        if options.thumbnail {
            let png = outDir.appendingPathComponent("thumbnail.png")
            do {
                try Thumbnailer.render(model: rec.usdzURL, to: png)
                log.add("thumbnail: \(png.path)")
            } catch {
                log.add("thumbnail failed: \(error)")
            }
        }

        // Files
        result.files = ((try? fm.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.lastPathComponent != "result.json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { .init(name: $0.lastPathComponent + (($0.hasDirectoryPath) ? "/" : ""), bytes: Fmt.treeSize($0)) }
        for f in result.files { log.add("file: \(f.name) \(Fmt.bytes(f.bytes))") }
        result.peakMemoryBytes = peakRSS()
        result.ok = true
        result.totalSeconds = Date().timeIntervalSince(t0)
        log.section("DONE")
        log.add("detail=\(options.detail.rawValue) photos=\(input.images.count) reconstruction=\(Fmt.duration(result.reconstructionSeconds)) total=\(Fmt.duration(result.totalSeconds)) polygons=\(result.polygons.map(Fmt.count) ?? "?") usdchecker=\(check.passed ? "pass" : "FAIL") peakRSS=\(Fmt.bytes(result.peakMemoryBytes ?? 0))")
        log.add("model: \(rec.usdzURL.path)")
        writeResult(result, outDir)
        status.update(force: true) { $0.state = "done"; $0.fraction = 1; $0.message = "Model ready" }
        return (.ok, result)
    }

    /// Guard: obj/ must hold exactly one `baked_mesh_<id>` set. Two sets appear when two builds write
    /// to the same --out folder (seen when two sessions ran at once, before the build lock), so keep
    /// only the newest set so obj/ and model-obj.zip describe one model. A single build writes one set.
    func dedupeObjFolder(_ dir: URL, log: ReconLog) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let objs = files.filter { $0.pathExtension.lowercased() == "obj" }
        guard objs.count > 1 else { return }
        func mtime(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        let keep = objs.max { mtime($0) < mtime($1) }!
        let keepStem = keep.deletingPathExtension().lastPathComponent
        let otherStems = objs.map { $0.deletingPathExtension().lastPathComponent }.filter { $0 != keepStem }
        var removed: [String] = []
        for f in files {
            let n = f.lastPathComponent
            if otherStems.contains(where: { n == $0 + "." + f.pathExtension || n.hasPrefix($0 + "_") }) {
                try? fm.removeItem(at: f)
                removed.append(n)
            }
        }
        log.add("obj/: Apple wrote \(objs.count) OBJ sets; kept the newest (\(keepStem)), removed \(removed.count) files of the older set(s): \(otherStems.joined(separator: ", "))")
    }

    /// CoreOC clamps `maximumPolygonCount` to a per-device limit and only says so in the unified log
    /// ("Clamped max poly count: N to device limit. M is used."). Read it back for this process.
    static func polygonClampMessage(pid: Int32, since: Date) -> String? {
        let mins = max(1, Int(Date().timeIntervalSince(since) / 60) + 2)
        guard let r = try? Shell.run("/usr/bin/log", ["show", "--last", "\(mins)m", "--style", "compact",
                                                     "--predicate", "processIdentifier == \(pid) AND eventMessage CONTAINS \"Clamped max poly\""]),
              r.status == 0 else { return nil }
        guard let line = r.stdout.split(separator: "\n").last(where: { $0.contains("Clamped max poly") }),
              let range = line.range(of: "Clamped max poly") else { return nil }
        return String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
    }

    func writeResult(_ r: BuildResult, _ outDir: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(r) { try? d.write(to: outDir.appendingPathComponent("result.json"), options: .atomic) }
    }
}
