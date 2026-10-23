import Foundation

/// Every deliverable of a LiDAR mesh scan, as file name + bytes.
public enum LiDARMeshExporter {
    public static let usdzName = "model.usdz"
    public static let objName = "mesh.obj"
    public static let mtlName = "mesh.mtl"
    public static let plyName = "mesh.ply"
    public static let csvName = "measurements.csv"
    public static let infoName = "scan-info.json"

    public struct Output: Sendable {
        public var measurements: MeshMeasurements
        public var files: [(name: String, data: Data)]
    }

    /// `mesh` should come from `MeshNormalizer.prepareForExport` (aligned, centered, on the floor).
    /// `progress` gets 0...1 as files are written.
    public static func export(_ prepared: MeshNormalizer.Result, title: String, units: UnitSystem,
                              includePLY: Bool = true, progress: ((Double) -> Void)? = nil) -> Output {
        let mesh = prepared.mesh
        let m = prepared.measurements
        var files: [(name: String, data: Data)] = []
        files.append((usdzName, USDZPackager.meshModel(mesh, name: title)))
        progress?(0.4)
        let obj = OBJWriter.write(mesh: mesh, name: title, mtlFileName: mtlName)
        files.append((objName, obj.obj))
        files.append((mtlName, obj.mtl))
        progress?(0.75)
        if includePLY {
            files.append((plyName, PLYWriter.write(mesh: mesh, name: title)))
        }
        progress?(0.9)
        files.append((csvName, Data(MeshMeasurementsCSV.write(m, title: title, units: units).utf8)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let info = try? encoder.encode(m) { files.append((infoName, info)) }
        progress?(1)
        return Output(measurements: m, files: files)
    }
}
