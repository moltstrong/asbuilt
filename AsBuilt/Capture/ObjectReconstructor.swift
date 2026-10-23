import Foundation
import SwiftUI
import AsBuiltCore

#if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
import RealityKit

/// Runs on-device photogrammetry over a capture's saved photos with an automatic retry chain
/// (`ReconstructionAttempt.chain`), writing `reconstruction-log.txt` next to the photos.
///
/// Each attempt writes to its own output file; the first one that produces a model is renamed to
/// model.usdz. The capture is only reported failed after every attempt failed, with a plain-language
/// message (`ReconstructionErrorExplainer`); the technical details stay in the log.
@MainActor
final class ObjectReconstructor: ObservableObject {
    struct Outcome {
        var succeeded: Bool
        var attempts: Int
        /// Plain-language message when every attempt failed.
        var message: String?
        var explanation: ReconstructionErrorExplainer.Explanation?
    }

    @Published private(set) var isRunning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var attemptNumber = 0
    @Published private(set) var stageText = ""

    let attemptCount = ReconstructionAttempt.chain.count

    /// Capture folders with a build in progress (one PhotogrammetrySession per capture at a time).
    private static var active: Set<String> = []

    func run(captureDirectory: URL, reason: String) async -> Outcome {
        let key = captureDirectory.standardizedFileURL.path
        guard !Self.active.contains(key) else {
            return Outcome(succeeded: false, attempts: 0,
                           message: "A 3D build is already running for this capture. Keep the app open until it finishes.",
                           explanation: nil)
        }
        Self.active.insert(key)
        defer { Self.active.remove(key) }
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isRunning = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        let fm = FileManager.default
        let images = captureDirectory.appendingPathComponent(CaptureFile.images, isDirectory: true)
        let checkpoint = captureDirectory.appendingPathComponent(CaptureFile.checkpoint, isDirectory: true)
        let logURL = captureDirectory.appendingPathComponent(CaptureFile.reconstructionLog)
        let finalURL = captureDirectory.appendingPathComponent(CaptureFile.modelUSDZ)
        let imageFiles = Self.imageFiles(in: images)
        let imageBytes = imageFiles.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

        var log = ReconstructionLog(header: [])
        if let previous = try? String(contentsOf: logURL, encoding: .utf8), !previous.isEmpty {
            log.add(previous.trimmingCharacters(in: .newlines))
            log.add("")
        }
        log.add("==================== AsBuilt on-device 3D build ====================")
        log.add("Started: \(ReconstructionLog.timestamp())  (\(reason))")
        log.add("App: AsBuilt \(Self.appVersion)")
        log.add("Device: \(DeviceCapabilities.modelIdentifier())  \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        log.add("PhotogrammetrySession.isSupported: \(PhotogrammetrySession.isSupported)")
        log.add("PhotogrammetrySession.limits: maxImages=\(PhotogrammetrySession.limits.maximumNumberOfInputImages) maxDimension=\(PhotogrammetrySession.limits.maximumInputImageDimension)")
        log.add("Images: \(imageFiles.count) files, \(ByteCountFormatter.string(fromByteCount: imageBytes, countStyle: .file)) in \(images.lastPathComponent)/")
        log.add("Checkpoint folder: \(Self.isNonEmptyDirectory(checkpoint) ? "present" : "missing or empty")")
        log.add("Free disk space: \(Self.freeDiskSpace(captureDirectory))")
        log.add("Thermal state: \(Self.thermalText)  Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        write(log, to: logURL)

        var lastError: Error?
        var attempts = 0
        guard PhotogrammetrySession.isSupported else {
            log.add("RESULT: PhotogrammetrySession is not supported on this device. No attempt made.")
            write(log, to: logURL)
            return Outcome(succeeded: false, attempts: 0,
                           message: "This phone can't build 3D models from photos on device. The photos are saved; use LiDAR Mesh, or build it on a Mac.",
                           explanation: nil)
        }
        guard !imageFiles.isEmpty else {
            log.add("RESULT: no images found. No attempt made.")
            write(log, to: logURL)
            return Outcome(succeeded: false, attempts: 0, message: "No photos were saved for this capture. Capture the object again.",
                           explanation: nil)
        }

        for attempt in ReconstructionAttempt.chain {
            attempts += 1
            attemptNumber = attempt.number
            progress = 0
            stageText = "Starting"
            let output = captureDirectory.appendingPathComponent(attempt.outputFileName)
            try? fm.removeItem(at: output)

            var configuration = PhotogrammetrySession.Configuration()
            var useCheckpoint = attempt.useCheckpoint
            if useCheckpoint && !Self.isNonEmptyDirectory(checkpoint) { useCheckpoint = false }
            if useCheckpoint { configuration.checkpointDirectory = checkpoint }
            configuration.sampleOrdering = attempt.sampleOrdering == .sequential ? .sequential : .unordered
            configuration.featureSensitivity = attempt.featureSensitivity == .high ? .high : .normal
            configuration.isObjectMaskingEnabled = attempt.objectMasking

            log.section("Attempt \(attempt.number) of \(attemptCount)  \(ReconstructionLog.timestamp())")
            log.add("Config: \(attempt.summary)\(attempt.useCheckpoint && !useCheckpoint ? " (checkpoint requested but missing: not used)" : "")")
            log.add("Request: .modelFile(url: \(output.lastPathComponent)) (default detail; iOS builds .reduced)")
            write(log, to: logURL)

            let started = Date()
            var attemptError: Error?
            var invalid = 0, skipped = 0
            do {
                let session = try PhotogrammetrySession(input: images, configuration: configuration)
                try session.process(requests: [.modelFile(url: output)])
                var lastStage = ""
                outputs: for try await item in session.outputs {
                    switch item {
                    case .requestProgress(_, let fraction):
                        progress = fraction
                    case .requestProgressInfo(_, let info):
                        if let stage = info.processingStage {
                            let text = Self.stageText(stage)
                            if text != lastStage {
                                lastStage = text
                                stageText = text
                                log.add("  stage: \(text) at \(Int(progress * 100))%  (+\(Self.elapsed(since: started)))")
                            }
                        }
                    case .inputComplete:
                        log.add("  inputComplete  (+\(Self.elapsed(since: started)))")
                    case .invalidSample(let id, let reason):
                        invalid += 1
                        if invalid <= 40 { log.add("  invalidSample id=\(id) reason=\(reason)") }
                    case .skippedSample(let id):
                        skipped += 1
                        if skipped <= 40 { log.add("  skippedSample id=\(id)") }
                    case .automaticDownsampling:
                        log.add("  automaticDownsampling (images were downsampled to fit memory)")
                    case .stitchingIncomplete:
                        log.add("  stitchingIncomplete (not all photo segments could be joined)")
                    case .requestComplete(_, let result):
                        log.add("  requestComplete: \(String(describing: result))")
                    case .requestError(_, let error):
                        attemptError = error
                        log.add("  requestError: \(String(reflecting: error))")
                    case .processingCancelled:
                        attemptError = attemptError ?? CancellationError()
                        log.add("  processingCancelled")
                        break outputs
                    case .processingComplete:
                        log.add("  processingComplete  (+\(Self.elapsed(since: started)))")
                        break outputs
                    @unknown default:
                        log.add("  output: \(String(describing: item))")
                    }
                }
            } catch {
                attemptError = error
            }
            if invalid > 40 || skipped > 40 { log.add("  (\(invalid) invalid / \(skipped) skipped samples in total)") }

            let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if attemptError == nil, size > 0 {
                try? fm.removeItem(at: finalURL)
                do {
                    try fm.moveItem(at: output, to: finalURL)
                } catch {
                    log.add("  could not rename \(output.lastPathComponent) to \(finalURL.lastPathComponent): \(error)")
                }
                log.add("RESULT: attempt \(attempt.number) succeeded in \(Self.elapsed(since: started)); model.usdz \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
                write(log, to: logURL)
                Self.cleanUpAttemptFiles(in: captureDirectory)
                progress = 1
                return Outcome(succeeded: true, attempts: attempts, message: nil, explanation: nil)
            }
            let error = attemptError ?? NSError(domain: "AsBuilt.Reconstruction", code: 1,
                                                userInfo: [NSLocalizedDescriptionKey: "Processing finished without a model file"])
            lastError = error
            try? fm.removeItem(at: output)
            log.add("FAILED after \(Self.elapsed(since: started))")
            log.add(contentsOf: Self.describe(error, imageCount: imageFiles.count))
            write(log, to: logURL)
            if error is CancellationError { break }
        }

        let ns = lastError.map { $0 as NSError }
        let explanation = ns.map {
            ReconstructionErrorExplainer.explain(domain: $0.domain, code: $0.code, description: Self.fullDescription(lastError!),
                                                 imageCount: imageFiles.count)
        }
        log.section("RESULT: all \(attempts) attempts failed  \(ReconstructionLog.timestamp())")
        if let explanation {
            log.add("Decoded: \(explanation.technical)  kind=\(explanation.kind.rawValue)")
            log.add("Shown to user: \(explanation.message)")
        }
        write(log, to: logURL)
        Self.cleanUpAttemptFiles(in: captureDirectory)
        return Outcome(succeeded: false, attempts: attempts,
                       message: explanation?.message ?? "Apple's 3D builder couldn't finish this model.",
                       explanation: explanation)
    }

    // MARK: Helpers

    private func write(_ log: ReconstructionLog, to url: URL) {
        try? Data(log.text.utf8).write(to: url, options: .atomic)
    }

    static func describe(_ error: Error, imageCount: Int) -> [String] {
        let ns = error as NSError
        var lines = [
            "  error (reflecting): \(String(reflecting: error))",
            "  NSError domain: \(ns.domain)  code: \(ns.code)",
            "  decoded case: \(ReconstructionErrorExplainer.caseName(domain: ns.domain, code: ns.code) ?? "unknown")",
            "  localizedDescription: \(ns.localizedDescription)",
        ]
        if let reason = ns.localizedFailureReason { lines.append("  failureReason: \(reason)") }
        if !ns.userInfo.isEmpty {
            lines.append("  userInfo: \(ns.userInfo.map { "\($0.key)=\(String(describing: $0.value))" }.sorted().joined(separator: "; "))")
        }
        var underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        var depth = 0
        while let u = underlying, depth < 4 {
            lines.append("  underlying: \(u.domain) \(u.code) \(u.localizedDescription)")
            underlying = u.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        let explanation = ReconstructionErrorExplainer.explain(domain: ns.domain, code: ns.code,
                                                               description: fullDescription(error), imageCount: imageCount)
        lines.append("  plain language: \(explanation.message)")
        return lines
    }

    static func fullDescription(_ error: Error) -> String {
        let ns = error as NSError
        return "\(String(reflecting: error)) \(ns.localizedDescription) \(ns.userInfo.values.map { String(describing: $0) }.joined(separator: " "))"
    }

    static func imageFiles(in dir: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        let extensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff"]
        return urls.filter { extensions.contains($0.pathExtension.lowercased()) }
    }

    static func isNonEmptyDirectory(_ url: URL) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path))?.isEmpty == false)
    }

    static func cleanUpAttemptFiles(in dir: URL) {
        for attempt in ReconstructionAttempt.chain {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(attempt.outputFileName))
        }
    }

    static func freeDiskSpace(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values?.volumeAvailableCapacityForImportantUsage else { return "unknown" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static var thermalText: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    static func elapsed(since date: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(date))
    }

    static func stageText(_ stage: PhotogrammetrySession.Output.ProcessingStage) -> String {
        switch stage {
        case .preProcessing: return "Preparing photos"
        case .imageAlignment: return "Aligning photos"
        case .pointCloudGeneration: return "Building point cloud"
        case .meshGeneration: return "Building mesh"
        case .textureMapping: return "Texturing"
        case .optimization: return "Optimizing"
        @unknown default: return "Processing"
        }
    }
}

private extension ReconstructionLog {
    mutating func add(contentsOf lines: [String]) {
        for line in lines { add(line) }
    }
}
#endif
