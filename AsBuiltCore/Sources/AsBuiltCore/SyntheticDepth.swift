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

    /// Signed distance to the union of all parts.
    public func distance(_ p: SIMD3<Float>) -> Float {
        parts.reduce(Float.greatestFiniteMagnitude) { min($0, Self.distance($1.shape, p)) }
    }

    /// Nearest ray parameter t > tMin where the ray o + t d (d unit) enters `shape`, or infinity.
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
            var tNear = -Float.greatestFiniteMagnitude, tFar = Float.greatestFiniteMagnitude
            let o = [ox - c.x, oy - c.y, oz - c.z], d = [dx, dy, dz], ext = [e.x, e.y, e.z]
            for k in 0..<3 {
                if abs(d[k]) < 1e-12 {
                    if abs(o[k]) > ext[k] { return .infinity }
                    continue
                }
                var ta = (-ext[k] - o[k]) / d[k], tb = (ext[k] - o[k]) / d[k]
                if ta > tb { swap(&ta, &tb) }
                tNear = max(tNear, ta)
                tFar = min(tFar, tb)
                if tNear > tFar { return .infinity }
            }
            if tNear > tMin { return tNear }
            return tFar > tMin ? tFar : .infinity
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
                    for t in [(-qb - sq) / (2 * qa), (-qb + sq) / (2 * qa)] where t > tMin && t < best {
                        let s = ld + t * dd
                        if s >= 0 && s <= height { best = t }
                    }
                }
            }
            // Caps.
            if abs(dd) > 1e-12 {
                for capS in [Float(0), height] {
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
                for (k, shape) in shapes.enumerated() {
                    let t = Self.intersect(shape, ox: ox, oy: oy, oz: oz, dx: dx, dy: dy, dz: dz, tMin: 0.01)
                    if t < best {
                        best = t
                        hit = k
                    }
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

/// The demo job's "Detail scan": a utility corner on a plywood backboard (a 4" square electrical box
/// with a conduit, and a copper supply line with a ball valve), rendered into 256x192 LiDAR-like depth
/// maps from 3 height bands around the front and actually fused with `TSDFVolume` at 4 mm.
public enum DemoDetailScan {
    public static let depthIntrinsics = PinholeIntrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440)
        .scaled(toWidth: 256, height: 192)

    public static func scene() -> AnalyticScene {
        let inch: Float = 0.0254
        let plywood = SIMD3<UInt8>(196, 160, 110)
        let steel = SIMD3<UInt8>(150, 156, 162)
        let conduit = SIMD3<UInt8>(185, 190, 195)
        let copper = SIMD3<UInt8>(184, 104, 58)
        let brass = SIMD3<UInt8>(205, 170, 70)
        let red = SIMD3<UInt8>(200, 40, 35)
        let white = SIMD3<UInt8>(235, 232, 225)
        let backZ: Float = -0.10
        let pipeZ = backZ + 0.035
        return AnalyticScene(parts: [
            // Backboard (3/4" plywood), 50 x 36 cm.
            .init(.box(center: SIMD3(0, 0.18, backZ - 0.0095), halfExtents: SIMD3(0.25, 0.18, 0.0095)), color: plywood),
            // 4" square electrical box, 2-1/8" deep, with a cover plate and a duplex receptacle.
            .init(.box(center: SIMD3(-0.10, 0.17, backZ + 1.0625 * inch), halfExtents: SIMD3(2 * inch, 2 * inch, 1.0625 * inch)), color: steel),
            .init(.box(center: SIMD3(-0.10, 0.17, backZ + 2.125 * inch + 0.002), halfExtents: SIMD3(2.1 * inch, 2.1 * inch, 0.002)), color: steel),
            .init(.box(center: SIMD3(-0.10, 0.17, backZ + 2.125 * inch + 0.008), halfExtents: SIMD3(0.017, 0.033, 0.005)), color: white),
            // 3/4" EMT conduit up out of the box, with a compression coupling.
            .init(.cylinder(a: SIMD3(-0.10, 0.17 + 2 * inch, backZ + 0.03), b: SIMD3(-0.10, 0.36, backZ + 0.03), radius: 0.0118), color: conduit),
            .init(.cylinder(a: SIMD3(-0.10, 0.27, backZ + 0.03), b: SIMD3(-0.10, 0.30, backZ + 0.03), radius: 0.0145), color: conduit),
            // 3/4" copper supply line with a ball valve, its stem and a red lever handle.
            .init(.cylinder(a: SIMD3(0.0, 0.10, pipeZ), b: SIMD3(0.25, 0.10, pipeZ), radius: 0.0111), color: copper),
            .init(.sphere(center: SIMD3(0.12, 0.10, pipeZ), radius: 0.024), color: brass),
            .init(.cylinder(a: SIMD3(0.09, 0.10, pipeZ), b: SIMD3(0.15, 0.10, pipeZ), radius: 0.017), color: brass),
            .init(.cylinder(a: SIMD3(0.12, 0.10, pipeZ), b: SIMD3(0.12, 0.145, pipeZ), radius: 0.006), color: brass),
            .init(.box(center: SIMD3(0.155, 0.15, pipeZ), halfExtents: SIMD3(0.045, 0.006, 0.004)), color: red),
            // Pipe strap (a short wide band around the pipe).
            .init(.cylinder(a: SIMD3(0.205, 0.10, pipeZ), b: SIMD3(0.215, 0.10, pipeZ), radius: 0.0138), color: steel),
        ])
    }

    /// World bounds of the demo object (fusion is limited to it, like the app's scan box).
    public static let bounds: (min: SIMD3<Float>, max: SIMD3<Float>) = (SIMD3(-0.27, -0.02, -0.13), SIMD3(0.27, 0.38, 0.06))

    /// Camera poses: 3 height bands (low, mid, high) of `perBand` views across the front, 0.45 m away.
    public static func poses(perBand: Int = 6) -> [simd_float4x4] {
        AnalyticScene.orbitPoses(target: SIMD3(0.0, 0.17, -0.07), distance: 0.45, count: perBand,
                                 elevationsDegrees: [-20, 5, 30], azimuthRangeDegrees: -55...55)
    }

    /// Fuses the demo object and returns the extracted, colored mesh (world space).
    public static func fuse(perBand: Int = 6, voxelSize: Float = 0.004, noise: Float = 0.0015,
                            progress: ((Double) -> Void)? = nil) -> (mesh: FusedMesh, stats: TSDFVolume.Stats) {
        var config = TSDFVolume.Configuration.detail
        config.voxelSize = voxelSize
        let volume = TSDFVolume(configuration: config)
        let scene = scene()
        let K = depthIntrinsics
        let poses = poses(perBand: perBand)
        for (k, pose) in poses.enumerated() {
            let frame = scene.render(intrinsics: K, cameraToWorld: pose, maxDistance: 1.2, noise: noise, seed: UInt64(k + 1), withColor: true)
            let color = ColorImage(width: K.width, height: K.height, rgb: frame.rgb, intrinsics: K)
            volume.integrate(DepthFrame(width: K.width, height: K.height, depth: frame.depth, intrinsics: K,
                                        cameraToWorld: pose, color: color), bounds: bounds)
            progress?(0.8 * Double(k + 1) / Double(poses.count))
        }
        let mesh = volume.extractMesh(minWeight: 2) { progress?(0.8 + 0.2 * $0) }
        return (mesh, volume.stats)
    }
}
