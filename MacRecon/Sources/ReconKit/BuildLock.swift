import Foundation

/// Machine-wide lock so only one PhotogrammetrySession runs at a time (CLI, watch and the server
/// all go through `build`). Two concurrent full/raw builds on a 16 GB Mac thrash memory and both
/// take twice as long.
public final class BuildLock {
    public static var defaultURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("asbuilt-recon/build.lock")
    }

    let url: URL
    private var fd: Int32 = -1

    public init(url: URL = BuildLock.defaultURL) { self.url = url }

    /// Non-blocking attempt.
    public func tryLock() -> Bool {
        if fd < 0 {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fd = open(url.path, O_RDWR | O_CREAT, 0o644)
            if fd < 0 { return true } // can't lock: don't block builds over it
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            let s = "\(getpid())\n"
            ftruncate(fd, 0)
            _ = s.withCString { write(fd, $0, strlen($0)) }
            return true
        }
        return false
    }

    /// PID written by the current holder (best effort).
    public func holder() -> String {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    }

    /// Waits until the lock is free, calling `waiting` once, or returns false if `shouldStop` says so.
    public func lock(waiting: () -> Void, shouldStop: () -> Bool) async -> Bool {
        if tryLock() { return true }
        waiting()
        while !shouldStop() {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if tryLock() { return true }
        }
        return false
    }

    public func unlock() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { unlock() }
}

/// PhotogrammetrySession leaves 2-4 GB per run in $TMPDIR/com.apple.coreoc.Photogrammetry/<UUID>
/// (it ignores the TMPDIR env var; it's the per-user Darwin temp dir). Remove the folders created
/// during our run. Safe because the BuildLock means no other build was running meanwhile.
public enum SessionTempCleaner {
    public static var root: URL {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count)
        let tmp = n > 0 ? String(cString: buf) : NSTemporaryDirectory()
        return URL(fileURLWithPath: tmp, isDirectory: true).appendingPathComponent("com.apple.coreoc.Photogrammetry", isDirectory: true)
    }

    public static func snapshot() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
    }

    /// Deletes entries that weren't in `before`. Returns bytes freed.
    @discardableResult
    public static func clean(since before: Set<String>) -> Int64 {
        var freed: Int64 = 0
        for name in snapshot().subtracting(before) {
            let u = root.appendingPathComponent(name)
            freed += Fmt.treeSize(u)
            try? FileManager.default.removeItem(at: u)
        }
        return freed
    }
}
