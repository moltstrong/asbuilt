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

    /// Builds 6-9 remembered the LiDAR screen's Room/Detail picker here. Detail scan is its own object
    /// flow since build 10, so the value is meaningless now and is removed on launch.
    static let legacyLiDARModeKey = "lidarScanMode"

    init(rootURL: URL? = nil, defaults: UserDefaults = .standard) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.rootURL = rootURL ?? documents.appendingPathComponent("Jobs", isDirectory: true)
        self.defaults = defaults
        defaults.removeObject(forKey: Self.legacyLiDARModeKey)
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

    // MARK: Measure tool

    func addMeasurement(_ m: PrecisionMeasurement, to jobID: UUID) {
        guard var job = job(jobID) else { return }
        job.measurements.append(m)
        save(job)
    }

    func deleteMeasurement(_ id: UUID, in jobID: UUID) {
        guard var job = job(jobID) else { return }
        job.measurements.removeAll { $0.id == id }
        if !job.measurements.contains(where: { $0.tapeMeters != nil }) { job.measureScale = nil }
        save(job)
    }

    func renameMeasurement(_ id: UUID, label: String, in jobID: UUID) {
        guard var job = job(jobID), let i = job.measurements.firstIndex(where: { $0.id == id }) else { return }
        job.measurements[i].label = label
        save(job)
    }

    /// "Calibrate with tape": the true length of a saved measurement sets the job's scale factor.
    /// Returns false when the tape length is implausible (scale outside 0.8...1.25).
    @discardableResult
    func calibrate(measurement id: UUID, tapeMeters: Double, in jobID: UUID) -> Bool {
        guard var job = job(jobID), let i = job.measurements.firstIndex(where: { $0.id == id }),
              let scale = PrecisionMeasurement.calibrationScale(rawMeters: job.measurements[i].rawMeters, tapeMeters: tapeMeters)
        else { return false }
        for k in job.measurements.indices { job.measurements[k].tapeMeters = nil }
        job.measurements[i].tapeMeters = tapeMeters
        job.measureScale = scale
        save(job)
        return true
    }

    func clearCalibration(in jobID: UUID) {
        guard var job = job(jobID) else { return }
        for k in job.measurements.indices { job.measurements[k].tapeMeters = nil }
        job.measureScale = nil
        save(job)
    }

    /// Job-level ZIP: measurements.csv plus every capture folder (share-all from the job screen).
    func makeJobZip(_ jobID: UUID) throws -> URL {
        guard let job = job(jobID) else { throw CocoaError(.fileNoSuchFile) }
        let staging = fm.temporaryDirectory.appendingPathComponent("JobStaging-\(job.id.uuidString)", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var files: [URL] = []
        if !job.measurements.isEmpty {
            let csv = staging.appendingPathComponent(PrecisionMeasurementsCSV.fileName)
            let text = PrecisionMeasurementsCSV.write(job.measurements, scale: job.measureScale, units: Preferences.units,
                                                      jobName: job.name)
            try Data(text.utf8).write(to: csv, options: .atomic)
            files.append(csv)
        }
        for capture in job.captures {
            let src = captureDirectory(job: job.id, capture: capture.id)
            guard fm.fileExists(atPath: src.path) else { continue }
            // Folder per capture, named by title (photos/checkpoints stay out: use Export photos for those).
            let named = staging.appendingPathComponent(ExportService.safeFileName(capture.title) + "-" + capture.id.uuidString.prefix(4),
                                                       isDirectory: true)
            try fm.createDirectory(at: named, withIntermediateDirectories: true)
            for url in (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                if [CaptureFile.images, CaptureFile.checkpoint].contains(url.lastPathComponent) { continue }
                try? fm.linkItem(at: url, to: named.appendingPathComponent(url.lastPathComponent))
                if !fm.fileExists(atPath: named.appendingPathComponent(url.lastPathComponent).path) {
                    try? fm.copyItem(at: url, to: named.appendingPathComponent(url.lastPathComponent))
                }
            }
            files.append(named)
        }
        let url = try ExportService.makeZip(files: files, archiveName: job.name, folderName: ExportService.safeFileName(job.name))
        try? fm.removeItem(at: staging)
        return url
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
        let order = [CaptureFile.roomUSDZ, CaptureFile.fullModelUSDZ, CaptureFile.modelUSDZ, CaptureFile.meshOBJ, CaptureFile.meshMTL, CaptureFile.meshPLY,
                     CaptureFile.meshCSV, CaptureFile.dxf, CaptureFile.pdf, CaptureFile.csv, CaptureFile.svg,
                     CaptureFile.reconstructionLog, CaptureFile.fullModelLog, CaptureFile.coachReport, CaptureFile.roomJSON, CaptureFile.planJSON, CaptureFile.scanInfo,
                     CaptureFile.images, CaptureFile.checkpoint]
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
        // The Mac's full-detail build replaces the on-device preview as soon as it lands.
        for name in [CaptureFile.roomUSDZ, CaptureFile.fullModelUSDZ, CaptureFile.modelUSDZ] {
            let url = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Lets views that cache file lists (Files tab ZIP) refresh after files changed on disk.
    func touchExports() {
        exportsRevision += 1
    }

    /// Measurements of a LiDAR mesh capture: from job.json, else from scan-info.json.
    func meshMeasurements(job jobID: UUID, capture captureID: UUID) -> MeshMeasurements? {
        if let m = capture(job: jobID, capture: captureID)?.measurements { return m }
        let url = captureDirectory(job: jobID, capture: captureID).appendingPathComponent(CaptureFile.scanInfo)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MeshMeasurements.self, from: data)
    }

    /// Rewrites measurements.csv of a LiDAR mesh capture in the current units.
    func regenerateMeshCSV(job jobID: UUID, capture captureID: UUID) {
        guard let capture = capture(job: jobID, capture: captureID),
              let m = meshMeasurements(job: jobID, capture: captureID) else { return }
        let url = captureDirectory(job: jobID, capture: captureID).appendingPathComponent(CaptureFile.meshCSV)
        let text = MeshMeasurementsCSV.write(m, title: capture.title, units: Preferences.units, object: capture.isDetailScan)
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            exportsRevision += 1
        } catch {
            lastError = "Could not update measurements.csv: \(error.localizedDescription)"
        }
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
        case mesh = "LiDAR mesh"
        case detail = "Detail scan"
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
        let created = ISO8601DateFormatter().date(from: "2026-10-20T15:30:00Z") ?? Date()
        let meshCapture = Capture(id: SampleData.demoMeshCaptureID, kind: .mesh, origin: .sample, title: "Bedroom 2 LiDAR mesh",
                                  createdAt: created.addingTimeInterval(3600),
                                  notes: "Sample LiDAR Mesh scan of Bedroom 2 (generated): walls, floor, ceiling, door, windows, furniture and a water heater.")
        let detailCapture = Capture(id: SampleData.demoDetailCaptureID, kind: .mesh, origin: .sample,
                                    title: Self.demoDetailTitle, createdAt: created.addingTimeInterval(5400),
                                    notes: "Sample object Detail scan, made by AsBuilt's real pipeline on synthetic LiDAR depth: box fitted on the table, 2 mm depth fusion inside the box, table and clutter removed. 3/4\" brass ball valve with copper stubs and a lever.",
                                    coachGrade: "A", coachFix: nil)
        if var existing = job(id), samples.allSatisfy({ plan(job: id, capture: $0.0) != nil }) {
            // Demo jobs created by older builds lack the newer samples: add them (JSON only).
            var changed = false
            if !existing.captures.contains(where: { $0.id == SampleData.demoMeshCaptureID }) {
                existing.captures.append(meshCapture)
                changed = true
            }
            if let index = existing.captures.firstIndex(where: { $0.id == SampleData.demoDetailCaptureID }) {
                if existing.captures[index].title != Self.demoDetailTitle {
                    // Builds 6-9 had a wall-mounted utility corner here: swap in the object sample. Its
                    // files are regenerated after the first frame (prepareDemoExports).
                    existing.captures[index] = detailCapture
                    try? fm.removeItem(at: captureDirectory(job: id, capture: SampleData.demoDetailCaptureID))
                    changed = true
                }
            } else {
                existing.captures.append(detailCapture)
                changed = true
            }
            if existing.measurements.isEmpty {
                existing.measurements = SampleData.demoMeasurements()
                existing.measureScale = SampleData.demoMeasureScale
                changed = true
            }
            if changed { save(existing, touch: false) }
            return
        }
        let bedroom = Capture(id: SampleData.demoCaptureID, kind: .room, origin: .sample, title: "Bedroom 2",
                              createdAt: created,
                              notes: "Sample room: 12' x 14', 8' ceiling. Entry door, two windows, closet opening.")
        let kitchen = Capture(id: SampleData.demoKitchenCaptureID, kind: .room, origin: .sample, title: "Kitchen",
                              createdAt: created.addingTimeInterval(1800),
                              notes: "Sample room: 11' x 13', 9' ceiling. Base cabinets, sink, dishwasher, range, fridge.")
        let job = Job(id: id, name: "Demo: 412 Alder St Remodel", address: "412 Alder St, Portland, OR 97205",
                      client: "Sample Homeowner", notes: "Demo job with sample rooms. Works in the Simulator and on any iPhone.",
                      createdAt: created, updatedAt: created, isDemo: true, captures: [bedroom, kitchen, meshCapture, detailCapture],
                      measurements: SampleData.demoMeasurements(), measureScale: SampleData.demoMeasureScale)
        save(job, touch: false)
        for (captureID, plan) in samples {
            do {
                try setPlan(plan, job: id, capture: captureID)
            } catch {
                lastError = "Demo setup failed: \(error.localizedDescription)"
            }
        }
    }

    /// Title of the demo object Detail scan (build 10+); a different title means an older sample.
    static let demoDetailTitle = "Ball valve (Detail scan)"

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
        case .mesh, .detail:
            let target = stage == .mesh ? SampleData.demoMeshCaptureID : SampleData.demoDetailCaptureID
            return job.meshCaptures.filter { capture in
                guard capture.id == target else { return false }
                let dir = captureDirectory(job: job.id, capture: capture.id)
                if !Self.isCurrentRoomModel(dir.appendingPathComponent(CaptureFile.modelUSDZ)) { return true }
                return [CaptureFile.meshOBJ, CaptureFile.meshMTL, CaptureFile.meshCSV, CaptureFile.scanInfo]
                    .contains { !fm.fileExists(atPath: dir.appendingPathComponent($0).path) } || capture.measurements == nil
            }
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
                let dir = captureDirectory(job: job.id, capture: capture.id)
                if stage == .mesh || stage == .detail {
                    let title = capture.title
                    do {
                        let measurements = try await Task.detached(priority: .utility) {
                            stage == .mesh
                                ? try ExportService.writeDemoMeshScan(to: dir, title: title, units: units)
                                : try ExportService.writeDemoDetailScan(to: dir, title: title, units: units)
                        }.value
                        if var updated = self.capture(job: job.id, capture: capture.id),
                           var current = self.job(job.id), let index = current.captures.firstIndex(where: { $0.id == capture.id }) {
                            updated.measurements = measurements
                            current.captures[index] = updated
                            save(current, touch: false)
                        }
                    } catch {
                        failure = "Demo \(stage.rawValue) failed: \(error.localizedDescription)"
                    }
                    await Task.yield()
                    continue
                }
                guard let plan = plan(job: job.id, capture: capture.id) else { continue }
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
                    case .mesh, .detail:
                        break
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
