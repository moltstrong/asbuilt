import SwiftUI
import UIKit
import simd
import AsBuiltCore

/// Object Detail scan coach HUD driven by synthetic metrics (`CoachDemo`), so the Simulator and CI
/// screenshots show the real overlay: distance reticle, speed bar, coverage rings around the locked
/// object box, fused-confidence tint and the grade card. The "camera feed" is the demo valve on its
/// table rendered by AsBuiltCore's depth renderer, the box is the real fit, and the tint dots come
/// from a real partly fused TSDF volume inside it.
/// Launch with `-AsBuiltScreen coach | coach-fast | coach-far | coach-band | coach-grade`.
struct CoachPreviewView: View {
    @State var scenario: CoachDemo.Scenario

    @Environment(\.dismiss) private var dismiss
    @State private var result: CoachDemo.Result?
    @State private var image: UIImage?
    @State private var tint: [CoachPreviewTint] = []
    @State private var stats: TSDFVolume.Stats?
    @State private var boxSegments: [BoxSegment] = []
    @State private var viewSize: CGSize = .zero

    init(scenario: CoachDemo.Scenario) {
        _scenario = State(initialValue: scenario)
    }

    var body: some View {
        // Same layering as DetailScanView: only the "camera" and the tint are full-bleed; the coach
        // overlay and the bars respect the safe area, so the screenshots match the real scan screen.
        ZStack {
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
                    BoxWireframeOverlay(segments: boxSegments, color: CoachColors.good)
                    Canvas { context, size in
                        for p in tint {
                            let pt = CGPoint(x: p.u * size.width, y: p.v * size.height)
                            let r: CGFloat = 5
                            context.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: 2 * r, height: 2 * r)),
                                         with: .color(CoachColors.confidence(p.confidence).opacity(0.8)))
                        }
                    }
                    .allowsHitTesting(false)
                }
                .onAppear { viewSize = geo.size }
            }
            .ignoresSafeArea()
            if let result {
                CoachOverlay(output: result.output, thresholds: result.thresholds, highlightGaps: false,
                             isScanning: scenario != .grade)
            }
            VStack(spacing: 12) {
                topBar
                Spacer()
                bottomBar
            }
            .padding()
            if scenario == .grade, let report = result?.report {
                Color.black.opacity(0.35).ignoresSafeArea()
                GradeCard(report: report, onFillGaps: {}, onDone: {})
                    .padding()
            }
        }
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
        let out = await Task.detached(priority: .userInitiated) { () -> (CoachDemo.Result, CoachPreviewRenderer.Output) in
            (CoachDemo.run(scenario), CoachPreviewRenderer.render(viewSize: size, scenario: scenario))
        }.value
        result = out.0
        image = out.1.image
        tint = out.1.tint
        stats = out.1.stats
        boxSegments = out.1.box
    }
}

struct CoachPreviewTint: Hashable, Sendable {
    /// Normalized view coordinates (0...1).
    var u: CGFloat
    var v: CGFloat
    var confidence: Float
}

/// Renders the demo scene as a stand-in camera frame plus fused-confidence tint points and the box.
enum CoachPreviewRenderer {
    struct Output {
        var image: UIImage?
        var tint: [CoachPreviewTint]
        var stats: TSDFVolume.Stats
        var box: [BoxSegment]
    }

    static func render(viewSize: CGSize, scenario: CoachDemo.Scenario) -> Output {
        let distance: Float = scenario == .tooFar ? 1.35 : 0.5
        let pose = CoachDemo.orbitPose(azimuth: 18, elevation: 30, distance: distance)
        let (image, K) = cameraImage(viewSize: viewSize, pose: pose)
        let box = DemoDetailScan.fitBox()?.box
        // Real partial fusion: the first views of the orbit -> thin (red) and solid (green) areas.
        let volume = DemoDetailScan.partialVolume(frames: scenario == .grade ? 18 : 8)
        var tint: [CoachPreviewTint] = []
        let worldToCamera = pose.inverse
        for s in volume.surfaceSamples(solidWeight: 6, maxCount: 2500) {
            let pc4 = worldToCamera * SIMD4(s.position, 1)
            guard let uv = K.project(SIMD3(pc4.x, pc4.y, pc4.z)) else { continue }
            let u = CGFloat(uv.x) / CGFloat(K.width), v = CGFloat(uv.y) / CGFloat(K.height)
            guard u >= 0, u <= 1, v >= 0, v <= 1 else { continue }
            tint.append(CoachPreviewTint(u: u, v: v, confidence: s.confidence))
        }
        let segments = box.map { BoxWireframeOverlay.segments(box: $0, cameraToWorld: pose, intrinsics: K) } ?? []
        return Output(image: image, tint: tint, stats: volume.stats, box: segments)
    }

    /// Portrait "camera" frame of the demo table scene at the view's aspect ratio (~66 degrees
    /// horizontal FOV): Lambert shading from depth-map normals, a dim room where nothing is hit.
    static func cameraImage(viewSize: CGSize, pose: simd_float4x4) -> (UIImage?, PinholeIntrinsics) {
        let w = 300
        let h = max(200, Int((Double(w) * Double(viewSize.height / max(1, viewSize.width))).rounded()))
        let fx = Float(w) / (2 * tan(33 * Float.pi / 180))
        let K = PinholeIntrinsics(fx: fx, fy: fx, cx: Float(w) / 2, cy: Float(h) / 2, width: w, height: h)
        let frame = DemoDetailScan.scene().render(intrinsics: K, cameraToWorld: pose, maxDistance: 4, withColor: true)
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
                // A little darker with distance, like a real room behind the table.
                shade *= max(0.55, 1 - 0.25 * max(0, d - 0.5))
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
        return (image, K)
    }
}

/// Object Detail scan placement step with synthetic depth (`-AsBuiltScreen detail-place`): the demo
/// valve on its table, the box from the real `ObjectBoxFitter`, the real coach pre-flight, and the
/// same placement panel as the AR screen (+/- resize the box live).
struct ObjectPlacePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var router: Router
    @AppStorage(Preferences.unitsKey) private var unitsRaw = UnitSystem.imperial.rawValue
    @State private var image: UIImage?
    @State private var intrinsics: PinholeIntrinsics?
    @State private var fitted: ObjectBoxFitter.Result?
    @State private var box: ObjectBox?
    @State private var status: ObjectPlacementPanel.Status = .searching
    @State private var output: CoachOutput?
    @State private var viewSize: CGSize = .zero

    private let pose = DemoDetailScan.placementPose
    private var units: UnitSystem { UnitSystem(rawValue: unitsRaw) ?? .imperial }

    var body: some View {
        // Same layering as the AR screen: camera + box full-bleed, HUD inside the safe area.
        ZStack {
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
                    if let box, let intrinsics {
                        BoxWireframeOverlay(segments: BoxWireframeOverlay.segments(box: box, cameraToWorld: pose, intrinsics: intrinsics))
                    }
                }
                .onAppear { viewSize = geo.size }
            }
            .ignoresSafeArea()
            if let output {
                CoachOverlay(output: output, thresholds: .for(.detail), showsSpeed: false, showsRings: false, isScanning: false)
            }
            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(BigButtonStyle(filled: false, color: .white))
                        .frame(width: 110)
                        .accessibilityIdentifier("placePreviewClose")
                    Spacer()
                    Text("PREVIEW · synthetic depth, real box fit")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(.top, 14)
                    Spacer()
                    CoachHelpButton {}
                }
                Spacer()
                ObjectPlacementPanel(box: box, status: status, units: units, isReady: output?.isReady ?? false,
                                     onAdjust: { axis, delta in
                                         guard let b = box else { return }
                                         box = b.resized(axis: axis, by: delta)
                                         status = .adjusted
                                     },
                                     onFitAgain: {
                                         box = fitted?.box
                                         status = .fitted(onPlane: fitted?.planeY != nil)
                                     },
                                     onStart: { router.path.append(.coachPreview(CoachDemo.Scenario.midScan.rawValue)) })
            }
            .padding()
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden()
        .task { await load() }
    }

    private func load() async {
        let size = viewSize.width > 0 ? viewSize : CGSize(width: 402, height: 874)
        let pose = pose
        let out = await Task.detached(priority: .userInitiated) { () -> (UIImage?, PinholeIntrinsics, ObjectBoxFitter.Result?, CoachOutput?) in
            let (image, K) = CoachPreviewRenderer.cameraImage(viewSize: size, pose: pose)
            let fit = DemoDetailScan.fitBox()
            // Coach pre-flight: one steady second at the placement pose, distance measured to the box.
            var coach = CaptureCoach(mode: .detail)
            var last: CoachOutput?
            for k in 0..<40 {
                var frame = CoachFrame(timestamp: Double(k) / 30, cameraToWorld: pose, ambientIntensity: 900, centerDepth: 0.5,
                                       highConfidenceFraction: 0.8, tracking: .normal, featureCount: 300)
                if let box = fit?.box { frame = ObjectScan.coachFrame(frame, box: box) }
                last = coach.update(frame)
            }
            return (image, K, fit, last)
        }.value
        image = out.0
        intrinsics = out.1
        fitted = out.2
        box = out.2?.box
        status = out.2.map { .fitted(onPlane: $0.planeY != nil) } ?? .searching
        output = out.3
    }
}
