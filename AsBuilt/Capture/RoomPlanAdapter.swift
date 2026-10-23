import Foundation
import AsBuiltCore

#if canImport(RoomPlan) && !targetEnvironment(simulator)
import RoomPlan
import simd

/// Converts RoomPlan's `CapturedRoom` (3D, world space, meters) into an `AsBuiltCore.FloorPlan`
/// (2D, plan space, meters) by projecting each surface onto the floor (XZ) plane:
/// center = transform.columns.3, direction = transform.columns.0, length = dimensions.x,
/// height = dimensions.y. Plan coordinates are `(x, y) = (world.x, -world.z)`.
enum RoomPlanAdapter {
    static func floorPlan(from room: CapturedRoom, name: String) -> FloorPlan {
        let floorY = floorLevel(room)

        var walls: [WallSegment] = []
        for surface in room.walls {
            let center = planPoint(surface.transform.columns.3)
            let dir = planDirection(surface.transform.columns.0)
            let length = Double(surface.dimensions.x)
            guard length > 0.05 else { continue }
            let half = dir * (length / 2)
            let top = Double(surface.transform.columns.3.y) + Double(surface.dimensions.y) / 2
            let height = max(Double(surface.dimensions.y), top - floorY)
            walls.append(WallSegment(id: surface.identifier, start: center - half, end: center + half, height: height))
        }

        var openings: [Opening] = []
        let hosted: [(CapturedRoom.Surface, OpeningKind)] =
            room.doors.map { ($0, .door) } + room.windows.map { ($0, .window) } + room.openings.map { ($0, .opening) }
        for (surface, kind) in hosted {
            let center = planPoint(surface.transform.columns.3)
            let wall = hostWall(for: surface, center: center, in: walls)
            guard let wall else { continue }
            let width = Double(surface.dimensions.x)
            let height = Double(surface.dimensions.y)
            let bottom = Double(surface.transform.columns.3.y) - height / 2
            let sill = kind == .window ? max(0, bottom - floorY) : 0
            openings.append(Opening(id: surface.identifier, kind: kind, wallID: wall.id,
                                    offset: wall.offset(of: center), width: width, height: height, sillHeight: sill))
        }

        let fixtures: [FixtureBox] = room.objects.map { object in
            let c0 = object.transform.columns.0
            return FixtureBox(id: object.identifier, label: label(for: object.category),
                              center: planPoint(object.transform.columns.3),
                              width: Double(object.dimensions.x), depth: Double(object.dimensions.z),
                              height: Double(object.dimensions.y),
                              rotation: atan2(Double(-c0.z), Double(c0.x)))
        }

        let ceiling = walls.map(\.height).max()
        return FloorPlan(name: name, walls: walls, openings: openings, fixtures: fixtures,
                         floorPolygon: floorPolygon(room), ceilingHeight: ceiling).normalized()
    }

    // MARK: Helpers

    static func planPoint(_ column: simd_float4) -> Point2D { Point2D(Double(column.x), Double(-column.z)) }

    static func planDirection(_ column: simd_float4) -> Point2D {
        let d = Point2D(Double(column.x), Double(-column.z))
        return d.length > 1e-6 ? d.normalized : Point2D(1, 0)
    }

    /// World height of the floor: the scanned floor if present, otherwise the lowest wall bottom.
    static func floorLevel(_ room: CapturedRoom) -> Double {
        if let floor = room.floors.first { return Double(floor.transform.columns.3.y) }
        let bottoms = room.walls.map { Double($0.transform.columns.3.y) - Double($0.dimensions.y) / 2 }
        return bottoms.min() ?? 0
    }

    /// Floor outline from `CapturedRoom.floors` (iOS 17). Corners are in the surface's local space.
    static func floorPolygon(_ room: CapturedRoom) -> [Point2D]? {
        guard let floor = room.floors.max(by: { $0.dimensions.x * $0.dimensions.y < $1.dimensions.x * $1.dimensions.y }) else {
            return nil
        }
        var local = floor.polygonCorners
        if local.count < 3 {
            let hx = floor.dimensions.x / 2
            let hy = floor.dimensions.y / 2
            local = [simd_float3(-hx, -hy, 0), simd_float3(hx, -hy, 0), simd_float3(hx, hy, 0), simd_float3(-hx, hy, 0)]
        }
        let world = local.map { floor.transform * simd_float4($0, 1) }
        // Reject anything that is not horizontal (defensive: corner conventions differ across OS versions).
        let ys = world.map(\.y)
        guard let minY = ys.min(), let maxY = ys.max(), maxY - minY < 0.1 else { return nil }
        let points = world.map { Point2D(Double($0.x), Double(-$0.z)) }
        return Polygon2D.area(points) > 0.5 ? points : nil
    }

    /// Uses `parentIdentifier` (iOS 17) and falls back to the nearest parallel wall.
    static func hostWall(for surface: CapturedRoom.Surface, center: Point2D, in walls: [WallSegment]) -> WallSegment? {
        if let parent = surface.parentIdentifier, let wall = walls.first(where: { $0.id == parent }) { return wall }
        let dir = planDirection(surface.transform.columns.0)
        return walls
            .filter { abs($0.direction.dot(dir)) > 0.8 }
            .min { $0.distance(to: center) < $1.distance(to: center) }
            ?? walls.min { $0.distance(to: center) < $1.distance(to: center) }
    }

    static func label(for category: CapturedRoom.Object.Category) -> String {
        switch category {
        case .storage: return "Storage"
        case .refrigerator: return "Refrigerator"
        case .stove: return "Stove"
        case .bed: return "Bed"
        case .sink: return "Sink"
        case .washerDryer: return "Washer/Dryer"
        case .toilet: return "Toilet"
        case .bathtub: return "Bathtub"
        case .oven: return "Oven"
        case .dishwasher: return "Dishwasher"
        case .table: return "Table"
        case .sofa: return "Sofa"
        case .chair: return "Chair"
        case .fireplace: return "Fireplace"
        case .television: return "Television"
        case .stairs: return "Stairs"
        @unknown default: return "Object"
        }
    }
}
#endif
