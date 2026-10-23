import Foundation
import ReconKit

/// Polls an inbox folder (iCloud Drive, AirDrop/Downloads, a shared folder) for new photo zips or
/// photo folders, builds each one, and files the inputs away.
///
///   <inbox>/done/<name>/      model.usdz, recon-log.txt, ...
///   <inbox>/processed/<name>  the input after a successful build
///   <inbox>/failed/<name>     the input after a failed build (its log is in done/<name>/)
final class Watcher {
    let options: BuildOptions
    let box: CancelBox
    let inbox: URL
    let fm = FileManager.default
    /// path -> (signature, consecutive stable polls)
    var seen: [String: (String, Int)] = [:]
    static let reserved: Set<String> = ["done", "processed", "failed"]

    init(options: BuildOptions, box: CancelBox) {
        self.options = options
        self.box = box
        inbox = URL(fileURLWithPath: (options.input as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    func say(_ s: String) { print("[\(Fmt.timestamp())] \(s)") }

    /// Size + mtime + file count of a file or folder tree; changes while a copy/AirDrop is in flight.
    func signature(_ url: URL) -> String? {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            let a = try? fm.attributesOfItem(atPath: url.path)
            let size = (a?[.size] as? NSNumber)?.int64Value ?? -1
            let m = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(size)|\(m)"
        }
        var n = 0
        var total: Int64 = 0
        var latest = 0.0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) {
            for case let f as URL in e {
                guard let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
                n += 1
                total += Int64(v.fileSize ?? 0)
                latest = max(latest, v.contentModificationDate?.timeIntervalSince1970 ?? 0)
            }
        }
        return "\(n)|\(total)|\(latest)"
    }

    func candidates() -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { u in
            let name = u.lastPathComponent
            if Self.reserved.contains(name) { return false }
            // In-flight downloads / iCloud placeholders
            let lower = name.lowercased()
            if lower.hasSuffix(".download") || lower.hasSuffix(".part") || lower.hasSuffix(".partial") || lower.hasSuffix(".icloud") || lower.hasSuffix(".crdownload") { return false }
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                return InputResolver.bestImageFolder(under: u) != nil
            }
            return u.pathExtension.lowercased() == "zip"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func uniqueDestination(_ dir: URL, _ name: String) -> URL {
        var dest = dir.appendingPathComponent(name)
        var i = 2
        while fm.fileExists(atPath: dest.path) {
            let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base)-\(i)" : "\(base)-\(i).\(ext)")
            i += 1
        }
        return dest
    }

    func run() async {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: inbox.path, isDirectory: &isDir), isDir.boolValue else {
            say("error: inbox folder not found: \(inbox.path)")
            exit(ExitCode.usage.rawValue)
        }
        for d in Self.reserved { try? fm.createDirectory(at: inbox.appendingPathComponent(d), withIntermediateDirectories: true) }
        // iCloud Drive: ask for placeholders to be downloaded.
        say("watching \(inbox.path) every \(Int(options.interval))s at --detail \(options.detail.rawValue)\(options.obj ? " --obj" : ""); drop a photos .zip or folder in it. Ctrl-C to stop.")
        while !box.stop {
            for c in candidates() {
                guard !box.stop else { break }
                guard let sig = signature(c) else { continue }
                let prev = seen[c.path]
                let stable = (prev?.0 == sig) ? (prev!.1 + 1) : 0
                seen[c.path] = (sig, stable)
                if stable == 0 && prev == nil { say("found \(c.lastPathComponent); waiting for it to finish copying") }
                guard stable >= 1 else { continue } // unchanged across one full interval
                if c.pathExtension.lowercased() == "zip", let e = try? Shell.run("/usr/bin/unzip", ["-tq", c.path]), e.status != 0 {
                    // Still being written or corrupt: give it more time before trying again.
                    if stable < 6 { continue }
                    say("\(c.lastPathComponent) isn't a valid zip after \(stable) checks; moving to failed/")
                    try? fm.moveItem(at: c, to: uniqueDestination(inbox.appendingPathComponent("failed"), c.lastPathComponent))
                    seen[c.path] = nil
                    continue
                }
                await build(c)
                seen[c.path] = nil
            }
            if options.once && candidates().isEmpty { break }
            try? await Task.sleep(nanoseconds: UInt64(options.interval * 1_000_000_000))
        }
        say("stopped")
    }

    func build(_ input: URL) async {
        let name = input.deletingPathExtension().lastPathComponent
        let outDir = uniqueDestination(inbox.appendingPathComponent("done"), name)
        var o = options
        o.input = input.path
        o.outDir = outDir.path
        o.title = o.title ?? name
        say("building \(input.lastPathComponent) -> \(outDir.path)")
        let runner = BuildRunner(options: o)
        box.runner = runner
        let (code, r) = await runner.run()
        box.runner = nil
        let target = code == .ok ? "processed" : "failed"
        let dest = uniqueDestination(inbox.appendingPathComponent(target), input.lastPathComponent)
        do { try fm.moveItem(at: input, to: dest) } catch { say("warning: couldn't move input to \(target)/: \(error.localizedDescription)") }
        if code == .ok {
            say("done: \(name): \(r.polygons.map(String.init) ?? "?") polygons in \(Fmt.duration(r.totalSeconds)) -> \(outDir.path)/model.usdz")
        } else {
            say("FAILED: \(name): \(r.errorMessage ?? "see recon-log.txt") (log: \(outDir.path)/recon-log.txt)")
        }
    }
}
