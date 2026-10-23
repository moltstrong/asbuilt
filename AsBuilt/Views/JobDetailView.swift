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

                SectionHeader(title: "Capture", systemImage: "camera.viewfinder")
                HStack(spacing: 12) {
                    captureButton(title: "Scan room", subtitle: "LiDAR floor plan", icon: "square.split.bottomrightquarter",
                                  blocked: capabilities?.roomScanBlocker) {
                        showingRoomScan = true
                    }
                    .accessibilityIdentifier("scanRoomButton")
                    captureButton(title: "Capture object", subtitle: "3D model", icon: "cube.transparent",
                                  blocked: capabilities?.objectCaptureBlocker) {
                        showingObjectCapture = true
                    }
                    .accessibilityIdentifier("captureObjectButton")
                }
                if let blocker = capabilities?.roomScanBlocker {
                    Label(blocker, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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

                SectionHeader(title: "Objects (\(job.objectCaptures.count))", systemImage: "cube")
                if job.objectCaptures.isEmpty {
                    Text("No objects captured yet. Use Capture object for equipment, fixtures or damage, or import a USDZ.")
                        .foregroundStyle(.secondary)
                        .card()
                }
                ForEach(job.objectCaptures.sorted { $0.createdAt < $1.createdAt }) { capture in
                    NavigationLink(value: Route.capture(job: job.id, capture: capture.id, tab: .model)) {
                        ObjectCaptureRow(capture: capture)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    showingImporter = true
                } label: {
                    Label("Import USDZ model", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(BigButtonStyle(filled: false))
            }
            .padding(16)
        }
        .navigationTitle(job.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Edit job", systemImage: "pencil") { showingEditor = true }
                    if job.isDemo {
                        Button("Reset demo", systemImage: "arrow.counterclockwise") { store.ensureDemoJob(reset: true) }
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

    private func captureButton(title: String, subtitle: String, icon: String, blocked: String?,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 30, weight: .semibold))
                Text(title).font(.headline)
                Text(blocked == nil ? subtitle : "Needs LiDAR")
                    .font(.caption.weight(.semibold))
                    .opacity(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .foregroundStyle(blocked == nil ? Color.white : Color.secondary)
            .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .fill(blocked == nil ? Theme.accent : Color(uiColor: .tertiarySystemFill)))
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
        case .imagesOnly: return "Photos only, reconstruct on Mac" + photos
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
