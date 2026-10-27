import Foundation
import Testing
import simd
@testable import AsBuiltCore

/// Pose on an orbit around `center`: azimuth/elevation in degrees, looking at the center.
private func orbitPose(_ center: SIMD3<Float>, azimuth: Float, elevation: Float, distance: Float) -> simd_float4x4 {
    let az = azimuth * .pi / 180, el = elevation * .pi / 180
    let eye = center + SIMD3(cos(el) * sin(az), sin(el), cos(el) * cos(az)) * distance
    return RigidTransform.lookAt(eye: eye, target: center)
}

private func frame(_ t: Double, pose: simd_float4x4? = matrix_identity_float4x4, lux: Float = 1000, depth: Float = 0.5,
                   conf: Float = 0.9, tracking: CoachTracking = .normal, features: Int = 400,
                   external: Set<CoachIssue> = []) -> CoachFrame {
    CoachFrame(timestamp: t, cameraToWorld: pose, ambientIntensity: lux, centerDepth: depth, highConfidenceFraction: conf,
               tracking: tracking, featureCount: features, external: external)
}

private func translated(_ x: Float, _ y: Float = 0, _ z: Float = 0) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4(x, y, z, 1)
    return m
}

@Suite("Capture Coach")
struct CaptureCoachTests {
    @Test func speedFromTransforms() {
        let a = matrix_identity_float4x4
        let b = translated(0.03, 0.04, 0) // 5 cm
        let s = CaptureCoach.speeds(from: a, to: b, dt: 0.1)
        #expect(abs(s.linear - 0.5) < 1e-5)
        #expect(abs(s.angular) < 1e-3)
        // 9 degrees of yaw in 0.1 s = 90 deg/s.
        let yaw = simd_float4x4(simd_quatf(angle: 9 * .pi / 180, axis: SIMD3(0, 1, 0)))
        let r = CaptureCoach.speeds(from: a, to: yaw, dt: 0.1)
        #expect(abs(r.angular - 90) < 0.05)
        #expect(CaptureCoach.speeds(from: a, to: b, dt: 0) == (0, 0))

        // EMA: a steady 0.1 m/s walk at 60 fps converges to 0.1 m/s.
        var coach = CaptureCoach(mode: .detail)
        coach.beginScanning()
        var out: CoachOutput?
        for k in 0..<120 {
            out = coach.update(frame(Double(k) / 60, pose: translated(Float(k) * 0.1 / 60)))
        }
        #expect(abs(out!.linearSpeed - 0.1) < 0.002)
        #expect(out!.speedFraction < 0.5)
    }

    @Test func priorityOrdering() {
        // Everything wrong at once: tracking wins, then dark, then fast, then distance, then texture.
        var coach = CaptureCoach(mode: .detail)
        coach.beginScanning()
        var t = 0.0
        func run(_ seconds: Double, _ make: (Double, Int) -> CoachFrame) -> CoachOutput {
            var last: CoachOutput!
            let n = Int(seconds * 30)
            for k in 0..<n {
                last = coach.update(make(t, k))
                t += 1.0 / 30
            }
            return last
        }
        // Fast motion: 0.6 m/s.
        let fast: (Double, Int) -> simd_float4x4 = { time, _ in translated(Float(time) * 0.6) }
        var out = run(3) { time, k in frame(time, pose: fast(time, k), lux: 50, depth: 2.0, conf: 0.05, tracking: .relocalizing) }
        #expect(out.guidance == .trackingLost)
        #expect(!out.shouldIntegrate)
        out = run(3) { time, k in frame(time, pose: fast(time, k), lux: 50, depth: 2.0, conf: 0.05) }
        #expect(out.guidance == .tooDark)
        out = run(3) { time, k in frame(time, pose: fast(time, k), lux: 1000, depth: 2.0, conf: 0.05) }
        #expect(out.guidance == .tooFast)
        out = run(3) { time, _ in frame(time, pose: matrix_identity_float4x4, lux: 1000, depth: 2.0, conf: 0.05) }
        #expect(out.guidance == .tooFar)
        #expect(out.distanceZone == .tooFar)
        out = run(3) { time, _ in frame(time, pose: matrix_identity_float4x4, lux: 1000, depth: 0.15, conf: 0.05) }
        #expect(out.guidance == .tooClose)
        // In range but low confidence: advisory only, integration continues.
        out = run(1.5) { time, _ in frame(time, pose: matrix_identity_float4x4, lux: 1000, depth: 0.5, conf: 0.05) }
        #expect(out.shouldIntegrate)
        #expect(out.guidance == .lowTexture)
        // All good.
        out = run(10) { time, _ in frame(time, pose: matrix_identity_float4x4, lux: 1000, depth: 0.5, conf: 0.9) }
        #expect(out.guidance == .good)
        #expect(out.shouldIntegrate)
        #expect(out.quality > 0.8)
    }

    @Test func hysteresisPreventsFlicker() {
        // Distance jitters around the far limit: the cue changes at most a couple of times.
        var coach = CaptureCoach(mode: .detail)
        let limit = coach.thresholds.maxDistance
        coach.beginScanning()
        var changes = 0
        var gateChanges = 0
        var last: Guidance?
        var lastGate: Bool?
        var rng = SplitMix64(seed: 42)
        for k in 0..<600 {
            let jitter = Float(rng.nextUnit() - 0.5) * 0.08 // +-4 cm around the limit
            let out = coach.update(frame(Double(k) / 30, depth: limit + jitter))
            if let last, last != out.guidance { changes += 1 }
            if let lastGate, lastGate != out.shouldIntegrate { gateChanges += 1 }
            last = out.guidance
            lastGate = out.shouldIntegrate
        }
        #expect(changes <= 2, "guidance changed \(changes) times")
        #expect(gateChanges <= 2, "gate changed \(gateChanges) times")

        // Light flickering between 200 and 350 (between the dark and bright thresholds) once dark: stays dark.
        var dark = CaptureCoach(mode: .detail)
        dark.beginScanning()
        var outs: [CoachOutput] = []
        for k in 0..<30 { outs.append(dark.update(frame(Double(k) / 30, lux: 100))) }
        #expect(outs.last!.guidance == .tooDark)
        outs = []
        for k in 30..<300 { outs.append(dark.update(frame(Double(k) / 30, lux: k % 2 == 0 ? 200 : 350))) }
        #expect(outs.allSatisfy { $0.guidance == .tooDark })
        // A single bad frame never shows (enter delay).
        var blip = CaptureCoach(mode: .detail)
        blip.beginScanning()
        var seen = Set<Guidance>()
        for k in 0..<300 {
            let out = blip.update(frame(Double(k) / 30, depth: k == 150 ? 1.6 : 0.5))
            seen.insert(out.guidance)
        }
        #expect(!seen.contains(.tooFar))
        // Minimum dwell: a "good" cue replacing a problem waits at least minDisplaySeconds.
        var dwell = CaptureCoach(mode: .detail)
        dwell.beginScanning()
        for k in 0..<60 { _ = dwell.update(frame(Double(k) / 30, depth: 2)) }
        var firstGood: Double?
        for k in 60..<200 {
            let out = dwell.update(frame(Double(k) / 30, depth: 0.5))
            if out.guidance != .tooFar && firstGood == nil { firstGood = Double(k) / 30 }
        }
        #expect(firstGood != nil && firstGood! - 2.0 >= dwell.exitSeconds - 1e-9)
    }

    @Test func gateHapticsAndTorch() {
        var coach = CaptureCoach(mode: .detail)
        coach.beginScanning()
        var haptics: [CoachHaptic] = []
        var torch = false
        for k in 0..<300 {
            let t = Double(k) / 30
            // Good for 3 s, too far for 2 s, good for 2 s, dark for 3 s.
            let depth: Float = (t >= 3 && t < 5) ? 1.5 : 0.5
            let lux: Float = t >= 7 ? 60 : 1000
            let out = coach.update(frame(t, lux: lux, depth: depth))
            haptics.append(out.haptic)
            torch = out.wantsTorch
        }
        let ticks = haptics.filter { $0 == .tick }.count
        let warnings = haptics.filter { $0 == .warning }.count
        #expect(ticks > 20, "Geiger ticks while good")
        #expect(warnings == 2, "one double-buzz per transition into a bad state, got \(warnings)")
        #expect(torch, "torch latched on after sustained darkness")
        // No ticks while gated: frames 3.3..5 s.
        #expect(haptics[110..<150].allSatisfy { $0 != .tick })
    }

    @Test func readinessPreflight() {
        var coach = CaptureCoach(mode: .detail)
        var out = coach.update(frame(0, tracking: .initializing))
        #expect(out.guidance == .gettingReady && !out.isReady && !out.shouldIntegrate)
        var readyHaptics = 0
        for k in 1..<60 {
            out = coach.update(frame(Double(k) / 30, tracking: k < 20 ? .initializing : .normal))
            if out.haptic == .ready { readyHaptics += 1 }
        }
        #expect(out.isReady)
        #expect(readyHaptics == 1)
        #expect(!out.shouldIntegrate, "nothing integrates before Start")
        // Too dark keeps it not-ready.
        var dim = CaptureCoach(mode: .detail)
        for k in 0..<60 { out = dim.update(frame(Double(k) / 30, lux: 40)) }
        #expect(!out.isReady)
        #expect(out.guidance == .tooDark)
    }

    @Test func coverageFillsCellsAndCompletesBands() {
        let center = SIMD3<Float>(0, 0.8, -1)
        var coach = CaptureCoach(mode: .detail)
        coach.beginScanning()
        var t = 0.0
        var successes = 0
        var targets: [CoachBand] = []
        var guidanceSeen = Set<String>()
        // Slow walk (about 10 deg/s, 0.09 m/s at 0.5 m) around the object at mid height.
        func pass(elevation: Float) {
            for step in 0..<1100 {
                let az = Float(step) * 360 / 1080
                let out = coach.update(frame(t, pose: orbitPose(center, azimuth: az, elevation: elevation, distance: 0.5), depth: 0.5))
                if out.haptic == .success { successes += 1 }
                if let target = out.coverage.targetBand, targets.last != target { targets.append(target) }
                guidanceSeen.insert(out.guidance.label())
                t += 1.0 / 30
            }
        }
        pass(elevation: 20)
        var snap = coach.coverageSnapshot()
        #expect(snap.bandsComplete == [false, true, false])
        #expect(snap.fill[1].allSatisfy { $0 == 1 })
        #expect(snap.fill[0].allSatisfy { $0 == 0 })
        #expect(snap.targetBand == .low, "after the mid pass the coach asks for the low pass")
        #expect(guidanceSeen.contains("Now lower"))
        pass(elevation: -10)
        snap = coach.coverageSnapshot()
        #expect(snap.bandsComplete == [true, true, false])
        #expect(snap.targetBand == .high)
        pass(elevation: 55)
        snap = coach.coverageSnapshot()
        #expect(snap.bandsComplete == [true, true, true])
        #expect(snap.fraction == 1)
        #expect(successes == 3)
        #expect(targets == [.low, .high])
        #expect(guidanceSeen.contains("Now higher"))
        #expect(guidanceSeen.contains("Looks complete"))
        let report = coach.report()
        #expect(report.grade == .a, "\(report)")
        #expect(report.fix == nil)
    }

    @Test func badFramesDoNotFillCoverage() {
        let center = SIMD3<Float>(0, 0.8, -1)
        var coach = CaptureCoach(mode: .detail)
        coach.beginScanning()
        // Whipping around at 0.9 m/s: too fast, nothing counts.
        for step in 0..<200 {
            let az = Float(step) * 6
            _ = coach.update(frame(Double(step) / 30, pose: orbitPose(center, azimuth: az, elevation: 20, distance: 0.5), depth: 0.5))
        }
        #expect(coach.coverageSnapshot().fraction == 0)
        let report = coach.report()
        #expect(report.grade == .f)
        #expect(report.fix == "Mostly scanned too fast")
    }

    @Test func gradeNamesTheMostUsefulFix() {
        let center = SIMD3<Float>(0, 0.8, -1)
        // Front half only, all three bands, good technique: a wall-mounted item. Grade B+ with a back-side note.
        var front = CaptureCoach(mode: .detail)
        front.beginScanning()
        var t = 0.0
        for elevation: Float in [20, -10, 55] {
            for step in 0..<600 {
                let az = -80 + Float(step) * 170 / 600
                _ = front.update(frame(t, pose: orbitPose(center, azimuth: az, elevation: elevation, distance: 0.5), depth: 0.5))
                t += 1.0 / 30
            }
        }
        let r1 = front.report()
        #expect(r1.grade == .a || r1.grade == .b, "\(r1)")
        #expect(r1.fix == "Back side not scanned (fine if wall-mounted)")

        // Full mid ring only, in low light half the time.
        var dim = CaptureCoach(mode: .detail)
        dim.beginScanning()
        t = 0
        for step in 0..<2200 {
            let az = Float(step) * 360 / 1080
            let lux: Float = (step / 300) % 2 == 0 ? 1000 : 60
            _ = dim.update(frame(t, pose: orbitPose(center, azimuth: az, elevation: 20, distance: 0.5), lux: lux, depth: 0.5))
            t += 1.0 / 30
        }
        let r2 = dim.report()
        #expect(r2.grade != .a)
        #expect(r2.fix == "Low light: turn on lights" || r2.fix?.hasPrefix("Gaps") == true, "\(r2)")
        #expect(r2.tooDarkFraction > 0.3)

        // Mid ring complete, nothing else, good light: the fix is about coverage.
        var ring = CaptureCoach(mode: .detail)
        ring.beginScanning()
        t = 0
        for step in 0..<1100 {
            let az = Float(step) * 360 / 1080
            _ = ring.update(frame(t, pose: orbitPose(center, azimuth: az, elevation: 20, distance: 0.5), depth: 0.5))
            t += 1.0 / 30
        }
        let r3 = ring.report()
        #expect(r3.grade == .c || r3.grade == .d || r3.grade == .b, "\(r3)")
        #expect(r3.fix?.hasPrefix("Gaps") == true, "\(String(describing: r3.fix))")
    }

    @Test func surfaceTipShowsOncePerScan() {
        var coach = CaptureCoach(mode: .detail)
        coach.beginScanning()
        var tips = 0
        for k in 0..<1800 { // 60 s of a shiny surface
            let out = coach.update(frame(Double(k) / 30, conf: 0.1, features: 10))
            if out.showSurfaceTip { tips += 1 }
            #expect(out.shouldIntegrate)
        }
        #expect(tips == 1)
    }

    @Test func externalIssuesAndObjectCapturePasses() {
        // Object Capture / RoomPlan feed Apple's feedback as external issues.
        var coach = CaptureCoach(mode: .objectCapture)
        coach.beginScanning()
        var out: CoachOutput!
        for k in 0..<30 { out = coach.update(CoachFrame(timestamp: Double(k) / 30, external: [.tooFast])) }
        #expect(out.guidance == .tooFast)
        for k in 30..<90 { out = coach.update(CoachFrame(timestamp: Double(k) / 30, external: [])) }
        #expect(out.guidance == .good)
        #expect(coach.completePass(.mid) == .low)
        #expect(coach.completePass(.low) == .high)
        #expect(coach.completePass(.high) == nil)
        #expect(coach.coverageSnapshot().bandsComplete == [true, true, true])

        // Measure: steadiness only (no distance or light gating).
        var measure = CaptureCoach(mode: .measure)
        measure.beginScanning()
        for k in 0..<60 { out = measure.update(frame(Double(k) / 30, pose: translated(Float(k) * 0.2 / 30), lux: 10, depth: 9)) }
        #expect(out.guidance == .holdSteady)
        for k in 60..<120 { out = measure.update(frame(Double(k) / 30, pose: translated(0.4), lux: 10, depth: 9)) }
        #expect(out.guidance == .good && out.shouldIntegrate)
    }

    @Test func lookAroundCoverageForSpaces() {
        var coach = CaptureCoach(mode: .mesh)
        coach.beginScanning()
        var t = 0.0
        // Turn in place at level pitch, 20 deg/s.
        for step in 0..<1200 {
            let yaw = Float(step) * 20 / 30 * .pi / 180
            let pose = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
            _ = coach.update(frame(t, pose: pose, depth: 2))
            t += 1.0 / 30
        }
        let snap = coach.coverageSnapshot()
        #expect(snap.bandsComplete[1])
        #expect(snap.targetBand == .low)
        #expect(Guidance.nextBand(.low, lower: true).label(coverage: .lookAround) == "Aim lower")
    }

    @Test func labelsAreAtMostThreeWords() {
        let all: [Guidance] = [.gettingReady, .trackingLost, .tooDark, .tooFast, .tooFar, .tooClose, .lowTexture, .holdSteady,
                               .nextBand(.low, lower: true), .nextBand(.high, lower: false), .complete, .good]
        for g in all {
            #expect(g.label().split(separator: " ").count <= 3, "\(g.label())")
        }
    }
}
