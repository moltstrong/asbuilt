import Foundation
import AsBuiltCore

/// File-backed job database: `Documents/Jobs/<jobId>/job.json` plus one folder per capture
/// (`Documents/Jobs/<jobId>/<captureId>/`) holding every exported file. The Documents folder is
/// exposed in the Files app (UIFileSharingEnabled), so crews can also grab files from there.
@MainActor
final class JobStore: ObservableObject {
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var lastError: String?

    let rootURL: URL
    private var planCache: [UUID: FloorPlan] = [:]
    private let fm = FileManager.default

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(rootURL: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.rootURL = rootURL ?? documents.appendingPathComponent("Jobs", isDirectory: true)
        try? fm.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        load()
    }

    // MARK: Paths

    func jobDirectory(_ jobID: UUID) -> URL {
        rootURL.appendingPathComponent(jobID.uuidString, isDirectory: true)
    }

    func captureDirectory(job jobID: UUID, capture captureID: UUID) -> URL {
        jobDirectory(jobID).appendingPathComponent(captureID.uuidString, isDirectory: true)
    }

    // MARK: Loading and saving

    func load() {
        let dirs = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Job] = []
        for dir in dirs {
            let file = dir.appendingPathComponent("job.json")
            guard let data = try? Data(contentsOf: file) else { continue }
            if let job = try? Self.decoder.decode(Job.self, from: data) { loaded.append(job) }
        }
        jobs = sorted(loaded)
    }

    private func sorted(_ list: [Job]) -> [Job] {
        list.sorted { lhs, rhs in
            if lhs.isDemo != rhs.isDemo { return !lhs.isDemo }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }

    func capture(job jobID: UUID, capture captureID: UUID) -> Capture? {
        job(jobID)?.captures.first { $0.id == captureID }
    }

    func save(_ job: Job, touch: Bool = true) {
        var job = job
        if touch { job.updatedAt = Date() }
        do {
            try fm.createDirectory(at: jobDirectory(job.id), withIntermediateDirectories: true)
            let data = try Self.encoder.encode(job)
            try data.write(to: jobDirectory(job.id).appendingPathComponent("job.json"), options: .atomic)
            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[index] = job
            } else {
                jobs.append(job)
            }
            jobs = sorted(jobs)
        } catch {
            lastError = "Could not save job: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func createJob(name: String, address: String, client: String, notes: String) -> Job {
        let job = Job(name: name.isEmpty ? "Untitled job" : name, address: address, client: client, notes: notes)
        save(job)
        return job
    }

    func deleteJob(_ id: UUID) {
        try? fm.removeItem(at: jobDirectory(id))
        jobs.removeAll { $0.id == id }
    }

    func addCapture(_ capture: Capture, to jobID: UUID) {
        guard var job = job(jobID) else { return }
        job.captures.removeAll { $0.id == capture.id }
        job.captures.append(capture)
        save(job)
    }

    func updateCapture(_ capture: Capture, in jobID: UUID) {
        guard var job = job(jobID), let index = job.captures.firstIndex(where: { $0.id == capture.id }) else { return }
        job.captures[index] = capture
        save(job)
    }

    func deleteCapture(job jobID: UUID, capture captureID: UUID) {
        guard var job = job(jobID) else { return }
        try? fm.removeItem(at: captureDirectory(job: jobID, capture: captureID))
        job.captures.removeAll { $0.id == captureID }
        planCache[captureID] = nil
        save(job)
    }

    // MARK: Plans and files

    func plan(job jobID: UUID, capture captureID: UUID) -> FloorPlan? {
        if let cached = planCache[captureID] { return cached }
        let url = captureDirectory(job: jobID, capture: captureID).appendingPathComponent(CaptureFile.planJSON)
        guard let data = try? Data(contentsOf: url), let plan = try? JSONDecoder().decode(FloorPlan.self, from: data) else {
            return nil
        }
        planCache[captureID] = plan
        return plan
    }

    func setPlan(_ plan: FloorPlan, job jobID: UUID, capture captureID: UUID) throws {
        let dir = captureDirectory(job: jobID, capture: captureID)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(plan)
        try data.write(to: dir.appendingPathComponent(CaptureFile.planJSON), options: .atomic)
        planCache[captureID] = plan
    }

    /// Files and folders in a capture directory, CAD/3D files first.
    func files(job jobID: UUID, capture captureID: UUID) -> [URL] {
        let dir = captureDirectory(job: jobID, capture: captureID)
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
        let order = [CaptureFile.roomUSDZ, CaptureFile.modelUSDZ, CaptureFile.dxf, CaptureFile.pdf, CaptureFile.csv,
                     CaptureFile.svg, CaptureFile.roomJSON, CaptureFile.planJSON, CaptureFile.images, CaptureFile.checkpoint]
        return urls
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { a, b in
                let ia = order.firstIndex(of: a.lastPathComponent) ?? order.count
                let ib = order.firstIndex(of: b.lastPathComponent) ?? order.count
                return ia == ib ? a.lastPathComponent < b.lastPathComponent : ia < ib
            }
    }

    func modelURL(job jobID: UUID, capture captureID: UUID) -> URL? {
        let dir = captureDirectory(job: jobID, capture: captureID)
        for name in [CaptureFile.roomUSDZ, CaptureFile.modelUSDZ] {
            let url = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Regenerates DXF/SVG/PDF/CSV for a room capture with the current unit and estimating settings.
    func regenerateExports(job jobID: UUID, capture captureID: UUID) {
        guard let job = job(jobID), let capture = capture(job: jobID, capture: captureID),
              let plan = plan(job: jobID, capture: captureID) else { return }
        do {
            try ExportService.writePlanExports(plan: plan, to: captureDirectory(job: jobID, capture: captureID),
                                               context: .init(job: job, capture: capture),
                                               units: Preferences.units, options: Preferences.takeoffOptions)
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: Demo job

    /// Creates the bundled demo job (two rooms built from AsBuiltCore sample data, no LiDAR needed).
    func ensureDemoJob(reset: Bool = false) {
        let id = SampleData.demoJobID
        if reset {
            try? fm.removeItem(at: jobDirectory(id))
            jobs.removeAll { $0.id == id }
            planCache = [:]
        }
        if let existing = job(id), existing.captures.allSatisfy({ modelURL(job: id, capture: $0.id) != nil }) {
            return
        }
        let created = ISO8601DateFormatter().date(from: "2026-10-20T15:30:00Z") ?? Date()
        let bedroom = Capture(id: SampleData.demoCaptureID, kind: .room, origin: .sample, title: "Bedroom 2",
                              createdAt: created,
                              notes: "Sample room: 12' x 14', 8' ceiling. Entry door, two windows, closet opening.")
        let kitchen = Capture(id: SampleData.demoKitchenCaptureID, kind: .room, origin: .sample, title: "Kitchen",
                              createdAt: created.addingTimeInterval(1800),
                              notes: "Sample room: 11' x 13', 9' ceiling. Base cabinets, sink, dishwasher, range, fridge.")
        let job = Job(id: id, name: "Demo: 412 Alder St Remodel", address: "412 Alder St, Portland, OR 97205",
                      client: "Sample Homeowner", notes: "Demo job with sample rooms. Works in the Simulator and on any iPhone.",
                      createdAt: created, updatedAt: created, isDemo: true, captures: [bedroom, kitchen])
        save(job, touch: false)
        for (capture, plan) in [(bedroom, SampleData.bedroom()), (kitchen, SampleData.kitchen())] {
            do {
                try setPlan(plan, job: id, capture: capture.id)
                let dir = captureDirectory(job: id, capture: capture.id)
                try ExportService.writePlanExports(plan: plan, to: dir, context: .init(job: job, capture: capture),
                                                   units: Preferences.units, options: Preferences.takeoffOptions)
                try SceneModelBuilder.writeUSDZ(plan: plan, to: dir.appendingPathComponent(CaptureFile.modelUSDZ))
            } catch {
                lastError = "Demo export failed: \(error.localizedDescription)"
            }
        }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
