import SwiftUI
import AsBuiltCore

#if os(iOS) && !targetEnvironment(simulator)
import ARKit
import RealityKit

/// Object Detail scan: box the object, then fuse LiDAR depth inside the box.
///
/// 1. **Place** (`.ready`): every ~0.4 s the current depth map (plain copy) is handed to
///    `ObjectBoxFitter` on the fusion queue together with ARKit's horizontal plane heights; the fitted
///    box is drawn as a 3D wireframe and blended toward each new fit so it settles instead of jumping.
///    +/- per axis and pinch resize it (auto-fit stops until "Fit again").
/// 2. **Scan**: Start locks the box. The voxel follows the box (`TSDFVolume.Configuration.object`),
///    fusion is limited to the box plus a margin, and the coach measures coverage around the box center
///    and distance to the box. Frames are copied into plain buffers and fused on one serial queue;
///    frames arriving while it is busy are dropped. ARFrames are never retained.
/// 3. **Finish**: extract, crop to the box, drop the table, keep the object, export with W x D x H
///    measured from the table.
final class DetailScanModel: NSObject, ObservableObject, ARSessionDelegate {
    enum Phase: Equatable {
        case unsupported
        case ready
        case scanning
        case paused
        case interrupted
        case processing
        case review(MeshMeasurements)
        case failed(String)

        var isLive: Bool { self == .scanning || self == .interrupted || self == .paused }
    }

    struct TintPoint: Hashable {
        var point: CGPoint
        var confidence: Float
    }

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var stats = TSDFVolume.Stats(framesIntegrated: 0, blockCount: 0, voxelCount: 0, memoryBytes: 0,
                                                          memoryFraction: 0, isFull: false)
    @Published private(set) var tint: [TintPoint] = []
    @Published private(set) var progress = 0.0
    @Published private(set) var progressText = ""
    @Published private(set) var canRestart = true
    @Published private(set) var droppedFrames = 0
    @Published private(set) var videoFormatText = ""
    /// The object box (placement: live fit or user-sized; scanning: locked).
    @Published private(set) var box: ObjectBox?
    @Published private(set) var placementStatus: ObjectPlacementPanel.Status = .searching
    /// Voxel size of the running scan (m).
    @Published private(set) var voxelSize: Float = 0.002

    let isSupported = ARWorldTrackingConfiguration.isSupported
        && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)

    /// Set by the view; receives every frame's coach metrics (delegate callbacks are on the main queue).
    var onCoachFrame: (@MainActor (CoachFrame) -> CoachOutput?)?
    /// Set by the view: the box was locked (Start) and coverage should be measured around its center.
    var onBoxLocked: ((ObjectBox) -> Void)?

    private weak var arView: ARView?
    private var previewRunning = false
    private let fusionQueue = DispatchQueue(label: "com.moltstrong.asbuilt.tsdf", qos: .userInitiated)
    /// Only touched on `fusionQueue`.
    private var volume = TSDFVolume(configuration: .detail)
    /// Main-thread flag: one frame copy in flight at most.
    private var fusionBusy = false
    private var lastIntegratedPose: simd_float4x4?
    private var framesSinceIntegration = 0
    private var lastTintUpdate: TimeInterval = 0
    private var tintSamples: [(position: SIMD3<Float>, confidence: Float)] = []
    private var processingWork: DispatchWorkItem?
    private var usedFallbackFormat = false
    private var generation = 0

    // Placement.
    private var planeY: Float?
    private var autoFit = true
    private var replaceNextFit = true
    private var fitInFlight = false
    private var lastFitTime: TimeInterval = -1
    /// Box, margin and bounds of the running scan.
    private var lockedBox: ObjectBox?
    private var margin: Float = 0.015
    private var fusionBounds: (min: SIMD3<Float>, max: SIMD3<Float>)?
    private let wireframe = BoxWireframeEntity()

    override init() {
        super.init()
        if !isSupported { phase = .unsupported }
    }

    func attach(_ view: ARView) {
        arView = view
        view.session.delegate = self
        view.scene.addAnchor(wireframe.anchor)
        prepare()
    }

    /// Camera preview, plane detection and tracking warm-up (the box fit and the coach's pre-flight
    /// need depth, planes and light estimates before Start).
    func prepare() {
        guard isSupported, let view = arView, phase == .ready, !previewRunning else { return }
        previewRunning = true
        view.session.run(makeConfiguration())
    }

    func makeConfiguration() -> ARWorldTrackingConfiguration {
        let c = ARWorldTrackingConfiguration()
        c.worldAlignment = .gravity
        c.environmentTexturing = .none
        c.isLightEstimationEnabled = true
        // Table / floor heights for the box fit (the fitter checks them against the depth points).
        c.planeDetection = [.horizontal]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            c.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            c.frameSemantics.insert(.sceneDepth)
        }
        // Camera stream: keep a 4:3 format (1920 x 1440 by default) so the 256 x 192 depth map and the
        // ~960 x 720 color copy share one field of view and the scaled intrinsics stay exact. 16:9
        // formats (4K) crop differently from the depth map, so they are never used here.
        if !usedFallbackFormat,
           let f = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing,
           abs(f.imageResolution.width / max(1, f.imageResolution.height) - 4.0 / 3.0) < 0.01 {
            c.videoFormat = f
        }
        let size = c.videoFormat.imageResolution
        videoFormatText = "\(Int(size.width))x\(Int(size.height)) @ \(c.videoFormat.framesPerSecond) fps"
        return c
    }

    // MARK: Placement

    /// +/- on one side (0 width, 1 height, 2 depth); auto-fit stops until "Fit again".
    func adjust(axis: Int, by delta: Float) {
        guard phase == .ready, let box else { return }
        setManualBox(box.resized(axis: axis, by: delta))
    }

    /// Pinch: `base` is the box when the pinch began.
    func scale(_ base: ObjectBox, by factor: Float) {
        guard phase == .ready else { return }
        setManualBox(base.scaled(by: factor))
    }

    private func setManualBox(_ b: ObjectBox) {
        autoFit = false
        box = b
        placementStatus = .adjusted
        wireframe.update(box: b, color: .systemYellow)
    }

    func fitAgain() {
        guard phase == .ready else { return }
        autoFit = true
        replaceNextFit = true
        lastFitTime = -1
        placementStatus = box == nil ? .searching : placementStatus
    }

    private func maybeFit(_ frame: ARFrame) {
        guard autoFit, !fitInFlight, frame.timestamp - lastFitTime >= 0.4, let depth = ARFrameCopy.depth(frame) else { return }
        lastFitTime = frame.timestamp
        fitInFlight = true
        let intrinsics = PinholeIntrinsics(arkit: frame.camera.intrinsics,
                                           imageWidth: Int(frame.camera.imageResolution.width),
                                           imageHeight: Int(frame.camera.imageResolution.height))
            .scaled(toWidth: depth.width, height: depth.height)
        let pose = frame.camera.transform
        let planes = Self.horizontalPlaneHeights(frame)
        let g = generation
        fusionQueue.async { [weak self] in
            let depthFrame = DepthFrame(width: depth.width, height: depth.height, depth: depth.depth,
                                        confidence: depth.confidence, intrinsics: intrinsics, cameraToWorld: pose)
            let result = ObjectBoxFitter.fit(frame: depthFrame, planeCandidates: planes)
            DispatchQueue.main.async {
                guard let self else { return }
                self.fitInFlight = false
                guard g == self.generation, self.phase == .ready, self.autoFit, let result else { return }
                self.acceptFit(result)
            }
        }
    }

    /// A new fit replaces the box when it is somewhere else (aimed at another object) or after "Fit
    /// again"; otherwise the box moves a third of the way toward it, so it settles instead of jumping.
    private func acceptFit(_ result: ObjectBoxFitter.Result) {
        var next = result.box
        if let old = box, !replaceNextFit {
            let aligned = next.reoriented(near: old)
            let moved = simd_distance(aligned.center, old.center)
            let resized = simd_reduce_max(abs(aligned.size - old.size))
            if moved < 0.08, resized < 0.10 { next = old.blended(toward: aligned, weight: 0.35) }
        }
        replaceNextFit = false
        box = next
        planeY = result.planeY
        placementStatus = .fitted(onPlane: result.planeY != nil)
        wireframe.update(box: next, color: .systemYellow)
    }

    /// World heights of ARKit's horizontal planes (plain floats: no anchor is kept).
    static func horizontalPlaneHeights(_ frame: ARFrame) -> [Float] {
        frame.anchors.compactMap { anchor -> Float? in
            guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal else { return nil }
            return (plane.transform * SIMD4(plane.center, 1)).y
        }
    }

    // MARK: Scan

    func startScanning() {
        guard isSupported, let box else { return }
        if !previewRunning, let view = arView {
            previewRunning = true
            view.session.run(makeConfiguration())
        }
        let configuration = TSDFVolume.Configuration.object(for: box)
        let margin = ObjectScan.margin(voxelSize: configuration.voxelSize)
        lockedBox = box
        self.margin = margin
        fusionBounds = box.aabb(margin: margin)
        voxelSize = configuration.voxelSize
        fusionQueue.async { [weak self] in self?.volume = TSDFVolume(configuration: configuration) }
        stats = TSDFVolume.Stats()
        wireframe.update(box: box, color: UIColor(red: 0.2, green: 0.8, blue: 0.35, alpha: 1))
        onBoxLocked?(box)
        phase = .scanning
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// Pause/resume keeps the fused volume (used by "Fill gaps").
    func pause() { if phase == .scanning { phase = .paused } }
    func resume() { if phase == .paused { phase = .scanning } }

    /// Back to placement. The fused volume is dropped; the box stays (same world coordinates) unless
    /// the AR session has to restart (after a failure or a finished scan), which resets tracking.
    func reset(restartSession: Bool = false) {
        processingWork?.cancel()
        processingWork = nil
        generation += 1
        let g = generation
        fusionQueue.async { [weak self] in
            guard let self else { return }
            self.volume.reset()
            DispatchQueue.main.async {
                guard g == self.generation else { return }
                self.stats = self.volume.stats
            }
        }
        tint = []
        tintSamples = []
        lastIntegratedPose = nil
        framesSinceIntegration = 0
        droppedFrames = 0
        progress = 0
        lockedBox = nil
        fusionBounds = nil
        fitInFlight = false
        if isSupported { phase = .ready }
        if restartSession || !previewRunning, let view = arView {
            previewRunning = true
            view.session.run(makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
            // Tracking restarts with a new world origin: the old box would float somewhere else.
            box = nil
            planeY = nil
            autoFit = true
            replaceNextFit = true
            placementStatus = .searching
            wireframe.hide()
        } else if let box {
            wireframe.update(box: box, color: .systemYellow)
        }
    }

    func tearDown() {
        processingWork?.cancel()
        processingWork = nil
        generation += 1
        ARTorch.set(false)
        arView?.session.pause()
        previewRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: Per-frame

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Everything read from `frame` is copied before this method returns.
        let raw = ARFrameCopy.coachFrame(frame)
        let coachFrame = (lockedBox ?? box).map { ObjectScan.coachFrame(raw, box: $0) } ?? raw
        let output = ARFrameCopy.onMain { onCoachFrame?(coachFrame) } ?? nil
        if phase == .ready { maybeFit(frame) }
        guard phase == .scanning, let output, let bounds = fusionBounds else {
            updateTint(frame)
            return
        }
        framesSinceIntegration += 1
        if output.shouldIntegrate, !stats.isFull, shouldIntegrate(pose: frame.camera.transform) {
            if fusionBusy {
                droppedFrames += 1
            } else if let depth = ARFrameCopy.depth(frame) {
                let color = ARFrameCopy.color(frame, targetWidth: 960)
                let intrinsics = PinholeIntrinsics(arkit: frame.camera.intrinsics,
                                                   imageWidth: Int(frame.camera.imageResolution.width),
                                                   imageHeight: Int(frame.camera.imageResolution.height))
                    .scaled(toWidth: depth.width, height: depth.height)
                let pose = frame.camera.transform
                lastIntegratedPose = pose
                framesSinceIntegration = 0
                fusionBusy = true
                let g = generation
                fusionQueue.async { [weak self] in
                    guard let self else { return }
                    let rgb = color?.rgb()
                    let depthFrame = DepthFrame(width: depth.width, height: depth.height, depth: depth.depth,
                                                confidence: depth.confidence, intrinsics: intrinsics,
                                                cameraToWorld: pose, color: rgb)
                    self.volume.integrate(depthFrame, bounds: bounds)
                    let stats = self.volume.stats
                    // Tint samples every ~12 fused frames (cheap: one pass over block headers).
                    let samples = stats.framesIntegrated % 12 == 1 ? self.volume.surfaceSamples(maxCount: 1500) : nil
                    DispatchQueue.main.async {
                        self.fusionBusy = false
                        guard g == self.generation else { return }
                        self.stats = stats
                        if let samples { self.tintSamples = samples }
                    }
                }
            }
        }
        updateTint(frame)
    }

    /// Integrate when the camera moved >= 1 cm or turned >= 2 degrees, or every 8th frame.
    private func shouldIntegrate(pose: simd_float4x4) -> Bool {
        guard let last = lastIntegratedPose else { return true }
        let moved = simd_distance(RigidTransform.translation(last), RigidTransform.translation(pose))
        let turned = RigidTransform.rotationAngle(from: last, to: pose) * 180 / .pi
        return moved >= 0.01 || turned >= 2 || framesSinceIntegration >= 8
    }

    /// Projects the fused-surface samples into the view at ~8 Hz (red = thin, green = solid).
    private func updateTint(_ frame: ARFrame) {
        guard phase.isLive, !tintSamples.isEmpty, let view = arView else {
            if !tint.isEmpty && !phase.isLive { tint = [] }
            return
        }
        let now = frame.timestamp
        guard now - lastTintUpdate >= 0.125 else { return }
        lastTintUpdate = now
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        let camera = frame.camera
        let forward = -SIMD3<Float>(camera.transform.columns.2.x, camera.transform.columns.2.y, camera.transform.columns.2.z)
        let eye = RigidTransform.translation(camera.transform)
        var points: [TintPoint] = []
        points.reserveCapacity(tintSamples.count)
        for s in tintSamples {
            let d = s.position - eye
            guard simd_dot(d, forward) > 0.05 else { continue }
            let p = camera.projectPoint(s.position, orientation: orientation, viewportSize: size)
            guard p.x >= 0, p.y >= 0, p.x <= size.width, p.y <= size.height else { continue }
            points.append(TintPoint(point: p, confidence: s.confidence))
        }
        tint = points
    }

    // MARK: Stop -> object mesh -> files

    func stopAndProcess(directory: URL, title: String, units: UnitSystem, coachReport: String?,
                        completion: @escaping (MeshMeasurements?) -> Void) {
        guard phase.isLive, let box = lockedBox else { return }
        phase = .processing
        progress = 0
        progressText = "Finishing fusion"
        ARTorch.set(false)
        arView?.session.pause()
        previewRunning = false
        wireframe.hide()
        UIApplication.shared.isIdleTimerDisabled = false
        let g = generation
        let margin = margin
        let planeY = planeY
        let report: (Double, String) -> Void = { [weak self] value, text in
            DispatchQueue.main.async {
                guard let self, g == self.generation else { return }
                self.progress = value
                self.progressText = text
            }
        }
        var work: DispatchWorkItem!
        work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Runs after any in-flight integration (same serial queue).
            let voxel = self.volume.configuration.voxelSize
            let fused = self.volume.extractMesh(minWeight: 3) { report(0.5 * $0, "Extracting surface") }
            if work.isCancelled { return }
            report(0.5, "Separating the object")
            let cleaned = ObjectMeshCleaner.clean(fused, box: box, margin: margin, planeY: planeY, voxelSize: voxel)
            var result: Result<MeshMeasurements, Error>
            do {
                report(0.6, "Writing files")
                let m = try ExportService.writeObjectScan(cleaned.mesh, planeY: planeY, to: directory, title: title, units: units,
                                                          coachReport: coachReport) { report(0.6 + 0.4 * $0, "Writing files") }
                result = .success(m)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard g == self.generation, !work.isCancelled else { return }
                switch result {
                case .success(let m):
                    self.phase = .review(m)
                    completion(m)
                case .failure(let error):
                    self.canRestart = true
                    self.phase = .failed("Could not build the object model: \(error.localizedDescription)")
                    completion(nil)
                }
            }
        }
        processingWork = work
        fusionQueue.async(execute: work)
    }

    /// Back to placement after Discard (the session was paused for processing: restart it).
    func discardResult() {
        reset(restartSession: true)
    }

    // MARK: Session events

    func session(_ session: ARSession, didFailWithError error: Error) {
        UIApplication.shared.isIdleTimerDisabled = false
        // The 4K format with depth can be refused on some devices: retry once with the default format.
        if let arError = error as? ARError, arError.code == .unsupportedConfiguration, !usedFallbackFormat {
            usedFallbackFormat = true
            previewRunning = true
            session.run(makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
            return
        }
        let message: String
        if let arError = error as? ARError {
            switch arError.code {
            case .cameraUnauthorized:
                canRestart = false
                message = "Camera access is off. Enable it in Settings › AsBuilt › Camera, then try again."
            case .unsupportedConfiguration:
                canRestart = false
                message = "Detail scan needs a LiDAR iPhone or iPad Pro."
            case .sensorUnavailable, .sensorFailed:
                canRestart = true
                message = "The camera or LiDAR sensor stopped. Close other camera apps and tap Restart scan."
            default:
                canRestart = true
                message = "The AR session stopped: \(arError.localizedDescription)"
            }
        } else {
            canRestart = true
            message = "The AR session stopped: \(error.localizedDescription)"
        }
        ARTorch.set(false)
        if phase != .processing { phase = .failed(message) }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        if phase == .scanning { phase = .interrupted }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        if phase == .interrupted { phase = .scanning }
    }

    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }
}

/// The object box drawn in the AR scene: 12 thin unlit bars (always crisp, no SwiftUI redraws per frame).
final class BoxWireframeEntity {
    let anchor = AnchorEntity(world: .zero)
    private var bars: [ModelEntity] = []

    init() {
        let mesh = MeshResource.generateBox(size: 1)
        for _ in 0..<12 {
            let bar = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .systemYellow)])
            bars.append(bar)
            anchor.addChild(bar)
        }
        anchor.isEnabled = false
    }

    func update(box: ObjectBox, color: UIColor, thickness: Float = 0.003) {
        let corners = box.corners
        for (k, edge) in ObjectBox.edges.enumerated() {
            let a = corners[edge.0], b = corners[edge.1]
            let length = max(1e-4, simd_distance(a, b))
            let rotation = simd_quatf(from: SIMD3(1, 0, 0), to: (b - a) / length)
            bars[k].transform = Transform(scale: SIMD3(length + thickness, thickness, thickness), rotation: rotation,
                                          translation: (a + b) / 2)
            bars[k].model?.materials = [UnlitMaterial(color: color)]
        }
        anchor.isEnabled = true
    }

    func hide() { anchor.isEnabled = false }
}

/// Object Detail scan screen: box placement, then the coach HUD over the camera with the
/// fused-confidence tint and live fusion stats.
struct DetailScanView: View {
    let jobID: UUID
    var onFinished: (UUID?) -> Void

    @EnvironmentObject private var store: JobStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Preferences.unitsKey) private var unitsRaw = UnitSystem.imperial.rawValue
    @StateObject private var model = DetailScanModel()
    @StateObject private var coach = CoachDriver(mode: .detail)
    @State private var captureID = UUID()
    @State private var name = ""
    @State private var showingIntro = false
    @State private var report: CoachReport?
    @State private var showGrade = false
    @State private var pinchBase: ObjectBox?

    private var units: UnitSystem { UnitSystem(rawValue: unitsRaw) ?? .imperial }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.isSupported {
                DetailARViewContainer(model: model)
                    .ignoresSafeArea()
                TintOverlay(points: model.tint)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            if model.phase == .ready {
                // Pinch anywhere on the camera view to resize the box.
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .gesture(MagnificationGesture()
                        .onChanged { value in
                            if pinchBase == nil { pinchBase = model.box }
                            if let base = pinchBase { model.scale(base, by: Float(value)) }
                        }
                        .onEnded { _ in pinchBase = nil })
            }
            if model.phase.isLive || model.phase == .ready {
                CoachOverlay(output: coach.output, thresholds: coach.thresholds, showsSpeed: model.phase.isLive,
                             showsRings: model.phase.isLive, highlightGaps: coach.isFillingGaps,
                             isScanning: model.phase == .scanning)
            }
            VStack(spacing: 12) {
                topBar
                Spacer()
                bottomArea
            }
            .padding()
            if showGrade, let report {
                Color.black.opacity(0.35).ignoresSafeArea()
                GradeCard(report: report, onFillGaps: report.coverageFraction < 0.999 ? { fillGaps() } : nil) {
                    showGrade = false
                    finishScan()
                }
                .padding()
            }
        }
        .statusBarHidden()
        .coachIntro(.detail, isPresented: $showingIntro)
        .onAppear {
            coach.onTorch = { on in ARTorch.set(on) }
            model.onCoachFrame = { [weak coach] frame in coach?.update(frame) }
            model.onBoxLocked = { [weak coach] box in coach?.setOrbitCenter(box.center) }
            model.prepare()
        }
        .onDisappear {
            coach.setTorch(false)
            model.tearDown()
        }
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            Button("Cancel") {
                model.tearDown()
                if case .review = model.phase { try? FileManager.default.removeItem(at: captureDirectory) }
                onFinished(nil)
                dismiss()
            }
            .buttonStyle(BigButtonStyle(filled: false, color: .white))
            .frame(width: 110)
            .disabled(model.phase == .processing)
            Spacer()
            if model.phase.isLive {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(model.stats.framesIntegrated) frames fused").font(.headline.monospacedDigit())
                    Text("\(Int((model.voxelSize * 1000).rounded())) mm · \(memoryText)").font(.caption.monospacedDigit())
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("detailStats")
            }
            CoachHelpButton { showingIntro = true }
        }
    }

    private var memoryText: String {
        let mb = Double(model.stats.memoryBytes) / 1_048_576
        return String(format: "%.0f MB (%.0f%%)", mb, model.stats.memoryFraction * 100)
    }

    @ViewBuilder
    private var bottomArea: some View {
        switch model.phase {
        case .unsupported:
            card {
                Image(systemName: "cube.transparent").font(.system(size: 48)).foregroundStyle(Theme.accent)
                Text("Detail scan unavailable").font(.title2.bold())
                Text(DeviceCapabilitiesSnapshot.detailMessage).multilineTextAlignment(.center)
                Button("Close") { onFinished(nil); dismiss() }.buttonStyle(BigButtonStyle())
            }
        case .ready:
            ObjectPlacementPanel(box: model.box, status: model.placementStatus, units: units,
                                 isReady: coach.output?.isReady ?? false,
                                 onAdjust: { axis, delta in model.adjust(axis: axis, by: delta) },
                                 onFitAgain: { model.fitAgain() },
                                 onStart: { start() })
        case .scanning, .interrupted, .paused:
            VStack(spacing: 10) {
                if coach.output?.suggestFinish == true {
                    FinishPrompt(onFinish: { stop() }, onKeepGoing: { coach.dismissFinish() })
                }
                if model.stats.isFull {
                    Text("Memory full: Stop to save")
                        .font(.headline).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(CoachColors.bad, in: Capsule())
                }
                HStack(spacing: 12) {
                    Button {
                        coach.reset()
                        model.reset()
                        report = nil
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(BigButtonStyle(filled: false, color: .white))
                    Button {
                        stop()
                    } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(BigButtonStyle())
                    .disabled(model.stats.framesIntegrated == 0)
                }
            }
        case .processing:
            card {
                Text("Building the object model").font(.title2.bold())
                ProgressView(value: model.progress).progressViewStyle(.linear).frame(maxWidth: 280)
                Text("\(Int(model.progress * 100))% · \(model.progressText)").monospacedDigit()
            }
        case .review(let m):
            card {
                HStack(spacing: 10) {
                    if let report {
                        Text(report.grade.rawValue)
                            .font(.system(size: 30, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background([CoachReport.Grade.a, .b].contains(report.grade) ? CoachColors.good : CoachColors.warn, in: Circle())
                    }
                    VStack(alignment: .leading) {
                        Text("Object scanned").font(.title3.bold())
                        Text(m.objectDimensionsText(units)).font(.subheadline.monospacedDigit().weight(.semibold))
                    }
                }
                Text("\(m.triangleCount.formatted()) triangles · \(Int((model.voxelSize * 1000).rounded())) mm voxels · colored")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("Name (e.g. Ball valve, Pump, Bracket)", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                Button("Save scan") { save(m) }
                    .buttonStyle(BigButtonStyle())
                Button("Discard and scan again") {
                    try? FileManager.default.removeItem(at: captureDirectory)
                    captureID = UUID()
                    coach.reset()
                    report = nil
                    model.discardResult()
                }
                .buttonStyle(BigButtonStyle(filled: false))
            }
        case .failed(let message):
            card {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(Theme.warn)
                Text(message).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if model.canRestart {
                    Button("Restart scan") { coach.reset(); model.reset(restartSession: true) }.buttonStyle(BigButtonStyle())
                }
                Button("Close") { model.tearDown(); onFinished(nil); dismiss() }
                    .buttonStyle(BigButtonStyle(filled: !model.canRestart))
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12, content: content)
            .padding(20)
            .frame(maxWidth: 440)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func start() {
        coach.begin()
        model.startScanning()
    }

    /// Stop: pause progress and show the grade (Fill gaps / Done).
    private func stop() {
        model.pause()
        report = coach.finish()
        showGrade = true
    }

    private func fillGaps() {
        showGrade = false
        coach.resumeForGaps()
        model.resume()
    }

    private func finishScan() {
        let text = report.map { CoachReportText.text($0, mode: .detail) }
        model.stopAndProcess(directory: captureDirectory, title: titleForExport, units: units, coachReport: text) { _ in }
    }

    private var captureDirectory: URL { store.captureDirectory(job: jobID, capture: captureID) }

    private var defaultTitle: String {
        "Detail scan \((store.job(jobID)?.meshCaptures.filter(\.isDetailScan).count ?? 0) + 1)"
    }

    private var titleForExport: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? defaultTitle : trimmed
    }

    private func save(_ m: MeshMeasurements) {
        let voxel = Int((model.voxelSize * 1000).rounded())
        let capture = Capture(id: captureID, kind: .mesh, origin: .detailScan, title: titleForExport,
                              notes: "Object Detail scan (LiDAR depth fusion inside a fitted box, \(voxel) mm voxels, table removed): \(m.objectDimensionsText(.metric)) (W × D × H), \(m.triangleCount) triangles.",
                              measurements: m, coachGrade: report?.grade.rawValue, coachFix: report?.fix)
        store.addCapture(capture, to: jobID)
        model.tearDown()
        onFinished(captureID)
        dismiss()
    }
}

struct DetailARViewContainer: UIViewRepresentable {
    let model: DetailScanModel

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.renderOptions.insert(.disableMotionBlur)
        view.renderOptions.insert(.disableDepthOfField)
        view.renderOptions.insert(.disablePersonOcclusion)
        view.renderOptions.insert(.disableGroundingShadows)
        view.renderOptions.insert(.disableAREnvironmentLighting)
        model.attach(view)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {}

    static func dismantleUIView(_ view: ARView, coordinator: ()) {
        view.session.pause()
        view.session.delegate = nil
    }
}

/// Fused-surface samples drawn as dots: red/orange = few observations, green = solid.
struct TintOverlay: View {
    let points: [DetailScanModel.TintPoint]

    var body: some View {
        Canvas { context, _ in
            for p in points {
                let r: CGFloat = 5
                let rect = CGRect(x: p.point.x - r, y: p.point.y - r, width: 2 * r, height: 2 * r)
                context.fill(Path(ellipseIn: rect), with: .color(CoachColors.confidence(p.confidence).opacity(0.75)))
            }
        }
    }
}
#endif

/// coach-report.txt next to the scan files.
enum CoachReportText {
    static func text(_ r: CoachReport, mode: CoachMode) -> String {
        func pct(_ v: Float) -> String { "\(Int((v * 100).rounded()))%" }
        return """
        AsBuilt Capture Coach report (\(mode.rawValue))
        Grade: \(r.grade.rawValue)\(r.fix.map { " - \($0)" } ?? "")
        Coverage: \(pct(r.coverageFraction)) of 36 view cells (12 directions x 3 heights)
        Good technique: \(pct(r.goodFraction)) of scan time
        Too fast: \(pct(r.tooFastFraction)) · Too dark: \(pct(r.tooDarkFraction)) · Out of range: \(pct(r.distanceFraction)) · Shiny/plain: \(pct(r.lowTextureFraction))
        Scan time: \(Int(r.seconds.rounded())) s
        """
    }
}
