import Foundation
import AsBuiltCore
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// "Your 3D model is ready" while the phone is in a pocket. The cloud can't iMessage the owner the way the
/// Mac server did, so the app tells him itself, with a local notification:
///  * when the model lands while AsBuilt is in the background (`RemoteBuildService.download`), and
///  * while AsBuilt is suspended: status checks on a background URLSession, scheduled with
///    `earliestBeginDate`. iOS runs each check on its own and wakes the app with the job JSON;
///    done/failed posts the notification, anything else schedules the next check (about the build's ETA,
///    1-10 min). Tapping the notification opens AsBuilt, which downloads the model as usual.
/// Simulator and tests: no background session (checks are skipped; notifications still work).
@MainActor
final class ReconReadyNotifier {
    static let shared = ReconReadyNotifier()
    static let sessionID = "com.moltstrong.asbuilt.recon.status"
    /// Set by the app delegate when iOS wakes AsBuilt to deliver status-check results.
    var backgroundEventsCompletion: (() -> Void)?

    private let delegate = StatusCheckDelegate()
    private var session: URLSession?
    private static let notifiedKey = "reconNotifiedJobs"

    /// Creates the background session (call at launch and when iOS hands over its events).
    func activate() {
        #if os(iOS) && !targetEnvironment(simulator)
        guard session == nil else { return }
        let c = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        c.allowsCellularAccess = true
        c.timeoutIntervalForRequest = 60
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        delegate.owner = self
        session = URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
        #endif
    }

    /// Asks once for permission to post "model ready" notifications (when the first cloud build starts).
    func requestPermission() {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    /// Schedules one status check of `jobID` in about `seconds`, replacing any pending check of that job.
    func scheduleCheck(jobID: String, title: String, request: URLRequest, after seconds: TimeInterval, attempt: Int = 0) {
        activate()
        guard let session, !Self.alreadyNotified(jobID), attempt < 200 else { return }
        let description = ReconStatusCheck(jobID: jobID, title: title, attempt: attempt).encoded
        session.getAllTasks { tasks in
            for t in tasks where ReconStatusCheck(decoding: t.taskDescription)?.jobID == jobID { t.cancel() }
            let task = session.downloadTask(with: request)
            task.earliestBeginDate = Date().addingTimeInterval(max(30, seconds))
            task.countOfBytesClientExpectsToSend = 512
            task.countOfBytesClientExpectsToReceive = 16 * 1024
            task.taskDescription = description
            task.resume()
        }
    }

    func cancelChecks(jobID: String) {
        session?.getAllTasks { tasks in
            for t in tasks where ReconStatusCheck(decoding: t.taskDescription)?.jobID == jobID { t.cancel() }
        }
    }

    /// Posts the notification once per job (never while AsBuilt is on screen: the card already shows it).
    func notify(jobID: String, title: String, ready: Bool, message: String? = nil) {
        guard !Self.alreadyNotified(jobID) else { return }
        #if canImport(UIKit)
        if UIApplication.shared.applicationState == .active { Self.markNotified(jobID); return }
        #endif
        Self.markNotified(jobID)
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = ready ? "3D model ready" : "Cloud build didn't finish"
        let name = title.isEmpty ? "your scan" : title
        content.body = ready ? "The full-detail model of \(name) is ready. Tap to open it in AsBuilt."
                             : (message ?? "The photos of \(name) are safe on your iPhone. Open AsBuilt to try again.")
        content.sound = .default
        content.threadIdentifier = "recon"
        let request = UNNotificationRequest(identifier: "recon-\(jobID)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
        #endif
    }

    /// Result of one background status check.
    fileprivate func handle(check: ReconStatusCheck, data: Data?, status: Int, request: URLRequest?) {
        let decision = ReconStatusCheck.decide(status: status, body: data)
        switch decision {
        case .ready:
            notify(jobID: check.jobID, title: check.title, ready: true)
        case .failed(let message):
            notify(jobID: check.jobID, title: check.title, ready: false, message: message)
        case .stop:
            break
        case .again(let seconds):
            if let request { scheduleCheck(jobID: check.jobID, title: check.title, request: request, after: seconds, attempt: check.attempt + 1) }
        }
    }

    fileprivate func finishedBackgroundEvents() {
        backgroundEventsCompletion?()
        backgroundEventsCompletion = nil
    }

    private static func alreadyNotified(_ jobID: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: notifiedKey) ?? []).contains(jobID)
    }

    private static func markNotified(_ jobID: String) {
        var ids = UserDefaults.standard.stringArray(forKey: notifiedKey) ?? []
        guard !ids.contains(jobID) else { return }
        ids.append(jobID)
        UserDefaults.standard.set(Array(ids.suffix(50)), forKey: notifiedKey)
    }
}

/// Delegate for the status-check session. Reads the (tiny) job JSON before the temp file disappears and hands it
/// to the notifier on the main actor.
private final class StatusCheckDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var owner: ReconReadyNotifier?
    private let lock = NSLock()
    private var bodies: [Int: Data] = [:]

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let data = try? Data(contentsOf: location)
        lock.lock(); bodies[downloadTask.taskIdentifier] = data; lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let data = bodies.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let check = ReconStatusCheck(decoding: task.taskDescription) else { return }
        if let error = error as? URLError, error.code == .cancelled { return }  // replaced by a newer check
        let status = error == nil ? ((task.response as? HTTPURLResponse)?.statusCode ?? 0) : 0
        let request = task.originalRequest
        let owner = self.owner
        Task { @MainActor in owner?.handle(check: check, data: data, status: status, request: request) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let owner = self.owner
        Task { @MainActor in owner?.finishedBackgroundEvents() }
    }
}
