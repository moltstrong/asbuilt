import SwiftUI
import UIKit
import simd
import AsBuiltCore

/// Capture Coach HUD driven by synthetic metrics (`CoachDemo`), so the Simulator and CI screenshots
/// show the real overlay: distance reticle, speed bar, coverage rings, fused-confidence tint and the
/// grade card. The "camera feed" is the demo Detail scan scene rendered by AsBuiltCore's depth
/// renderer, and the tint dots come from a real partly fused TSDF volume.
/// Launch with `-AsBuiltScreen coach | coach-fast | coach-far | coach-band | coach-grade`.
struct CoachPreviewView: View {
    @State var scenario: CoachDemo.Scenario

    @Environment(\.dismiss) private var dismiss
    @State private var result: CoachDemo.Result?
    @State private var image: UIImage?
    @State private var tint: [CoachPreviewTint] = []
    @State private var stats: TSDFVolume.Stats?
    @State private var viewSize: CGSize = .zero

    init(scenario: CoachDemo.Scenario) {
        _scenario = State(initialValue: scenario)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                Canvas { context, size in
                    for p in tint {
                        let pt = CGPoint(x: p.u * size.width, y: p.v * size.height)
                        let r: CGFloat = 5
                        context.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: 2 * r, height: 2 * r)),
                                     with: .color(CoachColors.confidence(p.confidence).opacity(0.8)))
                    }
                }
                .allowsHitTesting(false)
                if let result {
                    CoachOverlay(output: result.output, thresholds: result.thresholds, highlightGaps: false,
                                 isScanning: scenario != .grade)
                }
                VStack(spacing: 12) {
                    topBar
                    Spacer()
                    bottomBar
                }
                .padding(.horizontal, 16)
                // Below the Dynamic Island (the ZStack ignores the safe area, so geo's insets read 0 here).
                .padding(.top, max(geo.safeAreaInsets.top, 59) + 6)
                .padding(.bottom, max(geo.safeAreaInsets.bottom, 34) + 10)
                if scenario == .grade, let report = result?.report {
                    Color.black.opacity(0.35)
                    GradeCard(report: report, onFillGaps: {}, onDone: {})
                        .padding()
                }
            }
            .ignoresSafeArea()
            .onAppear { viewSize = geo.size }
        }
        .ignoresSafeArea()
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden()
        .task(id: scenario) { await load() }
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            Button("Close") { dismiss() }
                .buttonStyle(BigButtonStyle(filled: false, color: .white))
                .frame(width: 100)
                .accessibilityIdentifier("coachPreviewClose")
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(result?.integratedFrames ?? 0) frames fused").font(.headline.monospacedDigit())
                if let stats {
                    Text("\(stats.blockCount.formatted()) blocks · \(String(format: "%.0f", Double(stats.memoryBytes) / 1_048_576)) MB")
                        .font(.caption.monospacedDigit())
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            Menu {
                ForEach(CoachDemo.Scenario.allCases, id: \.self) { s in
                    Button(Self.title(s)) { scenario = s }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("Preview scenario")
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Text("PREVIEW · synthetic motion, real coach")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.black.opacity(0.45), in: Capsule())
            HStack(spacing: 12) {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity, minHeight: Theme.minTap)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(.white, lineWidth: 2))
                Label("Stop", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity, minHeight: Theme.minTap)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.corner))
            }
            .frame(maxWidth: 460)
        }
    }

    static func title(_ s: CoachDemo.Scenario) -> String {
        switch s {
        case .midScan: return "Mid-scan (good)"
        case .tooFast: return "Too fast"
        case .tooFar: return "Too far"
        case .nextBand: return "Band done: now lower"
        case .grade: return "Grade card"
        }
    }

    private func load() async {
        let scenario = scenario
        let size = viewSize.width > 0 ? viewSize : CGSize(width: 402, height: 874)
        let out = await Task.detached(priority: .userInitiated) { () -> (CoachDemo.Result, UIImage?, [CoachPreviewTint], TSDFVolume.Stats) in
            let result = CoachDemo.run(scenario)
            let (image, tint, stats) = CoachPreviewRenderer.render(viewSize: size, scenario: scenario)
            return (result, image, tint, stats)
        }.value
        result = out.0
        image = out.1
        tint = out.2
        stats = out.3
    }
}

struct CoachPreviewTint: Hashable, Sendable {
    /// Normalized view coordinates (0...1).
    var u: CGFloat
    var v: CGFloat
    var confidence: Float
}

/// Renders the demo scene as a stand-in camera frame plus fused-confidence tint points.
enum CoachPreviewRenderer {
    static func render(viewSize: CGSize, scenario: CoachDemo.Scenario) -> (UIImage?, [CoachPreviewTint], TSDFVolume.Stats) {
        // Portrait "camera" at the view's aspect ratio, ~66 degrees horizontal FOV.
        let w = 300
        let h = max(200, Int((Double(w) * Double(viewSize.height / max(1, viewSize.width))).rounded()))
        let fx = Float(w) / (2 * tan(33 * Float.pi / 180))
        let K = PinholeIntrinsics(fx: fx, fy: fx, cx: Float(w) / 2, cy: Float(h) / 2, width: w, height: h)
        let distance: Float = scenario == .tooFar ? 1.35 : 0.5
        let pose = CoachDemo.orbitPose(azimuth: 18, elevation: 12, distance: distance)
        let scene = DemoDetailScan.scene()
        let frame = scene.render(intrinsics: K, cameraToWorld: pose, maxDistance: 3, withColor: true)

        // Lambert shading from depth-map normals + a dim room behind the board.
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        let light = simd_normalize(SIMD3<Float>(0.4, 0.7, 0.6))
        for j in 0..<h {
            for i in 0..<w {
                let k = j * w + i
                let o = k * 4
                let d = frame.depth[k]
                if d <= 0 {
                    let g = UInt8(70 + 40 * Double(j) / Double(h))
                    rgba[o] = g; rgba[o + 1] = g; rgba[o + 2] = UInt8(min(255, Int(g) + 8))
                    continue
                }
                var shade: Float = 1
                if i + 1 < w, j + 1 < h, frame.depth[k + 1] > 0, frame.depth[k + w] > 0 {
                    let p = K.unproject(i: i, j: j, depth: d)
                    let px = K.unproject(i: i + 1, j: j, depth: frame.depth[k + 1])
                    let py = K.unproject(i: i, j: j + 1, depth: frame.depth[k + w])
                    var n = simd_cross(px - p, py - p)
                    let len = simd_length(n)
                    if len > 1e-9 {
                        n /= len
                        if n.z < 0 { n = -n }
                        shade = 0.45 + 0.55 * max(0, simd_dot(n, light))
                    }
                }
                for c in 0..<3 {
                    rgba[o + c] = UInt8(max(0, min(255, Float(frame.rgb[k * 3 + c]) * shade)))
                }
            }
        }
        let image: UIImage? = rgba.withUnsafeMutableBytes { raw -> UIImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let cg = ctx.makeImage() else { return nil }
            return UIImage(cgImage: cg)
        }

        // Real partial fusion: the first two passes' frames -> thin (red) and solid (green) areas.
        let volume = DemoDetailScan.partialVolume(frames: scenario == .grade ? 18 : 8)
        var tint: [CoachPreviewTint] = []
        let worldToCamera = pose.inverse
        for s in volume.surfaceSamples(solidWeight: 6, maxCount: 2500) {
            let pc4 = worldToCamera * SIMD4(s.position, 1)
            guard let uv = K.project(SIMD3(pc4.x, pc4.y, pc4.z)) else { continue }
            let u = CGFloat(uv.x) / CGFloat(w), v = CGFloat(uv.y) / CGFloat(h)
            guard u >= 0, u <= 1, v >= 0, v <= 1 else { continue }
            tint.append(CoachPreviewTint(u: u, v: v, confidence: s.confidence))
        }
        return (image, tint, volume.stats)
    }
}
