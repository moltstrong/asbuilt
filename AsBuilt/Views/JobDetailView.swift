import SwiftUI
import UniformTypeIdentifiers
import AsBuiltCore

struct JobDetailView: View {
    let jobID: UUID

    @EnvironmentObject private var store: JobStore
    @EnvironmentObject private var router: Router
    @Environment(\.dismiss) private var dismiss
    @State private var showingRoomScan = false
    @State private var showingObjectCapture = false
    @State private var showingMeshScan = false
    @State private var showingDetailScan = false
    @State private var showingMeasure = false
    @State private var jobZipURL: URL?
    @State private var jobZipError: String?
    @State private var showingImporter = false
    @State private var showingEditor = false
    @State private var confirmDelete = false
    @State private var alertText: String?
    @State private var capabilities: DeviceCapabilities?

    var body: some View {
        Group {
            if let job = store.job(jobID) {
                content(job)
            } else {
                ContentUnavailableView("Job not found", systemImage: "questionmark.folder")
            }
        }
        .background(Theme.background)
        .onAppear { capabilities = DeviceCapabilities.current() }
    }

    private func content(_ job: Job) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                infoCard(job)

                // Objects first: the Detail scan is an object scan (box the object, then LiDAR fusion).
                SectionHeader(title: "Scan an object", systemImage: "cube.transparent")
                HStack(spacing: 10) {
                    captureButton(title: "Detail scan", subtitle: "Object · LiDAR · instant", icon: "cube.transparent.fill",
                                  blocked: capabilities?.meshScanBlocker, height: 132) {
                        showingDetailScan = true
                    }
                    .accessibilityIdentifier("detailScanButton")
                    captureButton(title: "Capture object", subtitle: "Photo 3D · full detail in the cloud", icon: "camera.aperture",
                                  blocked: capabilities?.objectCaptureBlocker, height: 132) {
                        showingObjectCapture = true
                    }
                    .accessibilityIdentifier("captureObjectButton")
                }
                SectionHeader(title: "Scan a room", systemImage: "square.split.bottomrightquarter")
                HStack(spacing: 10) {
                    captureButton(title: "Scan room", subtitle: "Floor plan", icon: "square.split.bottomrightquarter",
                                  blocked: capabilities?.roomScanBlocker, style: .secondary) {
                        showingRoomScan = true
                    }
                    .accessibilityIdentifier("scanRoomButton")
                    captureButton(title: "Room mesh", subtitle: "Walls & spaces · few cm", icon: CaptureKind.mesh.icon,
                                  blocked: capabilities?.meshScanBlocker, style: .secondary) {
                        showingMeshScan = true
                    }
                    .accessibilityIdentifier("lidarMeshButton")
                }
                Button {
                    showingMeasure = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "ruler").font(.system(size: 20, weight: .semibold))
                        Text("Measure").font(.headline)
                        Text(capabilities?.meshScanBlocker == nil ? "Point to point" : "Needs LiDAR")
                            .font(.subheadline).opacity(0.8)
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.bold)).opacity(0.6)
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: Theme.minTap)
                    .foregroundStyle(capabilities?.meshScanBlocker == nil ? Theme.accent : Color.secondary)
                    .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                        .fill(capabilities?.meshScanBlocker == nil ? Theme.accentSoft : Color(uiColor: .tertiarySystemFill)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("measureLauncherButton")
                if let blocker = capabilities?.roomScanBlocker {
                    Label(blocker, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SectionHeader(title: "Objects (\(job.allObjectCaptures.count))", systemImage: "cube")
                if job.allObjectCaptures.isEmpty {
                    Text("No objects yet. Detail scan measures an object in seconds with LiDAR; Capture object takes photos for a full-detail, photo-textured model built in the cloud.")
                        .foregroundStyle(.secondary)
                        .card()
                }
                ForEach(job.allObjectCaptures) { capture in
                    NavigationLink(value: Route.capture(job: job.id, capture: capture.id, tab: .model)) {
                        if capture.kind == .mesh {
                            MeshCaptureRow(jobID: job.id, capture: capture)
                        } else {
                            ObjectCaptureRow(capture: capture)
                        }
                    }
                    .buttonStyle(.plain)
                }

                MeasurementsSummary(job: job)

                SectionHeader(title: "Rooms (\(job.roomCaptures.count))", systemImage: "square.split.bottomrightquarter")
                if job.roomCaptures.isEmpty {
                    Text("No rooms scanned yet.").foregroundStyle(.secondary).card()
                }
                ForEach(job.roomCaptures.sorted { $0.createdAt < $1.createdAt }) { capture in
                    NavigationLink(value: Route.capture(job: job.id, capture: capture.id, tab: .plan)) {
                        RoomCaptureRow(jobID: job.id, capture: capture)
                    }
                    .buttonStyle(.plain)
                }

                SectionHeader(title: "Room meshes (\(job.roomMeshCaptures.count))", systemImage: CaptureKind.mesh.icon)
                if job.roomMeshCaptures.isEmpty {
                    Text("No room meshes yet. Room mesh captures a space, MEP runs or a whole wall as a 3D mesh (USDZ, OBJ, PLY) without photos.")
                        .foregroundStyle(.secondary)
                        .card()
                }
                ForEach(job.roomMeshCaptures.sorted { $0.createdAt < $1.createdAt }) { capture in
                    NavigationLink(value: Route.capture(job: job.id, capture: capture.id, tab: .model)) {
                        MeshCaptureRow(jobID: job.id, capture: capture)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    showingImporter = true
                } label: {
                    Label("Import USDZ model", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(BigButtonStyle(filled: false))

                if let jobZipURL {
                    ShareLink(item: jobZipURL) {
                        Label("Share all (\(jobZipURL.lastPathComponent))", systemImage: "square.and.arrow.up.on.square")
                    }
                    .buttonStyle(BigButtonStyle(filled: false))
                    .accessibilityIdentifier("shareAllJobButton")
                } else if let jobZipError {
                    Text(jobZipError).font(.footnote).foregroundStyle(Theme.bad)
                }
            }
            .padding(16)
        }
        .task(id: "\(job.captures.count)-\(job.measurements.count)-\(job.measureScale ?? 0)-\(store.exportsRevision)") {
            // Job ZIP (every capture's files + measurements.csv) built after the screen appears.
            try? await Task.sleep(nanoseconds: 300_000_000)
            do {
                jobZipURL = try store.makeJobZip(job.id)
                jobZipError = nil
            } catch {
                jobZipURL = nil
                jobZipError = "Could not build the job ZIP: \(error.localizedDescription)"
            }
        }
        .navigationTitle(job.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Edit job", systemImage: "pencil") { showingEditor = true }
                    if job.isDemo {
                        Button("Reset demo", systemImage: "arrow.counterclockwise") { Task { await store.resetDemo() } }
                    } else {
                        Button("Delete job", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .sheet(isPresented: $showingEditor) { JobEditorView(job: job) }
        .fullScreenCover(isPresented: $showingRoomScan) {
            RoomScanLauncher(jobID: job.id) { captureID in
                if let captureID { router.path.append(.capture(job: job.id, capture: captureID, tab: .plan)) }
            }
            .environmentObject(store)
        }
        .fullScreenCover(isPresented: $showingMeasure) {
            MeasureLauncher(jobID: job.id) { saved in
                if saved > 0 { router.path.append(.measurements(job.id)) }
            }
            .environmentObject(store)
        }
        .fullScreenCover(isPresented: $showingMeshScan) {
            MeshScanLauncher(jobID: job.id) { captureID in
                if let captureID { router.path.append(.capture(job: job.id, capture: captureID, tab: .model)) }
            }
            .environmentObject(store)
        }
        .fullScreenCover(isPresented: $showingDetailScan) {
            DetailScanLauncher(jobID: job.id) { captureID in
                if let captureID { router.path.append(.capture(job: job.id, capture: captureID, tab: .model)) }
            }
            .environmentObject(store)
        }
        .fullScreenCover(isPresented: $showingObjectCapture) {
            ObjectCaptureLauncher(jobID: job.id) { captureID in
                if let captureID { router.path.append(.capture(job: job.id, capture: captureID, tab: .model)) }
            }
            .environmentObject(store)
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [UTType.usdz]) { result in
            switch result {
            case .success(let url):
                do {
                    let capture = try ModelImporter.importModel(from: url, jobID: job.id, store: store)
                    router.path.append(.capture(job: job.id, capture: capture.id, tab: .model))
                } catch {
                    alertText = "Import failed: \(error.localizedDescription)"
                }
            case .failure(let error):
                alertText = error.localizedDescription
            }
        }
        .confirmationDialog("Delete \(job.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete job and all files", role: .destructive) {
                store.deleteJob(job.id)
                dismiss()
            }
        }
        .alert(alertText ?? "", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func infoCard(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(job.name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                if job.isDemo { Badge(text: "DEMO") }
            }
            if !job.address.isEmpty { Label(job.address, systemImage: "mappin.and.ellipse") }
            if !job.client.isEmpty { Label(job.client, systemImage: "person") }
            if !job.notes.isEmpty {
                Text(job.notes).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.subheadline)
        .card()
    }

    enum CaptureButtonStyle { case primary, secondary }

    /// Primary = filled (object scans); secondary = tinted (room scans).
    private func captureButton(title: String, subtitle: String, icon: String, blocked: String?, height: CGFloat = 112,
                               style: CaptureButtonStyle = .primary, action: @escaping () -> Void) -> some View {
        let enabled = blocked == nil
        let foreground: Color = !enabled ? .secondary : (style == .primary ? .white : Theme.accent)
        let background: Color = !enabled ? Color(uiColor: .tertiarySystemFill) : (style == .primary ? Theme.accent : Theme.accentSoft)
        return Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: style == .primary ? 30 : 24, weight: .semibold))
                Text(title).font(style == .primary ? .headline : .subheadline.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(enabled ? subtitle : "Needs LiDAR")
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(0.9)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: height)
            .foregroundStyle(foreground)
            .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(background))
        }
        .buttonStyle(.plain)
    }
}

struct RoomCaptureRow: View {
    let jobID: UUID
    let capture: Capture
    @EnvironmentObject private var store: JobStore
    @AppStorage(Preferences.unitsKey) private var unitsRaw = UnitSystem.imperial.rawValue

    var body: some View {
        let units = UnitSystem(rawValue: unitsRaw) ?? .imperial
        let plan = store.plan(job: jobID, capture: capture.id)
        let takeoff = plan.map { TakeoffCalculator.calculate($0, options: Preferences.takeoffOptions) }
        HStack(spacing: 14) {
            Group {
                if let plan {
                    PlanThumbnail(plan: plan)
                } else {
                    Image(systemName: "square.split.bottomrightquarter").font(.title)
                }
            }
            .frame(width: 76, height: 76)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(capture.title).font(.headline)
                    if capture.origin == .sample { Badge(text: "SAMPLE", color: .gray) }
                    if capture.origin == .roomPlan { Badge(text: "LIDAR", color: Theme.ok) }
                }
                if let takeoff {
                    Text("\(UnitFormatter.area(takeoff.floorArea, units)) · \(takeoff.walls.count) walls · clg \(UnitFormatter.length(takeoff.ceilingHeight, units))")
                        .font(.subheadline.monospacedDigit())
                    Text("\(takeoff.doorCount) door · \(takeoff.windowCount) win · \(takeoff.openingCount) opening · \(takeoff.fixtureCount) objects")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(capture.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .card()
        .contentShape(Rectangle())
    }
}

struct ObjectCaptureRow: View {
    let capture: Capture

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "cube.transparent.fill")
                .font(.title)
                .foregroundStyle(Theme.accent)
                .frame(width: 56, height: 56)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(capture.title).font(.headline)
                Text(statusText).font(.subheadline).foregroundStyle(statusColor)
                Text(capture.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .card()
        .contentShape(Rectangle())
    }

    private var statusText: String {
        let photos = capture.imageCount.map { " · \($0) photos" } ?? ""
        switch capture.status {
        case .complete: return "3D model ready" + photos
        case .imagesOnly: return "Photos saved, 3D build failed: retry" + photos
        case .processing: return "Processing…" + photos
        case .failed: return "Failed" + photos
        }
    }

    private var statusColor: Color {
        switch capture.status {
        case .complete: return Theme.ok
        case .imagesOnly, .processing: return Theme.warn
        case .failed: return Theme.bad
        }
    }
}

struct MeshCaptureRow: View {
    let jobID: UUID
    let capture: Capture
    @EnvironmentObject private var store: JobStore
    @AppStorage(Preferences.unitsKey) private var unitsRaw = UnitSystem.imperial.rawValue

    var body: some View {
        let units = UnitSystem(rawValue: unitsRaw) ?? .imperial
        let m = store.meshMeasurements(job: jobID, capture: capture.id)
        HStack(spacing: 14) {
            Image(systemName: capture.isDetailScan ? "cube.transparent.fill" : CaptureKind.mesh.icon)
                .font(.title)
                .foregroundStyle(Theme.accent)
                .frame(width: 56, height: 56)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(capture.title).font(.headline)
                    if capture.origin == .sample { Badge(text: "SAMPLE", color: .gray) }
                    if capture.origin == .lidarMesh { Badge(text: "LIDAR", color: Theme.ok) }
                    if capture.isDetailScan { Badge(text: "DETAIL", color: Theme.accent) }
                    if let grade = capture.coachGrade { Badge(text: grade, color: ["A", "B"].contains(grade) ? Theme.ok : Theme.warn) }
                }
                if let m {
                    Text(capture.isDetailScan ? m.objectDimensionsText(units) : m.dimensionsText(units))
                        .font(.subheadline.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("\(m.triangleCount.formatted()) triangles · USDZ, OBJ, PLY")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Preparing…").font(.subheadline).foregroundStyle(Theme.warn)
                }
                Text(capture.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .card()
        .contentShape(Rectangle())
    }
}

/// Small static plan preview (walls, openings, fixtures only).
struct PlanThumbnail: View {
    let plan: FloorPlan

    var body: some View {
        Canvas { context, size in
            var drawing = PlanGeometryBuilder.build(plan, units: .imperial)
            drawing.texts = []
            drawing.lines = drawing.lines.filter { $0.layer != .dimensions }
            let viewport = PlanViewport(bounds: drawing.bounds, width: size.width, height: size.height, padding: 6)
            context.withCGContext { cg in
                PlanCGDrawer.draw(drawing, in: cg, viewport: viewport, options: .init(lineScale: 0.6))
            }
        }
    }
}

/// Measure-tool summary on the job screen: the latest values and a link to the full list.
struct MeasurementsSummary: View {
    let job: Job
    @AppStorage(Preferences.unitsKey) private var unitsRaw = UnitSystem.imperial.rawValue

    var body: some View {
        let units = UnitSystem(rawValue: unitsRaw) ?? .imperial
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Measurements (\(job.measurements.count))", systemImage: "ruler")
            NavigationLink(value: Route.measurements(job.id)) {
                VStack(alignment: .leading, spacing: 6) {
                    if job.measurements.isEmpty {
                        Text("No measurements yet. Tap Measure for point-to-point LiDAR measurements, then calibrate with a tape.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(job.measurements.suffix(3)) { m in
                            HStack {
                                Text(m.label).lineLimit(1)
                                Spacer()
                                Text(UnitFormatter.precise(m.calibratedMeters(scale: job.measureScale), units))
                                    .font(.body.weight(.semibold).monospacedDigit())
                            }
                        }
                        HStack(spacing: 6) {
                            Image(systemName: job.measureScale == nil ? "ruler" : "checkmark.seal.fill")
                            Text(job.measureScale == nil ? "Not tape calibrated" : String(format: "Tape calibrated × %.4f", job.effectiveMeasureScale))
                            Spacer()
                            Text("All").fontWeight(.semibold)
                            Image(systemName: "chevron.right")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .card()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("measurementsSummary")
        }
    }
}
