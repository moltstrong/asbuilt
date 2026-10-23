import Foundation
import Testing
@testable import AsBuiltCore

private let ft = UnitFormatter.meters(feet:)

/// Unit cube (1 m) as an indexed mesh: 8 shared vertices, 12 triangles, counter-clockwise outside.
private func cubeMesh(size: Float = 1) -> USDIndexedMesh {
    let s = size
    let p: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(s, 0, 0), SIMD3(s, s, 0), SIMD3(0, s, 0),
        SIMD3(0, 0, s), SIMD3(s, 0, s), SIMD3(s, s, s), SIMD3(0, s, s),
    ]
    let f: [UInt32] = [
        0, 2, 1, 0, 3, 2, // back (-z)
        4, 5, 6, 4, 6, 7, // front (+z)
        0, 1, 5, 0, 5, 4, // bottom
        3, 7, 6, 3, 6, 2, // top
        0, 4, 7, 0, 7, 3, // left
        1, 2, 6, 1, 6, 5, // right
    ]
    return USDIndexedMesh(name: "Cube", materialName: "Other", positions: p, indices: f)
}

/// Parses OBJ text: counts and faces (as 1-based vertex indices).
private struct ParsedOBJ {
    var vertices = 0
    var normals = 0
    var faces: [[Int]] = []
    var faceNormals: [[Int]] = []
    var usemtl: [String] = []
    var groups: [String] = []
    var mtllib: String?

    init(_ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ")
            guard let head = parts.first else { continue }
            switch head {
            case "v": vertices += 1
            case "vn": normals += 1
            case "f":
                faces.append(parts.dropFirst().map { Int($0.split(separator: "/", omittingEmptySubsequences: false)[0])! })
                faceNormals.append(parts.dropFirst().compactMap { token in
                    let pieces = token.split(separator: "/", omittingEmptySubsequences: false)
                    return pieces.count == 3 ? Int(pieces[2]) : nil
                })
            case "usemtl": usemtl.append(String(parts[1]))
            case "g": groups.append(String(parts[1]))
            case "mtllib": mtllib = String(parts[1])
            default: break
            }
        }
    }
}

/// Two anchors: a floor quad (identity) and a wall quad with a transform; one degenerate face,
/// one out-of-range face, one face with a classification value ARKit may add later (99).
private func twoAnchorScan() -> [MeshAnchorInput] {
    let floor = MeshAnchorInput(
        vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, -1), SIMD3(0, 0, -1)],
        normals: Array(repeating: SIMD3(0, 1, 0), count: 4),
        // Second face is wound clockwise (normal -Y) on purpose: the builder must flip it.
        faces: [0, 1, 2, 0, 3, 2, 0, 0, 1, 0, 1, 9],
        classifications: [2, 2, 2, 2])
    let wall = MeshAnchorInput(
        transform: MeshAnchorInput.transform(yawRadians: .pi / 2, translation: SIMD3(5, 0, 0)),
        vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
        normals: Array(repeating: SIMD3(0, 0, 1), count: 4),
        faces: [0, 1, 2, 0, 2, 3],
        classifications: [1, 99])
    return [floor, wall]
}

@Suite("LiDAR mesh")
struct LiDARMeshTests {
    @Test func classificationGroupingAndWorldTransform() throws {
        var progress: [Double] = []
        let mesh = ClassifiedMeshBuilder.build(twoAnchorScan()) { progress.append($0) }
        #expect(progress.count == 2 && progress.last == 1)
        #expect(mesh.vertexCount == 8)
        #expect(mesh.triangleCount == 4) // 2 floor + 1 wall + 1 "other"; degenerate + out-of-range dropped
        #expect(mesh.triangleCount(of: .floor) == 2)
        #expect(mesh.triangleCount(of: .wall) == 1)
        #expect(mesh.triangleCount(of: .none) == 1) // unknown classification 99 -> none
        #expect(mesh.groups.map(\.classification) == [.floor, .wall, .none]) // export order
        // Wall vertex (1, 0, 0) turned 90 degrees about +Y lands at (0, 0, -1), then moved by (5, 0, 0).
        let p = mesh.positions[5]
        #expect(abs(p.x - 5) < 1e-5 && abs(p.y) < 1e-5 && abs(p.z + 1) < 1e-5)
        // Normal (0, 0, 1) turned 90 degrees -> (1, 0, 0).
        let n = mesh.normals[4]
        #expect(abs(n.x - 1) < 1e-5 && abs(n.z) < 1e-5)
        // Every floor face winds counter-clockwise seen from its normal side (+Y).
        let floor = try #require(mesh.groups.first { $0.classification == .floor })
        for f in stride(from: 0, to: floor.indices.count, by: 3) {
            let a = mesh.positions[Int(floor.indices[f])]
            let b = mesh.positions[Int(floor.indices[f + 1])]
            let c = mesh.positions[Int(floor.indices[f + 2])]
            #expect(ClassifiedMeshBuilder.cross(b - a, c - a).y > 0)
        }
    }

    @Test func missingClassificationAndNormalsAreHandled() {
        let anchor = MeshAnchorInput(vertices: [SIMD3(0, 0, 0), SIMD3(0, 0, -1), SIMD3(1, 0, 0)], faces: [0, 2, 1])
        let mesh = ClassifiedMeshBuilder.build([anchor])
        #expect(mesh.groups.map(\.classification) == [.none])
        // Computed normal from the face as given: (1,0,0) x (0,0,-1) = +Y.
        #expect(abs(mesh.normals[0].y - 1) < 1e-5)
        #expect(MeshClass(arkitValue: 7) == .door)
        #expect(MeshClass(arkitValue: -3) == .none)
        #expect(MeshClass(arkitValue: 300) == .none)
        #expect(MeshClass.allCases.count == 8)
    }

    @Test func byteBufferNumbersMatchUSDAFormatting() {
        let values: [Double] = [0, -0.0, 1, -1, 0.5, 0.05, 0.000001, -0.0000004, 12.000001, 3.14159265, -2.5e-3,
                                1234567.25, 0.1 + 0.2, 1e-7, 99.9999996, -0.0000005, .nan, .infinity]
        for v in values {
            var b = ByteBuffer()
            b.append(fixed: v, decimals: 6)
            #expect(b.string == USDAWriter.num(v), "\(v): \(b.string) vs \(USDAWriter.num(v))")
        }
        var b = ByteBuffer()
        b.append(int: -120)
        b.append(" ")
        b.append(uint: 4_000_000_000)
        b.append(" ")
        b.append(fixed: 0.0123, decimals: 3)
        #expect(b.string == "-120 4000000000 0.012")
    }

    @Test func objWriterRoundTrip() throws {
        let mesh = ClassifiedMeshBuilder.build(twoAnchorScan())
        let (objData, mtlData) = OBJWriter.write(mesh: mesh, name: "Test scan")
        let obj = ParsedOBJ(String(decoding: objData, as: UTF8.self))
        #expect(obj.mtllib == "mesh.mtl")
        #expect(obj.vertices == mesh.vertexCount)
        #expect(obj.normals == mesh.vertexCount)
        #expect(obj.faces.count == mesh.triangleCount)
        #expect(obj.usemtl == ["Floor", "Wall", "Other"])
        #expect(obj.groups == obj.usemtl)
        for (face, normals) in zip(obj.faces, obj.faceNormals) {
            #expect(face.count == 3)
            #expect(face.allSatisfy { $0 >= 1 && $0 <= obj.vertices }) // 1-based and in range
            #expect(normals == face)
        }
        // The first floor face is mesh index (0, 1, 2) -> OBJ "f 1//1 2//2 3//3".
        #expect(obj.faces.first == [1, 2, 3])
        let mtl = String(decoding: mtlData, as: UTF8.self)
        for cls in MeshClass.allCases { #expect(mtl.contains("newmtl \(cls.name)\n")) }
        #expect(mtl.contains("Kd "))
    }

    @Test func plyHeaderAndLayout() throws {
        let mesh = ClassifiedMeshBuilder.build(twoAnchorScan())
        let data = PLYWriter.write(mesh: mesh, name: "Test")
        let headerEnd = try #require(data.range(of: Data("end_header\n".utf8)))
        let header = String(decoding: data[..<headerEnd.upperBound], as: UTF8.self)
        #expect(header.hasPrefix("ply\nformat binary_little_endian 1.0\n"))
        #expect(header.contains("element vertex \(mesh.vertexCount)\n"))
        #expect(header.contains("element face \(mesh.triangleCount)\n"))
        #expect(header.contains("property list uchar uint vertex_indices\n"))
        let body = data.count - headerEnd.upperBound
        #expect(body == mesh.vertexCount * PLYWriter.vertexRecordSize + mesh.triangleCount * PLYWriter.faceRecordSize)
        // First vertex x/y/z as little-endian floats.
        let start = headerEnd.upperBound
        func float(at offset: Int) -> Float {
            let raw = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[start + offset + $1]) << (8 * $1) }
            return Float(bitPattern: raw)
        }
        #expect(float(at: 0) == mesh.positions[0].x && float(at: 8) == mesh.positions[0].z)
        // First face record: count 3, then indices.
        let faceStart = start + mesh.vertexCount * PLYWriter.vertexRecordSize
        #expect(data[faceStart] == 3)
    }

    @Test func usdaIndexedMeshStructure() throws {
        let cube = cubeMesh()
        let materials = MeshClass.exportOrder.map(\.usdMaterial)
        let text = String(decoding: USDAWriter.write(indexedMeshes: [cube], materials: materials, doc: "cube"), as: UTF8.self)
        #expect(text.hasPrefix("#usda 1.0\n"))
        #expect(text.contains("defaultPrim = \"Scan\""))
        #expect(text.contains("def Mesh \"Cube\""))
        #expect(text.contains("rel material:binding = </Scan/Materials/Other>"))
        #expect(text.contains("def Material \"Other\""))
        #expect(text.contains("float3[] extent = [(0, 0, 0), (1, 1, 1)]"))
        let counts = try #require(text.components(separatedBy: "int[] faceVertexCounts = [").last?.components(separatedBy: "]").first)
        #expect(counts.split(separator: ",").count == 12)
        let indices = try #require(text.components(separatedBy: "int[] faceVertexIndices = [").last?.components(separatedBy: "]").first)
        let parsed = indices.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces))! }
        #expect(parsed == cube.indices.map(Int.init))
        #expect(!text.contains("normal3f[]")) // no normals given

        // Classified mesh: one prim + material per class, usdz root layer first and 64-byte aligned.
        let scan = DemoMeshScan.bedroomMesh()
        let usdz = USDZPackager.meshModel(scan.mesh, name: "Demo")
        let nameLength = Int(usdz[26]) | Int(usdz[27]) << 8
        let extraLength = Int(usdz[28]) | Int(usdz[29]) << 8
        #expect((30 + nameLength + extraLength) % 64 == 0)
        #expect(String(decoding: usdz[30..<(30 + nameLength)], as: UTF8.self) == "model.usda")
        let layer = String(decoding: USDAWriter.write(classifiedMesh: scan.mesh, name: "Demo"), as: UTF8.self)
        for cls in MeshClass.exportOrder {
            #expect(layer.contains("def Mesh \"\(cls.name)\""), "missing \(cls.name)")
            #expect(layer.contains("rel material:binding = </Scan/Materials/\(cls.name)>"))
        }
    }

    @Test func boundsAndDimensionsOfATurnedBox() throws {
        // A 3 m x 1 m x 2 m box turned 30 degrees about +Y and moved: alignment must recover 3 x 1 x 2.
        var anchors: [MeshAnchorInput] = []
        let corners: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(3, 0, 0), SIMD3(3, 0, 1), SIMD3(0, 0, 1),
                                       SIMD3(0, 2, 0), SIMD3(3, 2, 0), SIMD3(3, 2, 1), SIMD3(0, 2, 1)]
        let faces: [UInt32] = [0, 1, 5, 0, 5, 4, 1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6, 3, 0, 4, 3, 4, 7, 4, 5, 6, 4, 6, 7, 0, 2, 1, 0, 3, 2]
        anchors.append(MeshAnchorInput(transform: MeshAnchorInput.transform(yawRadians: .pi / 6, translation: SIMD3(2, 0.5, -4)),
                                       vertices: corners, faces: faces, classifications: Array(repeating: 4, count: 12)))
        let raw = ClassifiedMeshBuilder.build(anchors)
        let rawBounds = try #require(raw.bounds)
        #expect(rawBounds.max.x - rawBounds.min.x > 3.0) // turned: axis-aligned box is bigger
        let prepared = MeshNormalizer.prepareForExport(raw)
        let m = prepared.measurements
        #expect(abs(m.width - 3) < 1e-3 && abs(m.depth - 1) < 1e-3 && abs(m.height - 2) < 1e-4)
        #expect(m.triangleCount == 12 && m.vertexCount == 8)
        #expect(abs(m.surfaceArea - 22) < 1e-3) // 2(3*1 + 3*2 + 1*2)
        #expect(abs(m.area(of: .table) - 22) < 1e-3)
        let b = try #require(prepared.mesh.bounds)
        #expect(abs(b.min.y) < 1e-6) // sits on y = 0
        #expect(abs(b.min.x + b.max.x) < 1e-4 && abs(b.min.z + b.max.z) < 1e-4) // centered
        #expect(m.dimensionsText(.metric) == "3.00 m × 1.00 m × 2.00 m")
        #expect(m.dimensionsText(.imperial) == "9' 10\" × 3' 3\" × 6' 7\"")

        let csv = MeshMeasurementsCSV.write(m, title: "Box", units: .imperial)
        let rows = CSVWriter.parse(csv)
        #expect(rows.first == ["Measurement", "Value", "Unit", "Display", "Metric value", "Metric unit"])
        let width = try #require(rows.first { $0.first == "Width (X, longest side)" })
        #expect(width[1] == "9.84" && width[2] == "ft" && width[4] == "3.000")
        #expect(rows.contains { $0.first == "Triangles: Table" && $0[1] == "12" })
    }

    @Test func demoScanMatchesTheBedroom() throws {
        let anchors = DemoMeshScan.bedroomAnchors()
        #expect(anchors.count >= 10)
        let raw = ClassifiedMeshBuilder.build(anchors)
        #expect(Set(raw.groups.map(\.classification)) == Set(MeshClass.allCases))
        let scan = MeshNormalizer.prepareForExport(raw)
        let m = scan.measurements
        // 12' x 14' room, 8' ceiling; turned 23 degrees in "ARKit world": alignment puts 14' along X.
        #expect(abs(m.width - ft(14)) < 0.012, "width \(m.width)")
        #expect(abs(m.depth - ft(12)) < 0.012, "depth \(m.depth)")
        #expect(abs(m.height - ft(8)) < 0.012, "height \(m.height)")
        #expect(m.triangleCount > 15_000)
        #expect(m.area(of: .floor) > ft(12) * ft(14) * 0.98)
        #expect(m.area(of: .door) > 1.5 && m.area(of: .window) > 2.5)
    }

    @Test func writeMeshExportsWhenRequested() throws {
        guard let dir = ProcessInfo.processInfo.environment["ASBUILT_EXPORT_DIR"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("mesh", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let materials = MeshClass.exportOrder.map(\.usdMaterial)
        let cube = USDAWriter.write(indexedMeshes: [cubeMesh()], materials: materials, doc: "AsBuilt test cube")
        try cube.write(to: url.appendingPathComponent("cube.usda"))
        try USDZPackager.package(rootLayer: cube).write(to: url.appendingPathComponent("cube.usdz"))
        let output = LiDARMeshExporter.export(DemoMeshScan.bedroomMesh(), title: "Demo LiDAR scan", units: .imperial)
        for file in output.files {
            let name = file.name == LiDARMeshExporter.usdzName ? "demo-mesh.usdz" : "demo-" + file.name
            try file.data.write(to: url.appendingPathComponent(name))
        }
        try USDAWriter.write(classifiedMesh: DemoMeshScan.bedroomMesh().mesh, name: "Demo")
            .write(to: url.appendingPathComponent("demo-mesh.usda"))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("demo-mesh.usdz").path))
    }

    @Test func exportPerformance200kTriangles() throws {
        let anchors = DemoMeshScan.syntheticAnchors(triangles: 200_000)
        let clock = ContinuousClock()
        var output: LiDARMeshExporter.Output?
        let elapsed = clock.measure {
            let mesh = ClassifiedMeshBuilder.build(anchors)
            output = LiDARMeshExporter.export(MeshNormalizer.prepareForExport(mesh), title: "Perf", units: .metric)
        }
        let out = try #require(output)
        #expect(out.measurements.triangleCount >= 199_000)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        #if DEBUG
        let limit = 30.0
        #else
        let limit = 3.0
        #endif
        print("LiDAR export perf: \(out.measurements.triangleCount) triangles, \(out.measurements.vertexCount) vertices in \(String(format: "%.2f", seconds)) s (limit \(limit) s); USDZ \(out.files[0].data.count / 1024) KB")
        #expect(seconds < limit)
    }
}

@Suite("Reconstruction errors")
struct ReconstructionErrorTests {
    @Test func decodesPhotogrammetryError6() {
        #expect(ReconstructionErrorExplainer.caseName(domain: "CoreOC.PhotogrammetrySession.Error", code: 6) == "processError")
        #expect(ReconstructionErrorExplainer.caseName(domain: "CoreOC.PhotogrammetrySession.Error", code: 0) == "reconstructionError")
        #expect(ReconstructionErrorExplainer.caseName(domain: "CoreOC.PhotogrammetrySession.Error", code: 7) == "storageFull")
        #expect(ReconstructionErrorExplainer.caseName(domain: "CoreOC.PhotogrammetrySession.Error", code: 8) == nil)
        #expect(ReconstructionErrorExplainer.caseName(domain: "RealityFoundation.PhotogrammetrySession.Error", code: 2) == "insufficientStorage")
        #expect(ReconstructionErrorExplainer.caseName(domain: "_RealityKit_SwiftUI.ObjectCaptureSession.Error", code: 4) == "trackingFailed")

        let e = ReconstructionErrorExplainer.explain(domain: "CoreOC.PhotogrammetrySession.Error", code: 6, imageCount: 64)
        #expect(e.kind == .alignment)
        #expect(e.message == ReconstructionErrorExplainer.alignmentAdvice)
        #expect(e.technical == "CoreOC.PhotogrammetrySession.Error.processError (code 6)")
        #expect(!e.message.contains("CoreOC") && !e.message.contains("error 6"))

        let few = ReconstructionErrorExplainer.explain(domain: "CoreOC.PhotogrammetrySession.Error", code: 6, imageCount: 12)
        #expect(few.kind == .tooFewImages)
        #expect(few.message.contains("Only 12 photos"))

        let storage = ReconstructionErrorExplainer.explain(domain: "CoreOC.PhotogrammetrySession.Error", code: 7)
        #expect(storage.kind == .storage)
        let unknown = ReconstructionErrorExplainer.explain(domain: "Some.Other", code: 3, imageCount: 80)
        #expect(unknown.kind == .unknown && unknown.technical == "Some.Other (code 3)")
        let sfm = ReconstructionErrorExplainer.explain(domain: "Some.Other", code: 4004, description: "No SfM map found")
        #expect(sfm.kind == .alignment)
    }

    /// Verifies the NSError code rule the tables rely on: payload cases first, then no-payload cases.
    @Test func swiftErrorCodeRule() {
        enum Probe: Error { case a, b, withPayload(Int), c, alsoPayload(String), d }
        let codes = ([Probe.a, .b, .withPayload(1), .c, .alsoPayload("x"), .d] as [Probe]).map { ($0 as NSError).code }
        #expect(codes == [2, 3, 0, 4, 1, 5])
    }

    @Test func retryChain() {
        let chain = ReconstructionAttempt.chain
        #expect(chain.count == 3)
        #expect(chain[0].useCheckpoint && chain[0].objectMasking)
        #expect(!chain[1].useCheckpoint && chain[1].sampleOrdering == .sequential && chain[1].featureSensitivity == .high && chain[1].objectMasking)
        #expect(!chain[2].objectMasking && chain[2].sampleOrdering == .sequential)
        #expect(Set(chain.map(\.outputFileName)).count == 3)
        var log = ReconstructionLog(header: ["AsBuilt reconstruction log"])
        log.section("Attempt 1")
        log.add(chain[0].summary)
        #expect(log.text.contains("== Attempt 1\ncheckpoint=on sampleOrdering=.unordered featureSensitivity=.normal isObjectMaskingEnabled=true\n"))
    }
}
