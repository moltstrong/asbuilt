import SwiftUI
import AVFoundation
import AsBuiltCore

struct CapabilitiesView: View {
    @State private var caps: DeviceCapabilities?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let caps {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This device").font(.headline)
                        Text(caps.deviceModel).font(.subheadline.monospaced())
                        Text(caps.systemVersion).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .card()

                    ResolutionGuide()

                    SectionHeader(title: "Capabilities", systemImage: "checklist")
                    VStack(spacing: 0) {
                        row("LiDAR depth sensor", ok: caps.hasLiDAR,
                            detail: caps.hasLiDAR ? "Scene reconstruction available" : "Not found on this device")
                        Divider()
                        row("Room scanning (RoomPlan)", ok: caps.roomPlanSupported,
                            detail: caps.roomScanBlocker ?? "Ready: scan rooms into floor plans, DXF and takeoffs")
                        Divider()
                        row("Object capture", ok: caps.objectCaptureSupported,
                            detail: caps.objectCaptureBlocker ?? "Ready: guided 3D capture of equipment, fixtures, damage")
                        Divider()
                        row("On-device 3D reconstruction", ok: caps.onDeviceReconstruction,
                            detail: caps.onDeviceReconstruction ? "model.usdz is built on the phone (with automatic retries)" : "Photos are kept; reconstruct on a Mac")
                        Divider()
                        row("LiDAR Mesh scan", ok: caps.meshScanSupported,
                            detail: caps.meshScanBlocker ?? (caps.meshClassification
                                ? "Ready: live 3D mesh of any space or object, classified walls/floor/doors. No photogrammetry."
                                : "Ready: live 3D mesh of any space or object. No photogrammetry."))
                        Divider()
                        row("Detail scan (depth fusion)", ok: caps.meshScanSupported,
                            detail: caps.meshScanBlocker ?? "Ready: 4 mm voxels within 1.5 m, colored mesh")
                        Divider()
                        row("Measure", ok: caps.meshScanSupported,
                            detail: caps.meshScanBlocker ?? "Ready: point-to-point LiDAR measuring, tape calibration")
                        Divider()
                        row("Camera permission", ok: caps.cameraStatus == .authorized,
                            warn: caps.cameraStatus == .notDetermined, detail: cameraText(caps.cameraStatus))
                        Divider()
                        row("Plans, takeoffs & exports", ok: true, detail: "Always available (try the Demo job)")
                    }
                    .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.card))

                    if caps.cameraStatus == .notDetermined && !caps.isSimulator {
                        Button("Allow camera access") {
                            AVCaptureDevice.requestAccess(for: .video) { _ in
                                Task { @MainActor in self.caps = DeviceCapabilities.current() }
                            }
                        }
                        .buttonStyle(BigButtonStyle())
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Supported hardware").font(.headline)
                        Text("Room scanning and object capture need LiDAR: iPhone 12 Pro / Pro Max or any later Pro model, or iPad Pro (2020 or later). Other iPhones and the Simulator can open jobs, review plans and takeoffs, and share every export.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .card()
                } else {
                    ProgressView()
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Device check")
        .onAppear { caps = DeviceCapabilities.current() }
    }

    private func row(_ title: String, ok: Bool, warn: Bool = false, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : (warn ? "questionmark.circle.fill" : "xmark.octagon.fill"))
                .font(.title2)
                .foregroundStyle(ok ? Theme.ok : (warn ? Theme.warn : Theme.bad))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(minHeight: 60)
    }

    private func cameraText(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Allowed"
        case .denied: return "Denied: enable in Settings › AsBuilt › Camera"
        case .restricted: return "Restricted by device management"
        case .notDetermined: return "Not asked yet (asked when you first scan)"
        @unknown default: return "Unknown"
        }
    }
}

/// Honest "what each mode resolves" table + technique tips. Numbers are the hardware's limits:
/// LiDAR depth is 256x192 (densified from a sparse emitter, ~1 cm absolute accuracy).
struct ResolutionGuide: View {
    struct Mode: Identifiable {
        var id: String { name }
        let name: String
        let icon: String
        let resolves: String
        let detail: String
    }

    static let modes: [Mode] = [
        Mode(name: "Room (RoomPlan)", icon: "square.split.bottomrightquarter", resolves: "about 1-2 cm",
             detail: "Walls, doors, windows, openings and major fixtures as clean shapes. Not small details."),
        Mode(name: "LiDAR Mesh", icon: "cube.transparent", resolves: "a few cm",
             detail: "ARKit's live mesh: triangles of a few cm. Fast for whole spaces."),
        Mode(name: "Detail scan", icon: "viewfinder", resolves: "about 3-5 mm within 1 m",
             detail: "Fuses many LiDAR depth frames into 4 mm voxels. Fine shapes appear after several passes; absolute accuracy is still about 1 cm."),
        Mode(name: "Object Capture", icon: "cube", resolves: "phone: reduced detail",
             detail: "On-phone builds use Apple's reduced detail. Export the photos for a Mac build: about 1 mm on small textured objects."),
        Mode(name: "Measure", icon: "ruler", resolves: "about ±1 cm, better after tape calibration",
             detail: "Each point is the median of about 20 depth samples; the ± comes from their spread."),
    ]

    static let tips: [(String, String)] = [
        ("sun.max.fill", "Even, bright light (the torch turns on by itself when it is dark)"),
        ("tortoise.fill", "Move slowly: keep the speed bar green"),
        ("arrow.down.right.and.arrow.up.left", "Stay within about 1 m for detail"),
        ("circle.dashed", "3 passes: low, middle, high"),
        ("sparkles", "Shiny or plain surfaces: matte spray or painter's tape"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "What each mode resolves", systemImage: "scope")
            VStack(spacing: 0) {
                ForEach(Self.modes) { m in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: m.icon)
                            .font(.title3)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(m.name).font(.headline)
                                Spacer(minLength: 8)
                                Text(m.resolves)
                                    .font(.subheadline.weight(.semibold))
                                    .multilineTextAlignment(.trailing)
                            }
                            Text(m.detail).font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                    if m.id != Self.modes.last?.id { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.card))
            .accessibilityIdentifier("resolutionGuide")

            VStack(alignment: .leading, spacing: 8) {
                Text("For the most detail").font(.headline)
                ForEach(Self.tips, id: \.1) { tip in
                    Label(tip.1, systemImage: tip.0)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .card()
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: JobStore
    @AppStorage(Preferences.unitsKey) private var unitsRaw = UnitSystem.imperial.rawValue
    @AppStorage(Preferences.wasteKey) private var wastePercent: Double = 10
    @AppStorage(Preferences.coatsKey) private var coats: Int = 2

    var body: some View {
        Form {
            Section("Units") {
                Picker("Measurement", selection: $unitsRaw) {
                    ForEach(UnitSystem.allCases) { u in Text(u.displayName).tag(u.rawValue) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section {
                Stepper(value: $wastePercent, in: 0...30, step: 1) {
                    LabeledContent("Waste factor", value: "\(Int(wastePercent))%")
                }
                Stepper(value: $coats, in: 1...4) {
                    LabeledContent("Paint coats", value: "\(coats)")
                }
                LabeledContent("Drywall sheet", value: "4' x 8' (32 sq ft)")
                LabeledContent("Paint coverage", value: "350 sq ft / gal / coat")
            } header: {
                Text("Estimating")
            } footer: {
                Text("Drywall = net wall area / 32. Paint = net wall area / 350 x coats. Baseboard = perimeter minus door and opening widths. Flooring = floor area. All include the waste factor.")
            }
            Section("Exports") {
                Button("Regenerate all room exports") {
                    for job in store.jobs {
                        for capture in job.roomCaptures { store.regenerateExports(job: job.id, capture: capture.id) }
                    }
                }
                Text("DXF is written in inches (imperial) or millimeters (metric) with $INSUNITS set, so it inserts at true scale.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-")
            }
        }
        .navigationTitle("Settings")
    }
}
