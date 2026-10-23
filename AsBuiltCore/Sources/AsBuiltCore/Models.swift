import Foundation

/// A straight wall in plan view. `start`/`end` lie on the room-side (interior) face, which is what
/// RoomPlan measures; `thickness` is drawn away from the room.
public struct WallSegment: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var start: Point2D
    public var end: Point2D
    /// Floor-to-top height in meters.
    public var height: Double
    /// Wall thickness in meters (used for drawing jambs and the 3D model).
    public var thickness: Double

    /// 4.5 in: 2x4 stud with 1/2 in drywall on both faces.
    public static let defaultThickness = 0.1143

    public init(id: UUID = UUID(), start: Point2D, end: Point2D, height: Double,
                thickness: Double = WallSegment.defaultThickness) {
        self.id = id
        self.start = start
        self.end = end
        self.height = height
        self.thickness = thickness
    }

    public var length: Double { start.distance(to: end) }
    public var direction: Point2D { (end - start).normalized }
    public var midpoint: Point2D { (start + end) * 0.5 }
    public var grossArea: Double { length * height }

    public func point(atOffset offset: Double) -> Point2D { start + direction * offset }

    /// Signed distance along the wall from `start` to the projection of `point`.
    public func offset(of point: Point2D) -> Double { (point - start).dot(direction) }

    /// Shortest distance from `point` to the wall segment.
    public func distance(to point: Point2D) -> Double {
        let l = length
        guard l > 0 else { return point.distance(to: start) }
        let t = min(max(offset(of: point), 0), l)
        return point.distance(to: self.point(atOffset: t))
    }
}

public enum OpeningKind: String, Codable, CaseIterable, Sendable {
    case door
    case window
    case opening

    public var displayName: String {
        switch self {
        case .door: return "Door"
        case .window: return "Window"
        case .opening: return "Opening"
        }
    }

    /// Tag prefix used on drawings and in the takeoff (D1, WIN1, OP1).
    public var tagPrefix: String {
        switch self {
        case .door: return "D"
        case .window: return "WIN"
        case .opening: return "OP"
        }
    }

    public var layer: PlanLayer {
        switch self {
        case .door: return .doors
        case .window: return .windows
        case .opening: return .openings
        }
    }
}

/// A door, window or cased opening hosted on a wall.
public struct Opening: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: OpeningKind
    /// The hosting wall.
    public var wallID: UUID
    /// Distance along the host wall from `WallSegment.start` to the opening's center (meters).
    public var offset: Double
    public var width: Double
    public var height: Double
    /// Height of the bottom of the opening above the floor (0 for doors and cased openings).
    public var sillHeight: Double

    public init(id: UUID = UUID(), kind: OpeningKind, wallID: UUID, offset: Double,
                width: Double, height: Double, sillHeight: Double = 0) {
        self.id = id
        self.kind = kind
        self.wallID = wallID
        self.offset = offset
        self.width = width
        self.height = height
        self.sillHeight = sillHeight
    }

    public var area: Double { width * height }
}

/// A detected object (cabinet, appliance, fixture, furniture) as a plan-view bounding box.
public struct FixtureBox: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var center: Point2D
    /// Size along the box's local x axis (meters).
    public var width: Double
    /// Size along the box's local y axis in plan (meters).
    public var depth: Double
    public var height: Double
    /// Counter-clockwise rotation of the local x axis from plan +x, radians.
    public var rotation: Double

    public init(id: UUID = UUID(), label: String, center: Point2D, width: Double,
                depth: Double, height: Double, rotation: Double = 0) {
        self.id = id
        self.label = label
        self.center = center
        self.width = width
        self.depth = depth
        self.height = height
        self.rotation = rotation
    }

    /// Footprint corners, counter-clockwise.
    public var corners: [Point2D] {
        let hx = width / 2
        let hy = depth / 2
        return [Point2D(-hx, -hy), Point2D(hx, -hy), Point2D(hx, hy), Point2D(-hx, hy)]
            .map { center + $0.rotated(by: rotation) }
    }
}

public enum FloorAreaSource: String, Codable, Sendable {
    case scannedFloor = "Scanned floor polygon"
    case wallLoop = "Closed wall loop"
    case wallExtents = "Wall extents (convex hull)"
    case unavailable = "Unavailable"
}

/// Platform-independent 2D representation of a scanned room.
public struct FloorPlan: Codable, Hashable, Sendable {
    public var name: String
    public var walls: [WallSegment]
    public var openings: [Opening]
    public var fixtures: [FixtureBox]
    /// Floor outline from the scan (RoomPlan `floors`), if available.
    public var floorPolygon: [Point2D]?
    public var ceilingHeight: Double?

    public init(name: String, walls: [WallSegment] = [], openings: [Opening] = [],
                fixtures: [FixtureBox] = [], floorPolygon: [Point2D]? = nil,
                ceilingHeight: Double? = nil) {
        self.name = name
        self.walls = walls
        self.openings = openings
        self.fixtures = fixtures
        self.floorPolygon = floorPolygon
        self.ceilingHeight = ceilingHeight
    }

    public func wall(withID id: UUID) -> WallSegment? { walls.first { $0.id == id } }

    /// 1-based wall number in drawing/takeoff order.
    public func wallNumber(for id: UUID) -> Int? {
        walls.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    public func openings(onWall id: UUID) -> [Opening] {
        openings.filter { $0.wallID == id }.sorted { $0.offset < $1.offset }
    }

    /// Stable opening tags (D1, WIN1, WIN2, OP1...) in wall order, then along each wall.
    public func openingTags() -> [UUID: String] {
        var counters: [OpeningKind: Int] = [:]
        var tags: [UUID: String] = [:]
        for wall in walls {
            for opening in openings(onWall: wall.id) {
                counters[opening.kind, default: 0] += 1
                tags[opening.id] = "\(opening.kind.tagPrefix)\(counters[opening.kind]!)"
            }
        }
        for opening in openings where tags[opening.id] == nil {
            counters[opening.kind, default: 0] += 1
            tags[opening.id] = "\(opening.kind.tagPrefix)\(counters[opening.kind]!)"
        }
        return tags
    }

    /// The best available floor outline and where it came from.
    public func resolveFloorPolygon() -> (source: FloorAreaSource, polygon: [Point2D]) {
        if let scanned = floorPolygon, scanned.count >= 3, Polygon2D.area(scanned) > 0.01 {
            return (.scannedFloor, scanned)
        }
        if let loop = WallLoopBuilder.loop(for: walls) {
            return (.wallLoop, loop)
        }
        let hull = Polygon2D.convexHull(walls.flatMap { [$0.start, $0.end] })
        if hull.count >= 3 {
            return (.wallExtents, hull)
        }
        return (.unavailable, [])
    }

    public var effectiveFloorPolygon: [Point2D] { resolveFloorPolygon().polygon }

    /// A point inside the room used to decide which side of a wall is interior.
    public var interiorReferencePoint: Point2D {
        let polygon = effectiveFloorPolygon
        if polygon.count >= 3 { return Polygon2D.centroid(polygon) }
        guard !walls.isEmpty else { return .zero }
        return walls.map(\.midpoint).reduce(Point2D.zero, +) * (1 / Double(walls.count))
    }
}
