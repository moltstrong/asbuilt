import Foundation

/// Plain-language explanations for PhotogrammetrySession failures on the Mac.
///
/// Copied (not imported) from AsBuiltCore's ReconstructionErrorExplainer so this tool stays
/// self-contained. A Swift error enum bridges to NSError with `domain` = the type name and
/// `code` = the case's runtime tag (payload cases first, then no-payload cases, each in
/// declaration order). Decoded from the frameworks' Swift reflection metadata:
///
/// - `CoreOC.PhotogrammetrySession.Error` (private; what PhotogrammetrySession actually throws):
///   0 reconstructionError(payload), 1 snapshotURLError, 2 imageURLError, 3 initError,
///   4 requestError, 5 sampleError, 6 processError, 7 storageFull.
///   6 = processError: the pipeline failed, usually "No SfM map found" (cv3dapi 4004), i.e. the
///   photos could not be aligned.
/// - `RealityFoundation.PhotogrammetrySession.Error` (public): 0 invalidImages(URL),
///   1 invalidOutput(URL), 2 insufficientStorage(requiredBytes:).
public enum ErrorExplainer {
    public enum Kind: String, Sendable { case alignment, tooFewImages, badImages, storage, output, unsupported, cancelled, unknown }

    public struct Explanation: Sendable, Equatable {
        public var kind: Kind
        /// e.g. "CoreOC.PhotogrammetrySession.Error.processError (code 6)"
        public var technical: String
        public var message: String
    }

    public static let coreOC = ["reconstructionError", "snapshotURLError", "imageURLError", "initError",
                                "requestError", "sampleError", "processError", "storageFull"]
    public static let publicErrors = ["invalidImages", "invalidOutput", "insufficientStorage"]

    /// Below this many photos alignment usually fails.
    public static let minimumImages = 20

    public static func caseName(domain: String, code: Int) -> String? {
        guard domain.hasSuffix("PhotogrammetrySession.Error") else { return nil }
        let table = domain.hasPrefix("CoreOC") ? coreOC : publicErrors
        return table.indices.contains(code) ? table[code] : nil
    }

    public static let alignmentAdvice = "Apple's photogrammetry couldn't line up the photos (no structure-from-motion map). Usual causes: too few photos, too little overlap between neighbouring shots, a shiny/plain/transparent object, motion blur or poor light. Re-shoot with 3 slow passes at different heights (about 60-120 photos), or try --ordering sequential --sensitivity high --no-masking."

    public static func explain(domain: String, code: Int, description: String = "", imageCount: Int? = nil) -> Explanation {
        let name = caseName(domain: domain, code: code)
        let technical = "\(domain)\(name.map { ".\($0)" } ?? "") (code \(code))"
        let lower = (description + " " + (name ?? "")).lowercased()
        let few = imageCount.map { $0 < minimumImages } ?? false
        let fewText = imageCount.map { " Only \($0) usable photos were found; aim for 40 or more." } ?? ""
        func make(_ k: Kind, _ m: String) -> Explanation { Explanation(kind: k, technical: technical, message: m) }

        switch name {
        case "processError", "reconstructionError", "sampleError":
            return few ? make(.tooFewImages, alignmentAdvice + fewText) : make(.alignment, alignmentAdvice)
        case "storageFull", "insufficientStorage":
            return make(.storage, "The Mac ran out of disk space while building the model. Raw/custom detail needs several GB of scratch space; free some space and run again.")
        case "imageURLError", "invalidImages", "snapshotURLError":
            return make(.badImages, "The photos couldn't be read. Check the folder or zip really contains HEIC/JPEG images (not iCloud placeholders) and that they open in Preview.")
        case "invalidOutput":
            return make(.output, "The model file couldn't be written. Check --out points to a writable folder and isn't inside a read-only or syncing location.")
        case "initError", "requestError":
            return make(.unsupported, "Apple's photogrammetry engine refused to start or rejected the request. It needs an Apple-silicon Mac (or an Intel Mac with a 4 GB+ AMD GPU) on macOS 14+; --detail custom needs macOS 14+.")
        default:
            if lower.contains("cancel") { return make(.cancelled, "The build was cancelled.") }
            if lower.contains("sfm") || lower.contains("align") || lower.contains("4004") {
                return few ? make(.tooFewImages, alignmentAdvice + fewText) : make(.alignment, alignmentAdvice)
            }
            if lower.contains("storage") || lower.contains("space") {
                return make(.storage, "The Mac ran out of disk space while building the model. Free some space and run again.")
            }
            if few { return make(.tooFewImages, alignmentAdvice + fewText) }
            return make(.unknown, "Apple's photogrammetry couldn't finish this model. See the technical details in recon-log.txt; retrying with --ordering sequential --sensitivity high --no-masking sometimes helps.")
        }
    }

    /// Full technical description of any error for the log.
    public static func technicalDump(_ error: Error) -> String {
        let ns = error as NSError
        var lines = [
            "String(reflecting:): \(String(reflecting: error))",
            "NSError: domain=\(ns.domain) code=\(ns.code)",
            "localizedDescription: \(ns.localizedDescription)",
        ]
        if !ns.userInfo.isEmpty {
            for (k, v) in ns.userInfo.sorted(by: { $0.key < $1.key }) {
                lines.append("userInfo[\(k)]: \(v)")
            }
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            lines.append("underlying: domain=\(underlying.domain) code=\(underlying.code) \(underlying.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }

    public static func explain(_ error: Error, imageCount: Int?) -> Explanation {
        let ns = error as NSError
        return explain(domain: ns.domain, code: ns.code, description: String(reflecting: error) + " " + ns.localizedDescription, imageCount: imageCount)
    }
}
