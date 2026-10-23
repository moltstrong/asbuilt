import Foundation
import AsBuiltCore

/// File-backed job database: `Documents/Jobs/<jobId>/job.json` plus one folder per capture
/// (`Documents/Jobs/<jobId>/<captureId>/`) holding every exported file. The Documents folder is
/// exposed in the Files app (UIFileSharingEnabled), so crews can also grab files from there.
@MainActor
final class JobStore: ObservableObject {
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var lastError: String?

    /// Progress of the demo job's export generation (runs after the first frame, never in App.init).
    enum DemoStatus: Equatable {
        case idle
        case preparing
        case ready
        case failed(String)
    }

    @Published private(set) var demoStatus: DemoStatus = .idle
    /// Non-fatal message shown when a demo generation stage was skipped (e.g. it crashed last launch).
    @Published private(set) var demoNotice: String?
    /// Bumped whenever files are (re)generated, so views that cache file lists can refresh.
    @Published private(set) var exportsRevision = 0

    let rootURL: URL
    let defaults: UserDefaults
    private var planCache: [UUID: FloorPlan] = [:]
    private var checkedForCrashedGeneration = false
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

    init(rootURL: URL? = nil, defaults: UserDefaults = .standard) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.rootURL = rootURL ?? documents.appendingPathComponent("Jobs", isDirectory: true)
        self.defaults = defaults
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

    /// UserDefaults key holding the demo generation stage that is currently running. It is set right
    /// before each stage and cleared when generation finishes, so finding it at launch means the
    /// previous attempt died (crashed or was killed) in that stage.
    static let demoInFlightKey = "demoGenerationInFlight"
    /// Stages that are skipped from now on because they did not finish before (cleared by Reset demo).
    static let demoSkippedStagesKey = "demoGenerationSkippedStages"

    enum DemoStage: String, CaseIterable {
        case cad = "CAD exports"
        case model = "3D model"
        case pdf = "PDF"
    }

    private var skippedDemoStages: Set<DemoStage> {
        get { Set((defaults.stringArray(forKey: Self.demoSkippedStagesKey) ?? []).compactMap(DemoStage.init(rawValue:))) }
        set { defaults.set(newValue.map(\.rawValue).sorted(), forKey: Self.demoSkippedStagesKey) }
    }

    /// Fast, launch-safe part of the demo: writes job.json and the two plan.json files only.
    /// No exports, no SceneKit, no drawing. Exports are generated later by `prepareDemoExports()`.
    func ensureDemoJob(reset: Bool = false) {
        let id = SampleData.demoJobID
        if reset {
            try? fm.removeItem(at: jobDirectory(id))
            jobs.removeAll { $0.id == id }
            planCache = [:]
            // An explicit reset is the user's "try again": re-enable every stage.
            defaults.removeObject(forKey: Self.demoSkippedStagesKey)
            demoNotice = nil
            demoStatus = .idle
        }
        let samples = [(SampleData.demoCaptureID, SampleData.bedroom()), (SampleData.demoKitchenCaptureID, SampleData.kitchen())]
        if job(id) != nil, samples.allSatisfy({ plan(job: id, capture: $0.0) != nil }) {
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
        for (captureID, plan) in samples {
            do {
                try setPlan(plan, job: id, capture: captureID)
            } catch {
                lastError = "Demo setup failed: \(error.localizedDescription)"
            }
        }
    }

    /// Reset demo (job menu): rewrite the demo job and regenerate all of its files.
    func resetDemo() async {
        ensureDemoJob(reset: true)
        await prepareDemoExports()
    }

    /// Demo captures whose files for `stage` are missing.
    private func demoCaptures(missing stage: DemoStage) -> [Capture] {
        guard let job = job(SampleData.demoJobID) else { return [] }
        let names: [String]
        switch stage {
        case .cad: names = [CaptureFile.dxf, CaptureFile.svg, CaptureFile.csv]
        case .model: names = [CaptureFile.modelUSDZ]
        case .pdf: names = [CaptureFile.pdf]
        }
        return job.roomCaptures.filter { capture in
            let dir = captureDirectory(job: job.id, capture: capture.id)
            if stage == .model, !Self.isCurrentRoomModel(dir.appendingPathComponent(CaptureFile.modelUSDZ)) { return true }
            return names.contains { !fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        }
    }

    /// True when `url` is a USDZ written by AsBuiltCore's packager (first entry `model.usda`, data at
    /// offset 64). Demo models left by builds <= 3 (SceneKit-written, or truncated by the iOS 27 crash)
    /// fail this check and get regenerated.
    static func isCurrentRoomModel(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64), head.count >= 40 else { return false }
        let bytes = [UInt8](head)
        let nameLength = Int(bytes[26]) | Int(bytes[27]) << 8
        let extraLength = Int(bytes[28]) | Int(bytes[29]) << 8
        guard bytes[0..<4] == [0x50, 0x4B, 0x03, 0x04], nameLength == 10, (30 + nameLength + extraLength) % 64 == 0 else {
            return false
        }
        return String(decoding: bytes[30..<40], as: UTF8.self) == "model.usda"
    }

    /// Slow part of the demo: DXF/SVG/CSV, model.usdz and PDF for each sample room. Called from a
    /// `.task` on the root view, so the first frame is never blocked.
    ///
    /// Crash-loop breaker: each stage is recorded in `demoGenerationInFlight` before it runs. If the
    /// key is still set when this runs for the first time in a process, that stage died last launch;
    /// it is skipped from now on (until Reset demo) and a non-fatal notice is shown instead.
    func prepareDemoExports() async {
        guard demoStatus != .preparing else { return }
        if !checkedForCrashedGeneration {
            checkedForCrashedGeneration = true
            if let raw = defaults.string(forKey: Self.demoInFlightKey) {
                defaults.removeObject(forKey: Self.demoInFlightKey)
                let stage = DemoStage(rawValue: raw) ?? .model
                skippedDemoStages.insert(stage)
            }
        }
        let skipped = skippedDemoStages
        if !skipped.isEmpty {
            let list = skipped.map(\.rawValue).sorted().joined(separator: ", ")
            demoNotice = "Demo \(list) skipped: it did not finish last time the app ran. Plans and takeoffs still work. Use Reset demo on the demo job to try again."
        }
        guard let job = job(SampleData.demoJobID) else { return }
        let stages = DemoStage.allCases.filter { !skipped.contains($0) && !demoCaptures(missing: $0).isEmpty }
        guard !stages.isEmpty else {
            demoStatus = .ready
            return
        }

        demoStatus = .preparing
        await Task.yield() // let the first frame (and the "Preparing demo…" state) render
        var failure: String?
        let units = Preferences.units
        let options = Preferences.takeoffOptions
        for stage in stages {
            defaults.set(stage.rawValue, forKey: Self.demoInFlightKey)
            for capture in demoCaptures(missing: stage) {
                guard let plan = plan(job: job.id, capture: capture.id) else { continue }
                let dir = captureDirectory(job: job.id, capture: capture.id)
                let context = ExportService.Context(job: job, capture: capture)
                do {
                    switch stage {
                    case .cad:
                        try await Task.detached(priority: .utility) {
                            _ = try ExportService.writeCADExports(plan: plan, to: dir, context: context, units: units, options: options)
                        }.value
                    case .model:
                        try await Task.detached(priority: .utility) {
                            _ = try ExportService.writeRoomModel(plan: plan, to: dir)
                        }.value
                    case .pdf:
                        // UIKit drawing: stays on the main actor, but after the first frame.
                        try ExportService.writePDF(plan: plan, to: dir, context: context, units: units, options: options)
                    }
                } catch {
                    failure = "Demo \(stage.rawValue) failed: \(error.localizedDescription)"
                }
                await Task.yield()
            }
        }
        defaults.removeObject(forKey: Self.demoInFlightKey)
        exportsRevision += 1
        if let failure {
            lastError = failure
            demoStatus = .failed(failure)
        } else {
            demoStatus = .ready
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
