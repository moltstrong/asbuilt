import SwiftUI
import SceneKit
import QuickLook
import AsBuiltCore

// MARK: - 3D tab

struct ModelTabView: View {
    let jobID: UUID
    let capture: Capture

    @EnvironmentObject private var store: JobStore
    @State private var showingQuickLook = false

    var body: some View {
        let url = store.modelURL(job: jobID, capture: capture.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let url {
                    SceneModelView(url: url)
                        .frame(height: 380)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline, lineWidth: 0.5))
                        .accessibilityIdentifier("modelView")
                    Text("Drag to orbit, pinch to zoom.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button {
                        showingQuickLook = true
                    } label: {
                        Label("Open in AR Quick Look (place & measure)", systemImage: "arkit")
                    }
                    .buttonStyle(BigButtonStyle())
                    Text(CaptureFile.description(for: url.lastPathComponent))
                        .font(.footnote).foregroundStyle(.secondary)
                    if capture.origin == .sample {
                        Label("Sample room: massing model generated from plan data. A real LiDAR scan exports Apple's parametric RoomPlan USDZ.",
                              systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "cube.transparent").font(.system(size: 48)).foregroundStyle(.secondary)
                        Text(capture.kind == .object ? "No 3D model yet" : "No USDZ model for this room").font(.headline)
                        if let message = capture.statusMessage {
                            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        }
                        if capture.kind == .object {
                            Text("The photos are in the Files tab. On a Mac, drop the Images folder into Reality Composer Pro (or run PhotogrammetrySession at .full / .raw detail) for a higher-detail model, then import the USDZ back here.")
                                .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
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
    }
}

/// Interactive SceneKit preview with orbit camera.
struct SceneModelView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(red: 0.93, green: 0.94, blue: 0.95, alpha: 1)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        load(into: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}

    private func load(into view: SCNView) {
        guard let scene = try? SCNScene(url: url, options: [.checkConsistency: false]) else { return }
        view.scene = scene
        let (minV, maxV) = scene.rootNode.boundingBox
        let center = SCNVector3((minV.x + maxV.x) / 2, (minV.y + maxV.y) / 2, (minV.z + maxV.z) / 2)
        let size = max(maxV.x - minV.x, max(maxV.y - minV.y, maxV.z - minV.z))
        let camera = SCNCamera()
        camera.fieldOfView = 45
        camera.zFar = Double(size) * 20 + 100
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        let distance = Float(size) * 1.25 + 0.5
        cameraNode.position = SCNVector3(center.x + distance * 0.55, center.y + distance * 0.95, center.z + distance * 0.75)
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
        .task(id: refresh) { buildZip(files: files, job: job) }
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
