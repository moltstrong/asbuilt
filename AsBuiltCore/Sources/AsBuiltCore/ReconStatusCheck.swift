import Foundation

/// One background "is my cloud model ready?" check (the app schedules these on a background URLSession while it
/// is suspended; see ReconReadyNotifier). Pure logic so it is unit tested: the task-description encoding that
/// survives an app relaunch, and what to do with each `GET /v1/jobs/{id}` answer.
public struct ReconStatusCheck: Equatable, Sendable {
    public var jobID: String
    public var title: String
    public var attempt: Int

    public init(jobID: String, title: String, attempt: Int = 0) {
        self.jobID = jobID
        self.title = title
        self.attempt = attempt
    }

    private static let prefix = "recon-status-v1"

    /// `URLSessionTask.taskDescription` form: prefix, attempt, jobID, title (tab separated; tabs in the title dropped).
    public var encoded: String {
        [Self.prefix, String(attempt), jobID, title.replacingOccurrences(of: "\t", with: " ")].joined(separator: "\t")
    }

    public init?(decoding description: String?) {
        guard let parts = description?.components(separatedBy: "\t"), parts.count >= 3, parts[0] == Self.prefix,
              let attempt = Int(parts[1]), !parts[2].isEmpty else { return nil }
        self.init(jobID: parts[2], title: parts.count > 3 ? parts[3...].joined(separator: " ") : "", attempt: attempt)
    }

    public enum Decision: Equatable, Sendable {
        case ready
        case failed(String?)
        /// Nothing more to do (job gone, wrong key): no notification, no more checks.
        case stop
        /// Check again in this many seconds.
        case again(TimeInterval)
    }

    /// What one status answer means. `status` 0 = the request itself failed (offline).
    public static func decide(status: Int, body: Data?) -> Decision {
        switch status {
        case 200:
            guard let body, let job = try? JSONDecoder().decode(ReconJob.self, from: body) else { return .again(300) }
            switch job.state {
            case "done": return .ready
            case "failed": return .failed(job.error?.message ?? job.message)
            default: return .again(nextDelay(eta: job.etaSeconds))
            }
        case 401, 403, 404: return .stop
        default: return .again(300)
        }
    }

    /// About when the build should be done: the server's ETA, kept between 1 and 10 minutes.
    public static func nextDelay(eta: Int?) -> TimeInterval {
        guard let eta, eta > 0 else { return 180 }
        return min(600, max(60, TimeInterval(eta) + 20))
    }
}
