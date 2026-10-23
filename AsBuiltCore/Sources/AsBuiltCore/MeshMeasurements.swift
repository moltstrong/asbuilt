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

    /// Measures `mesh` as is (no re-orientation): axis-aligned box of the used vertices.
    public static func measure(_ mesh: ClassifiedMesh, alignmentYawDegrees: Double = 0) -> MeshMeasurements {
        let b = mesh.bounds
        let size = b.map { SIMD3<Double>(Double($0.max.x - $0.min.x), Double($0.max.y - $0.min.y), Double($0.max.z - $0.min.z)) }
            ?? SIMD3<Double>(0, 0, 0)
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

    public static func prepareForExport(_ input: ClassifiedMesh) -> Result {
        let mesh = removingUnusedVertices(input)
        guard mesh.triangleCount > 0 else {
            return Result(mesh: mesh, measurements: .measure(mesh), yawRadians: 0)
        }
        let footprint = mesh.positions.map { Point2D(Double($0.x), Double($0.z)) }
        let yaw = alignmentYaw(footprint)
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
        let shift = SIMD3<Float>((lo.x + hi.x) / 2, lo.y, (lo.z + hi.z) / 2)
        for i in positions.indices { positions[i] -= shift }
        let out = ClassifiedMesh(positions: positions, normals: normals, groups: mesh.groups, colors: mesh.colors)
        var degrees = yaw * 180 / .pi
        if abs(degrees) < 1e-9 { degrees = 0 }
        return Result(mesh: out, measurements: .measure(out, alignmentYawDegrees: degrees), yawRadians: yaw)
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
    public static func alignmentYaw(_ points: [Point2D]) -> Double {
        // Quantize to 5 mm and dedupe first: big scans have ~10^5 vertices.
        var seen = Set<Point2D>()
        seen.reserveCapacity(points.count / 4)
        for p in points where p.x.isFinite && p.y.isFinite {
            seen.insert(Point2D((p.x * 200).rounded() / 200, (p.y * 200).rounded() / 200))
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
    public static func write(_ m: MeshMeasurements, title: String, units: UnitSystem) -> String {
        let lengthUnit = units == .imperial ? "ft" : "m"
        let areaUnit = units == .imperial ? "sq ft" : "m²"
        func len(_ v: Double) -> String { UnitFormatter.decimal(UnitFormatter.lengthValue(v, units), units == .imperial ? 2 : 3) }
        func area(_ v: Double) -> String { UnitFormatter.decimal(UnitFormatter.areaValue(v, units), 2) }
        var rows: [[String]] = [["Measurement", "Value", "Unit", "Display", "Metric value", "Metric unit"]]
        rows.append(["Scan", title, "", "", "", ""])
        rows.append(["Width (X, longest side)", len(m.width), lengthUnit, UnitFormatter.length(m.width, units),
                     UnitFormatter.decimal(m.width, 3), "m"])
        rows.append(["Depth (Z)", len(m.depth), lengthUnit, UnitFormatter.length(m.depth, units),
                     UnitFormatter.decimal(m.depth, 3), "m"])
        rows.append(["Height (Y)", len(m.height), lengthUnit, UnitFormatter.length(m.height, units),
                     UnitFormatter.decimal(m.height, 3), "m"])
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
        rows.append(["Note", "LiDAR mesh bounding box (gravity up). Areas are scanned surface, not net finished area. Verify on site.",
                     "", "", "", ""])
        return rows.map { $0.map(CSVWriter.escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}
