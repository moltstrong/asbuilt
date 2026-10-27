import SwiftUI
import simd
import AsBuiltCore

/// Placement step of the object Detail scan, shared by the AR screen and the Simulator preview:
/// the fitted box's size per axis with +/- steps, "Fit again" and Start.
struct ObjectPlacementPanel: View {
    enum Status: Equatable {
        /// No box yet: aim at the object.
        case searching
        /// Box fitted from depth (`onPlane`: standing on a detected table/floor).
        case fitted(onPlane: Bool)
        /// The user changed the size: auto-fit is off until "Fit again".
        case adjusted
    }

    let box: ObjectBox?
    let status: Status
    let units: UnitSystem
    let isReady: Bool
    var onAdjust: (_ axis: Int, _ delta: Float) -> Void
    var onFitAgain: () -> Void
    var onStart: () -> Void

    /// One tap = 1 cm (about 3/8"): fine enough to hug an object, quick enough to grow a box.
    static let step: Float = 0.01

    var body: some View {
        VStack(spacing: 10) {
            statusLine
            if let box {
                HStack(spacing: 8) {
                    axis("Width", box.size.x, index: 0, id: "width")
                    axis("Depth", box.size.z, index: 2, id: "depth")
                    axis("Height", box.size.y, index: 1, id: "height")
                }
                .accessibilityIdentifier("boxSize")
            }
            HStack(spacing: 10) {
                Button(action: onFitAgain) {
                    Label("Fit again", systemImage: "viewfinder")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .buttonStyle(BigButtonStyle(filled: false, color: .white))
                .frame(maxWidth: 150)
                .accessibilityIdentifier("fitAgainButton")
                ReadyStartButton(isReady: isReady && box != nil, title: "Start scan", action: onStart)
            }
        }
        .padding(14)
        .frame(maxWidth: 460)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("objectPlacementPanel")
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            Text(statusText)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let box {
                let voxel = TSDFVolume.Configuration.object(for: box).voxelSize
                Text("\(Int((voxel * 1000).rounded())) mm detail")
                    .font(.caption.weight(.heavy))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(CoachColors.good.opacity(0.85), in: Capsule())
                    .accessibilityIdentifier("voxelChip")
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
    }

    private var statusText: String {
        switch status {
        case .searching: return "Aim the cross at the object"
        case .fitted(true): return "Object boxed on the table"
        case .fitted(false): return "No table found: box around the aim point"
        case .adjusted: return "Box adjusted (Fit again resets it)"
        }
    }

    private var statusIcon: String {
        switch status {
        case .searching: return "scope"
        case .fitted: return "cube.transparent"
        case .adjusted: return "slider.horizontal.3"
        }
    }

    private var statusColor: Color {
        switch status {
        case .searching: return CoachColors.info
        case .fitted(true), .adjusted: return CoachColors.good
        case .fitted(false): return CoachColors.warn
        }
    }

    private func axis(_ label: String, _ value: Float, index: Int, id: String) -> some View {
        VStack(spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.white.opacity(0.7))
            Text(UnitFormatter.objectLength(Double(value), units))
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: 6) {
                stepButton("minus", id: "boxMinus-\(id)") { onAdjust(index, -Self.step) }
                stepButton("plus", id: "boxPlus-\(id)") { onAdjust(index, Self.step) }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func stepButton(_ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(Color.white.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// A box edge projected into an image, in normalized coordinates (0...1 of width and height).
struct BoxSegment: Hashable, Sendable {
    var a: CGPoint
    var b: CGPoint
}

/// 2D wireframe of the object box over a camera image that fills the view (Simulator previews; the
/// AR screen draws the box in 3D).
struct BoxWireframeOverlay: View {
    let segments: [BoxSegment]
    var color: Color = .yellow

    var body: some View {
        Canvas { context, size in
            func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
            var path = Path()
            for s in segments {
                path.move(to: pt(s.a))
                path.addLine(to: pt(s.b))
            }
            context.stroke(path, with: .color(.black.opacity(0.45)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            for s in segments {
                for p in [pt(s.a), pt(s.b)] {
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)), with: .color(color))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier("boxWireframe")
    }

    /// Projects `box` into the image of a pinhole camera (normalized image coordinates).
    static func segments(box: ObjectBox, cameraToWorld: simd_float4x4, intrinsics K: PinholeIntrinsics) -> [BoxSegment] {
        let worldToCamera = cameraToWorld.inverse
        func project(_ p: SIMD3<Float>) -> CGPoint? {
            let c = worldToCamera * SIMD4(p, 1)
            guard let uv = K.project(SIMD3(c.x, c.y, c.z)) else { return nil }
            return CGPoint(x: CGFloat(uv.x) / CGFloat(K.width), y: CGFloat(uv.y) / CGFloat(K.height))
        }
        return box.visibleEdges(cameraToWorld: cameraToWorld).compactMap { a, b in
            guard let pa = project(a), let pb = project(b) else { return nil }
            return BoxSegment(a: pa, b: pb)
        }
    }
}
