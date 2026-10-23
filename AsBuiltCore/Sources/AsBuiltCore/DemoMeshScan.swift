import Foundation

/// Procedural stand-in for an ARKit LiDAR scene-reconstruction capture, used by the demo job (so the
/// Simulator, screenshots and AR Quick Look show a real classified mesh) and by tests.
///
/// It "scans" the demo bedroom: tessellated floor, walls (door and window regions classified as such),
/// ceiling, plus furniture and a water heater, split into several mesh anchors with their own
/// transforms, with millimetre-scale noise like a real LiDAR mesh. The whole scan is turned by
/// `worldYawDegrees` about +Y, as ARKit's world origin never lines up with the room.
public enum DemoMeshScan {
    public static let worldYawDegrees: Float = 23
    public static let cellSize: Float = 0.1

    public static func bedroomAnchors(plan: FloorPlan = SampleData.bedroom(), cell: Float = cellSize) -> [MeshAnchorInput] {
        var builder = AnchorSet(worldYaw: worldYawDegrees * .pi / 180)
        let height = Float(plan.ceilingHeight ?? plan.walls.map(\.height).max() ?? 2.44)
        let outline = plan.effectiveFloorPolygon
        guard let box = Rect2D.enclosing(outline) else { return [] }

        // Floor and ceiling: grids over the plan's bounding box (the demo room is a rectangle).
        let x0 = Float(box.minX), x1 = Float(box.maxX)
        let y0 = Float(box.minY), y1 = Float(box.maxY)
        builder.begin()
        builder.grid(origin: w(x0, 0, y0), u: w(1, 0, 0) - w(0, 0, 0), v: w(0, 0, 1) - w(0, 0, 0),
                     uLength: x1 - x0, vLength: y1 - y0, cell: cell, normal: SIMD3(0, 1, 0)) { _, _ in .floor }
        builder.end()
        builder.begin()
        builder.grid(origin: w(x0, height, y0), u: w(1, 0, 0) - w(0, 0, 0), v: w(0, 0, 1) - w(0, 0, 0),
                     uLength: x1 - x0, vLength: y1 - y0, cell: cell, normal: SIMD3(0, -1, 0)) { _, _ in .ceiling }
        builder.end()

        // Walls: one anchor per wall, inner face, openings classified by region.
        let reference = plan.interiorReferencePoint
        for wall in plan.walls where wall.length > 1e-6 {
            let dir = wall.direction
            let left = dir.leftNormal
            let inward = (reference - wall.midpoint).dot(left) >= 0 ? left : -left
            let openings = plan.openings(onWall: wall.id).compactMap { opening -> (MeshClass, ClosedRange<Double>, ClosedRange<Double>)? in
                guard let iv = WallElevation.interval(of: opening, wallLength: wall.length),
                      let vc = WallElevation.verticalCut(of: opening, wallHeight: wall.height) else { return nil }
                let cls: MeshClass
                switch opening.kind {
                case .door: cls = .door
                case .window: cls = .window
                case .opening: cls = .none
                }
                return (cls, iv, vc)
            }
            let start = w(Float(wall.start.x), 0, Float(wall.start.y))
            let along = w(Float(dir.x), 0, Float(dir.y))
            let up = SIMD3<Float>(0, 1, 0)
            let normal = w(Float(inward.x), 0, Float(inward.y))
            builder.begin()
            builder.grid(origin: start, u: along, v: up, uLength: Float(wall.length), vLength: Float(wall.height),
                         cell: cell, normal: normal) { u, v in
                for (cls, iv, vc) in openings where iv.contains(Double(u)) && vc.contains(Double(v)) {
                    return cls == .none ? nil : cls
                }
                return .wall
            }
            builder.end()
        }

        // Furniture: the plan's fixtures (bed = "Other", dresser = table) plus a desk, chair and a
        // water heater (MEP, "Other").
        for fixture in plan.fixtures {
            let cls: MeshClass = fixture.label.lowercased().contains("dresser") ? .table : .none
            builder.begin()
            builder.box(footprint: fixture.corners, height: Float(fixture.height), cell: cell, cls: cls)
            builder.end()
        }
        let ft = UnitFormatter.meters(feet:)
        let inch = UnitFormatter.meters(inches:)
        let desk = FixtureBox(label: "Desk", center: Point2D(ft(3.5), ft(12.6)), width: inch(48), depth: inch(24), height: inch(30))
        let chair = FixtureBox(label: "Chair", center: Point2D(ft(3.5), ft(11.2)), width: inch(18), depth: inch(18),
                               height: inch(18), rotation: 0.2)
        builder.begin()
        builder.box(footprint: desk.corners, height: Float(desk.height), cell: cell, cls: .table)
        builder.end()
        builder.begin()
        builder.box(footprint: chair.corners, height: Float(chair.height), cell: cell, cls: .seat)
        builder.end()
        builder.begin()
        builder.cylinder(center: Point2D(ft(1.3), ft(1.3)), radius: Float(inch(11)), height: Float(inch(60)),
                         segments: 32, cell: cell, cls: .none)
        builder.end()
        return builder.anchors
    }

    /// Plan (x, y) + height -> world (x, h, -y), like RoomModelBuilder.
    @inline(__always)
    static func w(_ x: Float, _ h: Float, _ y: Float) -> SIMD3<Float> { SIMD3(x, h, -y) }

    /// Collects anchors: geometry is generated in "room" coordinates, turned by the world yaw, then
    /// stored anchor-local around the anchor's centroid with an anchor transform (yaw + translation).
    struct AnchorSet {
        let worldYaw: Float
        var anchors: [MeshAnchorInput] = []
        var points: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var faces: [UInt32] = []
        var classes: [UInt8] = []
        var seed: UInt32 = 0x9E37_79B9

        init(worldYaw: Float) { self.worldYaw = worldYaw }

        mutating func begin() {
            points.removeAll(keepingCapacity: true)
            normals.removeAll(keepingCapacity: true)
            faces.removeAll(keepingCapacity: true)
            classes.removeAll(keepingCapacity: true)
        }

        mutating func end() {
            guard !faces.isEmpty else { return }
            let c = cos(worldYaw), s = sin(worldYaw)
            func yaw(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z) }
            let world = points.map(yaw)
            let worldNormals = normals.map(yaw)
            var centroid = SIMD3<Float>(0, 0, 0)
            for p in world { centroid += p }
            centroid /= Float(world.count)
            // Each anchor carries the world yaw in its transform; local = R(-yaw) (world - t).
            let local = world.map { p -> SIMD3<Float> in
                let d = p - centroid
                return SIMD3(c * d.x - s * d.z, d.y, s * d.x + c * d.z)
            }
            let localNormals = worldNormals.map { n in SIMD3(c * n.x - s * n.z, n.y, s * n.x + c * n.z) }
            anchors.append(MeshAnchorInput(transform: MeshAnchorInput.transform(yawRadians: worldYaw, translation: centroid),
                                           vertices: local, normals: localNormals, faces: faces, classifications: classes))
        }

        /// Deterministic noise in [-1, 1].
        mutating func noise() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 8) / Float(1 << 24) * 2 - 1
        }

        /// A tessellated rectangle origin + u*a + v*b (a in 0...uLength, b in 0...vLength). `classify`
        /// gets the cell center (u, v); returning nil leaves a hole (open doorway).
        mutating func grid(origin: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>, uLength: Float, vLength: Float,
                           cell: Float, normal: SIMD3<Float>, jitter: Float = 0.004,
                           classify: (Float, Float) -> MeshClass?) {
            let nu = max(1, Int((uLength / cell).rounded(.up)))
            let nv = max(1, Int((vLength / cell).rounded(.up)))
            let base = UInt32(points.count)
            for j in 0...nv {
                for i in 0...nu {
                    let a = uLength * Float(i) / Float(nu)
                    let b = vLength * Float(j) / Float(nv)
                    let edge = i == 0 || j == 0 || i == nu || j == nv
                    let offset = edge ? 0 : noise() * jitter
                    points.append(origin + u * a + v * b + normal * offset)
                    normals.append(normal)
                }
            }
            let row = UInt32(nu + 1)
            for j in 0..<nv {
                for i in 0..<nu {
                    let a = uLength * (Float(i) + 0.5) / Float(nu)
                    let b = vLength * (Float(j) + 0.5) / Float(nv)
                    guard let cls = classify(a, b) else { continue }
                    let p00 = base + UInt32(j) * row + UInt32(i)
                    let p10 = p00 + 1
                    let p01 = p00 + row
                    let p11 = p01 + 1
                    // Winding is fixed up from the normals by ClassifiedMeshBuilder.
                    faces.append(contentsOf: [p00, p10, p11, p00, p11, p01])
                    classes.append(cls.rawValue)
                    classes.append(cls.rawValue)
                }
            }
        }

        /// Top + four sides of a box over a convex 4-corner footprint (the floor hides the bottom).
        mutating func box(footprint: [Point2D], height: Float, cell: Float, cls: MeshClass) {
            guard footprint.count == 4 else { return }
            let ring = Polygon2D.signedArea(footprint) < 0 ? Array(footprint.reversed()) : footprint
            let p = ring.map { DemoMeshScan.w(Float($0.x), 0, Float($0.y)) }
            let up = SIMD3<Float>(0, 1, 0)
            // Top.
            let ua = p[1] - p[0], va = p[3] - p[0]
            grid(origin: p[0] + up * height, u: normalize(ua), v: normalize(va), uLength: length(ua), vLength: length(va),
                 cell: cell, normal: up, jitter: 0.002) { _, _ in cls }
            // Sides, normals pointing away from the box center.
            let center = (p[0] + p[1] + p[2] + p[3]) / 4
            for k in 0..<4 {
                let a = p[k], b = p[(k + 1) % 4]
                let e = b - a
                var n = normalize(SIMD3<Float>(e.z, 0, -e.x))
                let mid: SIMD3<Float> = (a + b) / 2 - center
                let facing: Float = mid.x * n.x + mid.z * n.z
                if facing < 0 { n = -n }
                grid(origin: a, u: normalize(e), v: up, uLength: length(e), vLength: height, cell: cell, normal: n,
                     jitter: 0.002) { _, _ in cls }
            }
        }

        mutating func cylinder(center: Point2D, radius: Float, height: Float, segments: Int, cell: Float, cls: MeshClass) {
            let c = DemoMeshScan.w(Float(center.x), 0, Float(center.y))
            let rings = max(1, Int((height / cell).rounded(.up)))
            let base = UInt32(points.count)
            for j in 0...rings {
                let y = height * Float(j) / Float(rings)
                for i in 0..<segments {
                    let t = Float(i) / Float(segments) * 2 * .pi
                    let n = SIMD3<Float>(cos(t), 0, sin(t))
                    points.append(c + n * radius + SIMD3(0, y, 0))
                    normals.append(n)
                }
            }
            let seg = UInt32(segments)
            for j in 0..<UInt32(rings) {
                for i in 0..<seg {
                    let a = base + j * seg + i
                    let b = base + j * seg + (i + 1) % seg
                    let a2 = a + seg, b2 = b + seg
                    faces.append(contentsOf: [a, b, b2, a, b2, a2])
                    classes.append(cls.rawValue)
                    classes.append(cls.rawValue)
                }
            }
            // Top cap (fan).
            let hub = UInt32(points.count)
            points.append(c + SIMD3(0, height, 0))
            normals.append(SIMD3(0, 1, 0))
            let capBase = UInt32(points.count)
            for i in 0..<segments {
                let t = Float(i) / Float(segments) * 2 * .pi
                points.append(c + SIMD3(cos(t) * radius, height, sin(t) * radius))
                normals.append(SIMD3(0, 1, 0))
            }
            for i in 0..<seg {
                faces.append(contentsOf: [hub, capBase + i, capBase + (i + 1) % seg])
                classes.append(cls.rawValue)
            }
        }

        func length(_ v: SIMD3<Float>) -> Float { (v * v).sum().squareRoot() }
        func normalize(_ v: SIMD3<Float>) -> SIMD3<Float> {
            let l = length(v)
            return l > 0 ? v / l : v
        }
    }

    /// The demo scan, combined and prepared for export.
    public static func bedroomMesh() -> MeshNormalizer.Result {
        MeshNormalizer.prepareForExport(ClassifiedMeshBuilder.build(bedroomAnchors()))
    }

    /// A synthetic scan of about `triangles` triangles (perf tests): a tessellated, wavy sheet split
    /// into anchors of ~10k faces, cycling through every class.
    public static func syntheticAnchors(triangles: Int) -> [MeshAnchorInput] {
        let perAnchor = 10_000
        var anchors: [MeshAnchorInput] = []
        var remaining = triangles
        var index = 0
        while remaining > 0 {
            let n = min(perAnchor, remaining)
            let side = Int(Double(n / 2).squareRoot().rounded(.up))
            var vertices: [SIMD3<Float>] = []
            var normals: [SIMD3<Float>] = []
            vertices.reserveCapacity((side + 1) * (side + 1))
            for j in 0...side {
                for i in 0...side {
                    let x = Float(i) * 0.01, z = Float(j) * 0.01
                    vertices.append(SIMD3(x, 0.02 * sin(x * 7 + z * 3), z))
                    normals.append(SIMD3(0, 1, 0))
                }
            }
            var faces: [UInt32] = []
            var classes: [UInt8] = []
            faces.reserveCapacity(n * 3)
            let row = UInt32(side + 1)
            outer: for j in 0..<UInt32(side) {
                for i in 0..<UInt32(side) {
                    if classes.count + 2 > n { break outer }
                    let p = j * row + i
                    faces.append(contentsOf: [p, p + 1, p + row + 1, p, p + row + 1, p + row])
                    let cls = UInt8((Int(i / 8) + index) % MeshClass.allCases.count)
                    classes.append(cls)
                    classes.append(cls)
                }
            }
            let t = MeshAnchorInput.transform(yawRadians: Float(index) * 0.3, translation: SIMD3(Float(index % 5) * 1.2, 0, Float(index / 5) * 1.2))
            anchors.append(MeshAnchorInput(transform: t, vertices: vertices, normals: normals, faces: faces, classifications: classes))
            remaining -= max(2, classes.count)
            index += 1
        }
        return anchors
    }
}
