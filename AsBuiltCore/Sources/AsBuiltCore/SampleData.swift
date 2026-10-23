import Foundation

/// Bundled sample data so the plan, takeoff and exports can be reviewed without a LiDAR device.
public enum SampleData {
    public static let demoJobID = UUID(uuidString: "6A3B1C2D-0000-4000-8000-00000000A001")!
    public static let demoCaptureID = UUID(uuidString: "6A3B1C2D-0000-4000-8000-00000000B001")!
    /// Demo LiDAR Mesh scan (procedural, see `DemoMeshScan`).
    public static let demoMeshCaptureID = UUID(uuidString: "6A3B1C2D-0000-4000-8000-00000000B003")!
    /// Demo Detail scan (TSDF fusion of synthetic depth maps, see `DemoDetailScan`).
    public static let demoDetailCaptureID = UUID(uuidString: "6A3B1C2D-0000-4000-8000-00000000B004")!

    static let w1 = UUID(uuidString: "6A3B1C2D-0000-4000-8000-0000000000E1")!
    static let w2 = UUID(uuidString: "6A3B1C2D-0000-4000-8000-0000000000E2")!
    static let w3 = UUID(uuidString: "6A3B1C2D-0000-4000-8000-0000000000E3")!
    static let w4 = UUID(uuidString: "6A3B1C2D-0000-4000-8000-0000000000E4")!

    /// A 12 ft x 14 ft bedroom with 8 ft ceilings: a 3'-0" entry door, two windows and a
    /// 5'-0" closet opening, plus a bed and a dresser.
    ///
    /// Walls run counter-clockwise from the south-west corner along the interior faces:
    /// W1 south (12'), W2 east (14'), W3 north (12'), W4 west (14').
    public static func bedroom() -> FloorPlan {
        let ft = UnitFormatter.meters(feet:)
        let inch = UnitFormatter.meters(inches:)
        let h = ft(8)
        let sw = Point2D(0, 0)
        let se = Point2D(ft(12), 0)
        let ne = Point2D(ft(12), ft(14))
        let nw = Point2D(0, ft(14))
        let walls = [
            WallSegment(id: w1, start: sw, end: se, height: h),
            WallSegment(id: w2, start: se, end: ne, height: h),
            WallSegment(id: w3, start: ne, end: nw, height: h),
            WallSegment(id: w4, start: nw, end: sw, height: h),
        ]
        let openings = [
            // South window, centered: 3'-0" x 4'-0", 3'-0" sill.
            Opening(id: UUID(uuidString: "6A3B1C2D-0000-4000-8000-00000000C001")!, kind: .window, wallID: w1,
                    offset: ft(6), width: ft(3), height: ft(4), sillHeight: ft(3)),
            // East window: 4'-0" x 4'-0", 3'-0" sill, centered 7' from the SE corner.
            Opening(id: UUID(uuidString: "6A3B1C2D-0000-4000-8000-00000000C002")!, kind: .window, wallID: w2,
                    offset: ft(7), width: ft(4), height: ft(4), sillHeight: ft(3)),
            // Closet opening on the north wall: 5'-0" x 6'-8", 1'-6" from the NE corner.
            Opening(id: UUID(uuidString: "6A3B1C2D-0000-4000-8000-00000000C003")!, kind: .opening, wallID: w3,
                    offset: ft(1.5) + ft(2.5), width: ft(5), height: ft(6) + inch(8)),
            // Entry door on the west wall: 3'-0" x 6'-8", 1'-0" from the SW corner.
            Opening(id: UUID(uuidString: "6A3B1C2D-0000-4000-8000-00000000C004")!, kind: .door, wallID: w4,
                    offset: ft(14) - ft(1) - ft(1.5), width: ft(3), height: ft(6) + inch(8)),
        ]
        let fixtures = [
            FixtureBox(id: UUID(uuidString: "6A3B1C2D-0000-4000-8000-00000000F001")!, label: "Bed",
                       center: Point2D(ft(12) - ft(0.25) - inch(30), ft(7)), width: inch(60), depth: inch(80),
                       height: inch(24)),
            FixtureBox(id: UUID(uuidString: "6A3B1C2D-0000-4000-8000-00000000F002")!, label: "Dresser",
                       center: Point2D(inch(9.5), ft(8.5)), width: inch(18), depth: inch(48),
                       height: inch(34)),
        ]
        return FloorPlan(name: "Bedroom 2", walls: walls, openings: openings, fixtures: fixtures,
                         floorPolygon: nil, ceilingHeight: h)
    }

    public static let demoKitchenCaptureID = UUID(uuidString: "6A3B1C2D-0000-4000-8000-00000000B002")!

    /// An 11 ft x 13 ft kitchen, 9 ft ceilings: window over the sink, a 2'-8" side door,
    /// a 4'-0" cased opening to the dining room and RoomPlan-style appliance/cabinet boxes.
    public static func kitchen() -> FloorPlan {
        let ft = UnitFormatter.meters(feet:)
        let inch = UnitFormatter.meters(inches:)
        let h = ft(9)
        let ids = (1...4).map { UUID(uuidString: String(format: "6A3B1C2D-0000-4000-8000-0000000001E%d", $0))! }
        let p = [Point2D(0, 0), Point2D(ft(11), 0), Point2D(ft(11), ft(13)), Point2D(0, ft(13))]
        let walls = (0..<4).map { WallSegment(id: ids[$0], start: p[$0], end: p[($0 + 1) % 4], height: h) }
        func oid(_ n: Int) -> UUID { UUID(uuidString: String(format: "6A3B1C2D-0000-4000-8000-0000000002C%d", n))! }
        func fid(_ n: Int) -> UUID { UUID(uuidString: String(format: "6A3B1C2D-0000-4000-8000-0000000002F%d", n))! }
        let openings = [
            Opening(id: oid(1), kind: .window, wallID: ids[0], offset: ft(5.5), width: ft(4), height: inch(42), sillHeight: inch(42)),
            Opening(id: oid(2), kind: .door, wallID: ids[1], offset: ft(4) + inch(4), width: inch(32), height: inch(80)),
            Opening(id: oid(3), kind: .opening, wallID: ids[3], offset: ft(13) - ft(6), width: ft(4), height: inch(84)),
        ]
        let d = ft(2)
        let fixtures = [
            FixtureBox(id: fid(1), label: "Cabinets", center: Point2D(ft(4.25) / 2, d / 2), width: ft(4.25), depth: d, height: inch(36)),
            FixtureBox(id: fid(2), label: "Sink", center: Point2D(ft(5.5), d / 2), width: ft(2.5), depth: d, height: inch(36)),
            FixtureBox(id: fid(3), label: "Dishwasher", center: Point2D(ft(7.75), d / 2), width: ft(2), depth: d, height: inch(34)),
            FixtureBox(id: fid(4), label: "Cabinets", center: Point2D(ft(8.75) + ft(2.25) / 2, d / 2), width: ft(2.25), depth: d, height: inch(36)),
            FixtureBox(id: fid(5), label: "Refrigerator", center: Point2D(inch(15), ft(13) - inch(18)), width: inch(30), depth: inch(36), height: inch(70)),
            FixtureBox(id: fid(6), label: "Stove", center: Point2D(ft(6.25), ft(13) - d / 2), width: inch(30), depth: d, height: inch(36)),
        ]
        return FloorPlan(name: "Kitchen", walls: walls, openings: openings, fixtures: fixtures,
                         floorPolygon: nil, ceilingHeight: h)
    }

    /// Tape calibration of the demo job: the door opening read 36-1/8" and the tape said 36".
    public static let demoMeasureScale = 36.0 / 36.125

    /// Demo Measure-tool measurements (one tape-calibrated), so the Measurements list shows real data.
    public static func demoMeasurements() -> [PrecisionMeasurement] {
        let inch: Float = 0.0254
        let date = ISO8601DateFormatter().date(from: "2026-10-20T17:10:00Z") ?? Date(timeIntervalSince1970: 0)
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "6A3B1C2D-0000-4000-8000-0000000C%04d", n))! }
        let raw = 36.125 * inch
        return [
            PrecisionMeasurement(id: id(1), label: "Door rough opening width", createdAt: date,
                                 start: SIMD3(0, 1.0, -1.5), end: SIMD3(raw, 1.0, -1.5),
                                 uncertaintyMeters: 0.0021, samples: 24, method: "lidarDepth", tapeMeters: Double(36 * inch)),
            PrecisionMeasurement(id: id(2), label: "Window sill height", createdAt: date.addingTimeInterval(60),
                                 start: SIMD3(1.2, 0, -2.0), end: SIMD3(1.2, 30.25 * inch, -2.0),
                                 uncertaintyMeters: 0.0018, samples: 26, method: "lidarDepth"),
            PrecisionMeasurement(id: id(3), label: "Valve to box center", createdAt: date.addingTimeInterval(120),
                                 start: SIMD3(-0.10, 0.17, -0.05), end: SIMD3(0.12, 0.10, -0.065),
                                 uncertaintyMeters: 0.0012, samples: 22, method: "lidarDepth"),
            PrecisionMeasurement(id: id(4), label: "Ceiling height", createdAt: date.addingTimeInterval(180),
                                 start: SIMD3(2.0, 0, -1.0), end: SIMD3(2.0, 96.5 * inch, -1.0),
                                 uncertaintyMeters: 0.0042, samples: 18, method: "raycast"),
        ]
    }
}
