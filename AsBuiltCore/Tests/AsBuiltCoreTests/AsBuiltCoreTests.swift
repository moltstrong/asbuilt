import Foundation
import Testing
@testable import AsBuiltCore

private let ft = UnitFormatter.meters(feet:)
private let inch = UnitFormatter.meters(inches:)

private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }

/// Rectangle room with walls running counter-clockwise from the origin.
private func rectangleRoom(widthFt: Double, depthFt: Double, heightFt: Double = 8) -> FloorPlan {
    let w = ft(widthFt), d = ft(depthFt), h = ft(heightFt)
    let pts = [Point2D(0, 0), Point2D(w, 0), Point2D(w, d), Point2D(0, d)]
    let walls = (0..<4).map { WallSegment(start: pts[$0], end: pts[($0 + 1) % 4], height: h) }
    return FloorPlan(name: "Test", walls: walls, ceilingHeight: h)
}

@Suite("Geometry")
struct GeometryTests {
    @Test func shoelaceAreaAndPerimeter() {
        let square = [Point2D(0, 0), Point2D(3, 0), Point2D(3, 4), Point2D(0, 4)]
        #expect(approx(Polygon2D.signedArea(square), 12))
        #expect(approx(Polygon2D.signedArea(square.reversed()), -12))
        #expect(approx(Polygon2D.area(square.reversed()), 12))
        #expect(approx(Polygon2D.perimeter(square), 14))
    }

    @Test func lShapedArea() {
        // 10x10 square with a 5x5 notch removed = 75.
        let l = [Point2D(0, 0), Point2D(10, 0), Point2D(10, 5), Point2D(5, 5), Point2D(5, 10), Point2D(0, 10)]
        #expect(approx(Polygon2D.area(l), 75))
        #expect(approx(Polygon2D.perimeter(l), 40))
    }

    @Test func degeneratePolygons() {
        #expect(Polygon2D.area([]) == 0)
        #expect(Polygon2D.area([Point2D(0, 0), Point2D(1, 1)]) == 0)
        #expect(Polygon2D.perimeter([Point2D(0, 0)]) == 0)
    }

    @Test func centroidOfRectangle() {
        let c = Polygon2D.centroid([Point2D(0, 0), Point2D(4, 0), Point2D(4, 2), Point2D(0, 2)])
        #expect(approx(c.x, 2) && approx(c.y, 1))
    }

    @Test func convexHullDropsInteriorPoints() {
        let pts = [Point2D(0, 0), Point2D(2, 0), Point2D(2, 2), Point2D(0, 2), Point2D(1, 1), Point2D(1, 0)]
        let hull = Polygon2D.convexHull(pts)
        #expect(hull.count == 4)
        #expect(approx(Polygon2D.area(hull), 4))
        #expect(Polygon2D.signedArea(hull) > 0)
    }

    @Test func pointInPolygon() {
        let square = [Point2D(0, 0), Point2D(3, 0), Point2D(3, 3), Point2D(0, 3)]
        #expect(Polygon2D.contains(Point2D(1, 1), in: square))
        #expect(!Polygon2D.contains(Point2D(4, 1), in: square))
    }

    @Test func wallSegmentBasics() {
        let wall = WallSegment(start: Point2D(1, 1), end: Point2D(4, 5), height: 2.5)
        #expect(approx(wall.length, 5))
        #expect(approx(wall.grossArea, 12.5))
        #expect(approx(wall.offset(of: Point2D(4, 5)), 5))
        #expect(approx(wall.distance(to: Point2D(1, 1)), 0))
        let p = wall.point(atOffset: 2.5)
        #expect(approx(p.x, 2.5) && approx(p.y, 3))
    }

    @Test func fixtureCornersRotate() {
        let box = FixtureBox(label: "x", center: Point2D(0, 0), width: 2, depth: 1, height: 1, rotation: .pi / 2)
        let rect = Rect2D.enclosing(box.corners)!
        #expect(approx(rect.width, 1) && approx(rect.height, 2))
    }
}

@Suite("Wall loop")
struct WallLoopTests {
    @Test func closesShuffledAndReversedWalls() {
        var plan = rectangleRoom(widthFt: 12, depthFt: 14)
        // Shuffle and flip one wall to simulate RoomPlan's arbitrary ordering.
        let w = plan.walls
        plan.walls = [w[2], WallSegment(start: w[0].end, end: w[0].start, height: w[0].height), w[3], w[1]]
        let loop = WallLoopBuilder.loop(for: plan.walls)
        #expect(loop != nil)
        #expect(loop?.count == 4)
        #expect(approx(Polygon2D.area(loop!), ft(12) * ft(14), 1e-6))
    }

    @Test func absorbsSmallScanGaps() {
        // Walls that stop 5 cm short of each corner still produce exact corners.
        let g = 0.05
        let walls = [
            WallSegment(start: Point2D(g, 0), end: Point2D(4 - g, 0), height: 2.4),
            WallSegment(start: Point2D(4, g), end: Point2D(4, 3 - g), height: 2.4),
            WallSegment(start: Point2D(4 - g, 3), end: Point2D(g, 3), height: 2.4),
            WallSegment(start: Point2D(0, 3 - g), end: Point2D(0, g), height: 2.4),
        ]
        let loop = WallLoopBuilder.loop(for: walls)!
        #expect(approx(Polygon2D.area(loop), 12, 1e-9))
        #expect(approx(Polygon2D.perimeter(loop), 14, 1e-9))
    }

    @Test func openChainReturnsNil() {
        let walls = [
            WallSegment(start: Point2D(0, 0), end: Point2D(4, 0), height: 2.4),
            WallSegment(start: Point2D(4, 0), end: Point2D(4, 3), height: 2.4),
            WallSegment(start: Point2D(4, 3), end: Point2D(0, 3), height: 2.4),
        ]
        #expect(WallLoopBuilder.loop(for: walls) == nil)
        var plan = FloorPlan(name: "U", walls: walls)
        #expect(plan.resolveFloorPolygon().source == .wallExtents)
        plan.floorPolygon = [Point2D(0, 0), Point2D(4, 0), Point2D(4, 3), Point2D(0, 3)]
        #expect(plan.resolveFloorPolygon().source == .scannedFloor)
    }
}

@Suite("Units")
struct UnitTests {
    @Test func feetInchesFormatting() {
        #expect(UnitFormatter.feetInches(ft(12)) == "12' 0\"")
        #expect(UnitFormatter.feetInches(ft(14) + inch(3)) == "14' 3\"")
        #expect(UnitFormatter.feetInches(inch(80)) == "6' 8\"")
        #expect(UnitFormatter.feetInches(inch(11.6)) == "1' 0\"") // rounds and carries
        #expect(UnitFormatter.feetInches(inch(8)) == "0' 8\"")
        #expect(UnitFormatter.feetInches(0) == "0' 0\"")
        #expect(UnitFormatter.feetInches(-ft(2)) == "-2' 0\"")
    }

    @Test func fractionalInches() {
        #expect(UnitFormatter.feetInches(ft(3) + inch(4.5), fractionDenominator: 2) == "3' 4 1/2\"")
        #expect(UnitFormatter.feetInches(ft(3) + inch(4.25), fractionDenominator: 4) == "3' 4 1/4\"")
        #expect(UnitFormatter.feetInches(ft(3) + inch(4.5), fractionDenominator: 4) == "3' 4 1/2\"")
        #expect(UnitFormatter.feetInches(inch(0.5), fractionDenominator: 2) == "0' 1/2\"")
        #expect(UnitFormatter.feetInches(inch(11.99), fractionDenominator: 8) == "1' 0\"")
    }

    @Test func metricAndAreaFormatting() {
        #expect(UnitFormatter.length(3.6576, .metric) == "3.66 m")
        #expect(UnitFormatter.area(UnitFormatter.squareMeters(squareFeet: 168), .imperial) == "168.0 sq ft")
        #expect(UnitFormatter.area(15.6077, .metric) == "15.61 m²")
        #expect(UnitFormatter.decimal(-0.0001, 2) == "0.00")
    }

    @Test func conversionsRoundTrip() {
        #expect(approx(UnitFormatter.feet(ft(7.25)), 7.25))
        #expect(approx(UnitFormatter.squareFeet(UnitFormatter.squareMeters(squareFeet: 32)), 32))
        #expect(approx(UnitFormatter.metersPerFoot, 12 * UnitFormatter.metersPerInch))
    }
}

@Suite("Takeoff")
struct TakeoffTests {
    @Test func emptyRectangleRoom() {
        let t = TakeoffCalculator.calculate(rectangleRoom(widthFt: 12, depthFt: 14))
        #expect(approx(UnitFormatter.squareFeet(t.floorArea), 168, 1e-6))
        #expect(approx(UnitFormatter.feet(t.perimeter), 52, 1e-6))
        #expect(approx(UnitFormatter.feet(t.ceilingHeight), 8, 1e-9))
        #expect(approx(UnitFormatter.squareFeet(t.grossWallArea), 416, 1e-6))
        #expect(approx(t.netWallArea, t.grossWallArea, 1e-9))
        #expect(t.floorAreaSource == .wallLoop)
        #expect(t.walls.map(\.label) == ["W1", "W2", "W3", "W4"])
    }

    @Test func demoBedroomNumbers() {
        let plan = SampleData.bedroom()
        let t = TakeoffCalculator.calculate(plan)
        let sqft = UnitFormatter.squareFeet
        // Openings: window 3x4 = 12, window 4x4 = 16, closet 5x6.667 = 33.333, door 3x6.667 = 20.
        #expect(t.doorCount == 1)
        #expect(t.windowCount == 2)
        #expect(t.openingCount == 1)
        #expect(t.fixtureCount == 2)
        #expect(approx(sqft(t.floorArea), 168, 1e-6))
        #expect(approx(UnitFormatter.feet(t.perimeter), 52, 1e-6))
        #expect(approx(sqft(t.grossWallArea), 416, 1e-6))
        #expect(approx(sqft(t.openingArea), 12 + 16 + 100.0 / 3 + 20, 1e-6))
        #expect(approx(sqft(t.netWallArea), 416 - 81 - 1.0 / 3, 1e-6))

        // Per-wall net areas: W1 96-12, W2 112-16, W3 96-33.33, W4 112-20.
        let nets = t.walls.map { sqft($0.netArea) }
        #expect(approx(nets[0], 84, 1e-6))
        #expect(approx(nets[1], 96, 1e-6))
        #expect(approx(nets[2], 96 - 100.0 / 3, 1e-6))
        #expect(approx(nets[3], 92, 1e-6))
        #expect(t.walls[3].openingTags == ["D1"])
        #expect(t.walls[0].openingTags == ["WIN1"])
        #expect(t.walls[1].openingTags == ["WIN2"])
        #expect(t.walls[2].openingTags == ["OP1"])
    }

    @Test func materialFormulasWithTenPercentWaste() {
        let plan = SampleData.bedroom()
        let t = TakeoffCalculator.calculate(plan)
        let net = UnitFormatter.squareFeet(t.netWallArea) // 334.6667
        let drywall = t.material(.drywall)!
        #expect(approx(drywall.baseQuantity, net / 32, 1e-9))
        #expect(approx(drywall.quantity, net / 32 * 1.10, 1e-9))
        #expect(drywall.orderQuantity(.imperial) == 12) // 11.5042 -> 12

        let paint = t.material(.paint)!
        #expect(approx(paint.quantity, net / 350 * 2 * 1.10, 1e-9))
        #expect(paint.orderQuantity(.imperial) == 3) // 2.1036 -> 3
        #expect(approx(paint.displayQuantity(.metric), paint.quantity * 3.785411784, 1e-9))

        // Baseboard: 52 ft perimeter - 3 ft door - 5 ft cased opening = 44 ft, + 10%.
        let base = t.material(.baseboard)!
        #expect(approx(UnitFormatter.feet(t.baseboardLength), 44, 1e-6))
        #expect(approx(base.displayQuantity(.imperial), 44 * 1.10, 1e-6))
        #expect(base.orderQuantity(.imperial) == 49) // 48.4 -> 49

        let floor = t.material(.flooring)!
        #expect(approx(floor.displayQuantity(.imperial), 168 * 1.10, 1e-6))
        #expect(floor.orderQuantity(.imperial) == 185) // 184.8 -> 185
        #expect(floor.unit(.imperial) == "sq ft" && floor.unit(.metric) == "m2")
    }

    @Test func customWasteFactor() {
        let options = TakeoffOptions(wasteFactor: 0.15)
        let t = TakeoffCalculator.calculate(rectangleRoom(widthFt: 10, depthFt: 10), options: options)
        let floor = t.material(.flooring)!
        #expect(approx(floor.displayQuantity(.imperial), 100 * 1.15, 1e-6))
        #expect(floor.formula(.imperial).contains("x 1.15"))
        #expect(t.material(.drywall)!.formula(.imperial).contains("15% waste"))
    }

    @Test func openingClampedToWallAndOverlapsNotDoubleCounted() {
        var plan = rectangleRoom(widthFt: 10, depthFt: 10)
        let wall = plan.walls[0]
        // Door hanging 1 ft past the wall start; overlapping window across the door.
        plan.openings = [
            Opening(kind: .door, wallID: wall.id, offset: ft(0.5), width: ft(3), height: ft(7)),
            Opening(kind: .window, wallID: wall.id, offset: ft(1.5), width: ft(2), height: ft(2), sillHeight: ft(6)),
        ]
        let t = TakeoffCalculator.calculate(plan)
        let w1 = t.walls[0]
        // Door occupies 0..2 ft x 0..7 ft = 14; window 0.5..2.5 x 6..8 adds only the
        // non-overlapping parts: (2..2.5 x 6..8 = 1) + (0.5..2 x 7..8 = 1.5) = 2.5.
        #expect(approx(UnitFormatter.squareFeet(w1.openingArea), 14 + 2.5, 1e-6))
        #expect(approx(UnitFormatter.squareFeet(w1.netArea), 80 - 16.5, 1e-6))
    }

    @Test func scannedFloorPolygonWins() {
        var plan = rectangleRoom(widthFt: 12, depthFt: 14)
        plan.floorPolygon = [Point2D(0, 0), Point2D(ft(10), 0), Point2D(ft(10), ft(10)), Point2D(0, ft(10))]
        let t = TakeoffCalculator.calculate(plan)
        #expect(t.floorAreaSource == .scannedFloor)
        #expect(approx(UnitFormatter.squareFeet(t.floorArea), 100, 1e-6))
    }

    @Test func wallElevationPieces() {
        let wall = WallSegment(start: .zero, end: Point2D(4, 0), height: 2.5)
        let window = Opening(kind: .window, wallID: wall.id, offset: 2, width: 1, height: 1, sillHeight: 1)
        let pieces = WallElevation.pieces(for: wall, openings: [window])
        let area = pieces.reduce(0) { $0 + $1.area }
        #expect(approx(area, 10 - 1))
        // Left, right, below-sill and above-head pieces.
        #expect(pieces.count == 4)
    }
}

@Suite("DXF")
struct DXFTests {
    private func demoDXF(_ units: DXFUnits = .inches) throws -> (String, [DXFReader.Pair]) {
        let text = DXFWriter(units: units, notes: ["JOB: Demo"]).write(plan: SampleData.bedroom(), unitSystem: .imperial)
        return (text, try DXFReader.pairs(text))
    }

    @Test func wellFormedGroupCodePairs() throws {
        let (text, pairs) = try demoDXF()
        #expect(text.hasSuffix("  0\r\nEOF\r\n"))
        #expect(pairs.last == DXFReader.Pair(code: 0, value: "EOF"))
        // Every value line for numeric group codes parses as a number.
        for p in pairs where (10...59).contains(p.code) || (60...79).contains(p.code) {
            #expect(Double(p.value) != nil, "group \(p.code) value \(p.value) not numeric")
        }
        // Text is 7-bit ASCII as R12 requires.
        #expect(text.unicodeScalars.allSatisfy { $0.value < 128 })
    }

    @Test func balancedSections() throws {
        let (_, pairs) = try demoDXF()
        var depth = 0
        var sectionNames: [String] = []
        var tableDepth = 0
        for (i, p) in pairs.enumerated() where p.code == 0 {
            switch p.value {
            case "SECTION":
                #expect(depth == 0)
                depth += 1
                #expect(pairs[i + 1].code == 2)
                sectionNames.append(pairs[i + 1].value)
            case "ENDSEC":
                #expect(depth == 1)
                #expect(tableDepth == 0)
                depth -= 1
            case "TABLE": tableDepth += 1
            case "ENDTAB": tableDepth -= 1
            default: break
            }
        }
        #expect(depth == 0)
        #expect(sectionNames == ["HEADER", "TABLES", "BLOCKS", "ENTITIES"])
    }

    @Test func headerVariables() throws {
        let (_, pairs) = try demoDXF()
        func header(_ name: String) -> DXFReader.Pair? {
            guard let i = pairs.firstIndex(where: { $0.code == 9 && $0.value == name }) else { return nil }
            return pairs[i + 1]
        }
        #expect(header("$ACADVER")?.value == "AC1009")
        #expect(header("$INSUNITS") == DXFReader.Pair(code: 70, value: "1"))
        #expect(header("$MEASUREMENT") == DXFReader.Pair(code: 70, value: "0"))

        let metric = try demoDXF(.millimeters).1
        let i = metric.firstIndex { $0.code == 9 && $0.value == "$INSUNITS" }!
        #expect(metric[i + 1].value == "4")
        let j = metric.firstIndex { $0.code == 9 && $0.value == "$MEASUREMENT" }!
        #expect(metric[j + 1].value == "1")
    }

    @Test func layerTableAndEntityLayers() throws {
        let (_, pairs) = try demoDXF()
        var declared: [String] = []
        for (i, p) in pairs.enumerated() where p.code == 0 && p.value == "LAYER" {
            declared.append(pairs[i + 1].value)
        }
        let expected = ["0", "WALLS", "DOORS", "WINDOWS", "OPENINGS", "FIXTURES", "DIMENSIONS", "TEXT"]
        #expect(declared == expected)

        // Every entity references a declared layer, and every required layer is used.
        guard let start = pairs.firstIndex(where: { $0.code == 2 && $0.value == "ENTITIES" }) else {
            Issue.record("no ENTITIES"); return
        }
        var used = Set<String>()
        for p in pairs[start...] where p.code == 8 { used.insert(p.value) }
        #expect(used.isSubset(of: Set(declared)))
        for layer in ["WALLS", "DOORS", "WINDOWS", "OPENINGS", "FIXTURES", "DIMENSIONS", "TEXT"] {
            #expect(used.contains(layer), "layer \(layer) has no entities")
        }
    }

    @Test func entitiesAreInRealUnits() throws {
        let (_, pairs) = try demoDXF()
        let start = pairs.firstIndex { $0.code == 2 && $0.value == "ENTITIES" }!
        // Collect WALLS line x-coordinates; the 12 ft room must span 144 in on the interior face.
        var xs: [Double] = []
        var i = start
        while i < pairs.count {
            if pairs[i].code == 0 && pairs[i].value == "LINE" && pairs[i + 1].value == "WALLS" {
                xs.append(Double(pairs[i + 2].value)!)
                xs.append(Double(pairs[i + 5].value)!)
            }
            i += 1
        }
        #expect(!xs.isEmpty)
        #expect(xs.contains { abs($0 - 144) < 1e-3 })
        #expect(xs.contains { abs($0) < 1e-3 })

        // Wall-length dimension text, opening tags and the room name are present.
        let texts = pairs.enumerated().filter { $0.element.code == 1 }.map(\.element.value)
        #expect(texts.contains("12' 0\""))
        #expect(texts.contains("14' 0\""))
        #expect(texts.contains("BEDROOM 2"))
        #expect(texts.contains { $0.hasPrefix("D1 3'-0\"x6'-8\"") })
        #expect(texts.contains { $0.hasPrefix("WIN1") })
        #expect(texts.contains { $0.hasPrefix("OP1") })
        #expect(texts.contains("BED"))
        #expect(texts.contains("JOB: Demo"))
    }

    @Test func entityCounts() throws {
        let (_, pairs) = try demoDXF()
        let kinds = pairs.filter { $0.code == 0 }.map(\.value)
        #expect(kinds.filter { $0 == "ARC" }.count == 1) // one door swing
        #expect(kinds.filter { $0 == "POLYLINE" }.count == 2) // two fixtures
        #expect(kinds.filter { $0 == "POLYLINE" }.count == kinds.filter { $0 == "SEQEND" }.count)
        #expect(kinds.filter { $0 == "VERTEX" }.count == 8)
    }

    @Test func groupCodesRightAligned() {
        #expect(DXFStream.groupCode(0) == "  0")
        #expect(DXFStream.groupCode(10) == " 10")
        #expect(DXFStream.groupCode(100) == "100")
    }

    @Test func textEncoding() {
        #expect(DXFWriter.encodeText("Ø 2²") == "\\U+00D8 2\\U+00B2")
        #expect(DXFWriter.encodeText("a\nb") == "a b")
    }

    @Test func readerRejectsMalformed() {
        #expect(throws: DXFReader.ReadError.self) { try DXFReader.pairs("  0\nSECTION\n  2") }
        #expect(throws: DXFReader.ReadError.self) { try DXFReader.pairs("X\nSECTION\n") }
    }
}

@Suite("CSV")
struct CSVTests {
    @Test func headerColumns() {
        #expect(CSVWriter.header(.imperial) == [
            "Section", "Item", "Description", "Length (ft)", "Height (ft)",
            "Gross Area (sq ft)", "Openings Area (sq ft)", "Net Area (sq ft)",
            "Quantity", "Order Qty", "Unit", "Notes",
        ])
        #expect(CSVWriter.header(.metric)[3] == "Length (m)")
        #expect(CSVWriter.header(.metric)[5] == "Gross Area (m2)")
    }

    @Test func roundTripAndRowShape() {
        let plan = SampleData.bedroom()
        let csv = CSVWriter.write(plan: plan, units: .imperial)
        let rows = CSVWriter.parse(csv)
        let columns = CSVWriter.header(.imperial).count
        #expect(rows.count > 10)
        #expect(rows.allSatisfy { $0.count == columns })
        #expect(rows.filter { $0[0] == "Wall" }.count == 4)
        #expect(rows.filter { $0[0] == "Opening" }.count == 4)
        #expect(rows.filter { $0[0] == "Fixture" }.count == 2)
        #expect(rows.filter { $0[0] == "Material" }.map { $0[1] } ==
                ["Drywall 4x8 sheets", "Wall paint", "Baseboard", "Flooring"])

        let floor = rows.first { $0[0] == "Room" && $0[1] == "Floor area" }!
        #expect(floor[8] == "168.00")
        let w1 = rows.first { $0[0] == "Wall" && $0[1] == "W1" }!
        #expect(w1[3] == "12.00" && w1[4] == "8.00" && w1[5] == "96.00" && w1[6] == "12.00" && w1[7] == "84.00")
        let drywall = rows.first { $0[1] == "Drywall 4x8 sheets" }!
        #expect(drywall[9] == "12" && drywall[10] == "sheets")
        let base = rows.first { $0[1] == "Baseboard" }!
        #expect(base[8] == "48.40" && base[9] == "49" && base[10] == "LF")
    }

    @Test func metricExport() {
        let rows = CSVWriter.parse(CSVWriter.write(plan: SampleData.bedroom(), units: .metric))
        let floor = rows.first { $0[1] == "Floor area" }!
        #expect(floor[8] == "15.61" && floor[10] == "m2")
        let paint = rows.first { $0[1] == "Wall paint" }!
        #expect(paint[10] == "L")
    }

    @Test func escaping() {
        #expect(CSVWriter.escape("plain") == "plain")
        #expect(CSVWriter.escape("a,b") == "\"a,b\"")
        #expect(CSVWriter.escape("6' 8\"") == "\"6' 8\"\"\"")
        let parsed = CSVWriter.parse("x,\"a,b\",\"6' 8\"\"\"\r\n")
        #expect(parsed == [["x", "a,b", "6' 8\""]])
    }
}

@Suite("Plan drawing & SVG")
struct PlanDrawingTests {
    @Test func drawingContainsAllLayersAndDimensions() {
        let drawing = PlanGeometryBuilder.build(SampleData.bedroom(), units: .imperial)
        #expect(drawing.usedLayers == Set(PlanLayer.allCases))
        let dims = drawing.texts.filter { $0.role == .dimension }.map(\.text)
        #expect(dims.sorted() == ["12' 0\"", "12' 0\"", "14' 0\"", "14' 0\""])
        #expect(drawing.texts.filter { $0.role == .wallTag }.count == 4)
        #expect(drawing.arcs.count == 1)
        // Door swing radius equals door width.
        #expect(approx(drawing.arcs[0].radius, ft(3), 1e-9))
    }

    @Test func doorSwingsIntoRoom() {
        let plan = SampleData.bedroom()
        let arc = PlanGeometryBuilder.build(plan, units: .imperial).arcs[0]
        let mid = (arc.startAngle + 45) * .pi / 180
        let p = arc.center + Point2D(cos(mid), sin(mid)) * (arc.radius * 0.9)
        #expect(Polygon2D.contains(p, in: plan.effectiveFloorPolygon))
    }

    @Test func dimensionsSitOutsideRoom() {
        let plan = SampleData.bedroom()
        let drawing = PlanGeometryBuilder.build(plan, units: .imperial)
        for t in drawing.texts where t.role == .dimension {
            #expect(!Polygon2D.contains(t.position, in: plan.effectiveFloorPolygon))
        }
    }

    @Test func wallsJoinAtCorners() {
        // Exterior face lines meet at the outside corner (-t, -t) of the SW corner.
        let plan = SampleData.bedroom()
        let drawing = PlanGeometryBuilder.build(plan, units: .imperial)
        let t = WallSegment.defaultThickness
        let corner = Point2D(-t, -t)
        let hits = drawing.lines(on: .walls).filter { $0.a.distance(to: corner) < 1e-6 || $0.b.distance(to: corner) < 1e-6 }
        #expect(hits.count == 2)
    }

    @Test func readableAngles() {
        #expect(PlanGeometryBuilder.readableAngle(0) == 0)
        #expect(approx(PlanGeometryBuilder.readableAngle(180), 0))
        #expect(approx(PlanGeometryBuilder.readableAngle(270), 90))
        #expect(approx(PlanGeometryBuilder.readableAngle(-90), 90))
        #expect(approx(PlanGeometryBuilder.readableAngle(135), -45))
    }

    @Test func viewportProjection() {
        let vp = PlanViewport(bounds: Rect2D(minX: 0, minY: 0, maxX: 10, maxY: 5), width: 220, height: 120, padding: 10)
        #expect(approx(vp.scale, 20))
        let topLeft = vp.project(Point2D(0, 5))
        #expect(approx(topLeft.x, 10) && approx(topLeft.y, 10))
        let back = vp.unproject(x: 110, y: 60)
        #expect(approx(back.x, 5) && approx(back.y, 2.5))
    }

    @Test func svgIsWellFormed() throws {
        let svg = SVGRenderer.render(plan: SampleData.bedroom(), units: .imperial,
                                     options: .init(title: "Demo & Co", subtitle: "Bedroom 2"))
        #expect(svg.hasPrefix("<?xml"))
        #expect(svg.contains("Demo &amp; Co"))
        for layer in PlanLayer.allCases { #expect(svg.contains("id=\"\(layer.rawValue)\"")) }
        #expect(svg.components(separatedBy: "<g ").count == svg.components(separatedBy: "</g>").count)
        #if canImport(FoundationXML) || os(macOS)
        let parser = XMLParser(data: Data(svg.utf8))
        #expect(parser.parse(), "SVG failed to parse: \(String(describing: parser.parserError))")
        #endif
    }
}

@Suite("Codable")
struct CodableTests {
    @Test func floorPlanRoundTrip() throws {
        let plan = SampleData.bedroom()
        let data = try JSONEncoder().encode(plan)
        let back = try JSONDecoder().decode(FloorPlan.self, from: data)
        #expect(back == plan)
    }
}

@Suite("Sample export")
struct SampleExportTests {
    /// Writes the demo room's DXF/SVG/CSV to $ASBUILT_EXPORT_DIR (CI uploads these as an artifact).
    @Test func writeSampleFilesWhenRequested() throws {
        guard let dir = ProcessInfo.processInfo.environment["ASBUILT_EXPORT_DIR"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let plan = SampleData.bedroom()
        try DXFWriter(units: .inches, notes: ["AsBuilt demo export"]).write(plan: plan, unitSystem: .imperial)
            .write(to: url.appendingPathComponent("floorplan.dxf"), atomically: true, encoding: .ascii)
        try DXFWriter(units: .inches).write(plan: SampleData.kitchen(), unitSystem: .imperial)
            .write(to: url.appendingPathComponent("kitchen.dxf"), atomically: true, encoding: .ascii)
        try SVGRenderer.render(plan: SampleData.kitchen(), units: .imperial, options: .init(title: "Demo Job", subtitle: "Kitchen"))
            .write(to: url.appendingPathComponent("kitchen.svg"), atomically: true, encoding: .utf8)
        try SVGRenderer.render(plan: plan, units: .imperial, options: .init(title: "Demo Job", subtitle: plan.name))
            .write(to: url.appendingPathComponent("floorplan.svg"), atomically: true, encoding: .utf8)
        try CSVWriter.write(plan: plan, units: .imperial)
            .write(to: url.appendingPathComponent("takeoff.csv"), atomically: true, encoding: .utf8)
        var zip = ZipWriter()
        for name in ["floorplan.dxf", "floorplan.svg", "takeoff.csv"] {
            zip.add(path: "AsBuilt-Demo/" + name, data: try Data(contentsOf: url.appendingPathComponent(name)))
        }
        try zip.archive().write(to: url.appendingPathComponent("AsBuilt-Demo.zip"))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("floorplan.dxf").path))
    }
}

@Suite("Normalization")
struct NormalizationTests {
    @Test func ordersShuffledFlippedWallsCounterClockwiseFromSouthWest() {
        let plan = SampleData.bedroom()
        var scrambled = plan
        // Reverse direction of every wall (clockwise loop), shuffle the order and remap offsets.
        scrambled.walls = [plan.walls[2], plan.walls[0], plan.walls[3], plan.walls[1]].map {
            WallSegment(id: $0.id, start: $0.end, end: $0.start, height: $0.height)
        }
        scrambled.openings = plan.openings.map { o in
            var o = o
            o.offset = plan.wall(withID: o.wallID)!.length - o.offset
            return o
        }
        let normalized = scrambled.normalized()
        #expect(normalized.walls.map(\.id) == plan.walls.map(\.id))
        for (a, b) in zip(normalized.walls, plan.walls) {
            #expect(a.start.distance(to: b.start) < 1e-9 && a.end.distance(to: b.end) < 1e-9)
        }
        for o in normalized.openings {
            let original = plan.openings.first { $0.id == o.id }!
            #expect(approx(o.offset, original.offset, 1e-9))
        }
        // Takeoff is identical regardless of input order.
        let t1 = TakeoffCalculator.calculate(plan)
        let t2 = TakeoffCalculator.calculate(normalized)
        #expect(approx(t1.netWallArea, t2.netWallArea, 1e-9))
        #expect(t1.walls.map(\.openingTags) == t2.walls.map(\.openingTags))
    }

    @Test func openWallsAreLeftAlone() {
        let walls = [
            WallSegment(start: Point2D(0, 0), end: Point2D(4, 0), height: 2.4),
            WallSegment(start: Point2D(4, 0), end: Point2D(4, 3), height: 2.4),
        ]
        let plan = FloorPlan(name: "Open", walls: walls)
        #expect(plan.normalized() == plan)
    }
}

@Suite("Zip")
struct ZipTests {
    @Test func crc32KnownVector() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF43926)
        #expect(CRC32.checksum(Data()) == 0)
    }

    @Test func archiveStructure() {
        var zip = ZipWriter()
        zip.add(path: "floorplan.dxf", data: Data("  0\r\nEOF\r\n".utf8))
        zip.add(path: "takeoff.csv", data: Data("a,b\r\n".utf8))
        let data = zip.archive()
        #expect(data.readLE(UInt32.self, at: 0) == 0x04034b50)
        // End-of-central-directory record is the last 22 bytes.
        let eocd = data.count - 22
        #expect(data.readLE(UInt32.self, at: eocd) == 0x06054b50)
        #expect(data.readLE(UInt16.self, at: eocd + 10) == 2)
        let centralOffset = Int(data.readLE(UInt32.self, at: eocd + 16))
        #expect(data.readLE(UInt32.self, at: centralOffset) == 0x02014b50)
        // Stored payload is present verbatim.
        let payload = Data("a,b\r\n".utf8)
        #expect(data.range(of: payload) != nil)
    }

    @Test func dosDate() {
        let date = ISO8601DateFormatter().date(from: "2026-10-22T13:45:30Z")!
        let (time, day) = ZipWriter.dosDateTime(date)
        let expectedTime: Int = (13 << 11) | (45 << 5) | 15
        let expectedDay: Int = ((2026 - 1980) << 9) | (10 << 5) | 22
        #expect(Int(time) == expectedTime)
        #expect(Int(day) == expectedDay)
    }
}

@Suite("Label placement & kitchen sample")
struct LabelPlacementTests {
    @Test func kitchenTakeoff() {
        let t = TakeoffCalculator.calculate(SampleData.kitchen())
        #expect(approx(UnitFormatter.squareFeet(t.floorArea), 143, 1e-6))
        #expect(approx(UnitFormatter.feet(t.perimeter), 48, 1e-6))
        #expect(approx(UnitFormatter.feet(t.ceilingHeight), 9, 1e-9))
        #expect(t.doorCount == 1 && t.windowCount == 1 && t.openingCount == 1 && t.fixtureCount == 6)
        // Gross 48 x 9 = 432; openings 4x3.5=14, 2.667x6.667=17.78, 4x7=28.
        let openings = 14 + (32.0 * 80 / 144) + 28
        #expect(approx(UnitFormatter.squareFeet(t.netWallArea), 432 - openings, 1e-6))
        // Baseboard: 48 - 2.667 door - 4 opening.
        #expect(approx(UnitFormatter.feet(t.baseboardLength), 48 - 32.0 / 12 - 4, 1e-6))
    }

    @Test func labelsAvoidFixtures() {
        for plan in [SampleData.bedroom(), SampleData.kitchen()] {
            let drawing = PlanGeometryBuilder.build(plan, units: .imperial)
            let boxes = plan.fixtures.compactMap { Rect2D.enclosing($0.corners) }
            for text in drawing.texts where text.role == .wallTag || text.role == .roomName {
                #expect(!boxes.contains { $0.contains(text.position) }, "\(text.text) overlaps a fixture in \(plan.name)")
            }
        }
    }

    @Test func fixtureLabelsFitTheirBoxes() {
        let plan = SampleData.kitchen()
        let drawing = PlanGeometryBuilder.build(plan, units: .imperial)
        for text in drawing.texts where text.role == .fixtureLabel {
            let fixture = plan.fixtures.first { $0.center == text.position }!
            let span = max(fixture.width, fixture.depth)
            #expect(Double(text.text.count) * text.height * 0.82 <= span * 0.85 + 1e-9 || text.height == 0.05)
        }
    }

    @Test func kitchenDXFParses() throws {
        let dxf = DXFWriter(units: .millimeters).write(plan: SampleData.kitchen(), unitSystem: .metric)
        let pairs = try DXFReader.pairs(dxf)
        #expect(pairs.last?.value == "EOF")
        #expect(pairs.filter { $0.code == 0 && $0.value == "POLYLINE" }.count == 6)
    }
}

@Suite("Fixture label fit")
struct FixtureLabelFitTests {
    @Test func narrowDishwasherUsesAbbreviation() {
        let drawing = PlanGeometryBuilder.build(SampleData.kitchen(), units: .imperial)
        let labels = drawing.texts.filter { $0.role == .fixtureLabel }.map(\.text)
        #expect(labels.contains("DW"))
        #expect(!labels.contains("DISHWASHER"))
        #expect(labels.contains("SINK"))
    }

    @Test func abbreviationTable() {
        #expect(PlanDrawing.abbreviation(for: "Refrigerator") == "REF")
        #expect(PlanDrawing.abbreviation(for: "unknown thing") == nil)
    }
}
