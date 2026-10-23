import Foundation

/// Per-face surface class of a LiDAR scene mesh. Raw values match `ARMeshClassification`
/// (none = 0, wall, floor, ceiling, table, seat, window, door), so ARKit's per-face classification
/// bytes map straight onto this enum.
public enum MeshClass: UInt8, CaseIterable, Codable, Sendable {
    case none = 0
    case wall = 1
    case floor = 2
    case ceiling = 3
    case table = 4
    case seat = 5
    case window = 6
    case door = 7

    /// ARKit classification value to class; unknown future values fall back to `.none`.
    public init(arkitValue: Int) {
        self = MeshClass(rawValue: UInt8(clamping: max(0, arkitValue))) ?? .none
    }

    /// Group / material / prim name used in every export ("Wall", "Floor", ... "Other").
    public var name: String {
        switch self {
        case .none: return "Other"
        case .wall: return "Wall"
        case .floor: return "Floor"
        case .ceiling: return "Ceiling"
        case .table: return "Table"
        case .seat: return "Seat"
        case .window: return "Window"
        case .door: return "Door"
        }
    }

    /// Plain display color (sRGB-ish 0...1). "Other" (unclassified: equipment, MEP, objects) is
    /// the brand orange so scanned objects stand out from the room shell.
    public var color: (r: Double, g: Double, b: Double) {
        switch self {
        case .none: return (0.93, 0.52, 0.18)
        case .wall: return (0.85, 0.85, 0.83)
        case .floor: return (0.70, 0.56, 0.40)
        case .ceiling: return (0.96, 0.96, 0.94)
        case .table: return (0.29, 0.53, 0.84)
        case .seat: return (0.33, 0.68, 0.44)
        case .window: return (0.56, 0.80, 0.95)
        case .door: return (0.62, 0.40, 0.22)
        }
    }

    /// Export order: room shell first, then furnishings, then everything else.
    public static let exportOrder: [MeshClass] = [.floor, .wall, .ceiling, .door, .window, .table, .seat, .none]
}

/// One combined, indexed triangle mesh in world space (meters, +Y up), with per-vertex normals and
/// the faces grouped by `MeshClass`. Vertices are shared between groups; each group indexes into
/// the shared `positions`/`normals` arrays.
public struct ClassifiedMesh: Sendable {
    public struct Group: Sendable, Hashable {
        public var classification: MeshClass
        /// Triangle list, three indices per face into `ClassifiedMesh.positions`.
        public var indices: [UInt32]

        public init(classification: MeshClass, indices: [UInt32]) {
            self.classification = classification
            self.indices = indices
        }

        public var triangleCount: Int { indices.count / 3 }
    }

    public var positions: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    /// Non-empty groups in `MeshClass.exportOrder`.
    public var groups: [Group]
    /// Optional per-vertex sRGB colors (same count as `positions`), e.g. from TSDF depth fusion.
    /// Empty = color by surface class.
    public var colors: [SIMD3<UInt8>]

    public init(positions: [SIMD3<Float>], normals: [SIMD3<Float>], groups: [Group], colors: [SIMD3<UInt8>] = []) {
        self.positions = positions
        self.normals = normals
        self.groups = groups
        self.colors = colors
    }

    /// True when every vertex has a color.
    public var hasVertexColors: Bool { !colors.isEmpty && colors.count == positions.count }

    public var vertexCount: Int { positions.count }
    public var triangleCount: Int { groups.reduce(0) { $0 + $1.triangleCount } }

    public func triangleCount(of classification: MeshClass) -> Int {
        groups.filter { $0.classification == classification }.reduce(0) { $0 + $1.triangleCount }
    }

    /// Axis-aligned bounds of the vertices actually used by a face.
    public var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var any = false
        for group in groups {
            for index in group.indices {
                let p = positions[Int(index)]
                lo = pointwiseMin(lo, p)
                hi = pointwiseMax(hi, p)
                any = true
            }
        }
        return any ? (lo, hi) : nil
    }

    /// One compact, self-contained part of a `ClassifiedMesh` (see `compactParts()`).
    public struct Part: Sendable {
        public var classification: MeshClass
        public var positions: [SIMD3<Float>]
        public var normals: [SIMD3<Float>]
        /// Per-vertex colors, or empty.
        public var colors: [SIMD3<UInt8>]
        public var indices: [UInt32]
    }

    /// Splits the shared vertex pool into one compact, self-contained part per group (only the
    /// vertices each group uses, re-indexed from 0). Used by writers that want one mesh prim per class.
    public func compactParts() -> [Part] {
        var remap = [Int32](repeating: -1, count: positions.count)
        var result: [Part] = []
        let hasNormals = normals.count == positions.count
        let hasColors = hasVertexColors
        for group in groups where !group.indices.isEmpty {
            var pts: [SIMD3<Float>] = []
            var nrm: [SIMD3<Float>] = []
            var col: [SIMD3<UInt8>] = []
            var idx: [UInt32] = []
            var touched: [Int] = []
            pts.reserveCapacity(group.indices.count / 2)
            nrm.reserveCapacity(group.indices.count / 2)
            idx.reserveCapacity(group.indices.count)
            for index in group.indices {
                let v = Int(index)
                var r = remap[v]
                if r < 0 {
                    r = Int32(pts.count)
                    remap[v] = r
                    pts.append(positions[v])
                    if hasNormals { nrm.append(normals[v]) }
                    if hasColors { col.append(colors[v]) }
                    touched.append(v)
                }
                idx.append(UInt32(r))
            }
            for v in touched { remap[v] = -1 }
            result.append(Part(classification: group.classification, positions: pts, normals: nrm, colors: col, indices: idx))
        }
        return result
    }
}

/// Raw mesh data of one ARKit `ARMeshAnchor`, copied out of its Metal buffers (so the processing
/// below is pure Swift, testable on macOS and safe off the main thread).
public struct MeshAnchorInput: Sendable {
    /// `anchor.transform` columns (column-major, like `simd_float4x4`).
    public var transform: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    /// Anchor-local vertex positions.
    public var vertices: [SIMD3<Float>]
    /// Anchor-local vertex normals (may be empty: normals are then computed from the faces).
    public var normals: [SIMD3<Float>]
    /// Triangle list in anchor-local vertex indices (three per face).
    public var faces: [UInt32]
    /// One ARMeshClassification value per face (empty when the session had no classification).
    public var classifications: [UInt8]

    public init(transform: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = MeshAnchorInput.identity,
                vertices: [SIMD3<Float>], normals: [SIMD3<Float>] = [], faces: [UInt32], classifications: [UInt8] = []) {
        self.transform = transform
        self.vertices = vertices
        self.normals = normals
        self.faces = faces
        self.classifications = classifications
    }

    public static let identity = (SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0), SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(0, 0, 0, 1))

    /// A rigid transform: rotation about +Y by `yawRadians`, then translation.
    public static func transform(yawRadians: Float, translation: SIMD3<Float>) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        let c = cos(yawRadians)
        let s = sin(yawRadians)
        return (SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(translation.x, translation.y, translation.z, 1))
    }

    public var faceCount: Int { faces.count / 3 }
}

/// Combines ARKit mesh anchors into one world-space `ClassifiedMesh`.
public enum ClassifiedMeshBuilder {
    /// - Vertices go to world space with `anchor.transform`; normals with its rotation part.
    /// - Faces are grouped by their classification byte (missing/unknown = `.none`).
    /// - Out-of-range and degenerate (zero-area) faces are dropped.
    /// - Face winding is made consistent with the vertex normals (counter-clockwise front faces).
    /// - `progress` gets 0...1 after each anchor.
    public static func build(_ anchors: [MeshAnchorInput], progress: ((Double) -> Void)? = nil) -> ClassifiedMesh {
        let totalVertices = anchors.reduce(0) { $0 + $1.vertices.count }
        let totalFaces = max(1, anchors.reduce(0) { $0 + $1.faceCount })
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        positions.reserveCapacity(totalVertices)
        normals.reserveCapacity(totalVertices)
        var buckets = [[UInt32]](repeating: [], count: MeshClass.allCases.count)
        var facesDone = 0

        for anchor in anchors {
            let (c0, c1, c2, c3) = anchor.transform
            let r0 = SIMD3(c0.x, c0.y, c0.z)
            let r1 = SIMD3(c1.x, c1.y, c1.z)
            let r2 = SIMD3(c2.x, c2.y, c2.z)
            let t = SIMD3(c3.x, c3.y, c3.z)
            let base = positions.count
            let count = anchor.vertices.count
            for v in anchor.vertices {
                positions.append(r0 * v.x + r1 * v.y + r2 * v.z + t)
            }
            let hasNormals = anchor.normals.count == count
            if hasNormals {
                for n in anchor.normals {
                    normals.append(normalizedOrUp(r0 * n.x + r1 * n.y + r2 * n.z))
                }
            } else {
                normals.append(contentsOf: repeatElement(SIMD3<Float>(0, 0, 0), count: count))
            }

            let faceCount = anchor.faceCount
            let faces = anchor.faces
            let classes = anchor.classifications
            for f in 0..<faceCount {
                let a = Int(faces[3 * f])
                var b = Int(faces[3 * f + 1])
                var c = Int(faces[3 * f + 2])
                guard a < count, b < count, c < count, a != b, b != c, a != c else { continue }
                let pa = positions[base + a]
                let pb = positions[base + b]
                let pc = positions[base + c]
                let g = cross(pb - pa, pc - pa)
                let area2 = (g * g).sum()
                guard area2 > 1e-14, area2.isFinite else { continue }
                if hasNormals {
                    let avg = normals[base + a] + normals[base + b] + normals[base + c]
                    if (g * avg).sum() < 0 { swap(&b, &c) }
                } else {
                    // Area-weighted vertex normals from the faces as given.
                    normals[base + a] += g
                    normals[base + b] += g
                    normals[base + c] += g
                }
                let cls = f < classes.count ? MeshClass(arkitValue: Int(classes[f])) : .none
                let slot = Int(cls.rawValue)
                buckets[slot].append(UInt32(base + a))
                buckets[slot].append(UInt32(base + b))
                buckets[slot].append(UInt32(base + c))
            }
            if !hasNormals {
                for i in base..<(base + count) { normals[i] = normalizedOrUp(normals[i]) }
            }
            facesDone += faceCount
            progress?(Double(facesDone) / Double(totalFaces))
        }

        let groups = MeshClass.exportOrder.compactMap { cls -> ClassifiedMesh.Group? in
            let indices = buckets[Int(cls.rawValue)]
            return indices.isEmpty ? nil : ClassifiedMesh.Group(classification: cls, indices: indices)
        }
        return ClassifiedMesh(positions: positions, normals: normals, groups: groups)
    }

    @inline(__always)
    public static func cross(_ u: SIMD3<Float>, _ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
    }

    @inline(__always)
    static func normalizedOrUp(_ n: SIMD3<Float>) -> SIMD3<Float> {
        let l = (n * n).sum().squareRoot()
        return l > 1e-12 && l.isFinite ? n / l : SIMD3(0, 1, 0)
    }
}
