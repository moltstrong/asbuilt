import Foundation

/// A material for `USDAWriter.write(indexedMeshes:...)`: a plain `UsdPreviewSurface` color.
public struct USDMaterialSpec: Sendable, Hashable {
    public var name: String
    public var r: Double
    public var g: Double
    public var b: Double
    public var opacity: Double
    public var roughness: Double

    public init(name: String, r: Double, g: Double, b: Double, opacity: Double = 1, roughness: Double = 0.85) {
        self.name = name
        self.r = r
        self.g = g
        self.b = b
        self.opacity = opacity
        self.roughness = roughness
    }
}

/// An arbitrary indexed triangle mesh for the USDA writer (world space, meters, +Y up).
public struct USDIndexedMesh: Sendable {
    public var name: String
    public var materialName: String
    public var positions: [SIMD3<Float>]
    /// Per-vertex normals (same count as `positions`), or empty to omit normals.
    public var normals: [SIMD3<Float>]
    /// Triangle list, three indices per face, 0-based into `positions`.
    public var indices: [UInt32]
    public var doubleSided: Bool

    public init(name: String, materialName: String, positions: [SIMD3<Float>], normals: [SIMD3<Float>] = [],
                indices: [UInt32], doubleSided: Bool = false) {
        self.name = name
        self.materialName = materialName
        self.positions = positions
        self.normals = normals
        self.indices = indices
        self.doubleSided = doubleSided
    }

    public var triangleCount: Int { indices.count / 3 }
}

extension USDAWriter {
    /// Writes indexed meshes, each bound to one of `materials`, under a single root `Xform`
    /// (kind = component, the default prim):
    ///
    ///     /<root>/Materials/<material>   UsdPreviewSurface
    ///     /<root>/Geometry/<mesh>        Mesh, material:binding -> its material
    ///
    /// Numbers are written straight into a preallocated byte buffer (no per-vertex `String`s),
    /// so a 300k-triangle LiDAR scan exports quickly. The output passes `usdchecker --arkit`.
    public static func write(indexedMeshes meshes: [USDIndexedMesh], materials: [USDMaterialSpec],
                             rootPrimName: String = "Scan", doc: String) -> Data {
        let root = identifier(rootPrimName)
        let vertexTotal = meshes.reduce(0) { $0 + $1.positions.count }
        let indexTotal = meshes.reduce(0) { $0 + $1.indices.count }
        var out = ByteBuffer(capacity: 4096 + vertexTotal * 2 * 36 + indexTotal * 8 + indexTotal)
        out.append("#usda 1.0\n(\n    customLayerData = {\n        string creator = \"AsBuilt\"\n    }\n")
        out.append("    defaultPrim = \"\(root)\"\n")
        out.append("    doc = \(quoted(doc))\n")
        out.append("    metersPerUnit = 1\n    upAxis = \"Y\"\n)\n\n")
        out.append("def Xform \"\(root)\" (\n    assetInfo = {\n        string name = \"\(root)\"\n    }\n    kind = \"component\"\n)\n{\n")

        // Materials actually used (plus the first one, so the scope is never empty).
        var materialNames: [String: String] = [:]
        var usedNames = Set<String>()
        for spec in materials {
            var prim = identifier(spec.name)
            var n = 2
            while usedNames.contains(prim) { prim = identifier(spec.name) + "_\(n)"; n += 1 }
            usedNames.insert(prim)
            materialNames[spec.name] = prim
        }
        let wanted = Set(meshes.map(\.materialName))
        out.append("    def Scope \"Materials\"\n    {\n")
        for (index, spec) in materials.enumerated() where wanted.contains(spec.name) || index == 0 {
            writeMaterial(spec, prim: materialNames[spec.name]!, root: root, into: &out)
        }
        out.append("    }\n\n")

        out.append("    def Xform \"Geometry\"\n    {\n")
        var meshNames = Set<String>()
        for mesh in meshes where mesh.triangleCount > 0 && !mesh.positions.isEmpty {
            var prim = identifier(mesh.name)
            var n = 2
            while meshNames.contains(prim) { prim = identifier(mesh.name) + "_\(n)"; n += 1 }
            meshNames.insert(prim)
            let material = materialNames[mesh.materialName] ?? materialNames[materials.first?.name ?? ""]
            writeIndexedMesh(mesh, prim: prim, materialPath: material.map { "/\(root)/Materials/\($0)" }, into: &out)
        }
        out.append("    }\n}\n")
        return out.data
    }

    private static func writeMaterial(_ spec: USDMaterialSpec, prim: String, root: String, into out: inout ByteBuffer) {
        let path = "/\(root)/Materials/\(prim)"
        out.append("        def Material \"\(prim)\"\n        {\n")
        out.append("            token outputs:surface.connect = <\(path)/PreviewSurface.outputs:surface>\n\n")
        out.append("            def Shader \"PreviewSurface\"\n            {\n")
        out.append("                uniform token info:id = \"UsdPreviewSurface\"\n")
        out.append("                color3f inputs:diffuseColor = (\(num(spec.r)), \(num(spec.g)), \(num(spec.b)))\n")
        out.append("                float inputs:metallic = 0\n")
        out.append("                float inputs:opacity = \(num(spec.opacity))\n")
        out.append("                float inputs:roughness = \(num(spec.roughness))\n")
        out.append("                token outputs:surface\n            }\n        }\n")
    }

    private static func writeIndexedMesh(_ mesh: USDIndexedMesh, prim: String, materialPath: String?,
                                         into out: inout ByteBuffer) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in mesh.positions {
            lo = pointwiseMin(lo, p)
            hi = pointwiseMax(hi, p)
        }
        out.append("        def Mesh \"\(prim)\" (\n")
        if materialPath != nil { out.append("            prepend apiSchemas = [\"MaterialBindingAPI\"]\n") }
        out.append("        )\n        {\n")
        out.append(mesh.doubleSided ? "            uniform bool doubleSided = 1\n" : "            uniform bool doubleSided = 0\n")
        out.append("            float3[] extent = [")
        appendVec(lo, into: &out)
        out.append(", ")
        appendVec(hi, into: &out)
        out.append("]\n")

        out.append("            int[] faceVertexCounts = [")
        let faces = mesh.triangleCount
        if faces > 0 {
            out.append(UInt8(ascii: "3"))
            for _ in 1..<faces {
                out.append(UInt8(ascii: ","))
                out.append(UInt8(ascii: " "))
                out.append(UInt8(ascii: "3"))
            }
        }
        out.append("]\n")

        out.append("            int[] faceVertexIndices = [")
        let used = faces * 3
        for i in 0..<used {
            if i > 0 {
                out.append(UInt8(ascii: ","))
                out.append(UInt8(ascii: " "))
            }
            out.append(uint: mesh.indices[i])
        }
        out.append("]\n")
        if let materialPath { out.append("            rel material:binding = <\(materialPath)>\n") }

        if mesh.normals.count == mesh.positions.count {
            out.append("            normal3f[] normals = [")
            appendVecList(mesh.normals, decimals: 4, into: &out)
            out.append("] (\n                interpolation = \"vertex\"\n            )\n")
        }
        out.append("            point3f[] points = [")
        appendVecList(mesh.positions, decimals: 5, into: &out)
        out.append("]\n")
        out.append("            uniform token subdivisionScheme = \"none\"\n        }\n")
    }

    @inline(__always)
    static func appendVec(_ v: SIMD3<Float>, decimals: Int = 5, into out: inout ByteBuffer) {
        out.append(UInt8(ascii: "("))
        out.append(fixed: v.x, decimals: decimals)
        out.append(UInt8(ascii: ","))
        out.append(UInt8(ascii: " "))
        out.append(fixed: v.y, decimals: decimals)
        out.append(UInt8(ascii: ","))
        out.append(UInt8(ascii: " "))
        out.append(fixed: v.z, decimals: decimals)
        out.append(UInt8(ascii: ")"))
    }

    static func appendVecList(_ list: [SIMD3<Float>], decimals: Int, into out: inout ByteBuffer) {
        for (i, v) in list.enumerated() {
            if i > 0 {
                out.append(UInt8(ascii: ","))
                out.append(UInt8(ascii: " "))
            }
            appendVec(v, decimals: decimals, into: &out)
        }
    }

    /// One material per class, one mesh prim per non-empty class group.
    public static func write(classifiedMesh mesh: ClassifiedMesh, name: String) -> Data {
        let parts = mesh.compactParts()
        let meshes = parts.map {
            USDIndexedMesh(name: $0.classification.name, materialName: $0.classification.name,
                           positions: $0.positions, normals: $0.normals, indices: $0.indices, doubleSided: false)
        }
        return write(indexedMeshes: meshes, materials: MeshClass.exportOrder.map(\.usdMaterial), rootPrimName: "Scan",
                     doc: "AsBuilt LiDAR mesh scan: \(name)")
    }
}

extension MeshClass {
    public var usdMaterial: USDMaterialSpec {
        let c = color
        return USDMaterialSpec(name: name, r: c.r, g: c.g, b: c.b, opacity: 1, roughness: self == .window ? 0.2 : 0.85)
    }
}

extension USDZPackager {
    /// A LiDAR mesh scan as USDZ bytes (USDA root layer, 64-byte aligned).
    public static func meshModel(_ mesh: ClassifiedMesh, name: String) -> Data {
        package(rootLayer: USDAWriter.write(classifiedMesh: mesh, name: name))
    }
}

/// Wavefront OBJ + MTL: Y-up, meters, one `g`/`usemtl` block per class group, `f v//vn` faces (1-based).
/// Imports into Blender, SketchUp (OBJ importer), Rhino, 3ds Max, MeshLab and CloudCompare.
public enum OBJWriter {
    public static func write(mesh: ClassifiedMesh, name: String, mtlFileName: String = "mesh.mtl") -> (obj: Data, mtl: Data) {
        let v = mesh.positions.count
        let indexTotal = mesh.groups.reduce(0) { $0 + $1.indices.count }
        var out = ByteBuffer(capacity: 512 + v * 2 * 34 + indexTotal * 16)
        out.append("# AsBuilt LiDAR mesh scan: ")
        out.append(name.replacingOccurrences(of: "\n", with: " "))
        out.append("\n# Units: meters. Up axis: +Y. Faces are counter-clockwise triangles.\n")
        out.append("# Vertices: ")
        out.append(int: v)
        out.append("  Triangles: ")
        out.append(int: mesh.triangleCount)
        out.append("\nmtllib ")
        out.append(mtlFileName)
        out.append("\no AsBuiltScan\n")
        for p in mesh.positions {
            out.append("v ")
            out.append(fixed: p.x, decimals: 5)
            out.append(UInt8(ascii: " "))
            out.append(fixed: p.y, decimals: 5)
            out.append(UInt8(ascii: " "))
            out.append(fixed: p.z, decimals: 5)
            out.append(UInt8(ascii: "\n"))
        }
        let hasNormals = mesh.normals.count == v
        if hasNormals {
            for n in mesh.normals {
                out.append("vn ")
                out.append(fixed: n.x, decimals: 4)
                out.append(UInt8(ascii: " "))
                out.append(fixed: n.y, decimals: 4)
                out.append(UInt8(ascii: " "))
                out.append(fixed: n.z, decimals: 4)
                out.append(UInt8(ascii: "\n"))
            }
        }
        for group in mesh.groups where !group.indices.isEmpty {
            out.append("g ")
            out.append(group.classification.name)
            out.append("\nusemtl ")
            out.append(group.classification.name)
            out.append(UInt8(ascii: "\n"))
            var i = 0
            let indices = group.indices
            while i + 2 < indices.count {
                out.append(UInt8(ascii: "f"))
                for k in 0..<3 {
                    let index = indices[i + k] &+ 1
                    out.append(UInt8(ascii: " "))
                    out.append(uint: index)
                    if hasNormals {
                        out.append(UInt8(ascii: "/"))
                        out.append(UInt8(ascii: "/"))
                        out.append(uint: index)
                    }
                }
                out.append(UInt8(ascii: "\n"))
                i += 3
            }
        }

        var mtl = ByteBuffer(capacity: 2048)
        mtl.append("# AsBuilt LiDAR mesh materials (one per surface class)\n")
        for cls in MeshClass.exportOrder {
            let c = cls.color
            mtl.append("\nnewmtl ")
            mtl.append(cls.name)
            mtl.append("\nKa 0 0 0\nKd ")
            mtl.append(fixed: c.r, decimals: 4)
            mtl.append(UInt8(ascii: " "))
            mtl.append(fixed: c.g, decimals: 4)
            mtl.append(UInt8(ascii: " "))
            mtl.append(fixed: c.b, decimals: 4)
            mtl.append("\nKs 0 0 0\nd 1\nillum 1\n")
        }
        return (out.data, mtl.data)
    }
}

/// Binary little-endian PLY: float xyz, float normals, uchar rgb per vertex (colored by the class of
/// the first face that uses it), uchar-count / uint-index triangle list.
public enum PLYWriter {
    public static func header(vertexCount: Int, faceCount: Int, comment: String) -> String {
        """
        ply
        format binary_little_endian 1.0
        comment \(comment.replacingOccurrences(of: "\n", with: " "))
        comment units meters, +Y up
        element vertex \(vertexCount)
        property float x
        property float y
        property float z
        property float nx
        property float ny
        property float nz
        property uchar red
        property uchar green
        property uchar blue
        element face \(faceCount)
        property list uchar uint vertex_indices
        end_header

        """
    }

    /// Bytes per vertex record and per triangle record.
    public static let vertexRecordSize = 6 * 4 + 3
    public static let faceRecordSize = 1 + 3 * 4

    public static func write(mesh: ClassifiedMesh, name: String) -> Data {
        let v = mesh.positions.count
        let f = mesh.triangleCount
        var colors = [UInt8](repeating: 255, count: v * 3)
        var assigned = [Bool](repeating: false, count: v)
        for group in mesh.groups {
            let c = group.classification.color
            let rgb = [UInt8(clamping: Int(c.r * 255)), UInt8(clamping: Int(c.g * 255)), UInt8(clamping: Int(c.b * 255))]
            for index in group.indices where !assigned[Int(index)] {
                let k = Int(index)
                assigned[k] = true
                colors[3 * k] = rgb[0]
                colors[3 * k + 1] = rgb[1]
                colors[3 * k + 2] = rgb[2]
            }
        }
        var out = ByteBuffer(capacity: 1024 + v * vertexRecordSize + f * faceRecordSize)
        out.append(header(vertexCount: v, faceCount: f, comment: "AsBuilt LiDAR mesh scan: \(name)"))
        let hasNormals = mesh.normals.count == v
        for i in 0..<v {
            let p = mesh.positions[i]
            out.appendLE(p.x)
            out.appendLE(p.y)
            out.appendLE(p.z)
            let n = hasNormals ? mesh.normals[i] : SIMD3<Float>(0, 1, 0)
            out.appendLE(n.x)
            out.appendLE(n.y)
            out.appendLE(n.z)
            out.append(colors[3 * i])
            out.append(colors[3 * i + 1])
            out.append(colors[3 * i + 2])
        }
        for group in mesh.groups {
            var i = 0
            while i + 2 < group.indices.count {
                out.append(UInt8(3))
                out.appendLE(group.indices[i])
                out.appendLE(group.indices[i + 1])
                out.appendLE(group.indices[i + 2])
                i += 3
            }
        }
        return out.data
    }
}
