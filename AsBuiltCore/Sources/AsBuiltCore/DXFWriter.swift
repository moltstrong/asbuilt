import Foundation

/// Drawing units written to the DXF. Plan geometry (meters) is scaled on output.
public enum DXFUnits: Int, Codable, CaseIterable, Sendable {
    // Values are the AutoCAD $INSUNITS codes.
    case inches = 1
    case feet = 2
    case millimeters = 4
    case meters = 6

    /// Drawing units per meter.
    public var scale: Double {
        switch self {
        case .inches: return 1 / UnitFormatter.metersPerInch
        case .feet: return 1 / UnitFormatter.metersPerFoot
        case .millimeters: return 1000
        case .meters: return 1
        }
    }

    /// $MEASUREMENT: 0 = English, 1 = Metric.
    public var measurement: Int {
        switch self {
        case .inches, .feet: return 0
        case .millimeters, .meters: return 1
        }
    }

    public var name: String {
        switch self {
        case .inches: return "inches"
        case .feet: return "feet"
        case .millimeters: return "millimeters"
        case .meters: return "meters"
        }
    }

    /// US convention is inches for architectural CAD; metric is millimeters.
    public static func preferred(for system: UnitSystem) -> DXFUnits {
        system == .imperial ? .inches : .millimeters
    }
}

/// Writes ASCII DXF Release 12 (AC1009), the most widely readable DXF flavour
/// (AutoCAD, Revit, SketchUp, BricsCAD, LibreCAD, QCAD, Rhino, Illustrator).
///
/// Structure: HEADER ($ACADVER, $INSUNITS, $MEASUREMENT, extents), TABLES (LTYPE, LAYER, STYLE),
/// BLOCKS (empty), ENTITIES (LINE, ARC, POLYLINE/VERTEX/SEQEND, TEXT), EOF.
public struct DXFWriter {
    public var units: DXFUnits
    /// Extra note lines placed under the plan (job, date, source...).
    public var notes: [String]
    /// Use CRLF line endings (friendlier for Windows CAD tools; every reader accepts both).
    public var lineEnding: String = "\r\n"

    public init(units: DXFUnits = .inches, notes: [String] = []) {
        self.units = units
        self.notes = notes
    }

    public static let layers: [PlanLayer] = PlanLayer.allCases

    public func write(plan: FloorPlan, unitSystem: UnitSystem) -> String {
        var drawing = PlanGeometryBuilder.build(plan, units: unitSystem)
        if !notes.isEmpty {
            let bounds = drawing.bounds
            let h = 0.12
            for (i, note) in notes.enumerated() {
                let y = bounds.minY - 0.35 - Double(i) * h * 1.8
                drawing.texts.append(PlanText(text: note, position: Point2D(bounds.center.x, y), height: h,
                                              rotation: 0, layer: .text, role: .roomInfo))
            }
        }
        return write(drawing: drawing)
    }

    public func write(drawing: PlanDrawing) -> String {
        var out = DXFStream(scale: units.scale)
        let bounds = drawing.bounds

        // HEADER
        out.pair(0, "SECTION"); out.pair(2, "HEADER")
        out.pair(9, "$ACADVER"); out.pair(1, "AC1009")
        out.pair(9, "$INSBASE"); out.point(.zero, base: 10)
        out.pair(9, "$EXTMIN"); out.point(Point2D(bounds.minX, bounds.minY), base: 10)
        out.pair(9, "$EXTMAX"); out.point(Point2D(bounds.maxX, bounds.maxY), base: 10)
        out.pair(9, "$LIMMIN"); out.point2(Point2D(bounds.minX, bounds.minY), base: 10)
        out.pair(9, "$LIMMAX"); out.point2(Point2D(bounds.maxX, bounds.maxY), base: 10)
        out.pair(9, "$INSUNITS"); out.pair(70, "\(units.rawValue)")
        out.pair(9, "$MEASUREMENT"); out.pair(70, "\(units.measurement)")
        out.pair(9, "$LUNITS"); out.pair(70, units == .inches || units == .feet ? "4" : "2")
        out.pair(9, "$TEXTSTYLE"); out.pair(7, "STANDARD")
        out.pair(9, "$CLAYER"); out.pair(8, "0")
        out.pair(0, "ENDSEC")

        // TABLES
        out.pair(0, "SECTION"); out.pair(2, "TABLES")
        // Line types
        out.pair(0, "TABLE"); out.pair(2, "LTYPE"); out.pair(70, "2")
        out.pair(0, "LTYPE"); out.pair(2, "CONTINUOUS"); out.pair(70, "0")
        out.pair(3, "Solid line"); out.pair(72, "65"); out.pair(73, "0"); out.pair(40, out.number(0))
        let dash = 0.15 * units.scale
        let gap = 0.075 * units.scale
        out.pair(0, "LTYPE"); out.pair(2, "DASHED"); out.pair(70, "0")
        out.pair(3, "Dashed __ __ __"); out.pair(72, "65"); out.pair(73, "2")
        out.pair(40, out.number(dash + gap)); out.pair(49, out.number(dash)); out.pair(49, out.number(-gap))
        out.pair(0, "ENDTAB")
        // Layers
        out.pair(0, "TABLE"); out.pair(2, "LAYER"); out.pair(70, "\(Self.layers.count + 1)")
        out.pair(0, "LAYER"); out.pair(2, "0"); out.pair(70, "0"); out.pair(62, "7"); out.pair(6, "CONTINUOUS")
        for layer in Self.layers {
            out.pair(0, "LAYER"); out.pair(2, layer.rawValue); out.pair(70, "0")
            out.pair(62, "\(layer.aciColor)"); out.pair(6, layer.dxfLineType)
        }
        out.pair(0, "ENDTAB")
        // Text style
        out.pair(0, "TABLE"); out.pair(2, "STYLE"); out.pair(70, "1")
        out.pair(0, "STYLE"); out.pair(2, "STANDARD"); out.pair(70, "0")
        out.pair(40, out.number(0)); out.pair(41, out.number(1)); out.pair(50, out.number(0))
        out.pair(71, "0"); out.pair(42, out.number(0.2 * units.scale)); out.pair(3, "txt"); out.pair(4, "")
        out.pair(0, "ENDTAB")
        out.pair(0, "ENDSEC")

        // BLOCKS (empty, present for strict readers)
        out.pair(0, "SECTION"); out.pair(2, "BLOCKS"); out.pair(0, "ENDSEC")

        // ENTITIES
        out.pair(0, "SECTION"); out.pair(2, "ENTITIES")
        for line in drawing.lines {
            out.pair(0, "LINE"); out.pair(8, line.layer.rawValue)
            out.point(line.a, base: 10); out.point(line.b, base: 11)
        }
        for arc in drawing.arcs {
            out.pair(0, "ARC"); out.pair(8, arc.layer.rawValue)
            out.point(arc.center, base: 10)
            out.pair(40, out.number(arc.radius * units.scale))
            out.pair(50, out.number(arc.startAngle, scaled: false))
            out.pair(51, out.number(arc.endAngle, scaled: false))
        }
        for poly in drawing.polylines {
            out.pair(0, "POLYLINE"); out.pair(8, poly.layer.rawValue); out.pair(66, "1")
            out.point(.zero, base: 10); out.pair(70, poly.closed ? "1" : "0")
            for p in poly.points {
                out.pair(0, "VERTEX"); out.pair(8, poly.layer.rawValue); out.point(p, base: 10)
            }
            out.pair(0, "SEQEND"); out.pair(8, poly.layer.rawValue)
        }
        for text in drawing.texts {
            out.pair(0, "TEXT"); out.pair(8, text.layer.rawValue)
            out.point(text.position, base: 10)
            out.pair(40, out.number(text.height * units.scale))
            out.pair(1, Self.encodeText(text.text))
            if abs(text.rotation) > 1e-9 { out.pair(50, out.number(text.rotation, scaled: false)) }
            out.pair(7, "STANDARD")
            out.pair(72, "1") // center
            out.point(text.position, base: 11)
            out.pair(73, "2") // middle
        }
        out.pair(0, "ENDSEC")
        out.pair(0, "EOF")
        return out.lines.joined(separator: lineEnding) + lineEnding
    }

    /// DXF R12 text is 7-bit; encode anything else as `\U+XXXX` and strip control characters.
    public static func encodeText(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if scalar.value < 32 { result += " "; continue }
            if scalar.value < 128 { result.unicodeScalars.append(scalar); continue }
            result += String(format: "\\U+%04X", scalar.value)
        }
        return result
    }
}

struct DXFStream {
    var lines: [String] = []
    let scale: Double

    mutating func pair(_ code: Int, _ value: String) {
        lines.append(Self.groupCode(code))
        lines.append(value)
    }

    /// Group codes are right-aligned in a 3-character field by convention.
    static func groupCode(_ code: Int) -> String {
        let s = String(code)
        return s.count >= 3 ? s : String(repeating: " ", count: 3 - s.count) + s
    }

    func number(_ value: Double, scaled: Bool = false) -> String {
        UnitFormatter.decimal(value, 6)
    }

    mutating func point(_ p: Point2D, base: Int) {
        pair(base, number(p.x * scale))
        pair(base + 10, number(p.y * scale))
        pair(base + 20, number(0))
    }

    mutating func point2(_ p: Point2D, base: Int) {
        pair(base, number(p.x * scale))
        pair(base + 10, number(p.y * scale))
    }
}

/// Minimal DXF group-code reader used by tests and import sanity checks.
public enum DXFReader {
    public struct Pair: Equatable, Sendable {
        public var code: Int
        public var value: String
    }

    public enum ReadError: Error, Equatable {
        case oddLineCount
        case badGroupCode(line: Int, text: String)
    }

    public static func pairs(_ text: String) throws -> [Pair] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.count % 2 == 0 else { throw ReadError.oddLineCount }
        var result: [Pair] = []
        result.reserveCapacity(lines.count / 2)
        var i = 0
        while i < lines.count {
            let codeText = lines[i].trimmingCharacters(in: .whitespaces)
            guard let code = Int(codeText) else { throw ReadError.badGroupCode(line: i + 1, text: lines[i]) }
            result.append(Pair(code: code, value: lines[i + 1]))
            i += 2
        }
        return result
    }
}
