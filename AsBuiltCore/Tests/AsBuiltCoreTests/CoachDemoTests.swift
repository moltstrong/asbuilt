import Foundation
import Testing
import simd
@testable import AsBuiltCore

@Suite("Coach demo scenarios and tape parsing")
struct CoachDemoTests {
    @Test func midScanShowsPartialCoverageAndGoodTechnique() {
        let r = CoachDemo.run(.midScan)
        print("coach demo mid: guidance=\(r.output.guidance) coverage=\(r.output.coverage.fraction) speed=\(r.output.speedFraction) zone=\(r.output.distanceZone) bands=\(r.output.coverage.bandsComplete) target=\(String(describing: r.output.coverage.targetBand))")
        #expect(r.output.distanceZone == .good)
        #expect(r.output.speedFraction < 1)
        #expect(r.output.shouldIntegrate)
        #expect(r.output.coverage.fraction > 0.3 && r.output.coverage.fraction < 0.75)
        #expect(r.output.coverage.bandsComplete == [false, true, false])
        #expect(!r.output.guidance.isProblem)
    }

    @Test func nextBandAsksForLower() {
        let r = CoachDemo.run(.nextBand)
        print("coach demo band: guidance=\(r.output.guidance) target=\(String(describing: r.output.coverage.targetBand))")
        #expect(r.output.guidance == .nextBand(.low, lower: true))
        #expect(r.output.guidance.label() == "Now lower")
    }

    @Test func tooFastPausesIntegration() {
        let r = CoachDemo.run(.tooFast)
        print("coach demo fast: guidance=\(r.output.guidance) speed=\(r.output.speedFraction)")
        #expect(r.output.guidance == .tooFast)
        #expect(r.output.speedFraction > 1)
        #expect(!r.output.shouldIntegrate)
    }

    @Test func tooFarShowsCloser() {
        let r = CoachDemo.run(.tooFar)
        print("coach demo far: guidance=\(r.output.guidance) zone=\(r.output.distanceZone) d=\(String(describing: r.output.distance))")
        #expect(r.output.guidance == .tooFar)
        #expect(r.output.distanceZone == .tooFar)
        #expect(!r.output.shouldIntegrate)
    }

    @Test func gradeScenarioHasAReportWithAFix() throws {
        let r = CoachDemo.run(.grade)
        let report = try #require(r.report)
        print("coach demo grade: \(report.grade.rawValue) score=\(report.score) fix=\(report.fix ?? "nil") coverage=\(report.coverageFraction) good=\(report.goodFraction)")
        #expect(report.grade != .a)
        #expect(report.fix != nil)
        #expect(report.coverageFraction > 0.4 && report.coverageFraction < 0.9)
    }

    @Test func objectCapturePassesDriveTheBandCue() {
        var coach = CaptureCoach(mode: .objectCapture)
        var t = 0.0
        func tick() -> CoachOutput {
            t += 1.0 / 10
            return coach.update(CoachFrame(timestamp: t, tracking: .normal))
        }
        for _ in 0..<10 { _ = tick() }
        coach.beginScanning()
        coach.beginPass(.mid)
        for _ in 0..<10 { #expect(tick().guidance == .good) }
        #expect(coach.completePass(.mid) == .low)
        var out = tick()
        for _ in 0..<10 { out = tick() }
        #expect(out.guidance == .nextBand(.low, lower: true))
        coach.beginPass(.low)
        for _ in 0..<12 { out = tick() }
        #expect(out.guidance == .good)
        #expect(coach.completePass(.low) == .high)
        for _ in 0..<12 { out = tick() }
        #expect(out.guidance == .nextBand(.high, lower: false))
        #expect(out.guidance.label() == "Now higher")
        // Apple's feedback goes through the same priority: dark beats too fast.
        for _ in 0..<12 { out = coach.update(CoachFrame(timestamp: { t += 0.1; return t }(), tracking: .normal, external: [.tooFast, .tooDark])) }
        #expect(out.guidance == .tooDark)
        #expect(!out.shouldIntegrate)
        let text = coach.report().text(mode: .objectCapture, title: "Valve", thresholds: coach.thresholds)
        #expect(text.contains("Grade: "))
        #expect(!text.contains("Sweet spot"))
    }

    @Test func partialVolumeHasThinAndSolidAreas() {
        let volume = DemoDetailScan.partialVolume(frames: 8)
        let samples = volume.surfaceSamples(solidWeight: 6)
        #expect(samples.count > 50)
        let solid = samples.filter { $0.confidence >= 0.99 }.count
        let thin = samples.filter { $0.confidence < 0.5 }.count
        print("partial volume: \(samples.count) samples, solid \(solid), thin \(thin)")
        #expect(solid > 0 && thin > 0)
    }

    @Test func parsesTapeReadings() {
        let inch = UnitFormatter.metersPerInch, foot = UnitFormatter.metersPerFoot
        func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }
        #expect(near(UnitFormatter.parseLength("12' 3 1/2\"", .imperial), 12 * foot + 3.5 * inch))
        #expect(near(UnitFormatter.parseLength("12ft 3in", .imperial), 12 * foot + 3 * inch))
        #expect(near(UnitFormatter.parseLength("36 1/16", .imperial), 36.0625 * inch))
        #expect(near(UnitFormatter.parseLength("147.5\"", .imperial), 147.5 * inch))
        #expect(near(UnitFormatter.parseLength("3'", .imperial), 3 * foot))
        #expect(near(UnitFormatter.parseLength("915 mm", .imperial), 0.915))
        #expect(near(UnitFormatter.parseLength("915", .metric), 0.915))
        #expect(near(UnitFormatter.parseLength("91.5 cm", .metric), 0.915))
        #expect(near(UnitFormatter.parseLength("0,915 m", .metric), 0.915))
        #expect(near(UnitFormatter.parseLength("3\u{2019} 0\u{201D}", .imperial), 3 * foot))
        #expect(UnitFormatter.parseLength("", .imperial) == nil)
        #expect(UnitFormatter.parseLength("abc", .imperial) == nil)
        #expect(UnitFormatter.parseLength("1/0", .imperial) == nil)
        #expect(UnitFormatter.parseLength("-3", .metric) == nil)
    }
}
