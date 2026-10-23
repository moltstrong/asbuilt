import Foundation
import simd

/// Robust 3D point from many noisy per-frame samples (Measure tool).
///
/// Each tap collects ~15-30 samples of the same screen location (LiDAR depth unprojection or a
/// raycast). The point is the component-wise median of the samples that survive outlier rejection
/// (distance from the first median > max(3 x robust sigma, 4 mm)), and the spread is the robust
/// sigma (1.4826 x MAD of distances) of those inliers. Spread is noise only; LiDAR's absolute error
/// (~1 cm) is not visible in it, which is why the tool offers tape calibration.
public struct PointSampler: Sendable {
    public private(set) var samples: [SIMD3<Float>] = []
    public let target: Int
    public let minimum: Int

    public init(target: Int = 24, minimum: Int = 15) {
        self.target = max(1, target)
        self.minimum = max(1, min(minimum, target))
    }

    public mutating func add(_ p: SIMD3<Float>) {
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite, samples.count < target * 2 else { return }
        samples.append(p)
    }

    public mutating func reset() { samples.removeAll() }

    /// 0...1 toward `target` samples.
    public var fill: Float { min(1, Float(samples.count) / Float(target)) }

    public struct Estimate: Sendable, Hashable {
        public var point: SIMD3<Float>
        /// Robust 1-sigma spread of the inliers (m).
        public var spread: Float
        public var inliers: Int
        public var rejected: Int
    }

    public var estimate: Estimate? { Self.estimate(samples) }

    /// Locks when there are enough samples and the inlier spread is under `maxSpread`.
    public func isSteady(maxSpread: Float) -> Bool {
        guard samples.count >= minimum, let e = estimate else { return false }
        return e.inliers >= minimum * 2 / 3 && e.spread <= maxSpread
    }

    /// Lock threshold for a point `range` meters away: 5 mm + 0.5 % of range (LiDAR noise grows with distance).
    public static func lockSpread(range: Float) -> Float { 0.005 + 0.005 * max(0, range) }

    public static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return .nan }
        let s = values.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    public static func componentMedian(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        SIMD3(median(points.map(\.x)), median(points.map(\.y)), median(points.map(\.z)))
    }

    public static func estimate(_ samples: [SIMD3<Float>]) -> Estimate? {
        guard !samples.isEmpty else { return nil }
        let m0 = componentMedian(samples)
        let d0 = samples.map { simd_distance($0, m0) }
        let sigma0 = 1.4826 * median(d0)
        let cut = max(3 * sigma0, 0.004)
        let inliers = zip(samples, d0).filter { $0.1 <= cut }.map(\.0)
        guard !inliers.isEmpty else { return nil }
        let m = componentMedian(inliers)
        let spread = 1.4826 * median(inliers.map { simd_distance($0, m) })
        return Estimate(point: m, spread: spread, inliers: inliers.count, rejected: samples.count - inliers.count)
    }
}

/// One point-to-point measurement saved on a job.
public struct PrecisionMeasurement: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var label: String
    public var createdAt: Date
    /// End points in the AR session's world space (meters); kept for re-display and auditing.
    public var start: [Float]
    public var end: [Float]
    /// Distance as measured, before any tape calibration (meters).
    public var rawMeters: Double
    /// ± estimate from the sample spread of both points (meters, ~1 sigma).
    public var uncertaintyMeters: Double
    public var samples: Int
    /// "lidarDepth" or "raycast".
    public var method: String
    /// The tape-measured true length, if the user calibrated with this measurement.
    public var tapeMeters: Double?

    public init(id: UUID = UUID(), label: String, createdAt: Date = Date(), start: SIMD3<Float>, end: SIMD3<Float>,
                uncertaintyMeters: Double, samples: Int, method: String, tapeMeters: Double? = nil) {
        self.id = id
        self.label = label
        self.createdAt = createdAt
        self.start = [start.x, start.y, start.z]
        self.end = [end.x, end.y, end.z]
        rawMeters = Double(simd_distance(start, end))
        self.uncertaintyMeters = uncertaintyMeters
        self.samples = samples
        self.method = method
        self.tapeMeters = tapeMeters
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, createdAt, start, end, rawMeters, uncertaintyMeters, samples, method, tapeMeters
    }

    /// Tolerant decoding (missing fields from older/newer builds get defaults).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "Measurement"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        start = (try? c.decodeIfPresent([Float].self, forKey: .start)) ?? []
        end = (try? c.decodeIfPresent([Float].self, forKey: .end)) ?? []
        rawMeters = try c.decodeIfPresent(Double.self, forKey: .rawMeters) ?? 0
        uncertaintyMeters = try c.decodeIfPresent(Double.self, forKey: .uncertaintyMeters) ?? 0
        samples = try c.decodeIfPresent(Int.self, forKey: .samples) ?? 0
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? "lidarDepth"
        tapeMeters = try c.decodeIfPresent(Double.self, forKey: .tapeMeters)
    }

    /// Distance shown to the user: raw x the job's tape-calibration scale.
    public func calibratedMeters(scale: Double?) -> Double { rawMeters * Self.validScale(scale) }

    public func calibratedUncertainty(scale: Double?) -> Double { uncertaintyMeters * Self.validScale(scale) }

    /// Plausible scales only (a 20 % correction means a mis-typed tape value, not LiDAR error).
    public static func validScale(_ scale: Double?) -> Double {
        guard let scale, scale.isFinite, scale > 0.8, scale < 1.25 else { return 1 }
        return scale
    }

    /// The scale that makes `rawMeters` read `tapeMeters`, or nil if implausible.
    public static func calibrationScale(rawMeters: Double, tapeMeters: Double) -> Double? {
        guard rawMeters > 0.01, tapeMeters > 0.01 else { return nil }
        let s = tapeMeters / rawMeters
        return validScale(s) == s ? s : nil
    }

    /// The ± for a two-point distance from per-point spreads.
    public static func combinedUncertainty(_ a: Float, _ b: Float) -> Double {
        Double((a * a + b * b).squareRoot())
    }
}

extension UnitFormatter {
    /// Precise length: ft-in to the nearest 1/16" (imperial) or whole millimeters (metric).
    public static func precise(_ meters: Double, _ system: UnitSystem) -> String {
        switch system {
        case .imperial: return feetInches(meters, fractionDenominator: 16)
        case .metric: return "\(Int(meters * 1000).formatted(.number.grouping(.never).locale(Locale(identifier: "en_US_POSIX")))) mm"
        }
    }

    /// "± 1/8\"" or "± 3 mm" (never below 1/16" / 1 mm).
    public static func plusMinus(_ meters: Double, _ system: UnitSystem) -> String {
        switch system {
        case .imperial:
            let sixteenths = max(1, Int((meters / metersPerInch * 16).rounded()))
            let whole = sixteenths / 16
            var num = sixteenths % 16
            var den = 16
            if num > 0 {
                let g = gcd(num, den)
                num /= g
                den /= g
            }
            let text = num == 0 ? "\(whole)" : (whole > 0 ? "\(whole) \(num)/\(den)" : "\(num)/\(den)")
            return "± \(text)\""
        case .metric:
            return "± \(max(1, Int((meters * 1000).rounded()))) mm"
        }
    }
}

/// measurements.csv for the job's Measure-tool measurements.
public enum PrecisionMeasurementsCSV {
    public static let fileName = "measurements.csv"

    public static func write(_ items: [PrecisionMeasurement], scale: Double?, units: UnitSystem, jobName: String) -> String {
        let s = PrecisionMeasurement.validScale(scale)
        var lines: [String] = []
        lines.append("# AsBuilt measurements: \(csvField(jobName))")
        if s != 1 {
            lines.append("# Tape calibration scale \(UnitFormatter.decimal(s, 5)) applied to calibrated columns; raw columns are as measured.")
        } else {
            lines.append("# No tape calibration (calibrated = raw).")
        }
        lines.append("#,Label,Length,\u{00B1},Calibrated (m),Raw (m),\u{00B1} (m),Tape (m),Samples,Method,Created (UTC)")
        let iso = ISO8601DateFormatter()
        for (i, m) in items.enumerated() {
            let fields: [String] = [
                "\(i + 1)",
                csvField(m.label),
                csvField(UnitFormatter.precise(m.calibratedMeters(scale: s), units)),
                csvField(UnitFormatter.plusMinus(m.calibratedUncertainty(scale: s), units)),
                UnitFormatter.decimal(m.calibratedMeters(scale: s), 4),
                UnitFormatter.decimal(m.rawMeters, 4),
                UnitFormatter.decimal(m.uncertaintyMeters, 4),
                m.tapeMeters.map { UnitFormatter.decimal($0, 4) } ?? "",
                "\(m.samples)",
                m.method,
                iso.string(from: m.createdAt),
            ]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func csvField(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}
