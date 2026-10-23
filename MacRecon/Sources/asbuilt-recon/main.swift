import Foundation
import RealityKit
import ReconKit

let usage = """
asbuilt-recon \(toolVersion): rebuild AsBuilt Object Capture photos into maximum-detail 3D models on a Mac
(Apple PhotogrammetrySession: full / raw / custom detail; USDZ + OBJ).

USAGE
  asbuilt-recon build <photos-folder|photos.zip> [options]
  asbuilt-recon info  <photos-folder|photos.zip>
  asbuilt-recon watch <inbox-folder> [build options] [--interval SECONDS] [--once]
  asbuilt-recon serve [--port 8765]          (HTTP upload/build server; see MacRecon/API.md)

BUILD OPTIONS
  --detail preview|reduced|medium|full|raw|custom   default: full
  --out DIR                 output folder (default: <input>-recon-<detail> next to the input)
  --obj                     also write OBJ + MTL + textures to DIR/obj/ and DIR/model-obj.zip
  --texture 1k|2k|4k|8k|16k custom detail: max texture size (default 8k; 16k needs macOS 15)
  --max-polys N             custom detail: max polygon count, e.g. 2000000 or 2m (default 250k)
  --maps all|diffuse,normal,roughness,displacement,ao   custom detail texture maps (default all)
  --texture-format png|jpeg[:Q]                         custom detail texture format (default png)
      (any of --texture/--max-polys/--maps/--texture-format implies --detail custom)
  --ordering unordered|sequential    sampleOrdering (default unordered)
  --sensitivity normal|high          featureSensitivity (default normal)
  --no-masking                       isObjectMaskingEnabled = false
  --checkpoint DIR                   checkpoint directory (reuse alignment between runs)
  --quads                            quad mesh (macOS 15+)
  --ignore-bbox                      ignore the capture's bounding box (macOS 15+)
  --no-retry                         don't retry with sequential + high + no masking on failure
  --no-thumbnail                     skip thumbnail.png
  --title TEXT                       capture name for the log

  If you set none of --ordering/--sensitivity/--no-masking and the first attempt fails, the build is
  retried once with --ordering sequential --sensitivity high --no-masking.

OUTPUT (in --out)
  model.usdz, obj/ + model-obj.zip (with --obj), recon-log.txt, result.json, thumbnail.png

EXIT CODES  0 ok · 1 build failed · 2 usage error · 3 photogrammetry unsupported on this Mac · 130 cancelled
"""

setvbuf(stdout, nil, _IOLBF, 0)
var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(ExitCode.usage.rawValue) }
args.removeFirst()

// Ctrl-C / SIGTERM cancel the running PhotogrammetrySession cleanly.
final class CancelBox: @unchecked Sendable { var runner: BuildRunner?; var stop = false }
let cancelBox = CancelBox()
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    s.setEventHandler {
        if cancelBox.stop { exit(ExitCode.cancelled.rawValue) }
        cancelBox.stop = true
        FileHandle.standardError.write(Data("\nCancelling (press Ctrl-C again to force quit)...\n".utf8))
        if let r = cancelBox.runner { r.cancel() } else { exit(ExitCode.cancelled.rawValue) }
    }
    s.resume()
    signalSources.append(s)
}

func parseOrExit(_ a: [String], positional: String, watch: Bool = false) -> BuildOptions {
    do { return try BuildOptions.parse(a, positional: positional, allowWatchFlags: watch) } catch {
        FileHandle.standardError.write(Data("error: \(error)\n\nRun asbuilt-recon help for usage.\n".utf8))
        exit(ExitCode.usage.rawValue)
    }
}

switch command {
case "build":
    let o = parseOrExit(args, positional: "photos-folder|photos.zip")
    let runner = BuildRunner(options: o)
    cancelBox.runner = runner
    let (code, r) = await runner.run()
    if code == .ok {
        print("")
        print("OK: \(r.polygons.map { "\($0) polygons, " } ?? "")\(r.textures.map { "\($0.width)x\($0.height)" }.joined(separator: ", ")) textures, \(String(format: "%.0f", r.totalSeconds))s")
    } else if let m = r.errorMessage {
        FileHandle.standardError.write(Data("\nFAILED: \(m)\n".utf8))
    }
    exit(code.rawValue)

case "info":
    guard args.count == 1 else { print("usage: asbuilt-recon info <photos-folder|photos.zip>"); exit(ExitCode.usage.rawValue) }
    print("asbuilt-recon \(toolVersion)")
    print("machine: \(machineSummary())")
    print("PhotogrammetrySession.isSupported: \(PhotogrammetrySession.isSupported)")
    print("limits: max \(PhotogrammetrySession.limits.maximumNumberOfInputImages) images, max dimension \(PhotogrammetrySession.limits.maximumInputImageDimension) px")
    do {
        let input = try InputResolver.resolve(args[0])
        defer { input.cleanup() }
        print("input: \(input.original.path)\(input.isZip ? " (zip, extracted in \(Fmt.duration(input.extractSeconds)))" : "")")
        if input.isZip, let root = input.tempRoot {
            let rel = input.imagesFolder.resolvingSymlinksInPath().path.replacingOccurrences(of: root.resolvingSymlinksInPath().path, with: "")
            print("images folder in zip: \(rel.ifEmpty("/"))")
        } else {
            print("images folder: \(input.imagesFolder.path)")
        }
        let s = ImageSetSummary.summarize(input.images)
        for l in s.lines { print(l) }
        if s.withDepth > 0 { print("note: depth maps present, so the model will be at real-world scale") }
        else { print("note: no depth maps; the model's scale will be arbitrary unless the photos came from Object Capture") }
        if s.count < ErrorExplainer.minimumImages { print("warning: fewer than \(ErrorExplainer.minimumImages) photos; alignment will probably fail") }
        if s.count > PhotogrammetrySession.limits.maximumNumberOfInputImages { print("warning: more photos than Apple's limit; extra photos may be ignored") }
        exit(PhotogrammetrySession.isSupported ? 0 : ExitCode.unsupported.rawValue)
    } catch {
        print("error: \(error)")
        exit(ExitCode.failed.rawValue)
    }

case "watch":
    let o = parseOrExit(args, positional: "inbox-folder", watch: true)
    let watcher = Watcher(options: o, box: cancelBox)
    await watcher.run()
    exit(0)

case "serve":
    // The HTTP server is a small Python 3 stdlib program that calls this binary for each build.
    let candidates = [
        ProcessInfo.processInfo.environment["ASBUILT_RECON_SERVER"],
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("asbuilt-recon-server.py").path,
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("../../../server/recon_server.py").standardizedFileURL.path as String?,
    ].compactMap { $0 }
    guard let script = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
        print("error: server script not found; looked in:\n  " + candidates.joined(separator: "\n  "))
        exit(ExitCode.failed.rawValue)
    }
    let self_ = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    var env = ProcessInfo.processInfo.environment
    env["ASBUILT_RECON_BIN"] = env["ASBUILT_RECON_BIN"] ?? self_
    let argv = ["/usr/bin/python3", "-u", script] + args
    let cargs = argv.map { strdup($0) } + [nil]
    let cenv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    execve("/usr/bin/python3", cargs, cenv)
    print("error: exec python3 failed: \(String(cString: strerror(errno)))")
    exit(ExitCode.failed.rawValue)

case "help", "-h", "--help":
    print(usage)
case "version", "--version":
    print(toolVersion)
default:
    print("unknown command '\(command)'\n")
    print(usage)
    exit(ExitCode.usage.rawValue)
}

extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}
