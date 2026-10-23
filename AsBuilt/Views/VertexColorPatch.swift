import SceneKit
import UIKit
import simd

/// SceneKit ignores USD `primvars:displayColor` read through a UsdPrimvarReader (the material comes
/// back with a black diffuse), so the 3D tab re-applies the Detail scan's per-vertex colors from the
/// capture's binary PLY. Vertices are matched by quantized position (0.1 mm), so the result does not
/// depend on SceneKit keeping the USD vertex order. AR Quick Look gets the USDZ unchanged.
enum VertexColorPatch {
    /// Quantized position -> packed RGB (0x00RRGGBB).
    typealias ColorMap = [SIMD3<Int32>: UInt32]

    static func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3(Int32((p.x * 10_000).rounded()), Int32((p.y * 10_000).rounded()), Int32((p.z * 10_000).rounded()))
    }

    /// Reads x/y/z (float) and red/green/blue (uchar) from a binary little-endian PLY. Nil when the
    /// file is missing, ASCII, or has no vertex colors.
    static func loadColors(ply url: URL) -> ColorMap? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let headerEnd = data.range(of: Data("end_header\n".utf8)) else { return nil }
        guard let header = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .ascii),
              header.contains("format binary_little_endian") else { return nil }
        let sizes: [String: Int] = ["char": 1, "uchar": 1, "int8": 1, "uint8": 1, "short": 2, "ushort": 2, "int16": 2,
                                    "uint16": 2, "int": 4, "uint": 4, "int32": 4, "uint32": 4, "float": 4,
                                    "float32": 4, "double": 8, "float64": 8]
        var vertexCount = 0
        var inVertex = false
        var stride = 0
        var offsets: [String: (offset: Int, type: String)] = [:]
        for line in header.split(separator: "\n") {
            let parts = line.split(separator: " ").map(String.init)
            if parts.first == "element" {
                inVertex = parts.count >= 3 && parts[1] == "vertex"
                if inVertex { vertexCount = Int(parts[2]) ?? 0 }
            } else if parts.first == "property", inVertex {
                guard parts.count >= 3, parts[1] != "list", let size = sizes[parts[1]] else { return nil }
                offsets[parts[2]] = (stride, parts[1])
                stride += size
            }
        }
        guard vertexCount > 0, stride > 0,
              let ox = offsets["x"], let oy = offsets["y"], let oz = offsets["z"],
              ["float", "float32"].contains(ox.type),
              let r = offsets["red"], let g = offsets["green"], let b = offsets["blue"],
              [r.type, g.type, b.type].allSatisfy({ $0 == "uchar" || $0 == "uint8" })
        else { return nil }
        let start = headerEnd.upperBound - data.startIndex
        guard data.count >= start + vertexCount * stride else { return nil }
        var map = ColorMap(minimumCapacity: vertexCount)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<vertexCount {
                let base = start + i * stride
                let p = SIMD3<Float>(raw.loadUnaligned(fromByteOffset: base + ox.offset, as: Float.self),
                                     raw.loadUnaligned(fromByteOffset: base + oy.offset, as: Float.self),
                                     raw.loadUnaligned(fromByteOffset: base + oz.offset, as: Float.self))
                let rgb = UInt32(raw[base + r.offset]) << 16 | UInt32(raw[base + g.offset]) << 8 | UInt32(raw[base + b.offset])
                map[key(p)] = rgb
            }
        }
        return map
    }

    /// Vertex positions of a SceneKit geometry source (float components only).
    static func positions(of source: SCNGeometrySource) -> [SIMD3<Float>] {
        guard source.usesFloatComponents, source.bytesPerComponent == 4, source.componentsPerVector >= 3 else { return [] }
        let n = source.vectorCount
        var out = [SIMD3<Float>](repeating: .zero, count: n)
        source.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<n {
                let base = source.dataOffset + i * source.dataStride
                guard base + 12 <= raw.count else { return }
                out[i] = SIMD3(raw.loadUnaligned(fromByteOffset: base, as: Float.self),
                               raw.loadUnaligned(fromByteOffset: base + 4, as: Float.self),
                               raw.loadUnaligned(fromByteOffset: base + 8, as: Float.self))
            }
        }
        return out
    }

    /// RGBA float color data for `positions` (nil when fewer than 90% of vertices match).
    static func colorData(for positions: [SIMD3<Float>], map: ColorMap) -> Data? {
        guard !positions.isEmpty else { return nil }
        var floats = [Float](repeating: 1, count: positions.count * 4)
        var matched = 0
        for (i, p) in positions.enumerated() {
            guard let rgb = lookup(p, in: map) else {
                floats[i * 4] = 0.75; floats[i * 4 + 1] = 0.75; floats[i * 4 + 2] = 0.75
                continue
            }
            matched += 1
            // PLY colors are sRGB; SceneKit vertex colors are linear.
            floats[i * 4] = srgbToLinear(Float((rgb >> 16) & 0xFF) / 255)
            floats[i * 4 + 1] = srgbToLinear(Float((rgb >> 8) & 0xFF) / 255)
            floats[i * 4 + 2] = srgbToLinear(Float(rgb & 0xFF) / 255)
        }
        guard Double(matched) >= 0.9 * Double(positions.count) else { return nil }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Exact bin first; then the 26 neighbor bins (the USDA stores rounded fixed-point positions, so a
    /// value on a 0.1 mm bin boundary can land one bin over from the PLY's float).
    static func lookup(_ p: SIMD3<Float>, in map: ColorMap) -> UInt32? {
        let k = key(p)
        if let rgb = map[k] { return rgb }
        for dx: Int32 in -1...1 {
            for dy: Int32 in -1...1 {
                for dz: Int32 in -1...1 where dx != 0 || dy != 0 || dz != 0 {
                    if let rgb = map[k &+ SIMD3(dx, dy, dz)] { return rgb }
                }
            }
        }
        return nil
    }

    /// Fraction of `positions` that find a color (tests / diagnostics).
    static func matchFraction(_ positions: [SIMD3<Float>], map: ColorMap) -> Double {
        guard !positions.isEmpty else { return 0 }
        return Double(positions.filter { lookup($0, in: map) != nil }.count) / Double(positions.count)
    }

    static func srgbToLinear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func colorSource(_ data: Data, count: Int) -> SCNGeometrySource {
        SCNGeometrySource(data: data, semantic: .color, vectorCount: count, usesFloatComponents: true,
                          componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
    }

    static func coloredGeometry(_ geometry: SCNGeometry, colors: Data, count: Int) -> SCNGeometry {
        let sources = geometry.sources.filter { $0.semantic != .color } + [colorSource(colors, count: count)]
        let colored = SCNGeometry(sources: sources, elements: geometry.elements)
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = UIColor.white // vertex colors multiply the diffuse
        material.isDoubleSided = true
        colored.materials = [material]
        return colored
    }

    /// Synchronous version (tests, small meshes). Returns the number of geometries colored.
    @discardableResult
    static func apply(to scene: SCNScene, ply: URL) -> Int {
        guard let map = loadColors(ply: ply) else { return 0 }
        var patched = 0
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let g = node.geometry, let vertices = g.sources(for: .vertex).first else { return }
            let positions = positions(of: vertices)
            guard let data = colorData(for: positions, map: map) else { return }
            node.geometry = coloredGeometry(g, colors: data, count: positions.count)
            patched += 1
        }
        return patched
    }

    /// Off-main version for the 3D tab: positions are copied on the main thread, colors are matched
    /// on a background queue, and geometries are swapped back on the main thread.
    static func applyAsync(to scene: SCNScene, ply: URL) {
        var targets: [(node: SCNNode, geometry: SCNGeometry, positions: [SIMD3<Float>])] = []
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let g = node.geometry, let vertices = g.sources(for: .vertex).first else { return }
            targets.append((node, g, positions(of: vertices)))
            // Until colors arrive (or if they never do): light gray instead of SceneKit's black.
            for m in g.materials where isBlack(m.diffuse.contents) {
                m.diffuse.contents = UIColor(white: 0.78, alpha: 1)
            }
        }
        guard !targets.isEmpty else { return }
        let inputs = targets.map(\.positions)
        DispatchQueue.global(qos: .userInitiated).async {
            guard let map = loadColors(ply: ply) else { return }
            let colors = inputs.map { colorData(for: $0, map: map) }
            DispatchQueue.main.async {
                for (k, t) in targets.enumerated() {
                    guard let data = colors[k], t.node.geometry === t.geometry else { continue }
                    t.node.geometry = coloredGeometry(t.geometry, colors: data, count: t.positions.count)
                }
            }
        }
    }

    static func isBlack(_ contents: Any?) -> Bool {
        if let n = contents as? NSNumber { return n.doubleValue == 0 }
        if let c = contents as? UIColor {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return r + g + b < 0.02
        }
        return contents == nil
    }
}
