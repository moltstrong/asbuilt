import Foundation

/// Estimating assumptions. Defaults follow common US residential practice.
public struct TakeoffOptions: Codable, Hashable, Sendable {
    /// Waste/overage applied to every material estimate (0.10 = 10%).
    public var wasteFactor: Double
    /// Drywall sheet area in square feet (4x8 = 32).
    public var drywallSheetAreaSqFt: Double
    /// Paint coverage per gallon per coat, square feet.
    public var paintCoverageSqFtPerGallon: Double
    public var paintCoats: Int

    public init(wasteFactor: Double = 0.10, drywallSheetAreaSqFt: Double = 32,
                paintCoverageSqFtPerGallon: Double = 350, paintCoats: Int = 2) {
        self.wasteFactor = wasteFactor
        self.drywallSheetAreaSqFt = drywallSheetAreaSqFt
        self.paintCoverageSqFtPerGallon = paintCoverageSqFtPerGallon
        self.paintCoats = paintCoats
    }

    public static let standard = TakeoffOptions()
}

public struct WallTakeoff: Hashable, Identifiable, Sendable {
    public var id: UUID { wallID }
    public var wallID: UUID
    /// 1-based wall number (W1, W2...).
    public var number: Int
    public var length: Double
    public var height: Double
    public var grossArea: Double
    public var openingArea: Double
    public var netArea: Double
    public var doorCount: Int
    public var windowCount: Int
    public var openingCount: Int
    /// Opening tags hosted on this wall, e.g. ["D1", "WIN1"].
    public var openingTags: [String]

    public var label: String { "W\(number)" }
}

public struct OpeningTakeoff: Hashable, Identifiable, Sendable {
    public var id: UUID
    public var tag: String
    public var kind: OpeningKind
    public var wallNumber: Int?
    public var width: Double
    public var height: Double
    public var sillHeight: Double
    public var area: Double
}

public enum MaterialKind: String, CaseIterable, Codable, Sendable {
    case drywall
    case paint
    case baseboard
    case flooring
}

/// One material line. Quantities are stored in SI-neutral base units:
/// drywall = sheets, paint = US gallons, baseboard = meters, flooring = square meters.
public struct MaterialEstimate: Hashable, Identifiable, Sendable {
    public var id: MaterialKind { kind }
    public var kind: MaterialKind
    /// Quantity before waste, in base units.
    public var baseQuantity: Double
    /// Quantity including waste, in base units.
    public var quantity: Double
    public var wasteFactor: Double
    /// Human-readable derivation, e.g. "338.7 sq ft net wall / 32 sq ft per sheet + 10% waste".
    public var formulaImperial: String
    public var formulaMetric: String

    public var name: String {
        switch kind {
        case .drywall: return "Drywall 4x8 sheets"
        case .paint: return "Wall paint"
        case .baseboard: return "Baseboard"
        case .flooring: return "Flooring"
        }
    }

    public func unit(_ system: UnitSystem) -> String {
        switch (kind, system) {
        case (.drywall, _): return "sheets"
        case (.paint, .imperial): return "gal"
        case (.paint, .metric): return "L"
        case (.baseboard, .imperial): return "LF"
        case (.baseboard, .metric): return "m"
        case (.flooring, .imperial): return "sq ft"
        case (.flooring, .metric): return "m2"
        }
    }

    /// Quantity with waste, in the display unit for `system`.
    public func displayQuantity(_ system: UnitSystem) -> Double { convert(quantity, system) }
    public func displayBaseQuantity(_ system: UnitSystem) -> Double { convert(baseQuantity, system) }

    /// Whole purchase quantity (rounded up).
    public func orderQuantity(_ system: UnitSystem) -> Int {
        Int((displayQuantity(system) - 1e-9).rounded(.up))
    }

    public func formula(_ system: UnitSystem) -> String { system == .imperial ? formulaImperial : formulaMetric }

    func convert(_ value: Double, _ system: UnitSystem) -> Double {
        switch (kind, system) {
        case (.drywall, _): return value
        case (.paint, .imperial): return value
        case (.paint, .metric): return value * UnitFormatter.litersPerUSGallon
        case (.baseboard, .imperial): return UnitFormatter.feet(value)
        case (.baseboard, .metric): return value
        case (.flooring, .imperial): return UnitFormatter.squareFeet(value)
        case (.flooring, .metric): return value
        }
    }
}

public struct RoomTakeoff: Hashable, Sendable {
    public var roomName: String
    public var walls: [WallTakeoff]
    public var openings: [OpeningTakeoff]
    /// Square meters.
    public var floorArea: Double
    public var floorAreaSource: FloorAreaSource
    /// Meters.
    public var perimeter: Double
    public var ceilingHeight: Double
    public var doorCount: Int
    public var windowCount: Int
    public var openingCount: Int
    public var fixtureCount: Int
    public var grossWallArea: Double
    public var openingArea: Double
    public var netWallArea: Double
    /// Sum of door widths (meters).
    public var doorWidthTotal: Double
    /// Sum of door + cased-opening widths, i.e. floor-level gaps with no baseboard (meters).
    public var floorLevelOpeningWidthTotal: Double
    public var baseboardLength: Double
    public var materials: [MaterialEstimate]
    public var options: TakeoffOptions

    public func material(_ kind: MaterialKind) -> MaterialEstimate? { materials.first { $0.kind == kind } }
}

public enum TakeoffCalculator {
    public static func calculate(_ plan: FloorPlan, options: TakeoffOptions = .standard) -> RoomTakeoff {
        let tags = plan.openingTags()
        var walls: [WallTakeoff] = []
        for (index, wall) in plan.walls.enumerated() {
            let hosted = plan.openings(onWall: wall.id)
            let net = WallElevation.pieces(for: wall, openings: hosted).reduce(0) { $0 + $1.area }
            let gross = wall.grossArea
            walls.append(WallTakeoff(
                wallID: wall.id, number: index + 1, length: wall.length, height: wall.height,
                grossArea: gross, openingArea: max(0, gross - net), netArea: net,
                doorCount: hosted.filter { $0.kind == .door }.count,
                windowCount: hosted.filter { $0.kind == .window }.count,
                openingCount: hosted.filter { $0.kind == .opening }.count,
                openingTags: hosted.compactMap { tags[$0.id] }))
        }

        let openings: [OpeningTakeoff] = plan.openings.map { o in
            OpeningTakeoff(id: o.id, tag: tags[o.id] ?? o.kind.tagPrefix, kind: o.kind,
                           wallNumber: plan.wallNumber(for: o.wallID), width: o.width, height: o.height,
                           sillHeight: o.sillHeight, area: o.area)
        }.sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                return OpeningKind.allCases.firstIndex(of: lhs.kind)! < OpeningKind.allCases.firstIndex(of: rhs.kind)!
            }
            return lhs.tag.localizedStandardCompare(rhs.tag) == .orderedAscending
        }

        let resolved = plan.resolveFloorPolygon()
        let floorArea = Polygon2D.area(resolved.polygon)
        let perimeter: Double
        switch resolved.source {
        case .scannedFloor, .wallLoop: perimeter = Polygon2D.perimeter(resolved.polygon)
        case .wallExtents, .unavailable: perimeter = plan.walls.reduce(0) { $0 + $1.length }
        }
        let ceiling = plan.ceilingHeight ?? plan.walls.map(\.height).max() ?? 0

        let gross = walls.reduce(0) { $0 + $1.grossArea }
        let net = walls.reduce(0) { $0 + $1.netArea }
        let doorWidths = plan.openings.filter { $0.kind == .door }.reduce(0) { $0 + $1.width }
        let floorGapWidths = plan.openings.filter { $0.kind != .window }.reduce(0) { $0 + $1.width }
        let baseboard = max(0, perimeter - floorGapWidths)

        let materials = estimateMaterials(netWallArea: net, floorArea: floorArea,
                                          baseboardLength: baseboard, options: options)

        return RoomTakeoff(
            roomName: plan.name, walls: walls, openings: openings,
            floorArea: floorArea, floorAreaSource: resolved.source, perimeter: perimeter,
            ceilingHeight: ceiling,
            doorCount: plan.openings.filter { $0.kind == .door }.count,
            windowCount: plan.openings.filter { $0.kind == .window }.count,
            openingCount: plan.openings.filter { $0.kind == .opening }.count,
            fixtureCount: plan.fixtures.count,
            grossWallArea: gross, openingArea: max(0, gross - net), netWallArea: net,
            doorWidthTotal: doorWidths, floorLevelOpeningWidthTotal: floorGapWidths,
            baseboardLength: baseboard, materials: materials, options: options)
    }

    public static func estimateMaterials(netWallArea: Double, floorArea: Double, baseboardLength: Double,
                                         options: TakeoffOptions) -> [MaterialEstimate] {
        let waste = 1 + options.wasteFactor
        let wastePct = "\(Int((options.wasteFactor * 100).rounded()))%"
        let netSqFt = UnitFormatter.squareFeet(netWallArea)

        let sheets = netSqFt / options.drywallSheetAreaSqFt
        let gallons = netSqFt / options.paintCoverageSqFtPerGallon * Double(options.paintCoats)
        let d = UnitFormatter.decimal
        let sheetM2 = UnitFormatter.squareMeters(squareFeet: options.drywallSheetAreaSqFt)
        let coverageM2 = UnitFormatter.squareMeters(squareFeet: options.paintCoverageSqFtPerGallon)

        return [
            MaterialEstimate(
                kind: .drywall, baseQuantity: sheets, quantity: sheets * waste, wasteFactor: options.wasteFactor,
                formulaImperial: "\(d(netSqFt, 1)) sq ft net wall / \(d(options.drywallSheetAreaSqFt, 0)) sq ft per sheet + \(wastePct) waste",
                formulaMetric: "\(d(netWallArea, 2)) m2 net wall / \(d(sheetM2, 2)) m2 per sheet + \(wastePct) waste"),
            MaterialEstimate(
                kind: .paint, baseQuantity: gallons, quantity: gallons * waste, wasteFactor: options.wasteFactor,
                formulaImperial: "\(d(netSqFt, 1)) sq ft / \(d(options.paintCoverageSqFtPerGallon, 0)) sq ft per gal x \(options.paintCoats) coats + \(wastePct) waste",
                formulaMetric: "\(d(netWallArea, 2)) m2 / \(d(coverageM2, 1)) m2 per 3.785 L x \(options.paintCoats) coats + \(wastePct) waste"),
            MaterialEstimate(
                kind: .baseboard, baseQuantity: baseboardLength, quantity: baseboardLength * waste, wasteFactor: options.wasteFactor,
                formulaImperial: "\(d(UnitFormatter.feet(baseboardLength), 1)) LF (perimeter - door/opening widths) + \(wastePct) waste",
                formulaMetric: "\(d(baseboardLength, 2)) m (perimeter - door/opening widths) + \(wastePct) waste"),
            MaterialEstimate(
                kind: .flooring, baseQuantity: floorArea, quantity: floorArea * waste, wasteFactor: options.wasteFactor,
                formulaImperial: "\(d(UnitFormatter.squareFeet(floorArea), 1)) sq ft floor x \(d(waste, 2))",
                formulaMetric: "\(d(floorArea, 2)) m2 floor x \(d(waste, 2))"),
        ]
    }
}
