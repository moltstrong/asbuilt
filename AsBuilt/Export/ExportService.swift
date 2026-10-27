import Foundation
import AsBuiltCore

/// Writes every CAD/estimating deliverable for a room capture.
enum ExportService {
    struct Context: Sendable {
        var jobName: String
        var address: String
        var client: String
        var roomTitle: String
        var date: Date
        var source: String

        init(jobName: String, address: String, client: String, roomTitle: String, date: Date, source: String) {
            self.jobName = jobName
            self.address = address
            self.client = client
            self.roomTitle = roomTitle
            self.date = date
            self.source = source
        }

        init(job: Job, capture: Capture) {
            let source: String
            switch capture.origin {
            case .roomPlan: source = "LiDAR scan (Apple RoomPlan)"
            case .objectCapture: source = "Object Capture"
            case .sample: source = "Sample data"
            case .lidarMesh: source = "LiDAR Mesh scan (ARKit)"
            case .detailScan: source = "Detail scan (LiDAR depth fusion)"
            case .unknown: source = "AsBuilt"
            }
            self.init(jobName: job.name, address: job.address, client: job.client, roomTitle: capture.title,
                      date: capture.createdAt, source: source)
        }

        var dateText: String {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return f.string(from: date)
        }
    }

    /// floorplan.dxf, floorplan.svg, floorplan.pdf and takeoff.csv (plan.json is written by the store).
    @discardableResult
    static func writePlanExports(plan: FloorPlan, to dir: URL, context: Context, units: UnitSystem,
                                 options: TakeoffOptions) throws -> [URL] {
        var urls = try writeCADExports(plan: plan, to: dir, context: context, units: units, options: options)
        urls.append(try writePDF(plan: plan, to: dir, context: context, units: units, options: options))
        return urls
    }

    /// floorplan.dxf, floorplan.svg and takeoff.csv. Pure AsBuiltCore text output: safe on any thread.
    @discardableResult
    static func writeCADExports(plan: FloorPlan, to dir: URL, context: Context, units: UnitSystem,
                                options: TakeoffOptions) throws -> [URL] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let takeoff = TakeoffCalculator.calculate(plan, options: options)

        let dxfURL = dir.appendingPathComponent(CaptureFile.dxf)
        let notes = [
            "JOB: \(context.jobName)",
            "ROOM: \(context.roomTitle)  DATE: \(context.dateText)",
            "SOURCE: \(context.source). UNITS: \(DXFUnits.preferred(for: units).name). VERIFY ON SITE.",
        ]
        let dxf = DXFWriter(units: .preferred(for: units), notes: notes).write(plan: plan, unitSystem: units)
        try Data(dxf.utf8).write(to: dxfURL, options: .atomic)

        let svgURL = dir.appendingPathComponent(CaptureFile.svg)
        let svg = SVGRenderer.render(plan: plan, units: units,
                                     options: .init(title: context.jobName, subtitle: "\(context.roomTitle) · \(context.address)"))
        try Data(svg.utf8).write(to: svgURL, options: .atomic)

        let csvURL = dir.appendingPathComponent(CaptureFile.csv)
        try Data(CSVWriter.write(plan: plan, takeoff: takeoff, units: units).utf8).write(to: csvURL, options: .atomic)
        return [dxfURL, svgURL, csvURL]
    }

    /// floorplan.pdf (plan sheet + takeoff), drawn with UIGraphicsPDFRenderer.
    @discardableResult
    static func writePDF(plan: FloorPlan, to dir: URL, context: Context, units: UnitSystem,
                         options: TakeoffOptions) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let takeoff = TakeoffCalculator.calculate(plan, options: options)
        let pdfURL = dir.appendingPathComponent(CaptureFile.pdf)
        let pdf = PDFPlanRenderer.render(plan: plan, takeoff: takeoff, context: context, units: units)
        try pdf.write(to: pdfURL, options: .atomic)
        return pdfURL
    }

    /// model.usdz: the room's 3D massing model (walls with openings, floor, windows, doors, fixtures).
    ///
    /// Written by AsBuiltCore's own USDA writer + 64-byte-aligned USDZ packager. Do NOT use
    /// `SCNScene.write(to:)` here: on iOS 27 SceneKit's USDKit exporter throws an uncatchable
    /// NSRangeException for this geometry (crashed every launch in build 1.0 (3)).
    @discardableResult
    static func writeRoomModel(plan: FloorPlan, to dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(CaptureFile.modelUSDZ)
        try USDZPackager.roomModel(plan: plan).write(to: url, options: .atomic)
        return url
    }

    /// Demo LiDAR Mesh scan: model.usdz, mesh.obj/.mtl, mesh.ply, measurements.csv, scan-info.json.
    /// Pure AsBuiltCore output, safe on any thread.
    @discardableResult
    static func writeDemoMeshScan(to dir: URL, title: String, units: UnitSystem) throws -> MeshMeasurements {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let output = LiDARMeshExporter.export(DemoMeshScan.bedroomMesh(), title: title, units: units)
        for file in output.files {
            try file.data.write(to: dir.appendingPathComponent(file.name), options: .atomic)
        }
        return output.measurements
    }

    /// Detail scan (TSDF fusion) deliverables: the same files as a LiDAR Mesh scan, with vertex colors
    /// (OBJ `v x y z r g b`, PLY uchar red/green/blue, USDZ `primvars:displayColor`) plus an optional
    /// coach-report.txt. Pure AsBuiltCore output, safe on any thread.
    @discardableResult
    static func writeFusedScan(_ fused: FusedMesh, to dir: URL, title: String, units: UnitSystem,
                               coachReport: String? = nil, progress: ((Double) -> Void)? = nil) throws -> MeshMeasurements {
        let prepared = MeshNormalizer.prepareForExport(fused.classifiedMesh())
        guard prepared.mesh.triangleCount > 0 else {
            throw NSError(domain: "AsBuilt.DetailScan", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The fused scan had no surface. Get within about 1 m and move slowly."])
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let output = LiDARMeshExporter.export(prepared, title: title, units: units, progress: progress)
        for file in output.files {
            try file.data.write(to: dir.appendingPathComponent(file.name), options: .atomic)
        }
        if let coachReport {
            try? Data(coachReport.utf8).write(to: dir.appendingPathComponent(CaptureFile.coachReport), options: .atomic)
        }
        return output.measurements
    }

    /// Demo Detail scan: runs the real TSDF fusion on synthetic depth maps of a small electrical box +
    /// conduit + ball valve, then writes the colored exports.
    @discardableResult
    static func writeDemoDetailScan(to dir: URL, title: String, units: UnitSystem) throws -> MeshMeasurements {
        let fused = DemoDetailScan.fuse()
        let report = """
        AsBuilt Capture Coach: demo Detail scan
        Fused \(fused.stats.framesIntegrated) synthetic LiDAR depth frames (256 x 192) at 4 mm voxels.
        Blocks: \(fused.stats.blockCount), voxels: \(fused.stats.voxelCount), memory: \(fused.stats.memoryBytes / 1024) KB.
        Mesh: \(fused.mesh.vertexCount) vertices, \(fused.mesh.triangleCount) triangles.
        """
        return try writeFusedScan(fused.mesh, to: dir, title: title, units: units, coachReport: report)
    }

    /// Object Capture photos (+ reconstruction log) as a STORE zip in the temporary directory,
    /// streamed file by file (`StreamingZipWriter`, Zip64 above 4 GB) so a 1-2 GB photo set never
    /// sits in memory. `progress` gets 0...1.
    static func makePhotoZip(captureDirectory: URL, title: String, progress: (@Sendable (Double) -> Void)? = nil,
                             isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> URL {
        let fm = FileManager.default
        let images = captureDirectory.appendingPathComponent(CaptureFile.images, isDirectory: true)
        let files = StreamingZipWriter.regularFiles(in: images)
        guard !files.isEmpty else {
            throw NSError(domain: "AsBuilt.PhotoZip", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "This capture has no photos to export."])
        }
        let outDir = fm.temporaryDirectory.appendingPathComponent("PhotoExports", isDirectory: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let out = outDir.appendingPathComponent(safeFileName(title) + "-photos.zip")
        try? fm.removeItem(at: out)
        let folder = safeFileName(title) + "-photos"
        do {
            let writer = try StreamingZipWriter(url: out)
            writer.isCancelled = isCancelled
            try writer.addDirectory(images, prefix: "\(folder)/Images") { done, total in
                progress?(total > 0 ? 0.98 * Double(done) / Double(total) : 0)
            }
            let log = captureDirectory.appendingPathComponent(CaptureFile.reconstructionLog)
            if fm.fileExists(atPath: log.path) {
                try writer.addFile(at: log, path: "\(folder)/\(CaptureFile.reconstructionLog)")
            }
            let readme = """
            AsBuilt Object Capture photos: \(title)
            AsBuilt sends these photos to the cloud for the full-detail model automatically. To build one
            yourself, open Reality Composer Pro > New Photogrammetry project and drop in the Images folder
            (or run PhotogrammetrySession with detail .full or .raw), then import the USDZ with "Import USDZ model".
            """
            try writer.addData(Data(readme.utf8), path: "\(folder)/README.txt")
            try writer.finish()
        } catch {
            try? fm.removeItem(at: out)
            throw error
        }
        progress?(1)
        return out
    }

    /// Bundles files (recursing into folders) into one stored ZIP in the temporary directory.
    static func makeZip(files: [URL], archiveName: String, folderName: String) throws -> URL {
        var zip = ZipWriter()
        let fm = FileManager.default
        for url in files {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey])
                while let child = enumerator?.nextObject() as? URL {
                    let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
                    if values?.isDirectory == true { continue }
                    let relative = child.path.replacingOccurrences(of: url.deletingLastPathComponent().path + "/", with: "")
                    zip.add(path: "\(folderName)/\(relative)", data: try Data(contentsOf: child))
                }
            } else {
                zip.add(path: "\(folderName)/\(url.lastPathComponent)", data: try Data(contentsOf: url))
            }
        }
        let outDir = fm.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let out = outDir.appendingPathComponent(safeFileName(archiveName) + ".zip")
        try? fm.removeItem(at: out)
        try zip.archive().write(to: out, options: .atomic)
        return out
    }

    static func safeFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        let collapsed = cleaned.replacingOccurrences(of: " ", with: "-")
        return collapsed.isEmpty ? "AsBuilt" : collapsed
    }
}
