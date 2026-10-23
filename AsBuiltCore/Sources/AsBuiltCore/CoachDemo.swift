import Foundation
import simd

/// Synthetic Capture Coach sessions for the Simulator HUD preview (`-AsBuiltScreen coach…`), CI
/// screenshots and tests. The frames run through the real `CaptureCoach`, so the HUD shows exactly
/// what the coach produces for that motion.
public enum CoachDemo {
    public enum Scenario: String, CaseIterable, Sendable {
        /// Detail scan mid-scan: low band done, half of the middle band, in the sweet spot, good speed.
        case midScan = "coach"
        /// Same, moving far too fast: red speed bar, "Slow down", progress paused.
        case tooFast = "coach-fast"
        /// Too far from the object: orange reticle with the closer arrow.
        case tooFar = "coach-far"
        /// Middle band just completed, still at mid height: "Now lower" with the arrow.
        case nextBand = "coach-band"
        /// Finished scan with gaps on the back side: grade card.
        case grade = "coach-grade"
    }

    public struct Result: Sendable {
        public var output: CoachOutput
        public var report: CoachReport?
        public var thresholds: CoachThresholds
        /// Camera pose of the last frame (the preview renders the scene from here).
        public var cameraToWorld: simd_float4x4
        public var integratedFrames: Int
    }

    /// The scan target (the demo Detail scan board).
    public static let target = SIMD3<Float>(0.0, 0.17, -0.07)

    /// Runs `scenario` at 30 fps and returns the final output.
    public static func run(_ scenario: Scenario) -> Result {
        var coach = CaptureCoach(mode: .detail)
        let fps = 30.0
        var t = 0.0
        var lastOutput: CoachOutput?
        var pose = matrix_identity_float4x4
        var integrated = 0

        func frame(azimuth: Float, elevation: Float, distance: Float, light: Float = 900, confidence: Float = 0.8) -> CoachFrame {
            pose = orbitPose(azimuth: azimuth, elevation: elevation, distance: distance)
            return CoachFrame(timestamp: t, cameraToWorld: pose, ambientIntensity: light, centerDepth: distance,
                              highConfidenceFraction: confidence, tracking: .normal, featureCount: 300)
        }

        func step(_ f: CoachFrame) {
            let out = coach.update(f)
            if out.shouldIntegrate { integrated += 1 }
            lastOutput = out
            t += 1 / fps
        }

        // Pre-flight: one second steady, then Start.
        for _ in 0..<30 { step(frame(azimuth: 0, elevation: 0, distance: 0.45)) }
        coach.beginScanning()

        /// Sweeps `degrees` of azimuth at `degreesPerSecond` in one band (orbit radius 0.45 m).
        func sweep(from start: Float, degrees: Float, elevation: Float, degreesPerSecond: Float, distance: Float = 0.45) -> Float {
            let seconds = Double(abs(degrees) / degreesPerSecond)
            let n = max(1, Int(seconds * fps))
            for k in 0...n {
                let a = start + degrees * Float(k) / Float(n)
                step(frame(azimuth: a, elevation: elevation, distance: distance))
            }
            return start + degrees
        }

        switch scenario {
        case .midScan:
            // Middle band all the way round (band complete), then the low band a third of the way.
            _ = sweep(from: 0, degrees: 330, elevation: 25, degreesPerSecond: 18)
            _ = sweep(from: 330, degrees: -150, elevation: 0, degreesPerSecond: 18)
        case .nextBand:
            let a = sweep(from: 0, degrees: 330, elevation: 25, degreesPerSecond: 18)
            for _ in 0..<45 { step(frame(azimuth: a, elevation: 25, distance: 0.45)) }
        case .tooFast:
            var a = sweep(from: 0, degrees: 180, elevation: 25, degreesPerSecond: 18)
            // Whip the phone round: ~1 m/s at 0.45 m radius.
            a = sweep(from: a, degrees: 60, elevation: 25, degreesPerSecond: 130)
            for _ in 0..<6 {
                a += 4.3
                step(frame(azimuth: a, elevation: 25, distance: 0.45))
            }
        case .tooFar:
            let a = sweep(from: 0, degrees: 180, elevation: 25, degreesPerSecond: 18)
            // Back away slowly (0.15 m/s, so speed is fine) to 1.35 m, then hold.
            for k in 0...180 { step(frame(azimuth: a, elevation: 25, distance: 0.45 + 0.9 * Float(k) / 180)) }
            for _ in 0..<30 { step(frame(azimuth: a, elevation: 25, distance: 1.35)) }
        case .grade:
            // Full middle and low passes on the front 300 degrees, the high band only half: gaps on one side.
            _ = sweep(from: 0, degrees: 300, elevation: 25, degreesPerSecond: 20)
            _ = sweep(from: 300, degrees: -300, elevation: 0, degreesPerSecond: 20)
            _ = sweep(from: 0, degrees: 150, elevation: 55, degreesPerSecond: 20)
        }
        var report: CoachReport?
        if scenario == .grade {
            coach.endScanning()
            report = coach.report()
        }
        let output = lastOutput ?? coach.update(CoachFrame(timestamp: t))
        return Result(output: output, report: report, thresholds: coach.thresholds, cameraToWorld: pose,
                      integratedFrames: integrated)
    }

    /// Camera on a sphere around `target`, looking at it. Azimuth 0 = in front (+Z), elevation up.
    public static func orbitPose(azimuth: Float, elevation: Float, distance: Float) -> simd_float4x4 {
        let a = azimuth * .pi / 180, e = elevation * .pi / 180
        let eye = target + SIMD3(sin(a) * cos(e), sin(e), cos(a) * cos(e)) * distance
        return RigidTransform.lookAt(eye: eye, target: target)
    }
}

extension DemoDetailScan {
    /// A partly fused demo volume (the first `frames` of the 3-band orbit), for the coverage-tint preview.
    public static func partialVolume(frames: Int, perBand: Int = 6, voxelSize: Float = 0.004) -> TSDFVolume {
        var config = TSDFVolume.Configuration.detail
        config.voxelSize = voxelSize
        let volume = TSDFVolume(configuration: config)
        let scene = scene()
        let K = depthIntrinsics
        for (k, pose) in poses(perBand: perBand).prefix(max(0, frames)).enumerated() {
            let frame = scene.render(intrinsics: K, cameraToWorld: pose, maxDistance: 1.2, noise: 0.0015, seed: UInt64(k + 1))
            volume.integrate(DepthFrame(width: K.width, height: K.height, depth: frame.depth, intrinsics: K, cameraToWorld: pose),
                             bounds: bounds)
        }
        return volume
    }
}

extension UnitFormatter {
    /// Parses a typed tape reading into meters.
    ///
    /// Accepts `12' 3 1/2"`, `12ft 3in`, `147.5"`, `147 1/2`, `36` (bare numbers are inches in imperial,
    /// millimeters in metric), `915 mm`, `91.5 cm`, `0.915 m`. Returns nil for anything else.
    public static func parseLength(_ text: String, _ system: UnitSystem) -> Double? {
        var s = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.hasPrefix("-"), !s.hasPrefix("\u{2212}") else { return nil }
        for (from, to) in [("\u{2019}", "'"), ("\u{2032}", "'"), ("\u{201D}", "\""), ("\u{2033}", "\""), ("feet", "'"),
                           ("foot", "'"), ("ft", "'"), ("inches", "\""), ("inch", "\""), ("in", "\""), (",", ".")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        func number(_ part: String) -> Double? {
            // "3 1/2", "1/2", "3.5", "3-1/2"
            let tokens = part.replacingOccurrences(of: "-", with: " ").split(separator: " ").map(String.init)
            guard !tokens.isEmpty, tokens.count <= 2 else { return nil }
            var total = 0.0
            for token in tokens {
                if token.contains("/") {
                    let f = token.split(separator: "/")
                    guard f.count == 2, let n = Double(f[0]), let d = Double(f[1]), d > 0 else { return nil }
                    total += n / d
                } else {
                    guard let v = Double(token) else { return nil }
                    total += v
                }
            }
            return total
        }
        var meters: Double?
        if s.hasSuffix("mm"), let v = number(String(s.dropLast(2)).trimmingCharacters(in: .whitespaces)) {
            meters = v / 1000
        } else if s.hasSuffix("cm"), let v = number(String(s.dropLast(2)).trimmingCharacters(in: .whitespaces)) {
            meters = v / 100
        } else if s.hasSuffix("m"), let v = number(String(s.dropLast(1)).trimmingCharacters(in: .whitespaces)) {
            meters = v
        } else if s.contains("'") || s.contains("\"") {
            var feet = 0.0, inches = 0.0
            var rest = s
            if let q = rest.firstIndex(of: "'") {
                guard let f = number(String(rest[..<q]).trimmingCharacters(in: .whitespaces)) else { return nil }
                feet = f
                rest = String(rest[rest.index(after: q)...])
            }
            rest = rest.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty {
                guard let i = number(rest) else { return nil }
                inches = i
            }
            meters = feet * metersPerFoot + inches * metersPerInch
        } else if let v = number(s) {
            meters = system == .imperial ? v * metersPerInch : v / 1000
        }
        guard let m = meters, m.isFinite, m > 0, m < 1000 else { return nil }
        return m
    }
}
