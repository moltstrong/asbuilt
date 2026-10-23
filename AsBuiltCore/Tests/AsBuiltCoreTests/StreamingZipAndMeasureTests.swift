import Foundation
import Testing
import simd
@testable import AsBuiltCore

private func scratchDirectory(_ name: String) throws -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("asbuilt-tests-\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

/// Runs a tool and returns (status, stdout+stderr).
private func run(_ tool: String, _ args: [String]) throws -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

@Suite("Streaming ZIP")
struct StreamingZipTests {
    /// Fake photo set: several "photos" (one bigger than the chunk size), a nested folder, a log.
    private func makeImages(in dir: URL) throws -> [String: Data] {
        let images = dir.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: images.appendingPathComponent("Extra"), withIntermediateDirectories: true)
        var rng = SplitMix64(seed: 7)
        var files: [String: Data] = [:]
        for (i, size) in [0, 1, 4095, 300_000, 2_500_000].enumerated() {
            var bytes = [UInt8](repeating: 0, count: size)
            for k in 0..<size { bytes[k] = UInt8(truncatingIfNeeded: rng.next()) }
            let name = String(format: "IMG_%04d.HEIC", i + 1)
            try Data(bytes).write(to: images.appendingPathComponent(name))
            files["Images/" + name] = Data(bytes)
        }
        let nested = Data("depth".utf8)
        try nested.write(to: images.appendingPathComponent("Extra/IMG_0001_depth.TIF"))
        files["Images/Extra/IMG_0001_depth.TIF"] = nested
        return files
    }

    @Test func streamsAMultiFileArchiveThatUnzipValidates() throws {
        let dir = try scratchDirectory("zip")
        defer { try? FileManager.default.removeItem(at: dir) }
        var expected = try makeImages(in: dir)
        let log = Data("Attempt 1: .reduced, 5 photos\nüñïçødé ok\n".utf8)
        expected["reconstruction-log.txt"] = log
        let out = dir.appendingPathComponent("photos.zip")
        let zip = try StreamingZipWriter(url: out, chunkSize: 64 * 1024)
        var progress: [UInt64] = []
        try zip.addDirectory(dir.appendingPathComponent("Images"), prefix: "Images/") { done, _ in progress.append(done) }
        try zip.addData(log, path: "reconstruction-log.txt")
        try zip.finish()
        #expect(zip.entryCount == expected.count)
        #expect(progress.last == UInt64(expected.values.reduce(0) { $0 + $1.count }) - UInt64(log.count))
        #expect(throws: StreamingZipWriter.ZipError.alreadyFinished) { try zip.finish() }

        // `unzip -t` (Info-ZIP) checks every CRC.
        let (status, text) = try run("/usr/bin/unzip", ["-t", out.path])
        print("unzip -t: \(text.split(separator: "\n").last ?? "")")
        #expect(status == 0, "\(text)")
        #expect(text.contains("No errors detected"))
        // Extract and compare every file byte for byte.
        let extracted = dir.appendingPathComponent("x", isDirectory: true)
        let (unzipStatus, _) = try run("/usr/bin/unzip", ["-q", out.path, "-d", extracted.path])
        #expect(unzipStatus == 0)
        for (path, data) in expected {
            let got = try Data(contentsOf: extracted.appendingPathComponent(path))
            #expect(got == data, "\(path)")
        }
        // The in-memory ZipWriter agrees on CRCs (same CRC-32).
        #expect(CRC32.update(0xFFFF_FFFF, log) ^ 0xFFFF_FFFF == CRC32.checksum(log))
    }

    @Test func zip64RecordsValidate() throws {
        // Force Zip64 headers for every entry (real 4 GB files are too slow for unit tests).
        let dir = try scratchDirectory("zip64")
        defer { try? FileManager.default.removeItem(at: dir) }
        let expected = try makeImages(in: dir)
        let out = dir.appendingPathComponent("photos64.zip")
        let zip = try StreamingZipWriter(url: out, chunkSize: 64 * 1024, zip64Threshold: 0)
        // Prefix without the trailing slash (what the app passes) must still make a folder.
        try zip.addDirectory(dir.appendingPathComponent("Images"), prefix: "Images")
        try zip.finish()
        let (status, text) = try run("/usr/bin/unzip", ["-t", out.path])
        #expect(status == 0, "\(text)")
        #expect(text.contains("No errors detected"))
        let extracted = dir.appendingPathComponent("x", isDirectory: true)
        _ = try run("/usr/bin/unzip", ["-q", out.path, "-d", extracted.path])
        for (path, data) in expected {
            #expect((try? Data(contentsOf: extracted.appendingPathComponent(path))) == data, "\(path)")
        }
    }

    @Test func cancellationAndUnreadableFiles() throws {
        let dir = try scratchDirectory("zipc")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try makeImages(in: dir)
        let zip = try StreamingZipWriter(url: dir.appendingPathComponent("c.zip"), chunkSize: 4096)
        #expect(throws: StreamingZipWriter.ZipError.self) {
            try zip.addFile(at: dir.appendingPathComponent("missing.heic"), path: "missing.heic")
        }
        zip.isCancelled = { true }
        #expect(throws: StreamingZipWriter.ZipError.cancelled) {
            try zip.addDirectory(dir.appendingPathComponent("Images"), prefix: "Images/")
        }
    }
}

@Suite("Precision measure")
struct PrecisionMeasureTests {
    @Test func medianWithOutlierRejection() {
        var rng = SplitMix64(seed: 3)
        let truth = SIMD3<Float>(0.4, 1.1, -0.9)
        var sampler = PointSampler(target: 24, minimum: 15)
        for k in 0..<24 {
            let n = SIMD3(Float(rng.nextGaussian()), Float(rng.nextGaussian()), Float(rng.nextGaussian())) * 0.002
            // Every 6th sample hits the background 40 cm behind (edge bleeding).
            sampler.add(k % 6 == 5 ? truth + SIMD3(0, 0, -0.4) : truth + n)
        }
        sampler.add(SIMD3(.nan, 0, 0)) // ignored
        let e = sampler.estimate!
        #expect(e.rejected == 4)
        #expect(simd_distance(e.point, truth) < 0.002)
        #expect(e.spread > 0.001 && e.spread < 0.006)
        #expect(sampler.isSteady(maxSpread: PointSampler.lockSpread(range: 1)))
        #expect(sampler.fill == 1)

        // Shaky hand: 2 cm spread never locks (ring stays yellow).
        var shaky = PointSampler()
        for _ in 0..<24 {
            shaky.add(truth + SIMD3(Float(rng.nextGaussian()), Float(rng.nextGaussian()), Float(rng.nextGaussian())) * 0.02)
        }
        #expect(!shaky.isSteady(maxSpread: PointSampler.lockSpread(range: 1)))
        // Too few samples never lock.
        var few = PointSampler()
        for _ in 0..<5 { few.add(truth) }
        #expect(!few.isSteady(maxSpread: 0.01))
    }

    @Test func formatsToSixteenthsAndMillimeters() {
        let inch = 0.0254
        #expect(UnitFormatter.precise(36.0625 * inch, .imperial) == "3' 1/16\"")
        #expect(UnitFormatter.precise(13.5 * inch, .imperial) == "1' 1 1/2\"")
        #expect(UnitFormatter.precise(1.2345, .metric) == "1234 mm")
        #expect(UnitFormatter.plusMinus(0.003, .imperial) == "± 1/8\"")
        #expect(UnitFormatter.plusMinus(0.0001, .imperial) == "± 1/16\"")
        #expect(UnitFormatter.plusMinus(0.0034, .metric) == "± 3 mm")
        #expect(UnitFormatter.plusMinus(0.0001, .metric) == "± 1 mm")
    }

    @Test func tapeCalibrationScalesDisplayAndKeepsRaw() throws {
        let m = PrecisionMeasurement(label: "Door width", start: SIMD3(0, 0, 0), end: SIMD3(0.9, 0, 0), uncertaintyMeters: 0.004,
                                     samples: 48, method: "lidarDepth")
        #expect(abs(m.rawMeters - 0.9) < 1e-6)
        // Tape says 0.9144 m (36"): scale 1.016.
        let scale = try #require(PrecisionMeasurement.calibrationScale(rawMeters: m.rawMeters, tapeMeters: 0.9144))
        #expect(abs(scale - 1.016) < 1e-4)
        #expect(abs(m.calibratedMeters(scale: scale) - 0.9144) < 1e-6)
        #expect(abs(m.rawMeters - 0.9) < 1e-6, "raw value kept")
        // Implausible tape values are refused and ignored.
        #expect(PrecisionMeasurement.calibrationScale(rawMeters: 0.9, tapeMeters: 2) == nil)
        #expect(m.calibratedMeters(scale: 3) == m.rawMeters)
        #expect(abs(PrecisionMeasurement.combinedUncertainty(0.003, 0.004) - 0.005) < 1e-6)

        let csv = PrecisionMeasurementsCSV.write([m], scale: scale, units: .imperial, jobName: "Demo, Inc")
        let lines = csv.split(separator: "\n")
        #expect(lines[0] == "# AsBuilt measurements: \"Demo, Inc\"")
        #expect(lines[1].contains("1.01600"))
        #expect(lines[3].hasPrefix(#"1,Door width,"3' 0""","± 3/16""",0.9144,0.9000,0.0040,,48,lidarDepth,"#))
    }

    @Test func measurementDecodingIsTolerant() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","label":"Sill","rawMeters":1.5}"#
        let m = try JSONDecoder().decode(PrecisionMeasurement.self, from: Data(old.utf8))
        #expect(m.label == "Sill" && m.rawMeters == 1.5 && m.method == "lidarDepth" && m.tapeMeters == nil)
        let round = try JSONDecoder().decode(PrecisionMeasurement.self, from: JSONEncoder().encode(m))
        #expect(round == m)
    }
}
