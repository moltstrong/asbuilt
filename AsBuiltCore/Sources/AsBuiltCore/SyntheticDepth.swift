import Foundation
import simd

/// Analytic scenes rendered into ARKit-style depth maps, for TSDF tests and the demo Detail scan.
///
/// Rays are intersected analytically (sphere, axis-aligned box, capped cylinder, plane) from each
/// depth pixel center with the same conventions as `PinholeIntrinsics` (camera looks down -Z, image
/// v down); the renderer writes the depth along the optical axis, like `ARFrame.sceneDepth`.
/// Scalar math only, so it is fast enough in unoptimized (Debug / Simulator) builds.
public struct AnalyticScene: Sendable {
    public enum Shape: Sendable {
        case sphere(center: SIMD3<Float>, radius: Float)
        /// Axis-aligned box.
        case box(center: SIMD3<Float>, halfExtents: SIMD3<Float>)
        /// Box turned about +Y by `yaw` radians (`ObjectBox` convention).
        case orientedBox(center: SIMD3<Float>, halfExtents: SIMD3<Float>, yaw: Float)
        /// Capped cylinder between two points.
        case cylinder(a: SIMD3<Float>, b: SIMD3<Float>, radius: Float)
        /// Infinite plane through `point` with unit `normal` (solid behind it).
        case plane(point: SIMD3<Float>, normal: SIMD3<Float>)
    }

    public struct Part: Sendable {
        public var shape: Shape
        public var color: SIMD3<UInt8>

        public init(_ shape: Shape, color: SIMD3<UInt8>) {
            self.shape = shape
            self.color = color
        }
    }

    public var parts: [Part]

    public init(parts: [Part]) {
        self.parts = parts
    }

    /// Exact signed distance to one shape (tests measure fused-surface error with it).
    public static func distance(_ shape: Shape, _ p: SIMD3<Float>) -> Float {
        switch shape {
        case let .sphere(c, r):
            return simd_length(p - c) - r
        case let .box(c, e):
            let q = abs(p - c) - e
            let outside = simd_length(simd_max(q, SIMD3(repeating: 0)))
            return outside + min(max(q.x, max(q.y, q.z)), 0)
        case let .orientedBox(c, e, yaw):
            return distance(.box(center: .zero, halfExtents: e), ObjectBox(center: c, halfExtents: e, yaw: yaw).local(p))
        case let .cylinder(a, b, r):
            let axisVector = b - a
            let height = simd_length(axisVector)
            let axis = axisVector / height
            let t = simd_dot(p - a, axis)
            let radial = simd_length(p - a - axis * t) - r
            let along = abs(t - height / 2) - height / 2
            let outside = simd_length(simd_max(SIMD2(radial, along), SIMD2(repeating: 0)))
            return outside + min(max(radial, along), 0)
        case let .plane(point, n):
            return simd_dot(p - point, n)
        }
    }

    /// Center and radius (w) of a sphere enclosing the shape; radius 0 = unbounded (plane).
    static func boundingSphere(_ shape: Shape) -> SIMD4<Float> {
        switch shape {
        case let .sphere(c, r): return SIMD4(c, r)
        case let .box(c, e): return SIMD4(c, simd_length(e) * 1.001)
        case let .orientedBox(c, e, _): return SIMD4(c, simd_length(e) * 1.001)
        case let .cylinder(a, b, r):
            let half = simd_length(b - a) / 2
            return SIMD4((a + b) / 2, (half * half + r * r).squareRoot() * 1.001)
        case .plane: return SIMD4(0, 0, 0, 0)
        }
    }

    /// Signed distance to the union of all parts.
    public func distance(_ p: SIMD3<Float>) -> Float {
        parts.reduce(Float.greatestFiniteMagnitude) { min($0, Self.distance($1.shape, p)) }
    }

    /// Nearest ray parameter t > tMin where the ray o + t d (d unit) enters `shape`, or infinity.
    @_optimize(speed)
    static func intersect(_ shape: Shape, ox: Float, oy: Float, oz: Float, dx: Float, dy: Float, dz: Float, tMin: Float) -> Float {
        switch shape {
        case let .sphere(c, r):
            let lx = ox - c.x, ly = oy - c.y, lz = oz - c.z
            let b = lx * dx + ly * dy + lz * dz
            let cc = lx * lx + ly * ly + lz * lz - r * r
            let disc = b * b - cc
            if disc < 0 { return .infinity }
            let sq = disc.squareRoot()
            let t0 = -b - sq
            if t0 > tMin { return t0 }
            let t1 = -b + sq
            return t1 > tMin ? t1 : .infinity
        case let .box(c, e):
            // Slab test without temporaries (fast in unoptimized builds).
            var tNear = -Float.greatestFiniteMagnitude, tFar = Float.greatestFiniteMagnitude
            let o0 = ox - c.x, o1 = oy - c.y, o2 = oz - c.z
            for k in 0..<3 {
                let o = k == 0 ? o0 : (k == 1 ? o1 : o2)
                let d = k == 0 ? dx : (k == 1 ? dy : dz)
                let ext = k == 0 ? e.x : (k == 1 ? e.y : e.z)
                if abs(d) < 1e-12 {
                    if abs(o) > ext { return .infinity }
                    continue
                }
                var ta = (-ext - o) / d, tb = (ext - o) / d
                if ta > tb { swap(&ta, &tb) }
                tNear = max(tNear, ta)
                tFar = min(tFar, tb)
                if tNear > tFar { return .infinity }
            }
            if tNear > tMin { return tNear }
            return tFar > tMin ? tFar : .infinity
        case let .orientedBox(c, e, yaw):
            // Into box coordinates (rotation about +Y), then the axis-aligned slab test.
            let cs = cos(yaw), sn = sin(yaw)
            let lx = ox - c.x, lz = oz - c.z
            return intersect(.box(center: .zero, halfExtents: e),
                             ox: cs * lx + sn * lz, oy: oy - c.y, oz: -sn * lx + cs * lz,
                             dx: cs * dx + sn * dz, dy: dy, dz: -sn * dx + cs * dz, tMin: tMin)
        case let .cylinder(a, b, r):
            let axx = b.x - a.x, axy = b.y - a.y, axz = b.z - a.z
            let height = (axx * axx + axy * axy + axz * axz).squareRoot()
            let ux = axx / height, uy = axy / height, uz = axz / height
            let lx = ox - a.x, ly = oy - a.y, lz = oz - a.z
            let dd = dx * ux + dy * uy + dz * uz
            let ld = lx * ux + ly * uy + lz * uz
            // Perpendicular components.
            let px = dx - ux * dd, py = dy - uy * dd, pz = dz - uz * dd
            let qx = lx - ux * ld, qy = ly - uy * ld, qz = lz - uz * ld
            let qa = px * px + py * py + pz * pz
            let qb = 2 * (px * qx + py * qy + pz * qz)
            let qc = qx * qx + qy * qy + qz * qz - r * r
            var best = Float.infinity
            if qa > 1e-12 {
                let disc = qb * qb - 4 * qa * qc
                if disc >= 0 {
                    let sq = disc.squareRoot()
                    for root in 0..<2 {
                        let t = root == 0 ? (-qb - sq) / (2 * qa) : (-qb + sq) / (2 * qa)
                        guard t > tMin && t < best else { continue }
                        let s = ld + t * dd
                        if s >= 0 && s <= height { best = t }
                    }
                }
            }
            // Caps.
            if abs(dd) > 1e-12 {
                for cap in 0..<2 {
                    let capS: Float = cap == 0 ? 0 : height
                    let t = (capS - ld) / dd
                    if t > tMin && t < best {
                        let hx = qx + px * t, hy = qy + py * t, hz = qz + pz * t
                        if hx * hx + hy * hy + hz * hz <= r * r { best = t }
                    }
                }
            }
            return best
        case let .plane(point, n):
            let denom = dx * n.x + dy * n.y + dz * n.z
            if abs(denom) < 1e-12 { return .infinity }
            let t = ((point.x - ox) * n.x + (point.y - oy) * n.y + (point.z - oz) * n.z) / denom
            return t > tMin ? t : .infinity
        }
    }

    /// Renders a depth map (meters along the optical axis, 0 = miss) and optionally an RGB image of the
    /// same size, from `cameraToWorld` with intrinsics `K`. `noise` adds deterministic Gaussian depth
    /// noise with that standard deviation (meters), seeded by `seed`.
    @_optimize(speed)
    public func render(intrinsics K: PinholeIntrinsics, cameraToWorld T: simd_float4x4, maxDistance: Float = 4,
                       noise: Float = 0, seed: UInt64 = 1, withColor: Bool = false) -> (depth: [Float], rgb: [UInt8]) {
        let w = K.width, h = K.height
        var depth = [Float](repeating: 0, count: w * h)
        var rgb = withColor ? [UInt8](repeating: 0, count: w * h * 3) : []
        let r00 = T.columns.0.x, r01 = T.columns.0.y, r02 = T.columns.0.z
        let r10 = T.columns.1.x, r11 = T.columns.1.y, r12 = T.columns.1.z
        let r20 = T.columns.2.x, r21 = T.columns.2.y, r22 = T.columns.2.z
        let ox = T.columns.3.x, oy = T.columns.3.y, oz = T.columns.3.z
        let shapes = parts.map(\.shape)
        // Bounding spheres: most rays miss most parts, so skip the exact test for those.
        let bounds = shapes.map(Self.boundingSphere)
        let n = shapes.count
        var rng = SplitMix64(seed: seed)
        for j in 0..<h {
            for i in 0..<w {
                let xn = (Float(i) + 0.5 - K.cx) / K.fx
                let yn = -(Float(j) + 0.5 - K.cy) / K.fy
                let len = (xn * xn + yn * yn + 1).squareRoot()
                let dx = (r00 * xn + r10 * yn - r20) / len
                let dy = (r01 * xn + r11 * yn - r21) / len
                let dz = (r02 * xn + r12 * yn - r22) / len
                var best = maxDistance
                var hit = -1
                var k = 0
                while k < n {
                    let b = bounds[k]
                    if b.w > 0 {
                        // Ray-sphere reject: closest approach farther than the radius, or behind / beyond best.
                        let lx = b.x - ox, ly = b.y - oy, lz = b.z - oz
                        let along = lx * dx + ly * dy + lz * dz
                        let d2 = lx * lx + ly * ly + lz * lz - along * along
                        if d2 > b.w * b.w || along + b.w < 0 || along - b.w > best {
                            k += 1
                            continue
                        }
                    }
                    let t = Self.intersect(shapes[k], ox: ox, oy: oy, oz: oz, dx: dx, dy: dy, dz: dz, tMin: 0.01)
                    if t < best {
                        best = t
                        hit = k
                    }
                    k += 1
                }
                guard hit >= 0 else { continue }
                var z = best / len // depth along the optical axis
                if noise > 0 { z += Float(rng.nextGaussian()) * noise }
                depth[j * w + i] = z
                if withColor {
                    let c = parts[hit].color
                    // A little deterministic texture so color fusion has something to average.
                    let px = ox + dx * best, py = oy + dy * best
                    let shade = 0.88 + 0.12 * sin(px * 150) * sin(py * 150)
                    let k = (j * w + i) * 3
                    rgb[k] = UInt8(max(0, min(255, Float(c.x) * shade)))
                    rgb[k + 1] = UInt8(max(0, min(255, Float(c.y) * shade)))
                    rgb[k + 2] = UInt8(max(0, min(255, Float(c.z) * shade)))
                }
            }
        }
        return (depth, rgb)
    }

    /// Camera poses on rings around `target`: `count` azimuths per ring at each elevation (degrees),
    /// all at `distance`, looking at the target. Deterministic.
    public static func orbitPoses(target: SIMD3<Float>, distance: Float, count: Int, elevationsDegrees: [Float],
                                  azimuthRangeDegrees: ClosedRange<Float> = 0...360) -> [simd_float4x4] {
        var poses: [simd_float4x4] = []
        let full = azimuthRangeDegrees.upperBound - azimuthRangeDegrees.lowerBound >= 359.9
        for elevation in elevationsDegrees {
            for k in 0..<count {
                let f = full ? Float(k) / Float(count) : Float(k) / Float(max(1, count - 1))
                let az = (azimuthRangeDegrees.lowerBound + f * (azimuthRangeDegrees.upperBound - azimuthRangeDegrees.lowerBound)) * .pi / 180
                let el = elevation * .pi / 180
                let eye = target + SIMD3(cos(el) * sin(az), sin(el), cos(el) * cos(az)) * distance
                poses.append(RigidTransform.lookAt(eye: eye, target: target))
            }
        }
        return poses
    }
}

/// Deterministic PRNG (SplitMix64) with a Box-Muller Gaussian.
public struct SplitMix64: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in (0, 1).
    public mutating func nextUnit() -> Double {
        (Double(next() >> 11) + 0.5) / Double(1 << 53)
    }

    public mutating func nextGaussian() -> Double {
        let u1 = nextUnit(), u2 = nextUnit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// The demo job's object Detail scan: a 3/4" brass ball valve with copper pipe stubs and a red lever,
/// lying on a tabletop next to a coffee mug and a tape measure (clutter), with the floor below.
/// Rendered into 256x192 LiDAR-like depth maps and run through the real object pipeline: box fit
/// from one placement view, TSDF fusion inside the box at the box's voxel size, then crop, table
/// removal and component cleanup.
public enum DemoDetailScan {
    public static let depthIntrinsics = PinholeIntrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440)
        .scaled(toWidth: 256, height: 192)

    /// Table top height (m) and the valve's yaw on it.
    public static let tableTopY: Float = 0.75
    public static let yaw: Float = 20 * .pi / 180
    /// True size of the valve, W (pipe end to pipe end) x D (ball housing) x H (table to lever top).
    public static let trueSize = SIMD3<Float>(0.250, 0.080, 0.105)
    /// Middle of the valve (orbit target).
    public static let target = SIMD3<Float>(0, tableTopY + 0.05, 0)

    /// Point on the valve's local frame (x along the pipe, y up from the table top, z across).
    static func valvePoint(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
        let c = cos(yaw), s = sin(yaw)
        return SIMD3(c * x - s * z, tableTopY + y, s * x + c * z)
    }

    public static func scene(clutter: Bool = true) -> AnalyticScene {
        let wood = SIMD3<UInt8>(176, 132, 88)
        let floor = SIMD3<UInt8>(120, 116, 110)
        let brass = SIMD3<UInt8>(205, 170, 70)
        let copper = SIMD3<UInt8>(184, 104, 58)
        let steel = SIMD3<UInt8>(150, 156, 162)
        let red = SIMD3<UInt8>(200, 40, 35)
        let mug = SIMD3<UInt8>(40, 90, 160)
        let tape = SIMD3<UInt8>(235, 190, 30)
        let v = valvePoint
        var parts: [AnalyticScene.Part] = [
            // Table top (4 cm thick) and the floor 75 cm below it.
            .init(.box(center: SIMD3(0, tableTopY - 0.02, 0), halfExtents: SIMD3(0.70, 0.02, 0.45)), color: wood),
            .init(.plane(point: SIMD3(0, 0, 0), normal: SIMD3(0, 1, 0)), color: floor),
            // Ball housing (resting on the table), barrel and union ends.
            .init(.sphere(center: v(0, 0.040, 0), radius: 0.040), color: brass),
            .init(.cylinder(a: v(-0.058, 0.040, 0), b: v(0.058, 0.040, 0), radius: 0.030), color: brass),
            .init(.cylinder(a: v(-0.078, 0.040, 0), b: v(-0.056, 0.040, 0), radius: 0.027), color: brass),
            .init(.cylinder(a: v(0.056, 0.040, 0), b: v(0.078, 0.040, 0), radius: 0.027), color: brass),
            // 3/4" copper pipe stubs (OD 22.2 mm).
            .init(.cylinder(a: v(-0.125, 0.040, 0), b: v(-0.076, 0.040, 0), radius: 0.0111), color: copper),
            .init(.cylinder(a: v(0.076, 0.040, 0), b: v(0.125, 0.040, 0), radius: 0.0111), color: copper),
            // Stem, packing nut and the red lever (open: along the pipe).
            .init(.cylinder(a: v(0, 0.075, 0), b: v(0, 0.098, 0), radius: 0.0065), color: steel),
            .init(.cylinder(a: v(0, 0.076, 0), b: v(0, 0.086, 0), radius: 0.0115), color: steel),
            .init(.orientedBox(center: v(0.045, 0.101, 0), halfExtents: SIMD3(0.060, 0.004, 0.011), yaw: yaw), color: red),
        ]
        if clutter {
            // A mug and a tape measure on the same table, a hand's width away.
            parts.append(.init(.cylinder(a: SIMD3(-0.24, tableTopY, -0.20), b: SIMD3(-0.24, tableTopY + 0.095, -0.20), radius: 0.042), color: mug))
            parts.append(.init(.orientedBox(center: SIMD3(0.26, tableTopY + 0.0175, 0.12), halfExtents: SIMD3(0.034, 0.0175, 0.034),
                                            yaw: -0.4), color: tape))
        }
        return AnalyticScene(parts: parts)
    }

    /// Where the user stands to place the box: in front, a little to the side, looking down at 35 deg.
    public static let placementPose = AnalyticScene.orbitPoses(target: target, distance: 0.50, count: 1,
                                                               elevationsDegrees: [35], azimuthRangeDegrees: 25...25)[0]

    /// Scan poses: 3 height bands (10, 30 and 52 deg) of `perBand` views all the way around, 0.42 m away.
    public static func poses(perBand: Int = 12) -> [simd_float4x4] {
        AnalyticScene.orbitPoses(target: target, distance: 0.42, count: perBand, elevationsDegrees: [10, 30, 52])
    }

    /// One synthetic LiDAR frame (1.5 mm depth noise, high confidence).
    public static func frame(pose: simd_float4x4, seed: UInt64, noise: Float = 0.0015, withColor: Bool = true) -> DepthFrame {
        let K = depthIntrinsics
        let r = scene().render(intrinsics: K, cameraToWorld: pose, maxDistance: 2.5, noise: noise, seed: seed, withColor: withColor)
        let color = withColor ? ColorImage(width: K.width, height: K.height, rgb: r.rgb, intrinsics: K) : nil
        return DepthFrame(width: K.width, height: K.height, depth: r.depth, intrinsics: K, cameraToWorld: pose, color: color)
    }

    /// The box the app would fit from the placement view.
    public static func fitBox(noise: Float = 0.0015) -> ObjectBoxFitter.Result? {
        ObjectBoxFitter.fit(frame: frame(pose: placementPose, seed: 99, noise: noise, withColor: false))
    }

    public struct Result: Sendable {
        /// Cleaned object mesh (world space): cropped to the box, table removed, clutter dropped.
        public var mesh: FusedMesh
        public var stats: TSDFVolume.Stats
        public var fit: ObjectBoxFitter.Result
        public var configuration: TSDFVolume.Configuration
        public var margin: Float
        public var cleanup: ObjectMeshCleaner.Report
    }

    /// Volume settings and fusion bounds for the fitted demo box.
    public static func fusionSetup(_ fit: ObjectBoxFitter.Result) -> (configuration: TSDFVolume.Configuration, margin: Float,
                                                                         bounds: (min: SIMD3<Float>, max: SIMD3<Float>)) {
        let configuration = TSDFVolume.Configuration.object(for: fit.box)
        let margin = ObjectScan.margin(voxelSize: configuration.voxelSize)
        return (configuration, margin, fit.box.aabb(margin: margin))
    }

    /// Runs the whole object pipeline on the synthetic orbit. Nil only if the box fit fails.
    public static func fuse(perBand: Int = 12, noise: Float = 0.0015, progress: ((Double) -> Void)? = nil) -> Result? {
        guard let fit = fitBox(noise: noise) else { return nil }
        let setup = fusionSetup(fit)
        let volume = TSDFVolume(configuration: setup.configuration)
        let poses = poses(perBand: perBand)
        for (k, pose) in poses.enumerated() {
            volume.integrate(frame(pose: pose, seed: UInt64(k + 1), noise: noise), bounds: setup.bounds)
            progress?(0.8 * Double(k + 1) / Double(poses.count))
        }
        let raw = volume.extractMesh(minWeight: 3) { progress?(0.8 + 0.15 * $0) }
        let cleaned = ObjectMeshCleaner.clean(raw, box: fit.box, margin: setup.margin, planeY: fit.planeY,
                                              voxelSize: setup.configuration.voxelSize)
        progress?(1)
        return Result(mesh: cleaned.mesh, stats: volume.stats, fit: fit, configuration: setup.configuration,
                      margin: setup.margin, cleanup: cleaned.report)
    }
}
