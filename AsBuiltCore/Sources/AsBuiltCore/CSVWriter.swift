import Foundation

/// RFC 4180 CSV takeoff export. One header row, one record per line item, so the file opens
/// cleanly in Excel/Numbers/Sheets and imports into estimating tools.
public enum CSVWriter {
    public static func header(_ units: UnitSystem) -> [String] {
        let l = units.lengthUnit
        let a = units.areaUnitASCII
        return [
            "Section", "Item", "Description",
            "Length (\(l))", "Height (\(l))",
            "Gross Area (\(a))", "Openings Area (\(a))", "Net Area (\(a))",
            "Quantity", "Order Qty", "Unit", "Notes",
        ]
    }

    public static func rows(plan: FloorPlan, takeoff: RoomTakeoff, units: UnitSystem) -> [[String]] {
        let d = UnitFormatter.decimal
        func len(_ m: Double) -> String { d(UnitFormatter.lengthValue(m, units), 2) }
        func area(_ m2: Double) -> String { d(UnitFormatter.areaValue(m2, units), 2) }
        let lu = units.lengthUnit
        let au = units.areaUnitASCII

        var rows: [[String]] = []
        // Room summary.
        rows.append(["Room", "Floor area", "\(plan.name) (\(takeoff.floorAreaSource.rawValue))", "", "", "", "", "",
                     area(takeoff.floorArea), "", au, ""])
        rows.append(["Room", "Perimeter", plan.name, len(takeoff.perimeter), "", "", "", "",
                     len(takeoff.perimeter), "", lu, UnitFormatter.length(takeoff.perimeter, units)])
        rows.append(["Room", "Ceiling height", plan.name, "", len(takeoff.ceilingHeight), "", "", "",
                     len(takeoff.ceilingHeight), "", lu, UnitFormatter.length(takeoff.ceilingHeight, units)])
        rows.append(["Room", "Wall area", "All walls", "", "", area(takeoff.grossWallArea), area(takeoff.openingArea),
                     area(takeoff.netWallArea), area(takeoff.netWallArea), "", au, "Net = gross - openings"])
        rows.append(["Room", "Doors", plan.name, "", "", "", "", "", "\(takeoff.doorCount)", "\(takeoff.doorCount)", "ea", ""])
        rows.append(["Room", "Windows", plan.name, "", "", "", "", "", "\(takeoff.windowCount)", "\(takeoff.windowCount)", "ea", ""])
        rows.append(["Room", "Openings", plan.name, "", "", "", "", "", "\(takeoff.openingCount)", "\(takeoff.openingCount)", "ea", "Cased openings without doors"])

        // Walls.
        for wall in takeoff.walls {
            let hosted = wall.openingTags.isEmpty ? "No openings" : "Openings: " + wall.openingTags.joined(separator: ", ")
            rows.append(["Wall", wall.label, hosted, len(wall.length), len(wall.height),
                         area(wall.grossArea), area(wall.openingArea), area(wall.netArea),
                         area(wall.netArea), "", au,
                         "\(UnitFormatter.length(wall.length, units)) x \(UnitFormatter.length(wall.height, units))"])
        }

        // Openings.
        for o in takeoff.openings {
            let host = o.wallNumber.map { "\(o.kind.displayName) on W\($0)" } ?? o.kind.displayName
            let sill = o.kind == .window ? "Sill \(UnitFormatter.length(o.sillHeight, units)); " : ""
            rows.append(["Opening", o.tag, host, len(o.width), len(o.height), area(o.area), "", "",
                         "1", "1", "ea",
                         sill + "\(UnitFormatter.length(o.width, units)) x \(UnitFormatter.length(o.height, units))"])
        }

        // Fixtures / detected objects.
        for f in plan.fixtures {
            rows.append(["Fixture", f.label, "Detected object", len(f.width), len(f.height), "", "", "",
                         "1", "1", "ea", "Depth \(UnitFormatter.length(f.depth, units))"])
        }

        // Materials.
        for m in takeoff.materials {
            rows.append(["Material", m.name, m.formula(units), "", "", "", "", "",
                         d(m.displayQuantity(units), 2), "\(m.orderQuantity(units))", m.unit(units),
                         "Includes \(Int((m.wasteFactor * 100).rounded()))% waste; before waste \(d(m.displayBaseQuantity(units), 2))"])
        }
        return rows
    }

    public static func write(plan: FloorPlan, takeoff: RoomTakeoff? = nil, units: UnitSystem) -> String {
        let t = takeoff ?? TakeoffCalculator.calculate(plan)
        let all = [header(units)] + rows(plan: plan, takeoff: t, units: units)
        return all.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    public static func escape(_ field: String) -> String {
        let needsQuotes = field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r")
            || field.hasPrefix(" ") || field.hasSuffix(" ")
        guard needsQuotes else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// RFC 4180 parser (used by tests to round-trip the export).
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text)
        if let last = chars.last, !last.isNewline { chars.append("\n") }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case _ where c.isNewline:
                    row.append(field); field = ""
                    rows.append(row); row = []
                default: field.append(c)
                }
            }
            i += 1
        }
        return rows
    }
}
