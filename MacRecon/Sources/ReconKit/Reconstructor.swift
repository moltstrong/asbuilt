import Foundation
import RealityKit

/// Runs PhotogrammetrySession with the requested options, retrying once with relaxed alignment
/// settings if the first attempt fails (unless the user pinned those settings).
public final class Reconstructor: @unchecked Sendable {
    public let options: BuildOptions
    public let outDir: URL
    public let log: ReconLog
    public let status: StatusWriter
    private var currentSession: PhotogrammetrySession?
    private let sessionLock = NSLock()
    public private(set) var cancelled = false

    public init(options: BuildOptions, outDir: URL, log: ReconLog, status: StatusWriter) {
        self.options = options
        self.outDir = outDir
        self.log = log
        self.status = status
    }

    public var usdzURL: URL { outDir.appendingPathComponent("model.usdz") }
    public var objDir: URL { outDir.appendingPathComponent("obj", isDirectory: true) }

    /// Called from a signal handler (SIGINT/SIGTERM).
    public func cancel() {
        sessionLock.lock(); defer { sessionLock.unlock() }
        cancelled = true
        currentSession?.cancel()
    }

    static func apiDetail(_ d: Detail) -> PhotogrammetrySession.Request.Detail {
        switch d {
        case .preview: return .preview
        case .reduced: return .reduced
        case .medium: return .medium
        case .full: return .full
        case .raw: return .raw
        case .custom: return .custom
        }
    }

    static func stageName(_ s: PhotogrammetrySession.Output.ProcessingStage?) -> String? {
        guard let s else { return nil }
        switch s {
        case .preProcessing: return "preProcessing"
        case .imageAlignment: return "imageAlignment"
        case .pointCloudGeneration: return "pointCloudGeneration"
        case .meshGeneration: return "meshGeneration"
        case .textureMapping: return "textureMapping"
        case .optimization: return "optimization"
        @unknown default: return "\(s)"
        }
    }

    func makeConfiguration(_ plan: AttemptPlan) -> PhotogrammetrySession.Configuration {
        var c = PhotogrammetrySession.Configuration()
        if plan.number == 1, let cp = options.checkpoint {
            let url = URL(fileURLWithPath: (cp as NSString).expandingTildeInPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            c.checkpointDirectory = url
        }
        c.sampleOrdering = plan.ordering == .sequential ? .sequential : .unordered
        c.featureSensitivity = plan.sensitivity == .high ? .high : .normal
        c.isObjectMaskingEnabled = plan.masking
        if options.detail == .custom {
            var spec = PhotogrammetrySession.Configuration.CustomDetailSpecification()
            spec.maximumPolygonCount = options.effectiveMaxPolys
            switch options.effectiveTexture {
            case .k1: spec.maximumTextureDimension = .oneK
            case .k2: spec.maximumTextureDimension = .twoK
            case .k4: spec.maximumTextureDimension = .fourK
            case .k8: spec.maximumTextureDimension = .eightK
            case .k16:
                if #available(macOS 15.0, *) { spec.maximumTextureDimension = .sixteenK } else { spec.maximumTextureDimension = .eightK }
            }
            var maps: PhotogrammetrySession.Configuration.CustomDetailSpecification.TextureMapOutputs = []
            for m in options.effectiveMaps {
                switch m {
                case .diffuse: maps.insert(.diffuseColor)
                case .normal: maps.insert(.normal)
                case .roughness: maps.insert(.roughness)
                case .displacement: maps.insert(.displacement)
                case .ao: maps.insert(.ambientOcclusion)
                }
            }
            spec.outputTextureMaps = maps
            switch options.effectiveTextureFormat {
            case .png: spec.textureFormat = .png
            case .jpeg(let q): spec.textureFormat = .jpeg(compressionQuality: q)
            }
            c.customDetailSpecification = spec
        }
        if #available(macOS 15.0, *) {
            if options.quads { c.meshPrimitive = .quad }
            if options.ignoreBoundingBox { c.ignoreBoundingBox = true }
        }
        return c
    }

    public struct AttemptOutcome {
        public var ok: Bool
        public var error: Error?
        public var seconds: Double
        public var stageSeconds: [String: Double]
        public var invalid: Int
        public var skipped: Int
        public var downsampled: Bool
        public var cancelled: Bool
    }

    /// One PhotogrammetrySession run. Writes model.usdz (and obj/ when requested).
    public func runAttempt(_ plan: AttemptPlan, imagesFolder: URL, imageCount: Int) async -> AttemptOutcome {
        let fm = FileManager.default
        try? fm.removeItem(at: usdzURL)
        if options.obj {
            try? fm.removeItem(at: objDir)
            try? fm.createDirectory(at: objDir, withIntermediateDirectories: true)
        }
        let config = makeConfiguration(plan)
        log.section("Attempt \(plan.number)")
        log.add("config: \(plan.summary) checkpoint=\(config.checkpointDirectory?.path ?? "none")")
        if options.detail == .custom {
            let s = config.customDetailSpecification
            log.add("customDetailSpecification: maximumPolygonCount=\(s.maximumPolygonCount) maximumTextureDimension=.\(s.maximumTextureDimension) outputTextureMaps.rawValue=\(s.outputTextureMaps.rawValue) textureFormat=\(s.textureFormat)")
        }
        if #available(macOS 15.0, *) {
            log.add("meshPrimitive=\(config.meshPrimitive) ignoreBoundingBox=\(config.ignoreBoundingBox)")
        }
        let start = Date()
        var outcome = AttemptOutcome(ok: false, error: nil, seconds: 0, stageSeconds: [:], invalid: 0, skipped: 0, downsampled: false, cancelled: false)

        let session: PhotogrammetrySession
        do {
            session = try PhotogrammetrySession(input: imagesFolder, configuration: config)
        } catch {
            log.add("PhotogrammetrySession init failed:")
            log.add(ErrorExplainer.technicalDump(error))
            outcome.error = error
            outcome.seconds = Date().timeIntervalSince(start)
            return outcome
        }
        let alreadyCancelled = sessionLock.withLock { () -> Bool in
            currentSession = session
            return cancelled
        }
        if alreadyCancelled { session.cancel() }

        let detail = Self.apiDetail(options.detail)
        var requests: [PhotogrammetrySession.Request] = [.modelFile(url: usdzURL, detail: detail)]
        if options.obj { requests.append(.modelFile(url: objDir, detail: detail)) }
        log.add("requests: " + requests.map { "\($0)" }.joined(separator: " | "))

        do {
            try session.process(requests: requests)
        } catch {
            log.add("process(requests:) threw:")
            log.add(ErrorExplainer.technicalDump(error))
            outcome.error = error
            outcome.seconds = Date().timeIntervalSince(start)
            return outcome
        }
        status.update(force: true) { $0.state = "processing"; $0.attempt = plan.number; $0.fraction = 0; $0.stage = nil; $0.message = "Processing \(imageCount) photos (attempt \(plan.number))" }

        var fractions: [Int: Double] = [:]
        var completed = 0
        var requestErrors: [Error] = []
        var stage: String?
        var stageStart = Date()
        var eta: Double?
        var lastPrint = Date.distantPast
        var lastPrintedPct = -1.0
        func idx(_ r: PhotogrammetrySession.Request) -> Int {
            if case .modelFile(let u, _, _) = r, u.standardizedFileURL == objDir.standardizedFileURL { return 1 }
            return 0
        }
        func report(force: Bool = false) {
            let total = fractions.values.reduce(0, +) / Double(max(requests.count, 1))
            status.update(force: force) {
                $0.fraction = total; $0.etaSeconds = eta; $0.stage = stage
                $0.message = "Building \(options.detail.rawValue)-detail model: \(Int(total * 100))%"
            }
            let now = Date()
            let pct = (total * 1000).rounded() / 10
            if force || (now.timeIntervalSince(lastPrint) >= 5 && pct != lastPrintedPct) {
                lastPrint = now
                lastPrintedPct = pct
                let etaText = eta.map { " ETA \(Fmt.duration($0))" } ?? ""
                log.add(String(format: "[%5.1f%%] %@ elapsed %@%@", pct, stage ?? "-", Fmt.duration(now.timeIntervalSince(start)), etaText))
            }
        }

        do {
            outer: for try await output in session.outputs {
                switch output {
                case .inputComplete:
                    log.add("input complete (\(Fmt.duration(Date().timeIntervalSince(start)))): images ingested")
                case .requestProgress(let r, let f):
                    fractions[idx(r)] = f
                    report()
                case .requestProgressInfo(let r, let info):
                    _ = r
                    eta = info.estimatedRemainingTime
                    let s = Self.stageName(info.processingStage)
                    if let s, s != stage {
                        let now = Date()
                        if let old = stage { outcome.stageSeconds[old, default: 0] += now.timeIntervalSince(stageStart) }
                        stage = s
                        stageStart = now
                        log.add("stage: \(s) (t=\(Fmt.duration(now.timeIntervalSince(start))))")
                        report(force: true)
                    }
                case .requestComplete(let r, let result):
                    fractions[idx(r)] = 1
                    completed += 1
                    switch result {
                    case .modelFile(let u): log.add("request complete: model file \(u.path)")
                    default: log.add("request complete: \(result)")
                    }
                case .requestError(let r, let e):
                    requestErrors.append(e)
                    log.add("request error for \(r):")
                    log.add(ErrorExplainer.technicalDump(e))
                case .processingComplete:
                    log.add("processing complete (\(Fmt.duration(Date().timeIntervalSince(start))))")
                    break outer
                case .processingCancelled:
                    log.add("processing cancelled")
                    outcome.cancelled = true
                    break outer
                case .invalidSample(let id, let reason):
                    outcome.invalid += 1
                    log.add("invalid sample \(id): \(reason)")
                case .skippedSample(let id):
                    outcome.skipped += 1
                    log.add("skipped sample \(id)")
                case .automaticDownsampling:
                    outcome.downsampled = true
                    log.add("automatic downsampling: Apple reduced the input image resolution to fit this Mac's memory")
                case .stitchingIncomplete:
                    log.add("stitching incomplete: some photos could not be connected to the main model")
                @unknown default:
                    log.add("output: \(output)")
                }
            }
        } catch {
            log.add("outputs stream threw:")
            log.add(ErrorExplainer.technicalDump(error))
            requestErrors.append(error)
        }
        if let old = stage { outcome.stageSeconds[old, default: 0] += Date().timeIntervalSince(stageStart) }
        sessionLock.withLock { currentSession = nil }
        outcome.seconds = Date().timeIntervalSince(start)
        outcome.cancelled = outcome.cancelled || cancelled
        outcome.error = requestErrors.first
        outcome.ok = requestErrors.isEmpty && !outcome.cancelled && completed == requests.count && fm.fileExists(atPath: usdzURL.path)
        if !outcome.ok && outcome.error == nil && !outcome.cancelled {
            log.add("attempt ended without an error but model.usdz is missing (completed \(completed)/\(requests.count))")
        }
        return outcome
    }
}
