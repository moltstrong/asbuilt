import Foundation

/// CAD layers used by every plan output (DXF, SVG, PDF and the in-app canvas).
public enum PlanLayer: String, Codable, CaseIterable, Sendable {
    case walls = "WALLS"
    case doors = "DOORS"
    case windows = "WINDOWS"
    case openings = "OPENINGS"
    case fixtures = "FIXTURES"
    case dimensions = "DIMENSIONS"
    case text = "TEXT"

    /// AutoCAD Color Index.
    public var aciColor: Int {
        switch self {
        case .walls: return 7       // white/black
        case .doors: return 30      // orange
        case .windows: return 4     // cyan
        case .openings: return 6    // magenta
        case .fixtures: return 8    // gray
        case .dimensions: return 1  // red
        case .text: return 7
        }
    }

    /// RGB hex color used for SVG/PDF/on-screen rendering.
    public var hexColor: String {
        switch self {
        case .walls: return "#111827"
        case .doors: return "#C2410C"
        case .windows: return "#0369A1"
        case .openings: return "#7E22CE"
        case .fixtures: return "#4B5563"
        case .dimensions: return "#B91C1C"
        case .text: return "#111827"
        }
    }

    /// Line weight in drawing points for rendered outputs.
    public var lineWeight: Double {
        switch self {
        case .walls: return 1.6
        case .doors, .windows: return 1.0
        case .openings: return 1.0
        case .fixtures: return 0.8
        case .dimensions: return 0.6
        case .text: return 0.5
        }
    }

    public var isDashed: Bool { self == .openings }
    public var dxfLineType: String { isDashed ? "DASHED" : "CONTINUOUS" }
}

public struct PlanLine: Hashable, Sendable {
    public var a: Point2D
    public var b: Point2D
    public var layer: PlanLayer
}

/// Circular arc swept counter-clockwise from `startAngle` to `endAngle` (degrees).
public struct PlanArc: Hashable, Sendable {
    public var center: Point2D
    public var radius: Double
    public var startAngle: Double
    public var endAngle: Double
    public var layer: PlanLayer
}

public struct PlanPolyline: Hashable, Sendable {
    public var points: [Point2D]
    public var closed: Bool
    public var layer: PlanLayer
}

/// Filled region (wall poché) for rendered outputs only; not written to DXF.
public struct PlanFill: Hashable, Sendable {
    public var points: [Point2D]
    public var layer: PlanLayer
}

public enum PlanTextRole: String, Hashable, Sendable {
    case roomName, roomInfo, dimension, tag, wallTag, fixtureLabel
}

/// Single-line text centered on `position`, rotated `rotation` degrees counter-clockwise.
public struct PlanText: Hashable, Sendable {
    public var text: String
    public var position: Point2D
    /// Cap height in meters.
    public var height: Double
    public var rotation: Double
    public var layer: PlanLayer
    public var role: PlanTextRole
}

/// Vector drawing of a floor plan in plan meters, consumed by every renderer/exporter.
public struct PlanDrawing: Sendable {
    public var lines: [PlanLine] = []
    public var arcs: [PlanArc] = []
    public var polylines: [PlanPolyline] = []
    public var fills: [PlanFill] = []
    public var texts: [PlanText] = []

    public init() {}

    /// Extents of all geometry, including approximate text boxes.
    public var bounds: Rect2D {
        var points: [Point2D] = []
        for l in lines { points.append(l.a); points.append(l.b) }
        for a in arcs {
            points.append(a.center + Point2D(a.radius, a.radius))
            points.append(a.center - Point2D(a.radius, a.radius))
        }
        for p in polylines { points.append(contentsOf: p.points) }
        for f in fills { points.append(contentsOf: f.points) }
        for t in texts {
            let halfWidth = Double(t.text.count) * t.height * 0.32
            points.append(t.position + Point2D(halfWidth, t.height))
            points.append(t.position - Point2D(halfWidth, t.height))
        }
        return Rect2D.enclosing(points) ?? Rect2D(minX: 0, minY: 0, maxX: 1, maxY: 1)
    }

    public func lines(on layer: PlanLayer) -> [PlanLine] { lines.filter { $0.layer == layer } }
    public func texts(on layer: PlanLayer) -> [PlanText] { texts.filter { $0.layer == layer } }

    public var usedLayers: Set<PlanLayer> {
        var set = Set<PlanLayer>()
        lines.forEach { set.insert($0.layer) }
        arcs.forEach { set.insert($0.layer) }
        polylines.forEach { set.insert($0.layer) }
        texts.forEach { set.insert($0.layer) }
        return set
    }
}

/// Turns a `FloorPlan` into architectural plan geometry: wall faces broken at openings,
/// door leaves and swings, window glazing, cased openings, fixture outlines, wall-length
/// dimensions and annotation text.
public enum PlanGeometryBuilder {
    public struct Style: Sendable {
        public var dimensionOffset: Double = 0.55
        public var dimensionTextHeight: Double = 0.13
        public var tagTextHeight: Double = 0.11
        public var roomNameHeight: Double = 0.24
        public var roomInfoHeight: Double = 0.14
        public var fixtureTextHeight: Double = 0.10
        public var tickSize: Double = 0.09
        public var extensionGap: Double = 0.06
        public var extensionOvershoot: Double = 0.08
        public var joinTolerance: Double = 0.35

        public init() {}
    }

    struct WallFrame {
        var wall: WallSegment
        var direction: Point2D
        var inward: Point2D
        var outward: Point2D
        var length: Double
        /// Along-wall parameters where the interior / exterior face lines start and end
        /// after joining neighbouring walls (may be < 0 or > length at corners).
        var interiorStart: Double
        var interiorEnd: Double
        var exteriorStart: Double
        var exteriorEnd: Double
        var startJoined: Bool
        var endJoined: Bool

        func interior(_ t: Double) -> Point2D { wall.start + direction * t }
        func exterior(_ t: Double) -> Point2D { wall.start + direction * t + outward * wall.thickness }
        func inside(_ t: Double, by d: Double) -> Point2D { interior(t) + inward * d }
        func outside(_ t: Double, by d: Double) -> Point2D { interior(t) + outward * d }
    }

    public static func build(_ plan: FloorPlan, units: UnitSystem, style: Style = Style()) -> PlanDrawing {
        var drawing = PlanDrawing()
        let reference = plan.interiorReferencePoint
        let frames = makeFrames(plan, reference: reference, tolerance: style.joinTolerance)
        let tags = plan.openingTags()
        let obstacles = plan.fixtures.compactMap { Rect2D.enclosing($0.corners) }

        for (index, frame) in frames.enumerated() {
            let wall = frame.wall
            let length = frame.length
            let wallOpenings = plan.openings(onWall: wall.id)
            let intervals = wallOpenings.compactMap { WallElevation.interval(of: $0, wallLength: length) }
            let spans = WallElevation.solidSpans(length: length, cuts: intervals)

            // Wall faces, broken at openings, plus poché fill.
            for span in spans {
                let touchesStart = span.lowerBound <= 1e-6
                let touchesEnd = span.upperBound >= length - 1e-6
                let inA = touchesStart ? frame.interiorStart : span.lowerBound
                let inB = touchesEnd ? frame.interiorEnd : span.upperBound
                let outA = touchesStart ? frame.exteriorStart : span.lowerBound
                let outB = touchesEnd ? frame.exteriorEnd : span.upperBound
                drawing.lines.append(PlanLine(a: frame.interior(inA), b: frame.interior(inB), layer: .walls))
                drawing.lines.append(PlanLine(a: frame.exterior(outA), b: frame.exterior(outB), layer: .walls))
                drawing.fills.append(PlanFill(points: [frame.interior(inA), frame.interior(inB),
                                                       frame.exterior(outB), frame.exterior(outA)],
                                              layer: .walls))
            }
            // Free wall ends get an end cap.
            if !frame.startJoined && (spans.first?.lowerBound ?? 1) <= 1e-6 {
                drawing.lines.append(PlanLine(a: frame.interior(frame.interiorStart),
                                              b: frame.exterior(frame.exteriorStart), layer: .walls))
            }
            if !frame.endJoined && (spans.last?.upperBound ?? 0) >= length - 1e-6 {
                drawing.lines.append(PlanLine(a: frame.interior(frame.interiorEnd),
                                              b: frame.exterior(frame.exteriorEnd), layer: .walls))
            }

            // Openings.
            for opening in wallOpenings {
                guard let iv = WallElevation.interval(of: opening, wallLength: length) else { continue }
                let a = iv.lowerBound
                let b = iv.upperBound
                let width = b - a
                // Jambs.
                if a > 1e-6 { drawing.lines.append(PlanLine(a: frame.interior(a), b: frame.exterior(a), layer: .walls)) }
                if b < length - 1e-6 { drawing.lines.append(PlanLine(a: frame.interior(b), b: frame.exterior(b), layer: .walls)) }

                switch opening.kind {
                case .door:
                    let hinge = frame.interior(a)
                    let leafEnd = hinge + frame.inward * width
                    drawing.lines.append(PlanLine(a: hinge, b: leafEnd, layer: .doors))
                    let wallAngle = frame.direction.angleDegrees
                    let leafAngle = frame.inward.angleDegrees
                    // Sweep from the closed position (along the wall) to the open leaf, CCW.
                    let leftTurn = frame.direction.cross(frame.inward) > 0
                    let start = leftTurn ? wallAngle : leafAngle
                    drawing.arcs.append(PlanArc(center: hinge, radius: width,
                                                startAngle: normalizeDegrees(start),
                                                endAngle: normalizeDegrees(start + 90), layer: .doors))
                    // Threshold line across the opening at the exterior face.
                    drawing.lines.append(PlanLine(a: frame.exterior(a), b: frame.exterior(b), layer: .doors))
                case .window:
                    let t = wall.thickness
                    drawing.lines.append(PlanLine(a: frame.interior(a), b: frame.interior(b), layer: .windows))
                    drawing.lines.append(PlanLine(a: frame.outside(a, by: t * 0.5), b: frame.outside(b, by: t * 0.5), layer: .windows))
                    drawing.lines.append(PlanLine(a: frame.exterior(a), b: frame.exterior(b), layer: .windows))
                case .opening:
                    drawing.lines.append(PlanLine(a: frame.interior(a), b: frame.interior(b), layer: .openings))
                    drawing.lines.append(PlanLine(a: frame.exterior(a), b: frame.exterior(b), layer: .openings))
                }

                // Tag just outside the wall: "D1 3'-0" x 6'-8"".
                let tag = tags[opening.id] ?? opening.kind.tagPrefix
                let label = "\(tag) \(sizeLabel(opening, units))"
                let tagPoint = frame.outside((a + b) / 2, by: wall.thickness + style.tagTextHeight * 1.4)
                drawing.texts.append(PlanText(text: label, position: tagPoint, height: style.tagTextHeight,
                                              rotation: readableAngle(frame.direction.angleDegrees),
                                              layer: .text, role: .tag))
            }

            // Wall tag inside the room, clear of fixtures.
            let tagPosition = wallTagPosition(frame: frame, cuts: intervals, fixtures: obstacles,
                                              inset: style.tagTextHeight * 2.2, textHeight: style.tagTextHeight)
            drawing.texts.append(PlanText(text: "W\(index + 1)",
                                          position: tagPosition,
                                          height: style.tagTextHeight,
                                          rotation: readableAngle(frame.direction.angleDegrees),
                                          layer: .text, role: .wallTag))

            // Dimension: measured interior face length.
            addDimension(to: &drawing, frame: frame, units: units, style: style)
        }

        for fixture in plan.fixtures {
            drawing.polylines.append(PlanPolyline(points: fixture.corners, closed: true, layer: .fixtures))
            let corners = fixture.corners
            drawing.lines.append(PlanLine(a: corners[0], b: corners[2], layer: .fixtures))
            // Run the label along the box's long side and shrink it to fit.
            let label = fixture.label.uppercased()
            let alongWidth = fixture.width >= fixture.depth
            let span = alongWidth ? fixture.width : fixture.depth
            let fit = span * 0.85 / max(1, Double(label.count) * 0.82)
            let angle = fixture.rotation * 180 / .pi + (alongWidth ? 0 : 90)
            drawing.texts.append(PlanText(text: label, position: fixture.center,
                                          height: max(0.05, min(style.fixtureTextHeight, fit)),
                                          rotation: readableAngle(angle),
                                          layer: .fixtures, role: .fixtureLabel))
        }

        // Room name and summary at the centroid.
        let takeoff = TakeoffCalculator.calculate(plan)
        let center = roomLabelPosition(plan: plan, reference: reference, obstacles: obstacles, style: style)
        drawing.texts.append(PlanText(text: plan.name.uppercased(), position: center + Point2D(0, style.roomNameHeight * 0.9),
                                      height: style.roomNameHeight, rotation: 0, layer: .text, role: .roomName))
        let areaText = UnitFormatter.area(takeoff.floorArea, units).replacingOccurrences(of: "²", with: "2").uppercased()
        drawing.texts.append(PlanText(text: areaText, position: center - Point2D(0, style.roomInfoHeight * 0.6),
                                      height: style.roomInfoHeight, rotation: 0, layer: .text, role: .roomInfo))
        drawing.texts.append(PlanText(text: "CLG \(UnitFormatter.length(takeoff.ceilingHeight, units))",
                                      position: center - Point2D(0, style.roomInfoHeight * 2.4),
                                      height: style.roomInfoHeight, rotation: 0, layer: .text, role: .roomInfo))
        return drawing
    }

    // MARK: - Helpers

    static func sizeLabel(_ opening: Opening, _ units: UnitSystem) -> String {
        switch units {
        case .imperial:
            return "\(compactFeetInches(opening.width))x\(compactFeetInches(opening.height))"
        case .metric:
            return "\(Int((opening.width * 1000).rounded()))x\(Int((opening.height * 1000).rounded()))"
        }
    }

    /// `3'-0"` style used on door/window tags.
    static func compactFeetInches(_ meters: Double) -> String {
        UnitFormatter.feetInches(meters).replacingOccurrences(of: "' ", with: "'-")
    }

    static func addDimension(to drawing: inout PlanDrawing, frame: WallFrame, units: UnitSystem, style: Style) {
        let length = frame.length
        guard length > 0.05 else { return }
        let offset = frame.wall.thickness + style.dimensionOffset
        let p0 = frame.outside(0, by: offset)
        let p1 = frame.outside(length, by: offset)
        drawing.lines.append(PlanLine(a: p0, b: p1, layer: .dimensions))
        for t in [0.0, length] {
            let from = frame.outside(t, by: frame.wall.thickness + style.extensionGap)
            let to = frame.outside(t, by: offset + style.extensionOvershoot)
            drawing.lines.append(PlanLine(a: from, b: to, layer: .dimensions))
            // 45 degree architectural tick.
            let tickCenter = frame.outside(t, by: offset)
            let diagonal = (frame.direction + frame.outward).normalized * style.tickSize
            drawing.lines.append(PlanLine(a: tickCenter - diagonal, b: tickCenter + diagonal, layer: .dimensions))
        }
        let textPoint = frame.outside(length / 2, by: offset + style.dimensionTextHeight * 0.95)
        drawing.texts.append(PlanText(text: UnitFormatter.length(length, units), position: textPoint,
                                      height: style.dimensionTextHeight,
                                      rotation: readableAngle(frame.direction.angleDegrees),
                                      layer: .dimensions, role: .dimension))
    }

    /// Keeps text upright: maps any angle into (-90, 90].
    public static func readableAngle(_ degrees: Double) -> Double {
        var a = normalizeDegrees(degrees)
        if a > 180 { a -= 360 }
        if a > 90.0001 { a -= 180 }
        if a <= -89.9999 { a += 180 }
        return abs(a) < 1e-9 ? 0 : a
    }

    /// Maps any angle into [0, 360).
    public static func normalizeDegrees(_ degrees: Double) -> Double {
        var a = degrees.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        if abs(a - 360) < 1e-9 { a = 0 }
        return a
    }

    /// Inside the room near the wall, preferring the middle of the widest solid span,
    /// and skipping spots covered by fixtures.
    static func wallTagPosition(frame: WallFrame, cuts: [ClosedRange<Double>], fixtures: [Rect2D],
                                inset: Double, textHeight: Double) -> Point2D {
        let length = frame.length
        var candidates = [bestWallTagOffset(length: length, cuts: cuts)]
        for f in [0.5, 0.3, 0.7, 0.15, 0.85, 0.08, 0.92] { candidates.append(length * f) }
        let pad = textHeight * 1.2
        // Try close to the wall first; if fixtures run the full wall (base cabinets), step clear of them.
        for depth in [inset, inset * 2.2, 0.75, 0.95, 1.2] {
            for t in candidates {
                let p = frame.inside(t, by: depth)
                let blocked = fixtures.contains { $0.expanded(by: pad).contains(p) }
                let onOpening = cuts.contains { ($0.lowerBound - pad)...($0.upperBound + pad) ~= t }
                if !blocked && !onOpening { return p }
            }
        }
        return frame.inside(candidates[0], by: inset)
    }

    /// Room name/area block position: nearest to the centroid where the label box is inside the
    /// floor outline and does not overlap fixtures.
    static func roomLabelPosition(plan: FloorPlan, reference: Point2D, obstacles: [Rect2D], style: Style) -> Point2D {
        let polygon = plan.effectiveFloorPolygon
        guard polygon.count >= 3, let bounds = Rect2D.enclosing(polygon) else { return reference }
        let halfW = max(Double(plan.name.count) * style.roomNameHeight * 0.36, 0.9)
        let top = style.roomNameHeight * 1.6
        let bottom = style.roomInfoHeight * 3.2
        func box(_ c: Point2D) -> Rect2D { Rect2D(minX: c.x - halfW, minY: c.y - bottom, maxX: c.x + halfW, maxY: c.y + top) }
        func fits(_ c: Point2D) -> Bool {
            let b = box(c)
            let corners = [Point2D(b.minX, b.minY), Point2D(b.maxX, b.minY), Point2D(b.maxX, b.maxY), Point2D(b.minX, b.maxY)]
            guard corners.allSatisfy({ Polygon2D.contains($0, in: polygon) }) else { return false }
            return !obstacles.contains { $0.intersects(b) }
        }
        if fits(reference) { return reference }
        let step = 0.1
        var best: Point2D?
        var bestDistance = Double.infinity
        var y = bounds.minY
        while y <= bounds.maxY {
            var x = bounds.minX
            while x <= bounds.maxX {
                let c = Point2D(x, y)
                let d = c.distance(to: reference)
                if d < bestDistance && fits(c) { best = c; bestDistance = d }
                x += step
            }
            y += step
        }
        return best ?? reference
    }

    /// Picks the point along the wall farthest from any opening for the "W#" tag.
    static func bestWallTagOffset(length: Double, cuts: [ClosedRange<Double>]) -> Double {
        let spans = WallElevation.solidSpans(length: length, cuts: cuts.map { ($0.lowerBound - 0.3)...($0.upperBound + 0.3) })
        guard let widest = spans.max(by: { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }) else {
            return length / 2
        }
        return (widest.lowerBound + widest.upperBound) / 2
    }

    static func makeFrames(_ plan: FloorPlan, reference: Point2D, tolerance: Double) -> [WallFrame] {
        var frames: [WallFrame] = plan.walls.map { wall in
            let d = wall.direction
            let left = d.leftNormal
            let inward = (reference - wall.midpoint).dot(left) >= 0 ? left : -left
            let length = wall.length
            return WallFrame(wall: wall, direction: d, inward: inward, outward: -inward, length: length,
                             interiorStart: 0, interiorEnd: length, exteriorStart: 0, exteriorEnd: length,
                             startJoined: false, endJoined: false)
        }

        for i in frames.indices {
            for isStart in [true, false] {
                let endpoint = isStart ? frames[i].wall.start : frames[i].wall.end
                var best: (index: Int, distance: Double)?
                for j in frames.indices where j != i {
                    let d = min(frames[j].wall.start.distance(to: endpoint), frames[j].wall.end.distance(to: endpoint))
                    if d <= tolerance && (best == nil || d < best!.distance) { best = (j, d) }
                }
                guard let neighbor = best.map({ frames[$0.index] }) else { continue }
                let me = frames[i]
                let endParam = isStart ? 0.0 : me.length
                guard let tIn = lineParameter(me.wall.start, me.direction, neighbor.wall.start, neighbor.direction),
                      let tOut = lineParameter(me.wall.start + me.outward * me.wall.thickness, me.direction,
                                               neighbor.wall.start + neighbor.outward * neighbor.wall.thickness,
                                               neighbor.direction),
                      abs(tIn - endParam) < 1.0, abs(tOut - endParam) < 1.0 else { continue }
                if isStart {
                    frames[i].interiorStart = tIn
                    frames[i].exteriorStart = tOut
                    frames[i].startJoined = true
                } else {
                    frames[i].interiorEnd = tIn
                    frames[i].exteriorEnd = tOut
                    frames[i].endJoined = true
                }
            }
        }
        return frames
    }

    /// Parameter `t` along line (p + d*t) where it meets line (q + e*s); nil if nearly parallel.
    static func lineParameter(_ p: Point2D, _ d: Point2D, _ q: Point2D, _ e: Point2D) -> Double? {
        let denom = d.cross(e)
        guard abs(denom) > 0.05 else { return nil }
        return (q - p).cross(e) / denom
    }
}
