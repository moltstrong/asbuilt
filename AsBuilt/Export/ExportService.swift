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
