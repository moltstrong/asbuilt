import Foundation

public enum UnitSystem: String, Codable, CaseIterable, Identifiable, Sendable {
    case imperial
    case metric

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .imperial: return "Imperial (ft-in)"
        case .metric: return "Metric (m)"
        }
    }

    public var lengthUnit: String { self == .imperial ? "ft" : "m" }
    public var areaUnit: String { self == .imperial ? "sq ft" : "m²" }
    /// ASCII-safe area unit for CSV/DXF.
    public var areaUnitASCII: String { self == .imperial ? "sq ft" : "m2" }
}

/// Unit conversion and display formatting. All internal values are SI (meters, square meters).
public enum UnitFormatter {
    public static let metersPerFoot = 0.3048
    public static let metersPerInch = 0.0254
    public static let squareMetersPerSquareFoot = 0.09290304
    public static let litersPerUSGallon = 3.785411784

    public static func feet(_ meters: Double) -> Double { meters / metersPerFoot }
    public static func meters(feet: Double) -> Double { feet * metersPerFoot }
    public static func meters(inches: Double) -> Double { inches * metersPerInch }
    public static func squareFeet(_ squareMeters: Double) -> Double { squareMeters / squareMetersPerSquareFoot }
    public static func squareMeters(squareFeet: Double) -> Double { squareFeet * squareMetersPerSquareFoot }

    /// Feet-inches text, e.g. `12' 3"` or with `fractionDenominator: 2`, `12' 3 1/2"`.
    /// Rounds to the nearest 1/`fractionDenominator` inch and carries into feet.
    public static func feetInches(_ meters: Double, fractionDenominator: Int = 1) -> String {
        let den = max(1, fractionDenominator)
        let totalInches = meters / metersPerInch
        let units = Int((abs(totalInches) * Double(den)).rounded())
        let perFoot = 12 * den
        let feet = units / perFoot
        let remainder = units % perFoot
        let wholeInches = remainder / den
        var numerator = remainder % den
        var denominator = den
        if numerator > 0 {
            let g = gcd(numerator, denominator)
            numerator /= g
            denominator /= g
        }
        let inchPart: String
        if numerator > 0 {
            inchPart = wholeInches > 0 ? "\(wholeInches) \(numerator)/\(denominator)" : "\(numerator)/\(denominator)"
        } else {
            inchPart = "\(wholeInches)"
        }
        let text = "\(feet)' \(inchPart)\""
        return (totalInches < 0 && units > 0) ? "-" + text : text
    }

    public static func length(_ meters: Double, _ system: UnitSystem) -> String {
        switch system {
        case .imperial: return feetInches(meters)
        case .metric: return decimal(meters, 2) + " m"
        }
    }

    public static func area(_ squareMeters: Double, _ system: UnitSystem) -> String {
        switch system {
        case .imperial: return decimal(squareFeet(squareMeters), 1) + " sq ft"
        case .metric: return decimal(squareMeters, 2) + " m²"
        }
    }

    /// Numeric length in the system's primary unit (decimal feet or meters).
    public static func lengthValue(_ meters: Double, _ system: UnitSystem) -> Double {
        system == .imperial ? feet(meters) : meters
    }

    /// Numeric area in the system's primary unit (square feet or square meters).
    public static func areaValue(_ squareMeters: Double, _ system: UnitSystem) -> Double {
        system == .imperial ? squareFeet(squareMeters) : squareMeters
    }

    /// Locale-independent fixed decimal ("12.50"); never prints "-0.00".
    public static func decimal(_ value: Double, _ places: Int) -> String {
        let text = String(format: "%.\(max(0, places))f", value)
        if text.hasPrefix("-"), Double(text) == 0 { return String(text.dropFirst()) }
        return text
    }

    static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = abs(a)
        var b = abs(b)
        while b != 0 { (a, b) = (b, a % b) }
        return max(a, 1)
    }
}
