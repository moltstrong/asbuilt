// applepose: one PhotogrammetrySession that writes the "phone" preset model, the raw model and the
// per-photo camera poses, all in the same coordinate frame, so the Apple meshes can be rendered from
// the exact COLMAP viewpoints after a similarity alignment of camera centers.
// usage: applepose <imagesDir> <outDir>
import Foundation
import RealityKit

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: applepose <imagesDir> <outDir> [phone,raw]"); exit(2) }
let input = URL(fileURLWithPath: args[1], isDirectory: true)
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
let which = args.count > 3 ? args[3].split(separator: ",").map(String.init) : ["phone", "raw"]
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var config = PhotogrammetrySession.Configuration()
config.sampleOrdering = .unordered
config.featureSensitivity = .normal
config.isObjectMaskingEnabled = true
var spec = PhotogrammetrySession.Configuration.CustomDetailSpecification()
spec.maximumPolygonCount = 250_000
spec.maximumTextureDimension = .eightK
spec.outputTextureMaps = [.diffuseColor, .normal, .ambientOcclusion]
spec.textureFormat = .jpeg(compressionQuality: 0.9)
config.customDetailSpecification = spec

let session = try PhotogrammetrySession(input: input, configuration: config)
var requests: [PhotogrammetrySession.Request] = [.poses]
if which.contains("phone") { requests.append(.modelFile(url: outDir.appendingPathComponent("phone.usdz"), detail: .custom)) }
if which.contains("raw") { requests.append(.modelFile(url: outDir.appendingPathComponent("raw.usdz"), detail: .raw)) }
try session.process(requests: requests)
let t0 = Date()
var lastPrint = Date.distantPast
func el() -> String { String(format: "%6.1fs", Date().timeIntervalSince(t0)) }

Task {
    do {
        for try await output in session.outputs {
            switch output {
            case .requestProgress(let r, let f):
                if Date().timeIntervalSince(lastPrint) > 10 { lastPrint = Date(); print(el(), "progress", r, String(format: "%.2f", f)) }
            case .requestProgressInfo(_, let info):
                _ = info
            case .requestComplete(let r, let result):
                switch result {
                case .poses(let poses):
                    var arr: [[String: Any]] = []
                    for (id, p) in poses.posesBySample.sorted(by: { $0.key < $1.key }) {
                        let m = p.transform.matrix
                        let cols = [m.columns.0, m.columns.1, m.columns.2, m.columns.3]
                        arr.append(["id": id, "url": poses.urlsBySample[id]?.lastPathComponent ?? "",
                                    "transformColumnMajor": cols.flatMap { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] },
                                    "quat": [Double(p.rotation.imag.x), Double(p.rotation.imag.y), Double(p.rotation.imag.z), Double(p.rotation.real)],
                                    "translation": [Double(p.translation.x), Double(p.translation.y), Double(p.translation.z)]])
                    }
                    let data = try JSONSerialization.data(withJSONObject: ["poses": arr], options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: outDir.appendingPathComponent("poses.json"))
                    print(el(), "poses: \(arr.count) samples written")
                case .modelFile(let u): print(el(), "model written", u.lastPathComponent)
                default: print(el(), "complete", r)
                }
            case .requestError(let r, let e): print(el(), "ERROR", r, e)
            case .processingComplete: print(el(), "processing complete"); exit(0)
            case .processingCancelled: print("cancelled"); exit(1)
            case .invalidSample(let id, let reason): print("invalid sample", id, reason)
            case .skippedSample(let id): print("skipped sample", id)
            case .automaticDownsampling: print("automatic downsampling")
            case .stitchingIncomplete: print("stitching incomplete")
            case .inputComplete: print(el(), "input complete")
            @unknown default: print("output", output)
            }
        }
    } catch { print("outputs threw", error); exit(1) }
}
RunLoop.main.run()
