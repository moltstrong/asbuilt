import Foundation

/// Turns Object Capture / PhotogrammetrySession errors into plain language for crews, keeping the
/// technical identity (domain, code, decoded case name) for the reconstruction log.
///
/// Swift error enums bridge to `NSError` with `domain` = the enum's mangled-for-humans type name
/// and `code` = the case's runtime tag: payload cases first (declaration order), then no-payload
/// cases (declaration order). The tables below were decoded from the frameworks' Swift reflection
/// metadata (scripts/dump-swift-enum.swift, run in CI against the iOS 27 simulator runtime) and the
/// public SDK swiftinterfaces:
///
/// - `CoreOC.PhotogrammetrySession.Error` (private; what on-device PhotogrammetrySession throws):
///   0 reconstructionError(payload), 1 snapshotURLError, 2 imageURLError, 3 initError,
///   4 requestError, 5 sampleError, 6 processError, 7 storageFull.
///   Error 6 = `processError`: the reconstruction pipeline itself failed. Logged with it, Apple's
///   SfM stage reports "No SfM map found" (cv3dapi 4004): the photos could not be aligned.
/// - `RealityFoundation.PhotogrammetrySession.Error` (public): 0 invalidImages(URL),
///   1 invalidOutput(URL), 2 insufficientStorage(requiredBytes:).
/// - `ObjectCaptureSession.Error` (public, _RealityKit_SwiftUI): 0 directoryNotEmpty(URL),
///   1 insufficientStorage(requiredBytes:), 2 cancelled, 3 sensorFailed, 4 trackingFailed.
public enum ReconstructionErrorExplainer {
    public enum Kind: String, Sendable, Hashable {
        case alignment
        case tooFewImages
        case badImages
        case storage
        case output
        case cancelled
        case sensor
        case tracking
        case unsupported
        case unknown
    }

    public struct Explanation: Sendable, Hashable {
        public var kind: Kind
        /// Decoded case, e.g. "CoreOC.PhotogrammetrySession.Error.processError (code 6)".
        public var technical: String
        /// Plain-language message for the crew.
        public var message: String
    }

    static let coreOCPhotogrammetry = ["reconstructionError", "snapshotURLError", "imageURLError", "initError",
                                       "requestError", "sampleError", "processError", "storageFull"]
    static let publicPhotogrammetry = ["invalidImages", "invalidOutput", "insufficientStorage"]
    static let objectCaptureSession = ["directoryNotEmpty", "insufficientStorage", "cancelled", "sensorFailed", "trackingFailed"]

    /// Case name for a known domain/code pair, or nil.
    public static func caseName(domain: String, code: Int) -> String? {
        let table: [String]
        if domain.hasSuffix("PhotogrammetrySession.Error") {
            table = domain.hasPrefix("CoreOC") ? coreOCPhotogrammetry : publicPhotogrammetry
        } else if domain.hasSuffix("ObjectCaptureSession.Error") {
            table = objectCaptureSession
        } else {
            return nil
        }
        return table.indices.contains(code) ? table[code] : nil
    }

    public static let alignmentAdvice = "Apple's 3D builder couldn't line up the photos. Try more light, a textured background, and a full slow circle (3 passes at different heights)."

    public static func explain(domain: String, code: Int, description: String = "", imageCount: Int? = nil) -> Explanation {
        let name = caseName(domain: domain, code: code)
        let technical = "\(domain)\(name.map { ".\($0)" } ?? "") (code \(code))"
        let lower = (description + " " + (name ?? "")).lowercased()
        let few = imageCount.map { $0 < ObjectCaptureGuidance.minimumShots } ?? false
        let fewText = imageCount.map { " Only \($0) photos were taken; aim for 40 or more." } ?? ""

        func make(_ kind: Kind, _ message: String) -> Explanation { Explanation(kind: kind, technical: technical, message: message) }

        switch name {
        case "processError", "reconstructionError", "sampleError":
            return few ? make(.tooFewImages, alignmentAdvice + fewText) : make(.alignment, alignmentAdvice)
        case "storageFull", "insufficientStorage":
            return make(.storage, "The phone ran out of storage while building the model. Free up a few GB and tap Retry 3D build.")
        case "imageURLError", "invalidImages", "snapshotURLError":
            return make(.badImages, "The saved photos couldn't be read for the 3D build. Capture the object again.")
        case "invalidOutput", "directoryNotEmpty":
            return make(.output, "The 3D model file couldn't be written. Tap Retry 3D build.")
        case "initError", "requestError":
            return make(.unsupported, "Apple's 3D builder didn't start on this phone. The photos are saved; tap Retry 3D build, or use LiDAR Mesh instead.")
        case "cancelled":
            return make(.cancelled, "The 3D build was cancelled. The photos are saved; tap Retry 3D build.")
        case "sensorFailed":
            return make(.sensor, "The camera or LiDAR sensor stopped during capture. Close other camera apps and try again.")
        case "trackingFailed":
            return make(.tracking, "The phone lost track of where it was. Move slower, add light, and keep the object in view.")
        default:
            if lower.contains("sfm") || lower.contains("align") || lower.contains("4004") {
                return few ? make(.tooFewImages, alignmentAdvice + fewText) : make(.alignment, alignmentAdvice)
            }
            if lower.contains("storage") || lower.contains("space") {
                return make(.storage, "The phone ran out of storage while building the model. Free up a few GB and tap Retry 3D build.")
            }
            if few {
                return make(.tooFewImages, alignmentAdvice + fewText)
            }
            return make(.unknown, "Apple's 3D builder couldn't finish this model. The photos are saved: tap Retry 3D build, or scan it with LiDAR Mesh instead.")
        }
    }
}

/// Capture-time thresholds shared by the Object Capture UI and the error explainer.
public enum ObjectCaptureGuidance {
    /// Below this many shots "Finish" asks for confirmation: reconstruction will most likely fail.
    public static let minimumShots = 20
    /// Apple recommends 20-200 images; full dials of 3 passes land around 70-120.
    public static let recommendedShots = 60
}

/// The automatic on-device reconstruction retry chain. Each attempt writes to its own output file;
/// the capture is only reported failed after every attempt failed.
public struct ReconstructionAttempt: Sendable, Hashable {
    public enum Ordering: String, Sendable { case unordered, sequential }
    public enum Sensitivity: String, Sendable { case normal, high }

    public var number: Int
    public var useCheckpoint: Bool
    public var sampleOrdering: Ordering
    public var featureSensitivity: Sensitivity
    public var objectMasking: Bool

    public init(number: Int, useCheckpoint: Bool, sampleOrdering: Ordering, featureSensitivity: Sensitivity, objectMasking: Bool) {
        self.number = number
        self.useCheckpoint = useCheckpoint
        self.sampleOrdering = sampleOrdering
        self.featureSensitivity = featureSensitivity
        self.objectMasking = objectMasking
    }

    /// 1: Apple defaults + the capture session's checkpoint (fastest, reuses capture-time poses).
    /// 2: no checkpoint, sequential ordering (photos were taken walking around), high feature sensitivity.
    /// 3: as 2, object masking off (lets plain/low-texture objects use background features to align).
    public static let chain: [ReconstructionAttempt] = [
        ReconstructionAttempt(number: 1, useCheckpoint: true, sampleOrdering: .unordered, featureSensitivity: .normal, objectMasking: true),
        ReconstructionAttempt(number: 2, useCheckpoint: false, sampleOrdering: .sequential, featureSensitivity: .high, objectMasking: true),
        ReconstructionAttempt(number: 3, useCheckpoint: false, sampleOrdering: .sequential, featureSensitivity: .high, objectMasking: false),
    ]

    /// Output file for this attempt; the winner is renamed to model.usdz.
    public var outputFileName: String { "model-attempt\(number).usdz" }

    public var summary: String {
        "checkpoint=\(useCheckpoint ? "on" : "off") sampleOrdering=.\(sampleOrdering.rawValue) featureSensitivity=.\(featureSensitivity.rawValue) isObjectMaskingEnabled=\(objectMasking)"
    }
}

/// Builds reconstruction-log.txt (shared from the capture's Files tab).
public struct ReconstructionLog: Sendable {
    public private(set) var lines: [String] = []

    public init(header: [String]) { lines = header }

    public mutating func add(_ line: String) { lines.append(line) }

    public mutating func section(_ title: String) {
        lines.append("")
        lines.append("== \(title)")
    }

    public var text: String { lines.joined(separator: "\n") + "\n" }

    public static func timestamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
