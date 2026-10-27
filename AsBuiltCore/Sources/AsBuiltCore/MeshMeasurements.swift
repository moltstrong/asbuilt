import Foundation

/// Size and surface statistics of a LiDAR mesh scan (meters / square meters).
public struct MeshMeasurements: Codable, Hashable, Sendable {
    public struct ClassStat: Codable, Hashable, Sendable {
        public var classification: MeshClass
        public var triangles: Int
        /// True (not projected) surface area of the class's faces.
        public var area: Double

        public init(classification: MeshClass, triangles: Int, area: Double) {
            self.classification = classification
            self.triangles = triangles
            self.area = area
        }
    }

    /// Bounding box of the scan after it is turned so its longest horizontal side runs along X:
    /// width = X (longer horizontal side), depth = Z, height = Y (gravity, ARKit +Y up).
    public var width: Double
    public var depth: Double
    public var height: Double
    public var triangleCount: Int
    public var vertexCount: Int
    public var surfaceArea: Double
    public var classes: [ClassStat]
    /// Yaw applied to line the scan up with the axes (degrees about +Y).
    public var alignmentYawDegrees: Double

    public init(width: Double, depth: Double, height: Double, triangleCount: Int, vertexCount: Int,
                surfaceArea: Double, classes: [ClassStat], alignmentYawDegrees: Double = 0) {
        self.width = width
        self.depth = depth
        self.height = height
        self.triangleCount = triangleCount
        self.vertexCount = vertexCount
        self.surfaceArea = surfaceArea
        self.classes = classes
        self.alignmentYawDegrees = alignmentYawDegrees
    }

    public func area(of classification: MeshClass) -> Double {
        classes.first { $0.classification == classification }?.area ?? 0
    }

    public func triangles(of classification: MeshClass) -> Int {
        classes.first { $0.classification == classification }?.triangles ?? 0
    }

    /// "12' 0" x 14' 0" x 8' 0"" or "3.66 m x 4.27 m x 2.44 m".
    public func dimensionsText(_ units: UnitSystem) -> String {
        [width, depth, height].map { UnitFormatter.length($0, units) }.joined(separator: " × ")
    }

    /// Measures `mesh` as is (no re-orientation): axis-aligned box of the used vertices. With `baseY`
    /// (object scans: the table top the object stands on) the height runs from there to the top.
    /// `trim` > 0 (object scans) ignores that fraction of the most extreme vertices on each side, so a
    /// stray vertex a voxel outside a face does not set the size.
    public static func measure(_ mesh: ClassifiedMesh, alignmentYawDegrees: Double = 0, baseY: Float? = nil,
                               trim: Double = 0) -> MeshMeasurements {
        let b = mesh.bounds
        var size = b.map { SIMD3<Double>(Double($0.max.x - $0.min.x), Double($0.max.y - $0.min.y), Double($0.max.z - $0.min.z)) }
            ?? SIMD3<Double>(0, 0, 0)
        var top = b?.max.y ?? 0
        if trim > 0, mesh.positions.count >= 20 {
            let f = min(0.05, trim)
            func extent(_ k: Int) -> (Float, Float) {
                let v = mesh.positions.map { $0[k] }.sorted()
                let n = v.count - 1
                return (v[Int((Double(n) * f).rounded())], v[Int((Double(n) * (1 - f)).rounded())])
            }
            let x = extent(0), y = extent(1), z = extent(2)
            size = SIMD3(Double(x.1 - x.0), Double(y.1 - y.0), Double(z.1 - z.0))
            top = y.1
        }
        if let baseY, b != nil { size.y = Double(max(0, top - baseY)) }
        var stats: [ClassStat] = []
        var total = 0.0
        for group in mesh.groups {
            var area = 0.0
            var i = 0
            let idx = group.indices
            while i + 2 < idx.count {
                let a = mesh.positions[Int(idx[i])]
                let bb = mesh.positions[Int(idx[i + 1])]
                let c = mesh.positions[Int(idx[i + 2])]
                let g = ClassifiedMeshBuilder.cross(bb - a, c - a)
                area += Double((g * g).sum().squareRoot()) / 2
                i += 3
            }
            total += area
            if let k = stats.firstIndex(where: { $0.classification == group.classification }) {
                stats[k].triangles += group.triangleCount
                stats[k].area += area
            } else {
                stats.append(ClassStat(classification: group.classification, triangles: group.triangleCount, area: area))
            }
        }
        return MeshMeasurements(width: size.x, depth: size.z, height: size.y, triangleCount: mesh.triangleCount,
                                vertexCount: mesh.vertexCount, surfaceArea: total, classes: stats,
                                alignmentYawDegrees: alignmentYawDegrees)
    }
}

/// Export preparation for scans: drop unused vertices, turn the scan about +Y so its minimum-area
/// footprint rectangle lines up with X (long side) and Z, and move it so the footprint is centered
/// on the origin with the lowest point at y = 0 (AR Quick Look then sets it on the floor/table).
public enum MeshNormalizer {
    public struct Result: Sendable {
        public var mesh: ClassifiedMesh
        public var measurements: MeshMeasurements
        public var yawRadians: Double
    }

    /// `baseY` (object scans): world height of the surface the object stands on. The export then puts
    /// that surface (not the lowest vertex, which sits a voxel or two above it after the table is
    /// removed) at y = 0 and measures the height from it.
    public static func prepareForExport(_ input: ClassifiedMesh, baseY: Float? = nil, trim: Double = 0) -> Result {
        // Objects are small: find their footprint direction on a 1 mm grid instead of 5 mm.
        let quantum = baseY == nil ? 0.005 : 0.001
        let mesh = removingUnusedVertices(input)
        guard mesh.triangleCount > 0 else {
            return Result(mesh: mesh, measurements: .measure(mesh), yawRadians: 0)
        }
        let footprint = mesh.positions.map { Point2D(Double($0.x), Double($0.z)) }
        let yaw = alignmentYaw(footprint, quantum: quantum)
        let c = Float(cos(yaw))
        let s = Float(sin(yaw))
        // Rotation about +Y by `yaw`: x' = c x + s z, z' = -s x + c z.
        var positions = mesh.positions.map { p in SIMD3<Float>(c * p.x + s * p.z, p.y, -s * p.x + c * p.z) }
        let normals = mesh.normals.map { n in SIMD3<Float>(c * n.x + s * n.z, n.y, -s * n.x + c * n.z) }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in positions {
            lo = pointwiseMin(lo, p)
            hi = pointwiseMax(hi, p)
        }
        // The surface must be where the object's base is (within 2 cm); otherwise measure from the mesh.
        let base = baseY.flatMap { $0.isFinite && abs($0 - lo.y) <= 0.02 ? $0 : nil }
        let shift = SIMD3<Float>((lo.x + hi.x) / 2, base ?? lo.y, (lo.z + hi.z) / 2)
        for i in positions.indices { positions[i] -= shift }
        let out = ClassifiedMesh(positions: positions, normals: normals, groups: mesh.groups, colors: mesh.colors)
        var degrees = yaw * 180 / .pi
        if abs(degrees) < 1e-9 { degrees = 0 }
        return Result(mesh: out, measurements: .measure(out, alignmentYawDegrees: degrees, baseY: base == nil ? nil : 0, trim: trim),
                      yawRadians: yaw)
    }

    /// Keeps only vertices referenced by a face (in first-use order) and re-indexes the groups.
    public static func removingUnusedVertices(_ mesh: ClassifiedMesh) -> ClassifiedMesh {
        var remap = [Int32](repeating: -1, count: mesh.positions.count)
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var colors: [SIMD3<UInt8>] = []
        positions.reserveCapacity(mesh.positions.count)
        let hasNormals = mesh.normals.count == mesh.positions.count
        let hasColors = mesh.hasVertexColors
        if hasNormals { normals.reserveCapacity(mesh.positions.count) }
        if hasColors { colors.reserveCapacity(mesh.positions.count) }
        var groups: [ClassifiedMesh.Group] = []
        for group in mesh.groups {
            var indices: [UInt32] = []
            indices.reserveCapacity(group.indices.count)
            for index in group.indices {
                let v = Int(index)
                if remap[v] < 0 {
                    remap[v] = Int32(positions.count)
                    positions.append(mesh.positions[v])
                    if hasNormals { normals.append(mesh.normals[v]) }
                    if hasColors { colors.append(mesh.colors[v]) }
                }
                indices.append(UInt32(remap[v]))
            }
            if !indices.isEmpty { groups.append(.init(classification: group.classification, indices: indices)) }
        }
        return ClassifiedMesh(positions: positions, normals: normals, groups: groups, colors: colors)
    }

    /// Yaw (radians, about +Y) that turns the minimum-area bounding rectangle of the XZ footprint so
    /// its longer side runs along +X. Rotating calipers over the convex hull.
    public static func alignmentYaw(_ points: [Point2D], quantum: Double = 0.005) -> Double {
        // Quantize (5 mm by default) and dedupe first: big scans have ~10^5 vertices.
        let q = max(1e-5, quantum)
        var seen = Set<Point2D>()
        seen.reserveCapacity(points.count / 4)
        for p in points where p.x.isFinite && p.y.isFinite {
            seen.insert(Point2D((p.x / q).rounded() * q, (p.y / q).rounded() * q))
        }
        let hull = Polygon2D.convexHull(Array(seen))
        guard hull.count >= 3 else { return 0 }
        var bestArea = Double.greatestFiniteMagnitude
        var bestAngle = 0.0
        var bestLongAlongX = true
        for i in 0..<hull.count {
            let e = hull[(i + 1) % hull.count] - hull[i]
            guard e.length > 1e-9 else { continue }
            let angle = atan2(e.y, e.x)
            let ca = cos(-angle)
            let sa = sin(-angle)
            var minX = Double.greatestFiniteMagnitude, maxX = -Double.greatestFiniteMagnitude
            var minY = Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
            for p in hull {
                let x = ca * p.x - sa * p.y
                let y = sa * p.x + ca * p.y
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
            let area = (maxX - minX) * (maxY - minY)
            if area < bestArea - 1e-12 {
                bestArea = area
                bestAngle = angle
                bestLongAlongX = (maxX - minX) >= (maxY - minY)
            }
        }
        // The footprint is (x, z). A rotation about +Y by yaw maps x' = cos x + sin z, z' = -sin x + cos z,
        // i.e. the 2D (x, z) plane rotates by -yaw. We want the chosen edge (at `bestAngle` in x-z) on +X.
        var yaw = bestAngle
        if !bestLongAlongX { yaw += .pi / 2 }
        // Normalize to (-pi/2, pi/2]: a rectangle is symmetric under half turns.
        while yaw > .pi / 2 { yaw -= .pi }
        while yaw <= -.pi / 2 { yaw += .pi }
        return yaw
    }
}

/// measurements.csv for a LiDAR mesh scan.
public enum MeshMeasurementsCSV {
    /// `object`: an object Detail scan: lengths in inches (imperial) or millimeters (metric), sizes
    /// measured from the surface the object stands on.
    public static func write(_ m: MeshMeasurements, title: String, units: UnitSystem, object: Bool = false) -> String {
        let lengthUnit = object ? (units == .imperial ? "in" : "mm") : (units == .imperial ? "ft" : "m")
        let areaUnit = units == .imperial ? "sq ft" : "m²"
        func len(_ v: Double) -> String {
            if object { return units == .imperial ? UnitFormatter.decimal(v / UnitFormatter.metersPerInch, 2) : UnitFormatter.decimal(v * 1000, 1) }
            return UnitFormatter.decimal(UnitFormatter.lengthValue(v, units), units == .imperial ? 2 : 3)
        }
        func display(_ v: Double) -> String { object ? UnitFormatter.objectLength(v, units) : UnitFormatter.length(v, units) }
        func area(_ v: Double) -> String { UnitFormatter.decimal(UnitFormatter.areaValue(v, units), 2) }
        var rows: [[String]] = [["Measurement", "Value", "Unit", "Display", "Metric value", "Metric unit"]]
        rows.append(["Scan", title, "", "", "", ""])
        rows.append(["Width (X, longest side)", len(m.width), lengthUnit, display(m.width),
                     UnitFormatter.decimal(m.width, object ? 4 : 3), "m"])
        rows.append(["Depth (Z)", len(m.depth), lengthUnit, display(m.depth),
                     UnitFormatter.decimal(m.depth, object ? 4 : 3), "m"])
        rows.append([object ? "Height (Y, from the surface it stands on)" : "Height (Y)", len(m.height), lengthUnit, display(m.height),
                     UnitFormatter.decimal(m.height, object ? 4 : 3), "m"])
        rows.append(["Bounding box footprint", area(m.width * m.depth), areaUnit, UnitFormatter.area(m.width * m.depth, units),
                     UnitFormatter.decimal(m.width * m.depth, 3), "m²"])
        rows.append(["Scanned surface area (all)", area(m.surfaceArea), areaUnit, UnitFormatter.area(m.surfaceArea, units),
                     UnitFormatter.decimal(m.surfaceArea, 3), "m²"])
        for cls in MeshClass.exportOrder {
            let stat = m.classes.first { $0.classification == cls }
            let a = stat?.area ?? 0
            rows.append(["Surface area: \(cls.name)", area(a), areaUnit, UnitFormatter.area(a, units),
                         UnitFormatter.decimal(a, 3), "m²"])
        }
        rows.append(["Triangles", "\(m.triangleCount)", "count", "\(m.triangleCount)", "\(m.triangleCount)", "count"])
        rows.append(["Vertices", "\(m.vertexCount)", "count", "\(m.vertexCount)", "\(m.vertexCount)", "count"])
        for cls in MeshClass.exportOrder {
            let t = m.triangles(of: cls)
            rows.append(["Triangles: \(cls.name)", "\(t)", "count", "\(t)", "\(t)", "count"])
        }
        rows.append(["Alignment yaw", UnitFormatter.decimal(m.alignmentYawDegrees, 2), "deg", "", "", ""])
        rows.append(["Note", object
                     ? "Object Detail scan: LiDAR depth fused inside a fitted box, table removed. Size is the object's box turned square to its footprint (gravity up), ignoring the 0.1 % most extreme surface points. LiDAR resolves about 2-5 mm; verify critical dimensions with a tape."
                     : "LiDAR mesh bounding box (gravity up). Areas are scanned surface, not net finished area. Verify on site.",
                     "", "", "", ""])
        return rows.map { $0.map(CSVWriter.escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}
