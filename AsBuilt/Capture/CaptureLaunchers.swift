import SwiftUI
import UniformTypeIdentifiers
import AsBuiltCore

/// Entry points for capture flows. Device-only flows are compiled out of Simulator builds.
struct RoomScanLauncher: View {
    let jobID: UUID
    var onFinished: (UUID?) -> Void

    var body: some View {
        #if canImport(RoomPlan) && !targetEnvironment(simulator)
        RoomScanView(jobID: jobID, onFinished: onFinished)
        #else
        UnsupportedCaptureView(kind: .room, message: DeviceCapabilitiesSnapshot.roomMessage)
        #endif
    }
}

struct ObjectCaptureLauncher: View {
    let jobID: UUID
    var onFinished: (UUID?) -> Void

    var body: some View {
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        ObjectCaptureFlowView(jobID: jobID, onFinished: onFinished)
        #else
        UnsupportedCaptureView(kind: .object, message: DeviceCapabilitiesSnapshot.objectMessage)
        #endif
    }
}

/// LiDAR scan screen with a Room / Detail mode picker: Room = ARKit scene mesh (a few cm),
/// Detail = TSDF fusion of the LiDAR depth maps (4 mm voxels within 1.5 m).
struct MeshScanLauncher: View {
    let jobID: UUID
    var initialMode: LiDARScanMode? = nil
    var onFinished: (UUID?) -> Void

    @AppStorage("lidarScanMode") private var modeRaw = LiDARScanMode.room.rawValue

    var body: some View {
        #if os(iOS) && !targetEnvironment(simulator)
        let mode = LiDARScanMode(rawValue: modeRaw) ?? .room
        Group {
            switch mode {
            case .room:
                LiDARMeshScanView(jobID: jobID, modePicker: AnyView(LiDARModePicker(modeRaw: $modeRaw)), onFinished: onFinished)
            case .detail:
                DetailScanView(jobID: jobID, modePicker: AnyView(LiDARModePicker(modeRaw: $modeRaw)), onFinished: onFinished)
            }
        }
        .id(mode)
        .onAppear { if let initialMode { modeRaw = initialMode.rawValue } }
        #else
        UnsupportedCaptureView(kind: .mesh, message: DeviceCapabilitiesSnapshot.meshMessage)
        #endif
    }
}

enum LiDARScanMode: String, CaseIterable, Identifiable {
    case room
    case detail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .room: return "Room"
        case .detail: return "Detail"
        }
    }

    var subtitle: String {
        switch self {
        case .room: return "Spaces · few cm"
        case .detail: return "Within 1 m · 3-5 mm"
        }
    }
}

/// Room / Detail segmented picker shown on the LiDAR scan screen before Start.
struct LiDARModePicker: View {
    @Binding var modeRaw: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(LiDARScanMode.allCases) { mode in
                let selected = modeRaw == mode.rawValue
                Button {
                    modeRaw = mode.rawValue
                } label: {
                    VStack(spacing: 2) {
                        Text(mode.title).font(.headline)
                        Text(mode.subtitle).font(.caption2.weight(.semibold)).opacity(0.85)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(selected ? Color.black : Color.white)
                    .background(selected ? Color.white : Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityIdentifier("lidarMode-\(mode.rawValue)")
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15))
        .frame(maxWidth: 420)
    }
}

enum DeviceCapabilitiesSnapshot {
    static let roomMessage = "Room scanning uses Apple RoomPlan and needs a LiDAR iPhone or iPad Pro."
    static let objectMessage = "Object capture uses Apple Object Capture and needs a LiDAR iPhone or iPad Pro on iOS 17+."
    static let meshMessage = "LiDAR Mesh needs an iPhone or iPad with a LiDAR scanner (iPhone 12 Pro or later Pro model, iPad Pro 2020 or later)."
}

struct UnsupportedCaptureView: View {
    let kind: CaptureKind
    let message: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: kind.icon)
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("\(kind.displayName) unavailable").font(.title2.bold())
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text("You can still open the Demo job to review plans, takeoffs and exports.")
                    .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("OK") { dismiss() }.buttonStyle(BigButtonStyle())
            }
            .padding(24)
        }
    }
}

/// Imports an existing USDZ (e.g. reconstructed on a Mac) as an object capture.
enum ModelImporter {
    @MainActor
    static func importModel(from url: URL, jobID: UUID, store: JobStore) throws -> Capture {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let name = url.deletingPathExtension().lastPathComponent
        let capture = Capture(kind: .object, origin: .objectCapture, title: name.isEmpty ? "Imported model" : name,
                              notes: "Imported from Files.")
        let dir = store.captureDirectory(job: jobID, capture: capture.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(CaptureFile.modelUSDZ))
        store.addCapture(capture, to: jobID)
        return capture
    }
}
