import SwiftUI
import AsBuiltCore

#if os(iOS) && !targetEnvironment(simulator)
import ARKit
import RealityKit

/// LiDAR Mesh scan: ARKit scene reconstruction (no photogrammetry), shown live as RealityKit's
/// scene-understanding wireframe. On Stop the mesh anchors are merged into one classified world-space
/// mesh off the main thread and exported as model.usdz, mesh.obj/.mtl, mesh.ply and measurements.csv.
struct LiDARMeshScanView: View {
    let jobID: UUID
    var onFinished: (UUID?) -> Void

    @EnvironmentObject private var store: JobStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Preferences.unitsKey) private var unitsRaw = UnitSystem.imperial.rawValue
    @StateObject private var model = MeshScanModel()
    @State private var captureID = UUID()
    @State private var name = ""

    private var units: UnitSystem { UnitSystem(rawValue: unitsRaw) ?? .imperial }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.isSupported {
                MeshARViewContainer(model: model)
                    .ignoresSafeArea()
            }
            VStack(spacing: 12) {
                topBar
                if let hint = model.hint, model.phase.isLive {
                    Text(hint)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                bottomArea
            }
            .padding()
        }
        .statusBarHidden()
        .onAppear { model.prepare() }
        .onDisappear { model.tearDown() }
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
            .frame(width: 120)
            .disabled(model.phase == .processing)
            Spacer()
            if model.phase.isLive || model.phase == .ready {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(model.triangleCount.formatted()) triangles").font(.headline.monospacedDigit())
                    Text("\(UnitFormatter.area(model.surfaceArea, units)) scanned").font(.subheadline.monospacedDigit())
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("meshStats")
            }
        }
    }

    @ViewBuilder
    private var bottomArea: some View {
        switch model.phase {
        case .unsupported:
            card {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted").font(.system(size: 48)).foregroundStyle(Theme.accent)
                Text("LiDAR Mesh unavailable").font(.title2.bold())
                Text(DeviceCapabilitiesSnapshot.meshMessage).multilineTextAlignment(.center)
                Button("Close") { onFinished(nil); dismiss() }.buttonStyle(BigButtonStyle())
            }
        case .ready:
            VStack(spacing: 10) {
                instruction("Point at the space or object. Tap Start, then sweep slowly over every surface from 0.5-3 m away.")
                Button {
                    model.startScanning()
                } label: {
                    Label("Start scan", systemImage: "record.circle")
                }
                .buttonStyle(BigButtonStyle())
            }
        case .scanning, .interrupted:
            VStack(spacing: 10) {
                instruction("Move slowly. Cover tops, sides and undersides. The colored mesh shows what's captured.")
                HStack(spacing: 12) {
                    Button {
                        model.reset()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(BigButtonStyle(filled: false, color: .white))
                    Button {
                        model.stopAndProcess(directory: captureDirectory, title: titleForExport, units: units)
                    } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(BigButtonStyle())
                    .disabled(model.triangleCount == 0)
                }
            }
        case .processing:
            card {
                Text("Building mesh").font(.title2.bold())
                ProgressView(value: model.progress).progressViewStyle(.linear).frame(maxWidth: 280)
                Text("\(Int(model.progress * 100))% · \(model.progressText)").monospacedDigit()
                Text("Merging \(model.anchorCount) mesh pieces into USDZ, OBJ and PLY.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        case .review(let m):
            card {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(Theme.ok)
                Text("Mesh captured").font(.title2.bold())
                Text(m.dimensionsText(units)).font(.title3.monospacedDigit().weight(.semibold))
                Text("W × D × H · \(m.triangleCount.formatted()) triangles · \(UnitFormatter.area(m.surfaceArea, units)) surface")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                TextField("Name (e.g. Mech room, Boiler, Stair 2)", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                Button("Save scan") { save(m) }
                    .buttonStyle(BigButtonStyle())
                Button("Discard and scan again") {
                    try? FileManager.default.removeItem(at: captureDirectory)
                    captureID = UUID()
                    model.reset()
                }
                .buttonStyle(BigButtonStyle(filled: false))
            }
        case .failed(let message):
            card {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(Theme.warn)
                Text(message).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if model.canRestart {
                    Button("Restart scan") { model.reset() }.buttonStyle(BigButtonStyle())
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

    private func instruction(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .shadow(radius: 4)
    }

    private var captureDirectory: URL { store.captureDirectory(job: jobID, capture: captureID) }

    private var defaultTitle: String { "LiDAR scan \((store.job(jobID)?.meshCaptures.count ?? 0) + 1)" }

    private var titleForExport: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? defaultTitle : trimmed
    }

    private func save(_ m: MeshMeasurements) {
        let capture = Capture(id: captureID, kind: .mesh, origin: .lidarMesh, title: titleForExport,
                              notes: "LiDAR Mesh scan: \(m.dimensionsText(.metric)) (W × D × H), \(m.triangleCount) triangles.",
                              measurements: m)
        store.addCapture(capture, to: jobID)
        model.tearDown()
        onFinished(captureID)
        dismiss()
    }
}

/// Hosts RealityKit's ARView with the scene-understanding mesh visualization.
struct MeshARViewContainer: UIViewRepresentable {
    let model: MeshScanModel

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.debugOptions.insert(.showSceneUnderstanding)
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

/// ARSession driver and live statistics. Delegate callbacks arrive on the main queue (the session's
/// default delegate queue); heavy work happens in a detached task after Stop.
final class MeshScanModel: NSObject, ObservableObject, ARSessionDelegate {
    enum Phase: Equatable {
        case unsupported
        case ready
        case scanning
        case interrupted
        case processing
        case review(MeshMeasurements)
        case failed(String)

        var isLive: Bool { self == .scanning || self == .interrupted }
    }

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var triangleCount = 0
    @Published private(set) var surfaceArea = 0.0
    @Published private(set) var anchorCount = 0
    @Published private(set) var hint: String?
    @Published private(set) var progress = 0.0
    @Published private(set) var progressText = ""
    @Published private(set) var canRestart = true

    let isSupported = ARWorldTrackingConfiguration.isSupported && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    private weak var arView: ARView?
    private var previewRunning = false
    private var meshAnchors: [UUID: ARMeshAnchor] = [:]
    private var areaCache: [UUID: (geometry: ObjectIdentifier, triangles: Int, area: Double)] = [:]
    private var lastStats = Date.distantPast
    private var processingTask: Task<Void, Never>?

    override init() {
        super.init()
        if !isSupported { phase = .unsupported }
    }

    func attach(_ view: ARView) {
        arView = view
        view.session.delegate = self
        prepare()
    }

    /// Camera preview + tracking warm-up (no reconstruction yet).
    func prepare() {
        guard isSupported, let view = arView, phase == .ready, !previewRunning else { return }
        previewRunning = true
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        view.session.run(configuration)
        hint = "Tap Start when the camera view is steady."
    }

    static func scanConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.environmentTexturing = .none
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        } else {
            configuration.sceneReconstruction = .mesh
        }
        return configuration
    }

    func startScanning() {
        guard isSupported, let view = arView else { return }
        clearStats()
        view.session.run(Self.scanConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        phase = .scanning
        hint = nil
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func reset() {
        processingTask?.cancel()
        processingTask = nil
        guard isSupported else { return }
        if arView == nil {
            phase = .ready
            return
        }
        startScanning()
    }

    func tearDown() {
        processingTask?.cancel()
        processingTask = nil
        arView?.session.pause()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func clearStats() {
        meshAnchors = [:]
        areaCache = [:]
        triangleCount = 0
        surfaceArea = 0
        anchorCount = 0
        progress = 0
    }

    // MARK: Processing

    func stopAndProcess(directory: URL, title: String, units: UnitSystem) {
        guard phase.isLive, let session = arView?.session else { return }
        // Latest anchors: what the delegate saw plus the current frame's (they're the same objects
        // normally; the frame wins).
        var anchors = meshAnchors
        for anchor in session.currentFrame?.anchors ?? [] {
            if let mesh = anchor as? ARMeshAnchor { anchors[mesh.identifier] = mesh }
        }
        session.pause()
        UIApplication.shared.isIdleTimerDisabled = false
        let list = Array(anchors.values)
        anchorCount = list.count
        guard !list.isEmpty else {
            phase = .failed("No mesh was captured. Point the phone at the surfaces and move slowly until the colored mesh appears.")
            return
        }
        phase = .processing
        progress = 0
        progressText = "Reading mesh"
        let report: @Sendable (Double, String) -> Void = { [weak self] value, text in
            Task { @MainActor in
                self?.progress = value
                self?.progressText = text
            }
        }
        processingTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<MeshMeasurements, Error>
            do {
                let inputs = list.enumerated().map { index, anchor -> MeshAnchorInput in
                    if index % 8 == 0 { report(0.25 * Double(index) / Double(list.count), "Reading mesh") }
                    return MeshScanModel.input(from: anchor)
                }
                try Task.checkCancellation()
                report(0.25, "Merging")
                let mesh = ClassifiedMeshBuilder.build(inputs) { report(0.25 + 0.25 * $0, "Merging") }
                try Task.checkCancellation()
                report(0.5, "Measuring")
                let prepared = MeshNormalizer.prepareForExport(mesh)
                guard prepared.mesh.triangleCount > 0 else {
                    throw NSError(domain: "AsBuilt.MeshScan", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "The scan had no usable triangles."])
                }
                try Task.checkCancellation()
                let output = LiDARMeshExporter.export(prepared, title: title, units: units) { report(0.6 + 0.35 * $0, "Writing files") }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for file in output.files {
                    try file.data.write(to: directory.appendingPathComponent(file.name), options: .atomic)
                }
                report(1, "Done")
                result = .success(output.measurements)
            } catch {
                result = .failure(error)
            }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                switch result {
                case .success(let m): self.phase = .review(m)
                case .failure(let error):
                    self.canRestart = true
                    self.phase = .failed("Could not build the mesh: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Copies an anchor's Metal buffers into plain arrays.
    static func input(from anchor: ARMeshAnchor) -> MeshAnchorInput {
        let geometry = anchor.geometry
        let t = anchor.transform
        return MeshAnchorInput(transform: (t.columns.0, t.columns.1, t.columns.2, t.columns.3),
                               vertices: read3(geometry.vertices), normals: read3(geometry.normals),
                               faces: readFaces(geometry.faces), classifications: readClasses(geometry.classification,
                                                                                               faces: geometry.faces.count))
    }

    static func read3(_ source: ARGeometrySource) -> [SIMD3<Float>] {
        guard source.format == .float3, source.componentsPerVector == 3 else { return [] }
        let base = UnsafeRawPointer(source.buffer.contents()).advanced(by: source.offset)
        let stride = source.stride
        let length = source.buffer.length - source.offset
        guard stride >= 12, source.count > 0, stride * (source.count - 1) + 12 <= length else { return [] }
        var out = [SIMD3<Float>]()
        out.reserveCapacity(source.count)
        for i in 0..<source.count {
            let p = base.advanced(by: i * stride)
            out.append(SIMD3(p.loadUnaligned(as: Float.self),
                             p.loadUnaligned(fromByteOffset: 4, as: Float.self),
                             p.loadUnaligned(fromByteOffset: 8, as: Float.self)))
        }
        return out
    }

    static func readFaces(_ element: ARGeometryElement) -> [UInt32] {
        guard element.primitiveType == .triangle, element.indexCountPerPrimitive == 3 else { return [] }
        let count = element.count * 3
        let bytes = element.bytesPerIndex
        guard count > 0, bytes == 2 || bytes == 4, count * bytes <= element.buffer.length else { return [] }
        let base = UnsafeRawPointer(element.buffer.contents())
        var out = [UInt32]()
        out.reserveCapacity(count)
        if bytes == 4 {
            for i in 0..<count { out.append(base.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)) }
        } else {
            for i in 0..<count { out.append(UInt32(base.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))) }
        }
        return out
    }

    static func readClasses(_ source: ARGeometrySource?, faces: Int) -> [UInt8] {
        guard let source, source.count > 0 else { return [] }
        let base = UnsafeRawPointer(source.buffer.contents()).advanced(by: source.offset)
        let stride = max(1, source.stride)
        let n = min(source.count, faces)
        guard stride * (n - 1) + 1 <= source.buffer.length - source.offset else { return [] }
        var out = [UInt8]()
        out.reserveCapacity(n)
        for i in 0..<n { out.append(base.load(fromByteOffset: i * stride, as: UInt8.self)) }
        return out
    }

    /// Triangle count and true surface area of one anchor (anchor-local; rigid transforms keep area).
    static func stats(of anchor: ARMeshAnchor) -> (Int, Double) {
        let geometry = anchor.geometry
        let vertices = read3(geometry.vertices)
        let faces = readFaces(geometry.faces)
        var area = 0.0
        var i = 0
        while i + 2 < faces.count {
            let a = Int(faces[i]), b = Int(faces[i + 1]), c = Int(faces[i + 2])
            if a < vertices.count, b < vertices.count, c < vertices.count {
                let g = ClassifiedMeshBuilder.cross(vertices[b] - vertices[a], vertices[c] - vertices[a])
                area += Double((g * g).sum().squareRoot()) / 2
            }
            i += 3
        }
        return (faces.count / 3, area)
    }

    private func updateStats(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastStats) > 0.5 else { return }
        lastStats = now
        var triangles = 0
        var area = 0.0
        for (id, anchor) in meshAnchors {
            let key = ObjectIdentifier(anchor.geometry)
            if let cached = areaCache[id], cached.geometry == key {
                triangles += cached.triangles
                area += cached.area
            } else {
                let (t, a) = Self.stats(of: anchor)
                areaCache[id] = (key, t, a)
                triangles += t
                area += a
            }
        }
        triangleCount = triangles
        surfaceArea = area
        anchorCount = meshAnchors.count
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard phase.isLive else { return }
        for case let mesh as ARMeshAnchor in anchors { meshAnchors[mesh.identifier] = mesh }
        updateStats()
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard phase.isLive else { return }
        for case let mesh as ARMeshAnchor in anchors { meshAnchors[mesh.identifier] = mesh }
        updateStats()
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        guard phase.isLive else { return }
        for anchor in anchors {
            meshAnchors[anchor.identifier] = nil
            areaCache[anchor.identifier] = nil
        }
        updateStats(force: true)
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal:
            hint = phase == .ready ? "Tap Start when the camera view is steady." : nil
        case .notAvailable:
            hint = "Tracking unavailable"
        case .limited(let reason):
            switch reason {
            case .initializing: hint = "Starting… move the phone slowly"
            case .excessiveMotion: hint = "Slow down"
            case .insufficientFeatures: hint = "Too little detail here: add light or aim at textured surfaces"
            case .relocalizing: hint = "Point back at an area you already scanned"
            @unknown default: hint = "Tracking limited"
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        UIApplication.shared.isIdleTimerDisabled = false
        let message: String
        if let arError = error as? ARError {
            switch arError.code {
            case .cameraUnauthorized:
                canRestart = false
                message = "Camera access is off. Enable it in Settings › AsBuilt › Camera, then try again."
            case .unsupportedConfiguration:
                canRestart = false
                message = DeviceCapabilitiesSnapshot.meshMessage
            case .sensorUnavailable, .sensorFailed:
                canRestart = true
                message = "The camera or LiDAR sensor stopped. Close other camera apps and tap Restart scan."
            case .worldTrackingFailed:
                canRestart = true
                message = "The phone lost track of where it was. Tap Restart scan and move more slowly."
            default:
                canRestart = true
                message = "The AR session stopped: \(arError.localizedDescription)"
            }
        } else {
            canRestart = true
            message = "The AR session stopped: \(error.localizedDescription)"
        }
        if phase != .processing { phase = .failed(message) }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        if phase == .scanning {
            phase = .interrupted
            hint = "Scan paused (interrupted). It resumes when the camera is back."
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        if phase == .interrupted {
            phase = .scanning
            hint = "Point back at an area you already scanned to continue"
        }
    }

    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }
}
#endif
