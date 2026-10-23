import SwiftUI
import UIKit
import AsBuiltCore

/// Measure launcher: AR point-to-point measuring on LiDAR devices, explanation elsewhere.
struct MeasureLauncher: View {
    let jobID: UUID
    var onFinished: (Int) -> Void

    var body: some View {
        #if os(iOS) && !targetEnvironment(simulator)
        MeasureARScreen(jobID: jobID, onFinished: onFinished)
        #else
        UnsupportedCaptureView(kind: .mesh, message: "Precision Measure uses the LiDAR depth sensor and needs a LiDAR iPhone or iPad Pro.")
        #endif
    }
}

// MARK: - Measurements list (all platforms)

struct MeasurementsView: View {
    let jobID: UUID

    @EnvironmentObject private var store: JobStore
    @AppStorage(Preferences.unitsKey) private var unitsRaw = UnitSystem.imperial.rawValue
    @State private var showingMeasure = false
    @State private var editing: PrecisionMeasurement?
    @State private var csvURL: URL?

    private var units: UnitSystem { UnitSystem(rawValue: unitsRaw) ?? .imperial }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let job = store.job(jobID) {
                    Button {
                        showingMeasure = true
                    } label: {
                        Label("Measure", systemImage: "ruler")
                    }
                    .buttonStyle(BigButtonStyle())
                    .accessibilityIdentifier("measureButton")

                    CalibrationCard(job: job, units: units) { store.clearCalibration(in: jobID) }

                    SectionHeader(title: "Measurements (\(job.measurements.count))", systemImage: "ruler")
                    if job.measurements.isEmpty {
                        Text("No measurements yet. Tap Measure, aim the cross at a point and hold until the ring turns green.")
                            .foregroundStyle(.secondary).card()
                    }
                    ForEach(job.measurements) { m in
                        Button {
                            editing = m
                        } label: {
                            MeasurementRow(measurement: m, scale: job.measureScale, units: units)
                        }
                        .buttonStyle(.plain)
                    }
                    if let csvURL, !job.measurements.isEmpty {
                        ShareLink(item: csvURL) {
                            Label("Share measurements.csv", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(BigButtonStyle(filled: false))
                    }
                    Text("Each point is the median of 15-30 LiDAR samples with outliers removed; ± is their spread. LiDAR's absolute accuracy is about 1 cm, so check one length with a tape and use Calibrate with tape: the correction is applied to every measurement on this job (raw values are kept).")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Measure")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.job(jobID)?.measurements.count ?? 0) { writeCSV() }
        .onChange(of: unitsRaw) { _, _ in writeCSV() }
        .onChange(of: store.job(jobID)?.measureScale) { _, _ in writeCSV() }
        .fullScreenCover(isPresented: $showingMeasure) {
            MeasureLauncher(jobID: jobID) { _ in }
                .environmentObject(store)
        }
        .sheet(item: $editing) { m in
            MeasurementEditor(jobID: jobID, measurement: m, units: units)
                .environmentObject(store)
                .presentationDetents([.medium, .large])
        }
    }

    private func writeCSV() {
        guard let job = store.job(jobID), !job.measurements.isEmpty else { csvURL = nil; return }
        let text = PrecisionMeasurementsCSV.write(job.measurements, scale: job.measureScale, units: units, jobName: job.name)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Measurements-\(job.id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(PrecisionMeasurementsCSV.fileName)
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            csvURL = url
        } catch {
            csvURL = nil
        }
    }
}

struct CalibrationCard: View {
    let job: Job
    let units: UnitSystem
    var onClear: () -> Void

    var body: some View {
        let scale = job.effectiveMeasureScale
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: job.measureScale == nil ? "ruler" : "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(job.measureScale == nil ? Color.secondary : Theme.ok)
            VStack(alignment: .leading, spacing: 4) {
                if job.measureScale != nil, let ref = job.measurements.first(where: { $0.tapeMeters != nil }) {
                    Text("Tape calibrated × \(String(format: "%.4f", scale))").font(.headline)
                    Text("From \"\(ref.label)\": measured \(UnitFormatter.precise(ref.rawMeters, units)), tape \(UnitFormatter.precise(ref.tapeMeters ?? 0, units)). Applied to all measure-tool values.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Remove calibration", role: .destructive, action: onClear).font(.footnote.weight(.semibold))
                } else {
                    Text("Not tape calibrated").font(.headline)
                    Text("Tap a measurement and enter the tape length to correct all of them.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .card()
        .accessibilityIdentifier("calibrationCard")
    }
}

struct MeasurementRow: View {
    let measurement: PrecisionMeasurement
    let scale: Double?
    let units: UnitSystem

    var body: some View {
        let m = measurement
        let value = m.calibratedMeters(scale: scale)
        HStack(spacing: 12) {
            Image(systemName: m.tapeMeters != nil ? "ruler.fill" : "arrow.left.and.right")
                .font(.title2)
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(m.label).font(.headline).lineLimit(1)
                    if m.tapeMeters != nil { Badge(text: "TAPE", color: Theme.ok) }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(UnitFormatter.precise(value, units)).font(.title3.weight(.bold).monospacedDigit())
                    Text(UnitFormatter.plusMinus(m.calibratedUncertainty(scale: scale), units))
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .card()
    }

    private var detail: String {
        let m = measurement
        var parts = ["\(m.samples) samples", m.method == "raycast" ? "raycast" : "LiDAR depth"]
        if PrecisionMeasurement.validScale(scale) != 1 { parts.append("raw \(UnitFormatter.precise(m.rawMeters, units))") }
        return parts.joined(separator: " · ")
    }
}

/// Rename / calibrate with tape / delete.
struct MeasurementEditor: View {
    let jobID: UUID
    let measurement: PrecisionMeasurement
    let units: UnitSystem

    @EnvironmentObject private var store: JobStore
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var tape = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Label", text: $label)
                }
                Section {
                    LabeledContent("Measured (raw)", value: UnitFormatter.precise(measurement.rawMeters, units))
                    TextField(units == .imperial ? "Tape length, e.g. 36 1/16" : "Tape length in mm, e.g. 915", text: $tape)
                        .keyboardType(.numbersAndPunctuation)
                        .accessibilityIdentifier("tapeField")
                    if let error { Text(error).foregroundStyle(Theme.bad).font(.footnote) }
                    Button("Calibrate with tape") { calibrate() }
                        .disabled(tape.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Calibrate with tape")
                } footer: {
                    Text("Sets a job-wide scale factor (true ÷ measured) that is applied to every measure-tool value. Corrections over 20% are rejected as typos.")
                }
                Section {
                    Button("Delete measurement", role: .destructive) {
                        store.deleteMeasurement(measurement.id, in: jobID)
                        dismiss()
                    }
                }
            }
            .navigationTitle(measurement.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let trimmed = label.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty, trimmed != measurement.label {
                            store.renameMeasurement(measurement.id, label: trimmed, in: jobID)
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                label = measurement.label
                if let t = measurement.tapeMeters { tape = UnitFormatter.precise(t, units) }
            }
        }
    }

    private func calibrate() {
        guard let meters = UnitFormatter.parseLength(tape, units) else {
            error = units == .imperial ? "Enter inches like 36 1/16 or feet-inches like 3' 0 1/16\"." : "Enter millimeters like 915."
            return
        }
        if store.calibrate(measurement: measurement.id, tapeMeters: meters, in: jobID) {
            dismiss()
        } else {
            error = "That's more than 20% off the measured \(UnitFormatter.precise(measurement.rawMeters, units)). Check the tape reading."
        }
    }
}

#if os(iOS) && !targetEnvironment(simulator)
import ARKit
import RealityKit

/// AR point-to-point measure: aim the cross (or tap a spot), hold until the ring turns green.
struct MeasureARScreen: View {
    let jobID: UUID
    var onFinished: (Int) -> Void

    @EnvironmentObject private var store: JobStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Preferences.unitsKey) private var unitsRaw = UnitSystem.imperial.rawValue
    @StateObject private var model = MeasureModel()
    @StateObject private var coach = CoachDriver(mode: .measure)
    @State private var showingIntro = false

    private var units: UnitSystem { UnitSystem(rawValue: unitsRaw) ?? .imperial }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MeasureARViewContainer(model: model)
                .ignoresSafeArea()
                .onTapGesture { location in model.beginPoint(at: location) }
            SegmentsOverlay(model: model, scale: store.job(jobID)?.measureScale, units: units)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            // Hold-steady ring at the point being sampled (screen center when idle).
            GeometryReader { geo in
                HoldSteadyRing(fill: model.ringFill, locked: model.ringLocked)
                    .position(model.ringPosition ?? CGPoint(x: geo.size.width / 2, y: geo.size.height / 2))
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    Button("Cancel") {
                        model.tearDown()
                        onFinished(0)
                        dismiss()
                    }
                    .buttonStyle(BigButtonStyle(filled: false, color: .white))
                    .frame(width: 110)
                    Spacer()
                    if let live = model.liveDistance {
                        Text(UnitFormatter.precise(live * PrecisionMeasurement.validScale(store.job(jobID)?.measureScale), units))
                            .font(.title2.weight(.heavy).monospacedDigit())
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    CoachHelpButton { showingIntro = true }
                }
                if let cue = cueGuidance {
                    CoachCue(guidance: cue, coverage: .none)
                }
                Spacer()
                VStack(spacing: 10) {
                    if !model.segments.isEmpty {
                        Text("\(model.segments.count) measured · last \(lastText)")
                            .font(.headline.monospacedDigit()).foregroundStyle(.white).shadow(radius: 3)
                    }
                    HStack(spacing: 12) {
                        Button {
                            model.undo()
                        } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(BigButtonStyle(filled: false, color: .white))
                        .disabled(model.segments.isEmpty && model.pendingStart == nil)
                        Button {
                            model.beginPoint(at: nil)
                        } label: {
                            Label(model.pendingStart == nil ? "Add point" : "End point", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(BigButtonStyle())
                        .accessibilityIdentifier("addPointButton")
                    }
                    Button {
                        save()
                    } label: {
                        Label("Save \(model.segments.count) to job", systemImage: "checkmark")
                    }
                    .buttonStyle(BigButtonStyle(filled: false, color: .white))
                    .disabled(model.segments.isEmpty)
                }
                .frame(maxWidth: 460)
            }
            .padding()
        }
        .statusBarHidden()
        .coachIntro(.measure, isPresented: $showingIntro)
        .onAppear {
            model.onCoachFrame = { [weak coach] frame in coach?.update(frame) }
            coach.begin()
            model.start()
        }
        .onDisappear { model.tearDown() }
    }

    private var cueGuidance: Guidance? {
        if model.isSampling, let g = coach.output?.guidance, g.isProblem { return .holdSteady }
        if let g = coach.output?.guidance, g == .trackingLost || g == .gettingReady { return g }
        return nil
    }

    private var lastText: String {
        guard let last = model.segments.last else { return "" }
        let scale = store.job(jobID)?.measureScale
        return "\(UnitFormatter.precise(last.calibratedMeters(scale: scale), units)) \(UnitFormatter.plusMinus(last.calibratedUncertainty(scale: scale), units))"
    }

    private func save() {
        let existing = store.job(jobID)?.measurements.count ?? 0
        for (k, var m) in model.segments.enumerated() {
            m.label = "Measurement \(existing + k + 1)"
            store.addMeasurement(m, to: jobID)
        }
        let count = model.segments.count
        model.tearDown()
        onFinished(count)
        dismiss()
    }
}

/// Session + point sampling. Delegate callbacks arrive on the main queue; only plain values are kept.
final class MeasureModel: NSObject, ObservableObject, ARSessionDelegate {
    struct Point {
        var world: SIMD3<Float>
        var spread: Float
        var samples: Int
        var method: String
    }

    @Published private(set) var segments: [PrecisionMeasurement] = []
    @Published private(set) var pendingStart: Point?
    @Published private(set) var ringFill = 0.0
    @Published private(set) var ringLocked = false
    @Published private(set) var ringPosition: CGPoint?
    @Published private(set) var liveDistance: Double?
    @Published private(set) var projected: [(CGPoint, CGPoint, PrecisionMeasurement)] = []
    @Published private(set) var projectedPending: CGPoint?
    @Published private(set) var isSampling = false

    var onCoachFrame: (@MainActor (CoachFrame) -> CoachOutput?)?

    private weak var arView: ARView?
    private var sampler = PointSampler(target: 24, minimum: 15)
    private var sampleLocation: CGPoint?
    private var raycastSamples = 0
    private var lockedFlashUntil: TimeInterval = 0
    private var lastProjection: TimeInterval = 0

    func attach(_ view: ARView) {
        arView = view
        view.session.delegate = self
    }

    func start() {
        guard let view = arView, ARWorldTrackingConfiguration.isSupported else { return }
        let c = ARWorldTrackingConfiguration()
        c.worldAlignment = .gravity
        c.isLightEstimationEnabled = true
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            c.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            c.frameSemantics.insert(.sceneDepth)
        }
        c.planeDetection = [.horizontal, .vertical]
        view.session.run(c)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func tearDown() {
        arView?.session.pause()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Starts sampling at `location` (view points), or the screen center when nil.
    func beginPoint(at location: CGPoint?) {
        guard let view = arView else { return }
        let size = view.bounds.size
        sampleLocation = location ?? CGPoint(x: size.width / 2, y: size.height / 2)
        sampler.reset()
        raycastSamples = 0
        ringFill = 0
        ringLocked = false
        ringPosition = sampleLocation
        isSampling = true
    }

    func undo() {
        if pendingStart != nil {
            pendingStart = nil
            liveDistance = nil
        } else if !segments.isEmpty {
            segments.removeLast()
        }
        isSampling = false
        ringFill = 0
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let coachFrame = ARFrameCopy.coachFrame(frame, includeFeatures: false)
        let steady = (ARFrameCopy.onMain { onCoachFrame?(coachFrame)?.shouldIntegrate } ?? nil) ?? true
        if isSampling, let location = sampleLocation, steady {
            if let p = depthSample(frame, at: location) {
                sampler.add(p)
            } else if let p = raycastSample(at: location) {
                sampler.add(p)
                raycastSamples += 1
            }
            ringFill = Double(sampler.fill)
            finishIfSteady(frame)
        }
        if frame.timestamp - lastProjection >= 1.0 / 20 {
            lastProjection = frame.timestamp
            project(frame)
        }
        if ringLocked, frame.timestamp > lockedFlashUntil, !isSampling {
            ringLocked = false
            ringFill = 0
            ringPosition = nil
        }
    }

    private func finishIfSteady(_ frame: ARFrame) {
        guard let estimate = sampler.estimate else { return }
        let range = simd_distance(estimate.point, RigidTransform.translation(frame.camera.transform))
        if sampler.isSteady(maxSpread: PointSampler.lockSpread(range: range)) {
            let point = Point(world: estimate.point, spread: estimate.spread, samples: estimate.inliers,
                              method: raycastSamples * 2 > sampler.samples.count ? "raycast" : "lidarDepth")
            lock(point, time: frame.timestamp)
        } else if sampler.samples.count >= sampler.target * 2 {
            // Too noisy: keep the ring yellow and start a fresh window.
            sampler.reset()
            raycastSamples = 0
        }
    }

    private func lock(_ point: Point, time: TimeInterval) {
        isSampling = false
        ringLocked = true
        ringFill = 1
        lockedFlashUntil = time + 0.6
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if let start = pendingStart {
            let m = PrecisionMeasurement(label: "Measurement", start: start.world, end: point.world,
                                         uncertaintyMeters: PrecisionMeasurement.combinedUncertainty(start.spread, point.spread),
                                         samples: start.samples + point.samples,
                                         method: start.method == "raycast" || point.method == "raycast" ? "raycast" : "lidarDepth")
            segments.append(m)
            pendingStart = nil
            liveDistance = nil
        } else {
            pendingStart = point
        }
    }

    /// LiDAR depth at a view location, high confidence only, unprojected to world space.
    private func depthSample(_ frame: ARFrame, at location: CGPoint) -> SIMD3<Float>? {
        guard let view = arView, let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        // View-normalized -> image-normalized (inverse of the display transform).
        let toView = frame.displayTransform(for: orientation, viewportSize: size)
        let normalized = CGPoint(x: location.x / size.width, y: location.y / size.height).applying(toView.inverted())
        guard normalized.x >= 0, normalized.x <= 1, normalized.y >= 0, normalized.y <= 1 else { return nil }
        let map = depthData.depthMap
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        let u = Float(normalized.x) * Float(w), v = Float(normalized.y) * Float(h)
        let i = min(w - 1, max(0, Int(u))), j = min(h - 1, max(0, Int(v)))
        guard let d = Self.read(map, i, j, Float32.self), d.isFinite, d > 0.05, d < 5 else { return nil }
        if let conf = depthData.confidenceMap, let c = Self.read(conf, i, j, UInt8.self),
           c < UInt8(ARConfidenceLevel.high.rawValue) {
            return nil
        }
        let K = PinholeIntrinsics(arkit: frame.camera.intrinsics, imageWidth: Int(frame.camera.imageResolution.width),
                                  imageHeight: Int(frame.camera.imageResolution.height)).scaled(toWidth: w, height: h)
        let pc = K.unproject(u: u, v: v, depth: d)
        let world = frame.camera.transform * SIMD4(pc, 1)
        return SIMD3(world.x, world.y, world.z)
    }

    private static func read<T>(_ buffer: CVPixelBuffer, _ i: Int, _ j: Int, _ type: T.Type) -> T? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard i >= 0, j >= 0, i < w, j < h, CVPixelBufferGetBytesPerRow(buffer) >= w * MemoryLayout<T>.size else { return nil }
        return base.advanced(by: j * CVPixelBufferGetBytesPerRow(buffer) + i * MemoryLayout<T>.size)
            .assumingMemoryBound(to: T.self).pointee
    }

    private func raycastSample(at location: CGPoint) -> SIMD3<Float>? {
        guard let view = arView else { return nil }
        let results = view.raycast(from: location, allowing: .estimatedPlane, alignment: .any)
        guard let t = results.first?.worldTransform else { return nil }
        return RigidTransform.translation(t)
    }

    /// Screen positions of the segments and the live distance from the pending start to the center.
    private func project(_ frame: ARFrame) {
        guard let view = arView else { return }
        let size = view.bounds.size
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        let camera = frame.camera
        let eye = RigidTransform.translation(camera.transform)
        let forward = RigidTransform.forward(camera.transform)
        func screen(_ p: SIMD3<Float>) -> CGPoint? {
            guard simd_dot(p - eye, forward) > 0.02 else { return nil }
            return camera.projectPoint(p, orientation: orientation, viewportSize: size)
        }
        var lines: [(CGPoint, CGPoint, PrecisionMeasurement)] = []
        for m in segments where m.start.count == 3 && m.end.count == 3 {
            let a = SIMD3(m.start[0], m.start[1], m.start[2]), b = SIMD3(m.end[0], m.end[1], m.end[2])
            if let pa = screen(a), let pb = screen(b) { lines.append((pa, pb, m)) }
        }
        projected = lines
        if let start = pendingStart {
            projectedPending = screen(start.world)
            if let hit = depthSample(frame, at: CGPoint(x: size.width / 2, y: size.height / 2)) {
                liveDistance = Double(simd_distance(start.world, hit))
            }
        } else {
            projectedPending = nil
        }
    }
}

struct MeasureARViewContainer: UIViewRepresentable {
    let model: MeasureModel

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.renderOptions.insert(.disableMotionBlur)
        view.renderOptions.insert(.disableDepthOfField)
        view.renderOptions.insert(.disablePersonOcclusion)
        model.attach(view)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {}

    static func dismantleUIView(_ view: ARView, coordinator: ()) {
        view.session.pause()
        view.session.delegate = nil
    }
}

struct SegmentsOverlay: View {
    @ObservedObject var model: MeasureModel
    let scale: Double?
    let units: UnitSystem

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                for (a, b, m) in model.projected {
                    var path = Path()
                    path.move(to: a)
                    path.addLine(to: b)
                    context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    context.stroke(path, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    for p in [a, b] {
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(.white))
                    }
                    let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 18)
                    let label = Text(UnitFormatter.precise(m.calibratedMeters(scale: scale), units))
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundColor(.black)
                    let resolved = context.resolve(label)
                    let ts = resolved.measure(in: size)
                    context.fill(Path(roundedRect: CGRect(x: mid.x - ts.width / 2 - 8, y: mid.y - ts.height / 2 - 4,
                                                          width: ts.width + 16, height: ts.height + 8), cornerRadius: 8),
                                 with: .color(.white))
                    context.draw(resolved, at: mid)
                }
                if let p = model.projectedPending {
                    let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                    var path = Path()
                    path.move(to: p)
                    path.addLine(to: center)
                    context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(Theme.accent))
                }
            }
        }
    }
}
#endif
