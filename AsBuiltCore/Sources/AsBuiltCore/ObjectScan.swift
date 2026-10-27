import Foundation
import simd

// MARK: - Object box

/// The Detail scan's target: a gravity-aligned box turned about +Y by `yaw` (world space, meters,
/// ARKit +Y up). Local axes: X = width `(cos yaw, 0, sin yaw)`, Y = up, Z = depth
/// `(-sin yaw, 0, cos yaw)`, i.e. `local(p).x = cos(yaw) dx + sin(yaw) dz` (the rotation
/// `MeshNormalizer` uses, so a box fitted here and a mesh measured there agree on W and D).
public struct ObjectBox: Codable, Hashable, Sendable {
    public var center: SIMD3<Float>
    /// Half sizes along the box's own X (width), Y (height) and Z (depth).
    public var halfExtents: SIMD3<Float>
    /// Rotation about +Y in radians.
    public var yaw: Float

    public init(center: SIMD3<Float>, halfExtents: SIMD3<Float>, yaw: Float = 0) {
        self.center = center
        self.halfExtents = simd_max(halfExtents, SIMD3(repeating: 0.001))
        self.yaw = yaw
    }

    /// A box standing on a surface: `bottomCenter` is the middle of its bottom face.
    public init(bottomCenter: SIMD3<Float>, size: SIMD3<Float>, yaw: Float = 0) {
        self.init(center: bottomCenter + SIMD3(0, size.y / 2, 0), halfExtents: size / 2, yaw: yaw)
    }

    public var size: SIMD3<Float> { halfExtents * 2 }
    public var maxSide: Float { simd_reduce_max(size) }
    public var bottomY: Float { center.y - halfExtents.y }
    public var topY: Float { center.y + halfExtents.y }
    public var axisX: SIMD3<Float> { SIMD3(cos(yaw), 0, sin(yaw)) }
    public var axisZ: SIMD3<Float> { SIMD3(-sin(yaw), 0, cos(yaw)) }

    /// World point -> box coordinates (origin at the center).
    @inline(__always)
    public func local(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let d = p - center
        let c = cos(yaw), s = sin(yaw)
        return SIMD3(c * d.x + s * d.z, d.y, -s * d.x + c * d.z)
    }

    /// Box coordinates -> world point.
    @inline(__always)
    public func world(_ l: SIMD3<Float>) -> SIMD3<Float> {
        let c = cos(yaw), s = sin(yaw)
        return center + SIMD3(c * l.x - s * l.z, l.y, s * l.x + c * l.z)
    }

    public func contains(_ p: SIMD3<Float>, margin: Float = 0) -> Bool {
        let l = abs(local(p))
        let h = halfExtents + margin
        return l.x <= h.x && l.y <= h.y && l.z <= h.z
    }

    public func expanded(by margin: Float) -> ObjectBox {
        ObjectBox(center: center, halfExtents: halfExtents + margin, yaw: yaw)
    }

    /// Corner k: bit 0 = +X, bit 1 = +Y (top), bit 2 = +Z.
    public var corners: [SIMD3<Float>] {
        (0..<8).map { k in
            world(SIMD3(k & 1 == 0 ? -halfExtents.x : halfExtents.x,
                        k & 2 == 0 ? -halfExtents.y : halfExtents.y,
                        k & 4 == 0 ? -halfExtents.z : halfExtents.z))
        }
    }

    /// The 12 edges as corner index pairs (4 along X, 4 along Y, 4 along Z).
    public static let edges: [(Int, Int)] = [(0, 1), (2, 3), (4, 5), (6, 7),
                                             (0, 2), (1, 3), (4, 6), (5, 7),
                                             (0, 4), (1, 5), (2, 6), (3, 7)]

    /// World axis-aligned bounds (for `TSDFVolume.integrate(_:bounds:)`).
    public func aabb(margin: Float = 0) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for c in expanded(by: margin).corners {
            lo = simd_min(lo, c)
            hi = simd_max(hi, c)
        }
        return (lo, hi)
    }

    /// One side (0 = width, 1 = height, 2 = depth) grown or shrunk by `delta` meters in total.
    /// Height changes keep the bottom where it is (the box stays on the table).
    public func resized(axis: Int, by delta: Float, minSide: Float = 0.02, maxSide: Float = 2) -> ObjectBox {
        guard (0...2).contains(axis) else { return self }
        var b = self
        let side = max(minSide, min(maxSide, size[axis] + delta))
        let bottom = bottomY
        b.halfExtents[axis] = side / 2
        if axis == 1 { b.center.y = bottom + side / 2 }
        return b
    }

    /// Uniform scale about the bottom center (pinch).
    public func scaled(by factor: Float, minSide: Float = 0.02, maxSide: Float = 2) -> ObjectBox {
        guard factor.isFinite, factor > 0 else { return self }
        var b = self
        let bottom = bottomY
        b.halfExtents = simd_clamp(halfExtents * factor, SIMD3(repeating: minSide / 2), SIMD3(repeating: maxSide / 2))
        b.center.y = bottom + b.halfExtents.y
        return b
    }

    /// Distance along the ray (unit `direction`) to where it enters the box; 0 when `origin` is inside.
    public func intersect(origin: SIMD3<Float>, direction: SIMD3<Float>) -> Float? {
        let o = local(origin)
        let c = cos(yaw), s = sin(yaw)
        let d = SIMD3(c * direction.x + s * direction.z, direction.y, -s * direction.x + c * direction.z)
        var tNear: Float = 0
        var tFar = Float.greatestFiniteMagnitude
        for k in 0..<3 {
            if abs(d[k]) < 1e-9 {
                if abs(o[k]) > halfExtents[k] { return nil }
                continue
            }
            var ta = (-halfExtents[k] - o[k]) / d[k]
            var tb = (halfExtents[k] - o[k]) / d[k]
            if ta > tb { swap(&ta, &tb) }
            tNear = max(tNear, ta)
            tFar = min(tFar, tb)
            if tNear > tFar { return nil }
        }
        return tNear
    }

    /// Distance from `p` to the box (0 inside).
    public func distance(to p: SIMD3<Float>) -> Float {
        let q = abs(local(p)) - halfExtents
        return simd_length(simd_max(q, SIMD3(repeating: 0)))
    }

    /// The same box in space, described with a yaw within 45 degrees of `reference.yaw` (a box turned by
    /// 180 degrees is itself; turned by 90 degrees it swaps width and depth). Lets successive fits of a
    /// square-ish object be compared and blended without the axes flipping.
    public func reoriented(near reference: ObjectBox) -> ObjectBox {
        var b = self
        var d = yaw - reference.yaw
        while d > .pi / 2 { d -= .pi; b.yaw -= .pi }
        while d <= -.pi / 2 { d += .pi; b.yaw += .pi }
        if d > .pi / 4 {
            b.yaw -= .pi / 2
            b.halfExtents = SIMD3(halfExtents.z, halfExtents.y, halfExtents.x)
        } else if d < -.pi / 4 {
            b.yaw += .pi / 2
            b.halfExtents = SIMD3(halfExtents.z, halfExtents.y, halfExtents.x)
        }
        return b
    }

    /// Moves `weight` (0...1) of the way toward `other` (center, size and yaw), for a box that settles
    /// over successive fits instead of jumping.
    public func blended(toward other: ObjectBox, weight: Float) -> ObjectBox {
        let w = max(0, min(1, weight))
        let o = other.reoriented(near: self)
        return ObjectBox(center: center + (o.center - center) * w, halfExtents: halfExtents + (o.halfExtents - halfExtents) * w,
                         yaw: yaw + (o.yaw - yaw) * w)
    }

    /// The 12 edges clipped to the half-space at least `near` meters in front of the camera, in world
    /// space (the live wireframe overlay projects these). Edges entirely behind it are dropped.
    public func visibleEdges(cameraToWorld: simd_float4x4, near: Float = 0.05) -> [(SIMD3<Float>, SIMD3<Float>)] {
        let eye = RigidTransform.translation(cameraToWorld)
        let forward = RigidTransform.forward(cameraToWorld)
        let cs = corners
        var out: [(SIMD3<Float>, SIMD3<Float>)] = []
        for (i, j) in Self.edges {
            var a = cs[i], b = cs[j]
            let da = simd_dot(a - eye, forward) - near
            let db = simd_dot(b - eye, forward) - near
            if da < 0 && db < 0 { continue }
            if da < 0 {
                a += (b - a) * (da / (da - db))
            } else if db < 0 {
                b += (a - b) * (db / (db - da))
            }
            out.append((a, b))
        }
        return out
    }
}

// MARK: - Depth points

/// A depth-map sample in world space with a normal estimated from neighboring depth pixels.
public struct ScenePoint: Sendable, Hashable {
    public var position: SIMD3<Float>
    /// Unit world normal facing the camera, or zero when the neighbors could not give one.
    public var normal: SIMD3<Float>

    public init(position: SIMD3<Float>, normal: SIMD3<Float> = .zero) {
        self.position = position
        self.normal = normal
    }
}

// MARK: - Box fit

/// Finds the object in front of the camera and fits an `ObjectBox` around it. Pure math on one depth
/// frame (no ARKit types), deterministic:
///
/// 1. **Support plane**: horizontal peaks of upward-facing depth points near the aim point. A peak only
///    counts when there are object points above it; ARKit's horizontal plane heights are tried first.
/// 2. **Object points**: above the plane (clearance), below `maxHeight`, within `searchRadius` of the
///    aim point and closer than `maxDepth` (far background ignored).
/// 3. **Component**: 3D flood fill on a coarse grid from the cell nearest the aim point, so clutter
///    beside the object (a mug, a tape) is left out.
/// 4. **Box**: yaw from the minimum-area rectangle of the footprint, extents from robust percentiles,
///    bottom on the plane. The side the camera cannot see is mirrored about the object's top (valves,
///    pumps and boxes are roughly symmetric about their highest part), never by more than 60 %.
///
/// No plane (object held in the hand, irregular surface): the box goes around the depth blob at the
/// aim point instead.
public enum ObjectBoxFitter {
    public struct Settings: Sendable, Hashable {
        public var minDepth: Float = 0.1
        public var maxDepth: Float = 1.3
        /// Every n-th depth pixel is used (256 x 192 / 2 = 128 x 96 points).
        public var stride: Int = 2
        public var minConfidence: UInt8 = 1
        /// Points closer than this above the plane are the plane itself (LiDAR noise is a few mm).
        public var clearance: Float = 0.008
        public var maxHeight: Float = 1.0
        /// Horizontal radius around the aim point that may hold the object or its support plane.
        public var searchRadius: Float = 0.6
        /// Flood-fill grid cell (m) when the point spacing is unknown; otherwise 3 point spacings
        /// (clamped to 12-30 mm), so thin parts (a valve stem under its lever) stay connected.
        public var cellSize: Float = 0.015
        /// Largest growth of the hidden side, as a fraction of the visible size along that axis.
        public var maxHiddenExtension: Float = 0.6
        public var minSide: Float = 0.02
        public var maxSide: Float = 1.2

        public init() {}
    }

    public struct Result: Sendable, Hashable {
        public var box: ObjectBox
        /// Support plane height, or nil (object held or on an irregular surface).
        public var planeY: Float?
        /// Depth points that made up the object.
        public var objectPoints: Int
        /// World point at the screen center (where the user aimed).
        public var aimPoint: SIMD3<Float>
    }

    /// Unprojects every `stride`-th valid depth pixel to world space, with normals from the pixels
    /// `normalBaseline` away (pixel pairs across depth jumps get no normal).
    public static func points(from frame: DepthFrame, stride: Int = 2, minDepth: Float = 0.1, maxDepth: Float = 1.3,
                              minConfidence: UInt8 = 1, normalBaseline: Int = 3) -> [ScenePoint] {
        let w = frame.width, h = frame.height
        guard w > 2, h > 2, frame.depth.count >= w * h else { return [] }
        let K = frame.intrinsics
        guard K.fx.isFinite, K.fy.isFinite, abs(K.fx) > 1e-6, abs(K.fy) > 1e-6 else { return [] }
        let T = frame.cameraToWorld
        let R = simd_float3x3(SIMD3(T.columns.0.x, T.columns.0.y, T.columns.0.z),
                              SIMD3(T.columns.1.x, T.columns.1.y, T.columns.1.z),
                              SIMD3(T.columns.2.x, T.columns.2.y, T.columns.2.z))
        let t = SIMD3(T.columns.3.x, T.columns.3.y, T.columns.3.z)
        guard t.x.isFinite, t.y.isFinite, t.z.isFinite else { return [] }
        let conf = frame.confidence.flatMap { $0.count >= w * h ? $0 : nil }
        let step = max(1, stride)
        let nb = max(1, normalBaseline)
        func valid(_ i: Int, _ j: Int) -> Float? {
            let d = frame.depth[j * w + i]
            guard d.isFinite, d >= minDepth, d <= maxDepth else { return nil }
            if let conf, conf[j * w + i] < minConfidence { return nil }
            return d
        }
        var out: [ScenePoint] = []
        out.reserveCapacity((w / step) * (h / step))
        var j = step / 2
        while j < h {
            var i = step / 2
            while i < w {
                if let d = valid(i, j) {
                    let p = K.unproject(i: i, j: j, depth: d)
                    var n = SIMD3<Float>.zero
                    let i2 = i + nb < w ? i + nb : i - nb
                    let j2 = j + nb < h ? j + nb : j - nb
                    if i2 >= 0, j2 >= 0, let dx = valid(i2, j), let dy = valid(i, j2),
                       abs(dx - d) < 0.03 + 0.05 * d, abs(dy - d) < 0.03 + 0.05 * d {
                        let px = K.unproject(i: i2, j: j, depth: dx)
                        let py = K.unproject(i: i, j: j2, depth: dy)
                        var c = simd_cross(px - p, py - p)
                        let len = simd_length(c)
                        if len > 1e-12 {
                            c /= len
                            if simd_dot(c, -p) < 0 { c = -c }
                            n = R * c
                        }
                    }
                    out.append(ScenePoint(position: R * p + t, normal: n))
                }
                i += step
            }
            j += step
        }
        return out
    }

    /// World point at the screen center: the median depth of the central ~10 % of the depth map along
    /// the optical axis. Nil when the center has too little valid depth.
    public static func aimPoint(in frame: DepthFrame, minDepth: Float = 0.1, maxDepth: Float = 1.3) -> SIMD3<Float>? {
        let w = frame.width, h = frame.height
        guard w > 8, h > 8, frame.depth.count >= w * h else { return nil }
        var values: [Float] = []
        let i0 = w * 9 / 20, i1 = w * 11 / 20, j0 = h * 9 / 20, j1 = h * 11 / 20
        for j in j0...j1 {
            for i in i0...i1 {
                let d = frame.depth[j * w + i]
                if d.isFinite, d >= minDepth, d <= maxDepth { values.append(d) }
            }
        }
        guard values.count >= 8 else { return nil }
        values.sort()
        let d = values[values.count / 2]
        let K = frame.intrinsics
        let p = K.unproject(u: K.cx, v: K.cy, depth: d)
        let world = frame.cameraToWorld * SIMD4(p, 1)
        return SIMD3(world.x, world.y, world.z)
    }

    /// Fits a box to the object at the center of `frame`. `planeCandidates`: heights (world y) of
    /// ARKit's horizontal planes, tried before the depth-only estimate.
    public static func fit(frame: DepthFrame, planeCandidates: [Float] = [], settings: Settings = Settings()) -> Result? {
        guard let aim = aimPoint(in: frame, minDepth: settings.minDepth, maxDepth: settings.maxDepth) else { return nil }
        let pts = points(from: frame, stride: settings.stride, minDepth: settings.minDepth, maxDepth: settings.maxDepth,
                         minConfidence: settings.minConfidence)
        let eye = RigidTransform.translation(frame.cameraToWorld)
        var s = settings
        // Grid cell from the sampling density at the aim distance.
        let spacing = Float(max(1, settings.stride)) * simd_distance(aim, eye) / max(1, abs(frame.intrinsics.fx))
        s.cellSize = min(0.03, max(0.012, 3 * spacing))
        return fit(points: pts, aim: aim, cameraPosition: eye, planeCandidates: planeCandidates, settings: s)
    }

    /// Height of the horizontal surface the object at `aim` stands on, or nil.
    public static func supportPlane(points: [ScenePoint], aim: SIMD3<Float>, candidates: [Float] = [],
                                    settings: Settings = Settings()) -> Float? {
        let r2 = settings.searchRadius * settings.searchRadius
        var near: [SIMD3<Float>] = []
        var up: [Float] = []
        for p in points {
            let dx = p.position.x - aim.x, dz = p.position.z - aim.z
            guard dx * dx + dz * dz <= r2 else { continue }
            near.append(p.position)
            if p.normal.y > 0.8 { up.append(p.position.y) }
        }
        guard up.count >= 20 else { return nil }
        let minSupport = max(30, near.count / 50)
        let band: Float = 0.008
        // Object points above a candidate height, close to the aim point (the thing being scanned).
        let objectR2: Float = 0.3 * 0.3
        let nearAim = near.filter { p in
            let dx = p.x - aim.x, dz = p.z - aim.z
            return dx * dx + dz * dz <= objectR2
        }
        func refined(_ y: Float) -> (y: Float, support: Int) {
            var inBand = up.filter { abs($0 - y) <= band }
            guard !inBand.isEmpty else { return (y, 0) }
            inBand.sort()
            return (inBand[inBand.count / 2], inBand.count)
        }
        func objectAbove(_ y: Float) -> Int {
            nearAim.reduce(0) { $0 + ($1.y > y + settings.clearance + 0.004 && $1.y < y + settings.maxHeight ? 1 : 0) }
        }
        let minAbove = 25
        // 1. ARKit plane heights: the highest one that is backed by depth points and has the object on it.
        for y in candidates.sorted(by: >) where y.isFinite && y <= aim.y + 0.01 {
            let r = refined(y)
            if r.support >= minSupport, objectAbove(r.y) >= minAbove { return r.y }
        }
        // 2. Peaks of a 4 mm height histogram of upward-facing points.
        guard let lo = up.min(), let hi = up.max(), hi > lo else {
            let r = refined(up[0])
            return r.support >= minSupport && objectAbove(r.y) >= minAbove ? r.y : nil
        }
        let bin: Float = 0.004
        let n = min(4000, Int((hi - lo) / bin) + 1)
        var hist = [Int](repeating: 0, count: n)
        for y in up { hist[min(n - 1, Int((y - lo) / bin))] += 1 }
        // 3-bin smoothed counts; a peak is a local maximum (first of a plateau).
        var smooth = [Int](repeating: 0, count: n)
        for k in 0..<n {
            var sum = hist[k]
            if k > 0 { sum += hist[k - 1] }
            if k + 1 < n { sum += hist[k + 1] }
            smooth[k] = sum
        }
        var peaks: [(y: Float, support: Int)] = []
        for k in 0..<n {
            let c = smooth[k]
            let left = k > 0 ? smooth[k - 1] : -1
            let right = k + 1 < n ? smooth[k + 1] : -1
            guard c >= minSupport, c > left, c >= right else { continue }
            let y = lo + (Float(k) + 0.5) * bin
            guard y <= aim.y + 0.01 else { continue }
            let r = refined(y)
            if r.support >= minSupport, !peaks.contains(where: { abs($0.y - r.y) < band }) { peaks.append(r) }
        }
        let qualifying = peaks.filter { objectAbove($0.y) >= minAbove }
        guard let best = qualifying.map(\.support).max() else { return nil }
        // The support is the highest real surface under the object (a table, not the floor below it).
        return qualifying.filter { Double($0.support) >= 0.25 * Double(best) }.max { $0.y < $1.y }?.y
    }

    public static func fit(points: [ScenePoint], aim: SIMD3<Float>, cameraPosition: SIMD3<Float>,
                           planeCandidates: [Float] = [], settings: Settings = Settings()) -> Result? {
        guard aim.x.isFinite, aim.y.isFinite, aim.z.isFinite else { return nil }
        let plane = supportPlane(points: points, aim: aim, candidates: planeCandidates, settings: settings)
        let r2 = settings.searchRadius * settings.searchRadius
        let aimRange = simd_distance(aim, cameraPosition)
        var objectPoints: [SIMD3<Float>] = []
        if let plane {
            for p in points {
                let q = p.position
                let dx = q.x - aim.x, dz = q.z - aim.z
                guard dx * dx + dz * dz <= r2, q.y > plane + settings.clearance, q.y < plane + settings.maxHeight else { continue }
                objectPoints.append(q)
            }
        }
        var component = plane != nil ? flood(objectPoints, from: aim, cell: settings.cellSize, maxReach: 0.15) : []
        var planeY = plane
        if component.count < 25 {
            // No plane, or nothing standing on it at the aim point: box around the depth blob there.
            planeY = nil
            objectPoints = points.compactMap { p in
                let q = p.position
                guard simd_distance(q, aim) <= 0.5, abs(simd_distance(q, cameraPosition) - aimRange) <= 0.3 else { return nil }
                return q
            }
            component = flood(objectPoints, from: aim, cell: settings.cellSize, maxReach: 0.05)
        }
        guard component.count >= 12 else { return nil }

        // Yaw: an elongated footprint (valve, pipe, beam) follows its principal axis, which a
        // half-visible footprint barely tilts; otherwise the minimum-area rectangle, long side on X.
        let yaw = footprintYaw(component)
        let c = cos(yaw), s = sin(yaw)
        let xs = component.map { c * $0.x + s * $0.z }.sorted()
        let zs = component.map { -s * $0.x + c * $0.z }.sorted()
        let ys = component.map(\.y).sorted()
        func pct(_ v: [Float], _ p: Double) -> Float { v[min(v.count - 1, max(0, Int((Double(v.count - 1) * p).rounded())))] }
        var x0 = pct(xs, 0.005), x1 = pct(xs, 0.995)
        var z0 = pct(zs, 0.005), z1 = pct(zs, 0.995)
        let y1 = pct(ys, 0.995)
        let y0 = planeY ?? pct(ys, 0.005)
        // The far side: the camera only sees the front. Mirror the near side about the top of the
        // object (mean footprint position of its highest 3 % of points) along each axis the camera
        // looks down, capped at `maxHiddenExtension` of the visible size.
        let camX = c * cameraPosition.x + s * cameraPosition.z - (x0 + x1) / 2
        let camZ = -s * cameraPosition.x + c * cameraPosition.z - (z0 + z1) / 2
        let horiz = max(1e-6, (camX * camX + camZ * camZ).squareRoot())
        let yTop = pct(ys, 0.97)
        var ridgeX: Float = 0, ridgeZ: Float = 0, ridgeN: Float = 0
        for p in component where p.y >= yTop {
            ridgeX += c * p.x + s * p.z
            ridgeZ += -s * p.x + c * p.z
            ridgeN += 1
        }
        if ridgeN > 0 {
            ridgeX /= ridgeN
            ridgeZ /= ridgeN
            let cap = settings.maxHiddenExtension
            if abs(camX) / horiz > 0.3 {
                let span = x1 - x0
                if camX > 0 { x0 = max(x0 - cap * span, min(x0, 2 * ridgeX - x1)) } else { x1 = min(x1 + cap * span, max(x1, 2 * ridgeX - x0)) }
            }
            if abs(camZ) / horiz > 0.3 {
                let span = z1 - z0
                if camZ > 0 { z0 = max(z0 - cap * span, min(z0, 2 * ridgeZ - z1)) } else { z1 = min(z1 + cap * span, max(z1, 2 * ridgeZ - z0)) }
            }
        }
        let lo = settings.minSide / 2, hi = settings.maxSide / 2
        let half = SIMD3<Float>(min(hi, max(lo, (x1 - x0) / 2)), min(hi, max(lo, (y1 - y0) / 2)), min(hi, max(lo, (z1 - z0) / 2)))
        let cl = SIMD2<Float>((x0 + x1) / 2, (z0 + z1) / 2)
        // Back to world: x = c lx - s lz, z = s lx + c lz.
        let center = SIMD3<Float>(c * cl.x - s * cl.y, y0 + half.y, s * cl.x + c * cl.y)
        return Result(box: ObjectBox(center: center, halfExtents: half, yaw: yaw), planeY: planeY,
                      objectPoints: component.count, aimPoint: aim)
    }

    /// Footprint direction of `points` (yaw about +Y that puts the long side on X).
    static func footprintYaw(_ points: [SIMD3<Float>]) -> Float {
        let n = Float(points.count)
        guard n >= 3 else { return 0 }
        var mx: Float = 0, mz: Float = 0
        for p in points { mx += p.x; mz += p.z }
        mx /= n
        mz /= n
        var sxx: Float = 0, szz: Float = 0, sxz: Float = 0
        for p in points {
            let dx = p.x - mx, dz = p.z - mz
            sxx += dx * dx
            szz += dz * dz
            sxz += dx * dz
        }
        // Eigenvalues of the 2x2 covariance.
        let tr = sxx + szz, det = sxx * szz - sxz * sxz
        let disc = max(0, tr * tr / 4 - det).squareRoot()
        let l1 = tr / 2 + disc, l2 = max(1e-12, tr / 2 - disc)
        if l1 / l2 > 3.2 { // std-dev ratio above ~1.8
            // Major axis angle in (x, z); `local x = cos(yaw) x + sin(yaw) z` puts it on X.
            var yaw = 0.5 * atan2(2 * sxz, sxx - szz)
            while yaw > .pi / 2 { yaw -= .pi }
            while yaw <= -.pi / 2 { yaw += .pi }
            return yaw
        }
        return Float(MeshNormalizer.alignmentYaw(points.map { Point2D(Double($0.x), Double($0.z)) }, quantum: 0.001))
    }

    /// Points of the 26-connected grid component that contains (or is nearest to, within `maxReach`)
    /// `seed`. Cells need two points, so single stray samples do not bridge gaps.
    static func flood(_ points: [SIMD3<Float>], from seed: SIMD3<Float>, cell: Float, maxReach: Float) -> [SIMD3<Float>] {
        guard !points.isEmpty else { return [] }
        func key(_ c: SIMD3<Int32>) -> Int64 {
            (Int64(c.x) + (1 << 20)) << 42 | (Int64(c.y) + (1 << 20)) << 21 | (Int64(c.z) + (1 << 20))
        }
        func cellOf(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)), Int32((p.z / cell).rounded(.down)))
        }
        var counts: [Int64: Int] = [:]
        for p in points { counts[key(cellOf(p)), default: 0] += 1 }
        // Start: the point nearest to the seed (first on ties: deterministic).
        var best = -1
        var bestD = maxReach * maxReach
        for (k, p) in points.enumerated() {
            let d = simd_distance_squared(p, seed)
            if d <= bestD && (best < 0 || d < bestD) {
                best = k
                bestD = d
            }
        }
        guard best >= 0 else { return [] }
        let start = cellOf(points[best])
        var inComponent: Set<Int64> = [key(start)]
        var queue = [start]
        var head = 0
        while head < queue.count {
            let c = queue[head]
            head += 1
            for dz: Int32 in -1...1 {
                for dy: Int32 in -1...1 {
                    for dx: Int32 in -1...1 where dx != 0 || dy != 0 || dz != 0 {
                        let n = c &+ SIMD3(dx, dy, dz)
                        let k = key(n)
                        guard !inComponent.contains(k), (counts[k] ?? 0) >= 2 else { continue }
                        inComponent.insert(k)
                        queue.append(n)
                    }
                }
            }
        }
        return points.filter { inComponent.contains(key(cellOf($0))) }
    }
}

// MARK: - Fusion settings

extension TSDFVolume.Configuration {
    /// Object Detail scan inside a fitted box: the voxel follows the box size (2 mm up to 0.30 m,
    /// 3 mm up to 0.60 m, 4 mm above, stepped up if the estimated volume would pass half the memory
    /// cap), 0.12-1.0 m depth range, high-confidence LiDAR depth only.
    public static func object(for box: ObjectBox, memoryCapBytes: Int = 384 << 20) -> TSDFVolume.Configuration {
        var voxel = objectVoxelSize(maxSide: box.maxSide)
        while voxel < 0.004, estimatedObjectBytes(box: box, voxelSize: voxel) > memoryCapBytes / 2 { voxel += 0.001 }
        return TSDFVolume.Configuration(voxelSize: voxel, truncationVoxels: voxel < 0.0025 ? 6 : 5, maxWeight: 64,
                                        memoryCapBytes: memoryCapBytes, minConfidence: 2, minDepth: 0.12, maxDepth: 1.0,
                                        allocationStride: 2)
    }

    public static func objectVoxelSize(maxSide: Float) -> Float {
        maxSide <= 0.30 ? 0.002 : (maxSide <= 0.60 ? 0.003 : 0.004)
    }

    /// Rough block memory for scanning everything inside `box`: its surface plus the support plane
    /// under it, times the truncation band thickness.
    public static func estimatedObjectBytes(box: ObjectBox, voxelSize: Float) -> Int {
        let s = box.size + 2 * ObjectScan.margin(voxelSize: voxelSize)
        let area = 2 * (s.x * s.y + s.y * s.z + s.x * s.z) + s.x * s.z
        let blockSide = voxelSize * Float(TSDFVolume.blockDim)
        let thickness = max(1, 2 * 6 * voxelSize / blockSide + 1)
        let blocks = area / (blockSide * blockSide) * thickness
        return Int(blocks) * (TSDFVolume.voxelsPerBlock * TSDFVolume.bytesPerVoxel + TSDFVolume.blockOverheadBytes)
    }
}

// MARK: - Coaching and cleanup

public enum ObjectScan {
    /// Room kept around the box for fusion and cropping (m).
    public static func margin(voxelSize: Float) -> Float { max(0.015, 5 * voxelSize) }

    /// Fraction of the most extreme vertices ignored per side when measuring an object.
    public static let measurementTrim = 0.001

    /// Export preparation for a cleaned object mesh: turned so its footprint's long side runs along X,
    /// the table (`planeY`) at y = 0, W x D x H from robust extents with the height from the table.
    public static func prepareForExport(_ mesh: FusedMesh, planeY: Float?) -> MeshNormalizer.Result {
        MeshNormalizer.prepareForExport(mesh.classifiedMesh(), baseY: planeY, trim: measurementTrim)
    }

    /// Coach metrics for an object scan: distance from the camera to the box along the view ray (or
    /// to the nearest point of the box when the ray misses it), and whether the box is out of view.
    public static func coachMetrics(box: ObjectBox, cameraToWorld: simd_float4x4) -> (distance: Float, offTarget: Bool) {
        let eye = RigidTransform.translation(cameraToWorld)
        let forward = simd_normalize(RigidTransform.forward(cameraToWorld))
        if let t = box.intersect(origin: eye, direction: forward) {
            return (t, false)
        }
        let toCenter = box.center - eye
        let d = max(1e-4, simd_length(toCenter))
        let angle = acos(max(-1, min(1, simd_dot(toCenter / d, forward)))) * 180 / .pi
        let radius = simd_length(box.halfExtents)
        let angularRadius = atan(radius / d) * 180 / .pi
        return (box.distance(to: eye), angle > angularRadius + 12)
    }

    /// The coach frame with the distance to the box instead of the center depth (which hits the
    /// background whenever the aim slips past the object) and `.offTarget` when the box is out of view.
    public static func coachFrame(_ frame: CoachFrame, box: ObjectBox) -> CoachFrame {
        guard let pose = frame.cameraToWorld else { return frame }
        var out = frame
        let m = coachMetrics(box: box, cameraToWorld: pose)
        out.centerDepth = m.distance
        if m.offTarget { out.external.insert(.offTarget) }
        return out
    }
}

/// Turns the fused volume's surface into the object: crop to the box, drop the support plane, keep
/// the significant connected pieces, weld.
public enum ObjectMeshCleaner {
    public struct Report: Sendable, Hashable {
        public var trianglesIn: Int
        public var croppedOut: Int
        public var planeRemoved: Int
        public var componentsKept: Int
        public var componentsDropped: Int
        public var trianglesOut: Int
    }

    public static func clean(_ mesh: FusedMesh, box: ObjectBox, margin: Float, planeY: Float?, voxelSize: Float,
                             minComponentFraction: Float = 0.1) -> (mesh: FusedMesh, report: Report) {
        let P = mesh.positions
        let total = mesh.triangleCount
        var keep: [UInt32] = []
        keep.reserveCapacity(mesh.indices.count)
        var cropped = 0, planeDropped = 0
        let inside = P.map { box.contains($0, margin: margin) }
        let planeTop = planeY.map { $0 + 1.5 * voxelSize }
        var t = 0
        while t + 2 < mesh.indices.count {
            let a = Int(mesh.indices[t]), b = Int(mesh.indices[t + 1]), c = Int(mesh.indices[t + 2])
            t += 3
            guard inside[a], inside[b], inside[c] else {
                cropped += 1
                continue
            }
            if let planeTop, max(P[a].y, max(P[b].y, P[c].y)) < planeTop {
                planeDropped += 1
                continue
            }
            keep.append(contentsOf: [UInt32(a), UInt32(b), UInt32(c)])
        }
        // Weld: vertices at the same position (marching cubes corner cases) become one.
        let q = max(1e-6, voxelSize * 0.01)
        var canonical = [Int32](repeating: -1, count: P.count)
        var byPosition: [SIMD3<Int32>: Int32] = [:]
        for v in Set(keep).sorted() {
            let p = P[Int(v)]
            let k = SIMD3<Int32>(Int32((p.x / q).rounded()), Int32((p.y / q).rounded()), Int32((p.z / q).rounded()))
            if let existing = byPosition[k] {
                canonical[Int(v)] = existing
            } else {
                byPosition[k] = Int32(v)
                canonical[Int(v)] = Int32(v)
            }
        }
        var welded: [UInt32] = []
        welded.reserveCapacity(keep.count)
        t = 0
        while t + 2 < keep.count {
            let a = UInt32(canonical[Int(keep[t])]), b = UInt32(canonical[Int(keep[t + 1])]), c = UInt32(canonical[Int(keep[t + 2])])
            t += 3
            if a == b || b == c || a == c { continue }
            welded.append(contentsOf: [a, b, c])
        }
        // Connected components over shared vertices (union-find).
        var parent = [Int32](repeating: -1, count: P.count)
        func find(_ x: Int32) -> Int32 {
            var r = x
            while parent[Int(r)] != r { r = parent[Int(r)] }
            var y = x
            while parent[Int(y)] != r {
                let next = parent[Int(y)]
                parent[Int(y)] = r
                y = next
            }
            return r
        }
        for v in welded where parent[Int(v)] < 0 { parent[Int(v)] = Int32(v) }
        t = 0
        while t + 2 < welded.count {
            let a = find(Int32(welded[t])), b = find(Int32(welded[t + 1])), c = find(Int32(welded[t + 2]))
            if a != b { parent[Int(max(a, b))] = min(a, b) }
            let ab = find(a)
            if ab != c { parent[Int(max(ab, c))] = min(ab, c) }
            t += 3
        }
        var triCount: [Int32: Int] = [:]
        t = 0
        while t + 2 < welded.count {
            triCount[find(Int32(welded[t])), default: 0] += 1
            t += 3
        }
        let largest = triCount.values.max() ?? 0
        let threshold = max(1, Int((Float(largest) * minComponentFraction).rounded(.up)))
        let kept = Set(triCount.filter { $0.value >= threshold }.keys)
        var out: [UInt32] = []
        out.reserveCapacity(welded.count)
        t = 0
        while t + 2 < welded.count {
            if kept.contains(find(Int32(welded[t]))) { out.append(contentsOf: welded[t..<(t + 3)]) }
            t += 3
        }
        // Compact: only referenced vertices, in first-use order.
        var remap = [Int32](repeating: -1, count: P.count)
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var colors: [SIMD3<UInt8>] = []
        let hasNormals = mesh.normals.count == P.count
        let hasColors = mesh.colors.count == P.count
        var indices: [UInt32] = []
        indices.reserveCapacity(out.count)
        for v in out {
            let i = Int(v)
            if remap[i] < 0 {
                remap[i] = Int32(positions.count)
                positions.append(P[i])
                if hasNormals { normals.append(mesh.normals[i]) }
                if hasColors { colors.append(mesh.colors[i]) }
            }
            indices.append(UInt32(remap[i]))
        }
        let report = Report(trianglesIn: total, croppedOut: cropped, planeRemoved: planeDropped,
                            componentsKept: kept.count, componentsDropped: triCount.count - kept.count,
                            trianglesOut: indices.count / 3)
        return (FusedMesh(positions: positions, normals: normals, colors: colors, indices: indices), report)
    }
}

extension UnitFormatter {
    /// Object-sized lengths: `9 7/8"` / `1' 2 3/8"` (1/8") or `254 mm` / `1.25 m`.
    public static func objectLength(_ meters: Double, _ system: UnitSystem) -> String {
        switch system {
        case .imperial:
            let inches = meters / metersPerInch
            if abs(inches) >= 24 { return feetInches(meters, fractionDenominator: 8) }
            let eighths = Int((abs(inches) * 8).rounded())
            let whole = eighths / 8
            var num = eighths % 8
            var den = 8
            if num > 0 {
                let g = gcd(num, den)
                num /= g
                den /= g
            }
            let text = num == 0 ? "\(whole)" : (whole > 0 ? "\(whole) \(num)/\(den)" : "\(num)/\(den)")
            return text + "\""
        case .metric:
            if abs(meters) >= 1 { return decimal(meters, 2) + " m" }
            return "\(Int((meters * 1000).rounded())) mm"
        }
    }
}

extension MeshMeasurements {
    /// "9 7/8" × 3 1/8" × 4 1/8"" or "251 mm × 80 mm × 105 mm" (W × D × H).
    public func objectDimensionsText(_ units: UnitSystem) -> String {
        [width, depth, height].map { UnitFormatter.objectLength($0, units) }.joined(separator: " × ")
    }
}
