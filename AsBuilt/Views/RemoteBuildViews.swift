import SwiftUI
import AsBuiltCore

/// "Full detail in the cloud" card: one bar for the whole trip (pack → send → build → bring back),
/// the current step in plain words, and a single action. Pure view (CI previews render it with
/// synthetic states); `RemoteBuildCard` binds it to a capture.
struct RemoteBuildCardView: View {
    let build: RemoteBuild?
    var photoCount: Int?
    /// Bytes of chunks still on the wire (smooth upload bar between 8 MB acknowledgements).
    var inFlightBytes: Int64 = 0
    var onStart: () -> Void = {}
    var onCancel: () -> Void = {}
    var onRetry: () -> Void = {}

    private static let steps = ["Pack", "Send", "Build", "Download"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let build {
                if build.isActive {
                    active(build)
                } else if build.phase == .done {
                    Text(build.detailLine)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("remoteBuildDetail")
                } else {
                    Text(build.message ?? build.detailLine)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: onRetry) {
                        Label("Try the cloud build again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(BigButtonStyle(filled: false))
                    .accessibilityIdentifier("remoteBuildRetry")
                }
            } else {
                Text("The cloud rebuilds this object in full detail (250k triangles, 8K photo texture, real-world size from LiDAR) and sends it back here, usually within 20-40 minutes.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onStart) {
                    Label("Build full detail in the cloud", systemImage: "icloud.and.arrow.up")
                }
                .buttonStyle(BigButtonStyle())
                .accessibilityIdentifier("remoteBuildStart")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remoteBuildCard")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 28)
            Text(build?.headline ?? "Full detail in the cloud")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let build, build.isActive {
                Text("\(Int((build.overallFraction(inFlightBytes: inFlightBytes) * 100).rounded()))%")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func active(_ build: RemoteBuild) -> some View {
        ProgressView(value: max(0.02, build.overallFraction(inFlightBytes: inFlightBytes)))
            .tint(build.phase == .waitingForMac ? Theme.warn : Theme.accent)
        HStack(spacing: 6) {
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, name in
                let state = index < build.step ? 2 : (index == build.step ? 1 : 0)
                HStack(spacing: 4) {
                    Image(systemName: state == 2 ? "checkmark.circle.fill" : (state == 1 ? "circle.inset.filled" : "circle"))
                        .font(.caption)
                    Text(name).font(.caption.weight(state == 1 ? .bold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(state == 0 ? Color.secondary : (state == 1 ? Theme.accent : Theme.ok))
                if index < Self.steps.count - 1 { Spacer(minLength: 2) }
            }
        }
        Text(build.phase == .waitingForMac ? (build.message ?? build.detailLine) : build.detailLine(inFlightBytes: inFlightBytes))
            .font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("remoteBuildDetail")
        if build.phase == .preparing || build.phase == .uploading || build.phase == .waitingForMac {
            Text("Sending keeps going if you lock the phone or switch apps; Wi-Fi is fastest. AsBuilt sends you a notification when the model is ready.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Button(role: .destructive, action: onCancel) {
            Text("Cancel cloud build").font(.footnote.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("remoteBuildCancel")
    }

    private var icon: String {
        guard let build else { return "icloud" }
        switch build.phase {
        case .done: return "checkmark.seal.fill"
        case .failed, .cancelled: return "exclamationmark.triangle.fill"
        case .waitingForMac: return "wifi.exclamationmark"
        default: return "icloud"
        }
    }

    private var color: Color {
        guard let build else { return Theme.accent }
        switch build.phase {
        case .done: return Theme.ok
        case .failed, .cancelled, .waitingForMac: return Theme.warn
        default: return Theme.accent
        }
    }
}

/// The card for a real Object Capture, driven by `RemoteBuildService`. Hidden when this copy of
/// the app has no cloud build server configured and no build was ever started.
struct RemoteBuildCard: View {
    let jobID: UUID
    let capture: Capture
    @ObservedObject private var service = RemoteBuildService.shared

    var body: some View {
        if capture.kind == .object, capture.origin != .sample, service.isConfigured || capture.remoteBuild != nil {
            RemoteBuildCardView(build: capture.remoteBuild, photoCount: capture.imageCount,
                                inFlightBytes: service.inFlightBytes[capture.id] ?? 0,
                                onStart: { service.start(job: jobID, capture: capture.id) },
                                onCancel: { service.cancel(job: jobID, capture: capture.id) },
                                onRetry: { service.start(job: jobID, capture: capture.id, restart: true) })
        }
    }
}

/// CI screenshots of the card (`-AsBuiltScreen mac-build`, `mac-build-done`, `mac-build-offline`).
struct RemoteBuildPreviewView: View {
    let scenario: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                RemoteBuildCardView(build: Self.build(for: scenario))
                RemoteBuildCardView(build: nil)
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Object 1")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func build(for scenario: String) -> RemoteBuild {
        var b = RemoteBuild(phase: .building, photoCount: 142, startedAt: Date())
        b.totalBytes = 612_000_000
        b.chunkSize = 16 << 20
        b.chunkCount = 37
        b.receivedChunks = Array(0..<37)
        switch scenario {
        case "mac-build-done":
            b.phase = .done
            b.polygons = 250_000
            b.textureSize = 8192
            b.textureCount = 1
            b.buildSeconds = 1182
            b.modelBytes = 20_419_211
        case "mac-build-offline":
            b.phase = .waitingForMac
            b.receivedChunks = Array(0..<14)
            b.message = "The cloud isn't reachable right now. AsBuilt keeps trying."
        case "mac-build-upload":
            b.phase = .uploading
            b.receivedChunks = Array(0..<22)
        default:
            b.phaseProgress = 0.63
            b.stage = "textureMapping"
            b.etaSeconds = 95
        }
        return b
    }
}
