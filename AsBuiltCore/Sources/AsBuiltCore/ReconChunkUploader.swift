import Foundation

/// Chunk uploads through a delegate-based URLSession, so the same code runs on a **background**
/// session on the iPhone (transfers continue in the system daemon while AsBuilt is suspended, the
/// user is in Messages, or the screen is locked) and on a default session in tests.
///
/// Background sessions don't allow completion-handler APIs (`upload(for:fromFile:)` would raise),
/// so every request is an `uploadTask(with:fromFile:)` keyed by `taskDescription`
/// (`"<uploadID>#<chunk>"`), and `send` awaits the delegate's completion for that key. Tasks that
/// were started before the app was killed are adopted instead of being sent twice.
public final class ReconChunkUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public struct Response: Sendable, Equatable {
        public let status: Int
        public let body: Data
    }

    /// Bytes sent so far for one in-flight chunk (`key`, bytes). Called on a background queue.
    public var onProgress: (@Sendable (_ key: String, _ sent: Int64) -> Void)?
    /// Background session finished delivering events (call the system's completion handler).
    public var onBackgroundEventsFinished: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var session: URLSession!
    private var waiters: [String: CheckedContinuation<Response, Error>] = [:]
    private var bodies: [Int: Data] = [:]
    private var finishedOK: [String: Response] = [:]

    public init(configuration: URLSessionConfiguration) {
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "ReconChunkUploader"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    public static func key(uploadID: String, index: Int) -> String { "\(uploadID)#\(index)" }

    public static func parse(key: String) -> (uploadID: String, index: Int)? {
        guard let hash = key.lastIndex(of: "#"), let index = Int(key[key.index(after: hash)...]), index >= 0 else { return nil }
        let id = String(key[..<hash])
        return id.isEmpty ? nil : (id, index)
    }

    /// Keys of chunk tasks still running (including ones started by an earlier launch).
    public func runningKeys() async -> Set<String> {
        let tasks = await session.allTasks
        return Set(tasks.filter { $0.state == .running || $0.state == .suspended }.compactMap(\.taskDescription))
    }

    /// PUTs `file` with `request` and returns the HTTP status and body. Network failures throw the
    /// URLError. Cancelling the calling task cancels the transfer.
    public func send(_ request: URLRequest, file: URL, key: String) async throws -> Response {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Response, Error>) in
                lock.lock()
                if let done = finishedOK.removeValue(forKey: key) {
                    lock.unlock()
                    cont.resume(returning: done)
                    return
                }
                let previous = waiters.updateValue(cont, forKey: key)
                lock.unlock()
                previous?.resume(throwing: CancellationError())
                session.getAllTasks { [weak self] tasks in
                    guard let self else { return }
                    // Adopt a transfer of this chunk that survived an app relaunch.
                    if tasks.contains(where: { $0.taskDescription == key && ($0.state == .running || $0.state == .suspended) }) { return }
                    let task = self.session.uploadTask(with: request, fromFile: file)
                    task.taskDescription = key
                    task.resume()
                }
            }
        } onCancel: {
            session.getAllTasks { tasks in
                for t in tasks where t.taskDescription == key { t.cancel() }
            }
        }
    }

    public func cancelAll(uploadID: String) {
        session.getAllTasks { tasks in
            for t in tasks where t.taskDescription.flatMap(Self.parse(key:))?.uploadID == uploadID { t.cancel() }
        }
    }

    // MARK: URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        bodies[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                           totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if let key = task.taskDescription { onProgress?(key, totalBytesSent) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = task.taskDescription ?? ""
        lock.lock()
        let body = bodies.removeValue(forKey: task.taskIdentifier) ?? Data()
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let waiter = waiters.removeValue(forKey: key)
        if waiter == nil, error == nil, !key.isEmpty {
            // Finished while nobody was waiting (app was suspended/relaunched): keep for the next send().
            if finishedOK.count > 256 { finishedOK.removeAll() }
            finishedOK[key] = Response(status: status, body: body)
        }
        lock.unlock()
        if let key = task.taskDescription { onProgress?(key, -1) }
        if let error {
            waiter?.resume(throwing: error)
        } else {
            waiter?.resume(returning: Response(status: status, body: body))
        }
    }

    #if os(iOS)
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        onBackgroundEventsFinished?()
    }
    #endif
}
