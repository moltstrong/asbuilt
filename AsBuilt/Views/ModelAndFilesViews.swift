import SwiftUI
import SceneKit
import QuickLook
import AsBuiltCore

// MARK: - 3D tab

struct ModelTabView: View {
    let jobID: UUID
    let capture: Capture

    @EnvironmentObject private var store: JobStore
    @EnvironmentObject private var router: Router
    @AppStorage(Preferences.unitsKey) private var unitsRaw = UnitSystem.imperial.rawValue
    @State private var showingQuickLook = false
    @State private var showingMeshScan = false
    @State private var savedMeshID: UUID?
    @State private var didAutoOpen = false

    private var units: UnitSystem { UnitSystem(rawValue: unitsRaw) ?? .imperial }

    var body: some View {
        let url = store.modelURL(job: jobID, capture: capture.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let url {
                    SceneModelView(url: url, revision: store.exportsRevision,
                                   vertexColorsPLY: capture.isDetailScan
                                       ? store.captureDirectory(job: jobID, capture: capture.id).appendingPathComponent(CaptureFile.meshPLY)
                                       : nil)
                        .frame(height: 380)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline, lineWidth: 0.5))
                        .accessibilityIdentifier("modelView")
                    Text(url.lastPathComponent == CaptureFile.fullModelUSDZ
                         ? "Full-detail model from the cloud. Drag to orbit, pinch to zoom."
                         : "Drag to orbit, pinch to zoom.")
                        .font(.footnote).foregroundStyle(.secondary)
                    RemoteBuildCard(jobID: jobID, capture: capture)
                    if capture.kind == .mesh, let m = store.meshMeasurements(job: jobID, capture: capture.id) {
                        MeshSummaryView(measurements: m, units: units)
                    }
                    Button {
                        showingQuickLook = true
                    } label: {
                        Label("Open in AR Quick Look (place & measure)", systemImage: "arkit")
                    }
                    .buttonStyle(BigButtonStyle())
                    .accessibilityIdentifier("quickLookButton")
                    Text(capture.kind == .mesh
                         ? "LiDAR mesh (USDZ, colored by surface type). The Files tab also has OBJ + MTL for Blender/SketchUp/AutoCAD, PLY and measurements.csv."
                         : CaptureFile.description(for: url.lastPathComponent))
                        .font(.footnote).foregroundStyle(.secondary)
                    if capture.origin == .sample {
                        Label(capture.kind == .mesh
                              ? "Sample LiDAR mesh generated from the demo bedroom. A real LiDAR Mesh scan records the phone's live depth mesh."
                              : "Sample room: massing model generated from plan data. A real LiDAR scan exports Apple's parametric RoomPlan USDZ.",
                              systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else if capture.origin == .sample && store.demoStatus == .preparing {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Preparing demo…").font(.headline)
                        Text(capture.kind == .mesh ? "Building the sample LiDAR mesh." : "Building the 3D model for this sample room.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .card()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "cube.transparent").font(.system(size: 48)).foregroundStyle(.secondary)
                        Text(capture.kind == .room ? "No USDZ model for this room" : "No 3D model yet").font(.headline)
                        if let message = capture.statusMessage {
                            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("statusMessage")
                        }
                        if capture.origin == .sample, let notice = store.demoNotice {
                            Text(notice).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        }
                        if capture.kind == .object {
                            RemoteBuildCard(jobID: jobID, capture: capture)
                            if capture.status == .imagesOnly || capture.status == .processing || capture.status == .failed {
                                RetryReconstructionSection(jobID: jobID, capture: capture)
                                Button {
                                    showingMeshScan = true
                                } label: {
                                    Label("Scan it with LiDAR mesh instead", systemImage: "point.3.filled.connected.trianglepath.dotted")
                                }
                                .buttonStyle(BigButtonStyle(filled: false))
                                .accessibilityIdentifier("meshInsteadButton")
                            }
                            Text("The photos and reconstruction-log.txt are in the Files tab. The cloud build below makes the full-detail model from the same photos.")
                                .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .card()
                }
            }
            .padding(16)
        }
        .fullScreenCover(isPresented: $showingQuickLook) {
            if let url { QuickLookPreview(url: url).ignoresSafeArea() }
        }
        .task(id: url?.path) {
            guard LaunchOptions.autoOpenQuickLook, !didAutoOpen, url != nil else { return }
            didAutoOpen = true
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            showingQuickLook = true
        }
        .fullScreenCover(isPresented: $showingMeshScan, onDismiss: {
            if let id = savedMeshID {
                savedMeshID = nil
                router.path.append(.capture(job: jobID, capture: id, tab: .model))
            }
        }) {
            MeshScanLauncher(jobID: jobID) { meshID in savedMeshID = meshID }
                .environmentObject(store)
        }
    }
}

/// Bounding box and surface breakdown of a LiDAR mesh scan.
struct MeshSummaryView: View {
    let measurements: MeshMeasurements
    let units: UnitSystem

    var body: some View {
        let m = measurements
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatTile(value: UnitFormatter.length(m.width, units), label: "Width", systemImage: "arrow.left.and.right")
                StatTile(value: UnitFormatter.length(m.depth, units), label: "Depth", systemImage: "arrow.up.left.and.arrow.down.right")
                StatTile(value: UnitFormatter.length(m.height, units), label: "Height", systemImage: "arrow.up.and.down")
            }
            .accessibilityIdentifier("meshDimensions")
            Text("Bounding box W × D × H: \(m.dimensionsText(units)) · \(m.triangleCount.formatted()) triangles · \(UnitFormatter.area(m.surfaceArea, units)) scanned surface")
                .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let rows = MeshClass.exportOrder.filter { m.triangles(of: $0) > 0 }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.self) { cls in
                    HStack(spacing: 6) {
                        let c = cls.color
                        RoundedRectangle(cornerRadius: 3).fill(Color(red: c.r, green: c.g, blue: c.b))
                            .frame(width: 14, height: 14)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.hairline, lineWidth: 0.5))
                        Text(cls.name).font(.caption.weight(.semibold))
                        Spacer(minLength: 2)
                        Text(UnitFormatter.area(m.area(of: cls), units)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .card()
    }
}

/// "Retry 3D build" for object captures whose on-device reconstruction failed. Re-runs the full
/// retry chain over the saved photos (device only).
struct RetryReconstructionSection: View {
    let jobID: UUID
    let capture: Capture

    @EnvironmentObject private var store: JobStore
    #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
    @StateObject private var reconstructor = ObjectReconstructor()
    #endif

    var body: some View {
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        if reconstructor.isRunning {
            ReconstructionProgressCard(reconstructor: reconstructor, photos: capture.imageCount)
        } else {
            Button {
                Task { await retry() }
            } label: {
                Label("Retry 3D build", systemImage: "arrow.clockwise")
            }
            .buttonStyle(BigButtonStyle())
            .accessibilityIdentifier("retryBuildButton")
            if let attempts = capture.reconstructionAttempts, attempts > 0 {
                Text("\(attempts) attempt\(attempts == 1 ? "" : "s") so far. Each retry runs \(reconstructor.attemptCount) settings in turn.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        #else
        Label("Retry 3D build runs on a LiDAR iPhone or iPad.", systemImage: "info.circle")
            .font(.footnote).foregroundStyle(.secondary)
        #endif
    }

    #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
    private func retry() async {
        guard var current = store.capture(job: jobID, capture: capture.id) else { return }
        current.status = .processing
        current.statusMessage = nil
        store.updateCapture(current, in: jobID)
        let outcome = await reconstructor.run(captureDirectory: store.captureDirectory(job: jobID, capture: capture.id),
                                              reason: "Retry 3D build (3D tab)")
        current = store.capture(job: jobID, capture: capture.id) ?? current
        current.reconstructionAttempts = (current.reconstructionAttempts ?? 0) + outcome.attempts
        current.status = outcome.succeeded ? .complete : .imagesOnly
        current.statusMessage = outcome.succeeded ? nil : outcome.message
        store.updateCapture(current, in: jobID)
        store.touchExports()
    }
    #endif
}

/// Interactive SceneKit preview with orbit camera.
struct SceneModelView: UIViewRepresentable {
    let url: URL
    /// Bumped when files are regenerated; the scene reloads when it changes.
    var revision: Int = 0
    /// Detail scans: binary PLY whose per-vertex colors are applied in the viewer (SceneKit ignores
    /// the USDZ's displayColor primvar reader).
    var vertexColorsPLY: URL? = nil

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(red: 0.93, green: 0.94, blue: 0.95, alpha: 1)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        load(into: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        if context.coordinator.revision != revision {
            context.coordinator.revision = revision
            load(into: view)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(revision: revision) }

    final class Coordinator {
        var revision: Int
        init(revision: Int) { self.revision = revision }
    }

    private func load(into view: SCNView) {
        guard let scene = try? SCNScene(url: url, options: [.checkConsistency: false]) else { return }
        view.scene = scene
        if let vertexColorsPLY { VertexColorPatch.applyAsync(to: scene, ply: vertexColorsPLY) }
        let (minV, maxV) = scene.rootNode.boundingBox
        let center = SCNVector3((minV.x + maxV.x) / 2, (minV.y + maxV.y) / 2, (minV.z + maxV.z) / 2)
        let size = max(maxV.x - minV.x, max(maxV.y - minV.y, maxV.z - minV.z))
        let camera = SCNCamera()
        camera.fieldOfView = 45
        camera.zFar = Double(size) * 20 + 100
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        if vertexColorsPLY != nil {
            // Detail scans are small (tens of cm) and mostly face +Z: frame them from the front.
            camera.zNear = 0.005
            let distance = Float(size) * 1.55
            cameraNode.position = SCNVector3(center.x + distance * 0.25, center.y + distance * 0.18, center.z + distance)
        } else {
            let distance = Float(size) * 1.25 + 0.5
            cameraNode.position = SCNVector3(center.x + distance * 0.55, center.y + distance * 0.95, center.z + distance * 0.75)
        }
        cameraNode.look(at: center)
        scene.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        scene.rootNode.addChildNode(ambient)
    }
}

/// QLPreviewController: USDZ gets AR Quick Look (object/AR modes, placement and measuring);
/// PDFs, CSVs and images get the standard previewer.
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { _ in
            context.coordinator.dismiss()
        })
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url, dismiss: { dismiss() }) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        let dismiss: () -> Void

        init(url: URL, dismiss: @escaping () -> Void) {
            self.url = url
            self.dismiss = dismiss
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

// MARK: - Files tab

struct FilesTabView: View {
    let jobID: UUID
    let capture: Capture

    @EnvironmentObject private var store: JobStore
    @State private var zipURL: URL?
    @State private var zipError: String?
    @State private var previewURL: URL?
    @State private var refresh = UUID()

    var body: some View {
        let files = store.files(job: jobID, capture: capture.id)
        let job = store.job(jobID)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Send to the office").font(.headline)
                    Text("Share every file in one ZIP (AirDrop, Mail, Messages, Files, Teams), or share files one at a time below.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let zipURL {
                        ShareLink(item: zipURL) {
                            Label("Share all (\(zipURL.lastPathComponent))", systemImage: "square.and.arrow.up.on.square")
                        }
                        .buttonStyle(BigButtonStyle())
                        .accessibilityIdentifier("shareAllButton")
                    } else if let zipError {
                        Text(zipError).foregroundStyle(Theme.bad)
                    } else {
                        ProgressView()
                    }
                    if !files.isEmpty {
                        ShareLink(items: files.filter { !isDirectory($0) }) {
                            Label("Share files individually", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(BigButtonStyle(filled: false))
                    }
                }
                .card()

                if capture.origin == .objectCapture, (capture.imageCount ?? 0) > 0 {
                    PhotoExportCard(jobID: jobID, capture: capture)
                }

                SectionHeader(title: "Files (\(files.count))", systemImage: "folder")
                VStack(spacing: 0) {
                    ForEach(files, id: \.self) { url in
                        FileRow(url: url, isDirectory: isDirectory(url)) { previewURL = url }
                        Divider().padding(.leading, 60)
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.card))

                Text("Files are also in the Files app: On My iPhone › AsBuilt › Jobs.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(16)
            .id(refresh)
        }
        .task(id: "\(refresh.uuidString)-\(store.exportsRevision)") { buildZip(files: files, job: job) }
        .fullScreenCover(item: $previewURL) { url in
            QuickLookPreview(url: url).ignoresSafeArea()
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func buildZip(files: [URL], job: Job?) {
        let name = "\(job?.name ?? "AsBuilt")-\(capture.title)"
        do {
            zipURL = try ExportService.makeZip(files: files, archiveName: name,
                                               folderName: ExportService.safeFileName(capture.title))
        } catch {
            zipError = "Could not build ZIP: \(error.localizedDescription)"
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

struct FileRow: View {
    let url: URL
    let isDirectory: Bool
    var onPreview: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: CaptureFile.icon(for: url.lastPathComponent))
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(url.lastPathComponent).font(.headline)
                    Spacer()
                    Text(sizeText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(CaptureFile.description(for: url.lastPathComponent))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !isDirectory {
                Menu {
                    Button("Preview", systemImage: "eye", action: onPreview)
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).frame(width: 44, height: 44)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 60)
    }

    private var sizeText: String {
        if isDirectory {
            let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
            return "\(count) items"
        }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// "Export photos": streams the Images folder (+ log) into a STORE zip
/// off the main thread, then offers the share sheet (AirDrop, Files, iCloud Drive).
struct PhotoExportCard: View {
    let jobID: UUID
    let capture: Capture

    @EnvironmentObject private var store: JobStore
    @State private var progress: Double?
    @State private var zipURL: URL?
    @State private var errorText: String?
    @State private var sharing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export the photos").font(.headline)
            Text("The cloud already builds the full-detail model. To build your own, share all \(capture.imageCount ?? 0) photos as a zip (Reality Composer Pro, PhotogrammetrySession or any photogrammetry tool).")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let progress {
                ProgressView(value: progress) { Text("Packing photos… \(Int(progress * 100))%").font(.caption) }
            } else {
                Button {
                    export()
                } label: {
                    Label("Export photos (zip)", systemImage: "photo.stack")
                }
                .buttonStyle(BigButtonStyle(filled: false))
                .accessibilityIdentifier("exportPhotosButton")
            }
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(Theme.bad)
            }
        }
        .card()
        .sheet(isPresented: $sharing) {
            if let zipURL { ActivityShareSheet(items: [zipURL]) }
        }
    }

    private func export() {
        errorText = nil
        progress = 0
        let dir = store.captureDirectory(job: jobID, capture: capture.id)
        let title = capture.title
        Task {
            let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let url = try ExportService.makePhotoZip(captureDirectory: dir, title: title) { p in
                        Task { @MainActor in if progress != nil { progress = p } }
                    }
                    return .success(url)
                } catch {
                    return .failure(error)
                }
            }.value
            progress = nil
            switch result {
            case .success(let url):
                zipURL = url
                sharing = true
            case .failure(let error):
                errorText = "Could not pack the photos: \(error.localizedDescription)"
            }
        }
    }
}

/// UIActivityViewController wrapper (AirDrop, Save to Files, iCloud Drive) for large files.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
