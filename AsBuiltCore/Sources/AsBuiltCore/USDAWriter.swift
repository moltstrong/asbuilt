import Foundation

/// Writes a room massing model as a USDA (USD ASCII) layer.
///
/// The layer has one root `Xform "Room"` (kind = component, the default prim), a `Materials` scope
/// with `UsdPreviewSurface` materials and triangulated `Mesh` prims with baked world-space points
/// (meters, +Y up, plan (x, y) -> USD (x, -y)). No SceneKit/ModelIO involved: the old
/// `SCNScene.write(to:)` USDZ path crashes inside SceneKit's USDKit exporter on iOS 27.
public enum USDAWriter {
    public static let rootPrimName = "Room"

    public static func write(plan: FloorPlan) -> String {
        write(meshes: RoomModelBuilder.meshes(for: plan), name: plan.name)
    }

    public static func write(meshes: [RoomMesh], name: String) -> String {
        var out = ""
        out.reserveCapacity(64 * 1024)
        out += "#usda 1.0\n"
        out += "(\n"
        out += "    customLayerData = {\n"
        out += "        string creator = \"AsBuilt\"\n"
        out += "    }\n"
        out += "    defaultPrim = \"\(rootPrimName)\"\n"
        out += "    doc = \(quoted("AsBuilt room massing model: \(name)"))\n"
        out += "    metersPerUnit = 1\n"
        out += "    upAxis = \"Y\"\n"
        out += ")\n\n"

        out += "def Xform \"\(rootPrimName)\" (\n"
        out += "    assetInfo = {\n"
        out += "        string name = \(quoted(identifier(name)))\n"
        out += "    }\n"
        out += "    kind = \"component\"\n"
        out += ")\n{\n"

        // Materials.
        let used = Set(meshes.map(\.material))
        out += "    def Scope \"Materials\"\n    {\n"
        for material in RoomMaterial.allCases where used.contains(material) || material == .wall {
            writeMaterial(material, into: &out)
        }
        out += "    }\n"

        // Meshes, grouped under one Xform per group in first-seen order.
        var groups: [String] = []
        for mesh in meshes where !groups.contains(mesh.group) { groups.append(mesh.group) }
        for group in groups {
            out += "\n    def Xform \(quoted(identifier(group)))\n    {\n"
            var usedNames: Set<String> = []
            for mesh in meshes where mesh.group == group {
                var primName = identifier(mesh.name)
                var n = 2
                while usedNames.contains(primName) {
                    primName = identifier(mesh.name) + "_\(n)"
                    n += 1
                }
                usedNames.insert(primName)
                writeMesh(mesh, primName: primName, into: &out)
            }
            out += "    }\n"
        }
        out += "}\n"
        return out
    }

    // MARK: Pieces

    static func materialPath(_ material: RoomMaterial) -> String {
        "</\(rootPrimName)/Materials/\(material.rawValue)>"
    }

    private static func writeMaterial(_ material: RoomMaterial, into out: inout String) {
        let c = material.color
        let path = "/\(rootPrimName)/Materials/\(material.rawValue)"
        out += "        def Material \"\(material.rawValue)\"\n        {\n"
        out += "            token outputs:surface.connect = <\(path)/PreviewSurface.outputs:surface>\n\n"
        out += "            def Shader \"PreviewSurface\"\n            {\n"
        out += "                uniform token info:id = \"UsdPreviewSurface\"\n"
        out += "                color3f inputs:diffuseColor = (\(num(c.r)), \(num(c.g)), \(num(c.b)))\n"
        out += "                float inputs:metallic = 0\n"
        out += "                float inputs:opacity = \(num(c.opacity))\n"
        out += "                float inputs:roughness = \(num(material.roughness))\n"
        out += "                token outputs:surface\n"
        out += "            }\n"
        out += "        }\n"
    }

    private static func writeMesh(_ mesh: RoomMesh, primName: String, into out: inout String) {
        guard let bounds = mesh.bounds, mesh.triangleCount > 0 else { return }
        out += "        def Mesh \(quoted(primName)) (\n"
        out += "            prepend apiSchemas = [\"MaterialBindingAPI\"]\n"
        out += "        )\n        {\n"
        out += "            uniform bool doubleSided = 1\n"
        out += "            float3[] extent = [\(vec(bounds.min)), \(vec(bounds.max))]\n"
        out += "            int[] faceVertexCounts = [\(Array(repeating: "3", count: mesh.triangleCount).joined(separator: ", "))]\n"
        out += "            int[] faceVertexIndices = [\(mesh.indices.map(String.init).joined(separator: ", "))]\n"
        out += "            rel material:binding = \(materialPath(mesh.material))\n"
        out += "            normal3f[] normals = [\(mesh.normals.map(vec).joined(separator: ", "))] (\n"
        out += "                interpolation = \"vertex\"\n"
        out += "            )\n"
        out += "            point3f[] points = [\(mesh.points.map(vec).joined(separator: ", "))]\n"
        out += "            uniform token subdivisionScheme = \"none\"\n"
        out += "        }\n"
    }

    // MARK: Formatting

    /// Fixed-point number with up to 6 decimals, trailing zeros trimmed, never "-0".
    static func num(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = (value * 1_000_000).rounded() / 1_000_000
        if rounded == 0 { return "0" }
        var s = String(format: "%.6f", rounded)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    static func vec(_ v: SIMD3<Double>) -> String { "(\(num(v.x)), \(num(v.y)), \(num(v.z)))" }

    /// A valid USD prim name: [A-Za-z_][A-Za-z0-9_]*.
    public static func identifier(_ raw: String) -> String {
        var s = String(raw.unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            let ok = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v == 95
            return ok ? Character(scalar) : "_"
        })
        while s.contains("__") { s = s.replacingOccurrences(of: "__", with: "_") }
        if s.hasSuffix("_") && s.count > 1 { s.removeLast() }
        if s.isEmpty || s == "_" { return "Item" }
        if let first = s.unicodeScalars.first, first.value >= 48 && first.value <= 57 { s = "_" + s }
        return s
    }

    static func quoted(_ text: String) -> String {
        var escaped = ""
        for ch in text {
            switch ch {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(ch)
            }
        }
        return "\"\(escaped)\""
    }
}

/// Packs USD layers into a `.usdz` package: an uncompressed (STORE) ZIP whose file data all start at
/// 64-byte-aligned offsets, padded with a 0x1986 extra field like Pixar's `usdzip`. The first entry
/// is the root layer.
public enum USDZPackager {
    public static let alignment = 64

    public static func package(rootLayerName: String = "model.usda", rootLayer: Data,
                               resources: [(path: String, data: Data)] = [],
                               modified: Date = Date(timeIntervalSince1970: 1_767_225_600)) -> Data {
        var zip = ZipWriter(dataAlignment: alignment, utf8Names: false)
        zip.add(path: rootLayerName, data: rootLayer, modified: modified)
        for resource in resources { zip.add(path: resource.path, data: resource.data, modified: modified) }
        return zip.archive()
    }

    /// The room massing model of `plan` as USDZ bytes.
    public static func roomModel(plan: FloorPlan) -> Data {
        package(rootLayer: Data(USDAWriter.write(plan: plan).utf8))
    }
}
