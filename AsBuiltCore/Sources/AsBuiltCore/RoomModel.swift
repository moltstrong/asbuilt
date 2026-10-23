import Foundation

/// Material slots of the generated room massing model.
public enum RoomMaterial: String, CaseIterable, Sendable {
    case wall = "Wall"
    case floor = "Floor"
    case glass = "Glass"
    case door = "Door"
    case fixture = "Fixture"

    /// Linear-ish display color (r, g, b) and opacity, matching the old SceneKit model.
    public var color: (r: Double, g: Double, b: Double, opacity: Double) {
        switch self {
        case .wall: return (0.93, 0.93, 0.93, 1)
        case .floor: return (0.74, 0.62, 0.48, 1)
        case .glass: return (0.55, 0.75, 0.90, 0.45)
        case .door: return (0.62, 0.42, 0.26, 1)
        case .fixture: return (0.45, 0.50, 0.56, 1)
        }
    }

    public var roughness: Double { self == .glass ? 0.1 : 0.8 }
}

/// A triangle mesh in USD world space (meters, +Y up). Vertices are not shared between faces,
/// so every point carries its face's flat normal.
public struct RoomMesh: Sendable {
    public var name: String
    public var group: String
    public var material: RoomMaterial
    public var points: [SIMD3<Double>] = []
    public var normals: [SIMD3<Double>] = []
    /// Triangle list (three indices per face).
    public var indices: [Int] = []

    public init(name: String, group: String, material: RoomMaterial) {
        self.name = name
        self.group = group
        self.material = material
    }

    public var triangleCount: Int { indices.count / 3 }

    public var bounds: (min: SIMD3<Double>, max: SIMD3<Double>)? {
        guard var lo = points.first else { return nil }
        var hi = lo
        for p in points.dropFirst() {
            lo = pointwiseMin(lo, p)
            hi = pointwiseMax(hi, p)
        }
        return (lo, hi)
    }

    /// Appends a planar convex face (fan-triangulated) with one flat normal.
    mutating func addFace(_ corners: [SIMD3<Double>]) {
        guard corners.count >= 3 else { return }
        let normal = Self.normal(corners[0], corners[1], corners[2])
        let base = points.count
        points.append(contentsOf: corners)
        normals.append(contentsOf: Array(repeating: normal, count: corners.count))
        for k in 1..<(corners.count - 1) {
            indices.append(contentsOf: [base, base + k, base + k + 1])
        }
    }

    /// Appends triangles over shared corner points with one flat normal (used for floor caps).
    mutating func addTriangles(_ corners: [SIMD3<Double>], triangles: [[Int]], normal: SIMD3<Double>) {
        let base = points.count
        points.append(contentsOf: corners)
        normals.append(contentsOf: Array(repeating: normal, count: corners.count))
        for t in triangles { indices.append(contentsOf: t.map { base + $0 }) }
    }

    static func normal(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> SIMD3<Double> {
        let u = b - a
        let v = c - a
        let n = SIMD3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
        let l = (n * n).sum().squareRoot()
        return l > 0 ? n / l : SIMD3(0, 1, 0)
    }
}

/// Builds the 3D massing model of a `FloorPlan` (extruded walls with real openings, floor slab,
/// window panes, open door leaves, fixture blocks) as plain triangle meshes.
///
/// Coordinates: plan (x, y) maps to USD (x, z = -y) with +Y up, meters. This is a straight port of
/// the former SceneKit `SceneModelBuilder.scene(for:)` geometry.
public enum RoomModelBuilder {
    public static let floorThickness = 0.02
    public static let paneThickness = 0.012
    public static let doorLeafThickness = 0.04
    public static let doorOpenAngleDegrees = 70.0

    /// Plan point plus height to USD world space.
    @inline(__always)
    public static func world(_ p: Point2D, _ height: Double) -> SIMD3<Double> {
        SIMD3(p.x, height, -p.y)
    }

    public static func meshes(for plan: FloorPlan) -> [RoomMesh] {
        var result: [RoomMesh] = []

        // Floor slab from the resolved outline: top at y = 0, 2 cm thick.
        let outline = plan.effectiveFloorPolygon
        if outline.count >= 3 {
            var floor = RoomMesh(name: "Floor", group: "Floor", material: .floor)
            addSlab(&floor, outline: outline, bottom: -floorThickness, top: 0)
            if !floor.indices.isEmpty { result.append(floor) }
        }

        let reference = plan.interiorReferencePoint
        for (index, wall) in plan.walls.enumerated() where wall.length > 1e-6 {
            let wallName = "W\(index + 1)"
            let dir = wall.direction
            let left = dir.leftNormal
            let inward = (reference - wall.midpoint).dot(left) >= 0 ? left : -left
            // Centerline sits half a thickness outside the interior face.
            let origin = wall.start - inward * (wall.thickness / 2)
            let half = wall.thickness / 2

            var wallMesh = RoomMesh(name: wallName, group: "Walls", material: .wall)
            let openings = plan.openings(onWall: wall.id)
            for piece in WallElevation.pieces(for: wall, openings: openings) {
                let a = origin + dir * piece.start
                let b = origin + dir * piece.end
                let footprint = [a - inward * half, b - inward * half, b + inward * half, a + inward * half]
                addPrism(&wallMesh, footprint: footprint, bottom: piece.bottom, top: piece.top)
            }
            if !wallMesh.indices.isEmpty { result.append(wallMesh) }

            var windowCount = 0
            var doorCount = 0
            for opening in openings {
                guard let iv = WallElevation.interval(of: opening, wallLength: wall.length),
                      let v = WallElevation.verticalCut(of: opening, wallHeight: wall.height) else { continue }
                let width = iv.upperBound - iv.lowerBound
                let height = v.upperBound - v.lowerBound
                switch opening.kind {
                case .window:
                    windowCount += 1
                    var pane = RoomMesh(name: "\(wallName)_Window\(windowCount)", group: "Openings", material: .glass)
                    let a = origin + dir * iv.lowerBound
                    let b = origin + dir * iv.upperBound
                    let t = paneThickness / 2
                    addPrism(&pane, footprint: [a - inward * t, b - inward * t, b + inward * t, a + inward * t],
                             bottom: v.lowerBound, top: v.upperBound)
                    result.append(pane)
                case .door:
                    // Leaf shown open 70 degrees into the room, hinged at the opening's start jamb.
                    doorCount += 1
                    var leaf = RoomMesh(name: "\(wallName)_Door\(doorCount)", group: "Openings", material: .door)
                    let angle = doorOpenAngleDegrees * .pi / 180
                    let hinge = origin + dir * iv.lowerBound
                    let leafDir = dir * cos(angle) + inward * sin(angle)
                    let side = leafDir.leftNormal * (doorLeafThickness / 2)
                    let tip = hinge + leafDir * width
                    addPrism(&leaf, footprint: [hinge - side, tip - side, tip + side, hinge + side],
                             bottom: 0, top: height)
                    result.append(leaf)
                case .opening:
                    break
                }
            }
        }

        for (index, fixture) in plan.fixtures.enumerated() {
            var box = RoomMesh(name: "Fixture\(index + 1)_\(USDAWriter.identifier(fixture.label))",
                               group: "Fixtures", material: .fixture)
            addPrism(&box, footprint: fixture.corners, bottom: 0, top: fixture.height)
            if !box.indices.isEmpty { result.append(box) }
        }
        return result
    }

    /// World-space bounds of all meshes.
    public static func bounds(of meshes: [RoomMesh]) -> (min: SIMD3<Double>, max: SIMD3<Double>)? {
        let all = meshes.compactMap(\.bounds)
        guard var result = all.first else { return nil }
        for b in all.dropFirst() {
            result.min = pointwiseMin(result.min, b.min)
            result.max = pointwiseMax(result.max, b.max)
        }
        return result
    }

    /// A vertical prism over a convex footprint (any winding): top, bottom and side quads.
    static func addPrism(_ mesh: inout RoomMesh, footprint: [Point2D], bottom: Double, top: Double) {
        guard footprint.count >= 3, top > bottom, Polygon2D.area(footprint) > 1e-12 else { return }
        let ring = Polygon2D.signedArea(footprint) < 0 ? Array(footprint.reversed()) : footprint
        mesh.addFace(ring.map { world($0, top) })
        mesh.addFace(ring.reversed().map { world($0, bottom) })
        addSides(&mesh, ring: ring, bottom: bottom, top: top)
    }

    /// A vertical slab over any simple polygon (concave allowed): ear-clipped caps plus sides.
    static func addSlab(_ mesh: inout RoomMesh, outline: [Point2D], bottom: Double, top: Double) {
        guard Polygon2D.area(outline) > 1e-9 else { return }
        let ring = Polygon2D.signedArea(outline) < 0 ? Array(outline.reversed()) : outline
        let triangles = Triangulator.triangulate(ring)
        guard !triangles.isEmpty else { return }
        mesh.addTriangles(ring.map { world($0, top) }, triangles: triangles, normal: SIMD3(0, 1, 0))
        mesh.addTriangles(ring.map { world($0, bottom) }, triangles: triangles.map { [$0[0], $0[2], $0[1]] },
                          normal: SIMD3(0, -1, 0))
        addSides(&mesh, ring: ring, bottom: bottom, top: top)
    }

    /// Outward-facing side quads for a counter-clockwise ring.
    private static func addSides(_ mesh: inout RoomMesh, ring: [Point2D], bottom: Double, top: Double) {
        for i in 0..<ring.count {
            let p = ring[i]
            let q = ring[(i + 1) % ring.count]
            guard p.distance(to: q) > 1e-9 else { continue }
            mesh.addFace([world(p, bottom), world(q, bottom), world(q, top), world(p, top)])
        }
    }
}
