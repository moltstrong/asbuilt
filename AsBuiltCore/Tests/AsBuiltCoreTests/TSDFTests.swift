import Foundation
import Testing
import simd
@testable import AsBuiltCore

/// ARKit-like depth intrinsics: 1920x1440 captured image scaled to the 256x192 LiDAR depth map.
private let arkitFull = PinholeIntrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440)
private let depthK = arkitFull.scaled(toWidth: 256, height: 192)

private func rms(_ values: [Float]) -> Float {
    guard !values.isEmpty else { return .infinity }
    return (values.reduce(0) { $0 + $1 * $1 } / Float(values.count)).squareRoot()
}

private func percentile(_ values: [Float], _ p: Double) -> Float {
    let sorted = values.map(abs).sorted()
    guard !sorted.isEmpty else { return .infinity }
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

/// Fuses `scene` from `poses` (optionally noisy) into a fresh volume.
private func fuse(_ scene: AnalyticScene, poses: [simd_float4x4], config: TSDFVolume.Configuration,
                  noise: Float = 0, withColor: Bool = false,
                  bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? = nil) -> TSDFVolume {
    let volume = TSDFVolume(configuration: config)
    for (k, pose) in poses.enumerated() {
        let r = scene.render(intrinsics: depthK, cameraToWorld: pose, maxDistance: 3, noise: noise, seed: UInt64(k + 7),
                             withColor: withColor)
        let color = withColor ? ColorImage(width: depthK.width, height: depthK.height, rgb: r.rgb, intrinsics: depthK) : nil
        volume.integrate(DepthFrame(width: depthK.width, height: depthK.height, depth: r.depth, intrinsics: depthK,
                                    cameraToWorld: pose, color: color), bounds: bounds)
    }
    return volume
}

@Suite("TSDF depth fusion")
struct TSDFFusionTests {
    // MARK: Conventions

    @Test func intrinsicsScaleFromCapturedImageToDepthMap() {
        #expect(abs(depthK.fx - 1450 * 256 / 1920) < 1e-3)
        #expect(abs(depthK.fy - 1450 * 192 / 1440) < 1e-3)
        #expect(abs(depthK.cx - 128) < 1e-4 && abs(depthK.cy - 96) < 1e-4)
        #expect(depthK.width == 256 && depthK.height == 192)

        // ARKit's column-major intrinsics matrix.
        let m = simd_float3x3(SIMD3(1450, 0, 0), SIMD3(0, 1450, 0), SIMD3(960, 720, 1))
        #expect(PinholeIntrinsics(arkit: m, imageWidth: 1920, imageHeight: 1440) == arkitFull)

        // A camera-space point projects to proportionally scaled pixel coordinates in both images.
        let p = SIMD3<Float>(0.12, -0.05, -0.9)
        let full = arkitFull.project(p)!
        let small = depthK.project(p)!
        #expect(abs(small.x - full.x * 256 / 1920) < 1e-3)
        #expect(abs(small.y - full.y * 192 / 1440) < 1e-3)

        // Camera looks down -Z; +X is right (u grows), +Y is up (v shrinks: image v goes down).
        #expect(simd_distance(depthK.project(SIMD3(0, 0, -1))!, SIMD2(128, 96)) < 1e-4)
        #expect(depthK.project(SIMD3(0.1, 0, -1))!.x > 128)
        #expect(depthK.project(SIMD3(0, 0.1, -1))!.y < 96)
        #expect(depthK.project(SIMD3(0, 0, 1)) == nil) // behind the camera

        // Unprojecting a pixel center at depth d and projecting it back lands on that pixel center.
        let q = depthK.unproject(i: 40, j: 150, depth: 0.7)
        #expect(abs(q.z + 0.7) < 1e-6)
        let back = depthK.project(q)!
        #expect(abs(back.x - 40.5) < 1e-3 && abs(back.y - 150.5) < 1e-3)

        // Scaling to a 960x720 color copy (Detail scan color) halves everything.
        let colorK = arkitFull.scaled(toWidth: 960, height: 720)
        #expect(colorK.fx == 725 && colorK.cx == 480 && colorK.cy == 360)
    }

    @Test func syntheticRendererMatchesTheConvention() {
        // A wall 1 m in front of a camera at the origin looking down -Z: every pixel's depth is 1 m.
        let scene = AnalyticScene(parts: [.init(.plane(point: SIMD3(0, 0, -1), normal: SIMD3(0, 0, 1)), color: SIMD3(1, 2, 3))])
        let r = scene.render(intrinsics: depthK, cameraToWorld: matrix_identity_float4x4)
        #expect(r.depth.allSatisfy { abs($0 - 1) < 1e-4 })
        // A sphere above the optical axis shows in the upper half of the image (v small).
        let ball = AnalyticScene(parts: [.init(.sphere(center: SIMD3(0, 0.25, -1), radius: 0.05), color: SIMD3(9, 9, 9))])
        let b = ball.render(intrinsics: depthK, cameraToWorld: matrix_identity_float4x4)
        let hitRows = (0..<192).filter { j in (0..<256).contains { b.depth[j * 256 + $0] > 0 } }
        #expect(!hitRows.isEmpty && hitRows.allSatisfy { $0 < 96 })
        // lookAt puts the target on the optical axis.
        let pose = RigidTransform.lookAt(eye: SIMD3(0.3, 0.2, 0.5), target: SIMD3(0, 0.25, -1))
        let c = ball.render(intrinsics: depthK, cameraToWorld: pose)
        #expect(c.depth[96 * 256 + 128] > 0)
    }

    @Test func marchingCubesTableMatchesBourkeEdgeTable() {
        #expect(MarchingCubesTables.triangles.count == 256)
        for (cube, mask) in MarchingCubesTables.referenceEdgeMasks {
            #expect(MarchingCubesTables.edgeMasks[cube] == mask, "case \(cube)")
        }
        // Complementary cases cut the same edges.
        for cube in 0..<256 {
            #expect(MarchingCubesTables.edgeMasks[cube] == MarchingCubesTables.edgeMasks[255 - cube])
            #expect(MarchingCubesTables.triangles[cube].count % 3 == 0)
        }
    }

    // MARK: Accuracy

    @Test func sphereFusedFromEightPlusPosesLiesOnTheSurface() {
        let center = SIMD3<Float>(0.05, 1.0, -0.4)
        let radius: Float = 0.12
        let scene = AnalyticScene(parts: [.init(.sphere(center: center, radius: radius), color: SIMD3(200, 60, 40))])
        let poses = AnalyticScene.orbitPoses(target: center, distance: 0.55, count: 8, elevationsDegrees: [-40, 0, 40])
        let volume = fuse(scene, poses: poses, config: .detail, withColor: true)
        let mesh = volume.extractMesh()
        let errors = mesh.positions.map { simd_length($0 - center) - radius }
        let r = rms(errors)
        print("TSDF sphere r=\(radius) m, \(poses.count) poses, 4 mm voxels: \(mesh.vertexCount) vertices, \(mesh.triangleCount) triangles, RMS \(String(format: "%.3f", r * 1000)) mm, p99 \(String(format: "%.3f", percentile(errors, 0.99) * 1000)) mm, blocks \(volume.blockCount)")
        #expect(mesh.triangleCount > 3000)
        #expect(r < 0.004, "RMS within one voxel")
        #expect(percentile(errors, 0.99) < 0.008)
        // Surface area of a closed sphere (4 pi r^2) within 5 %.
        var area: Float = 0
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.positions[Int(mesh.indices[i])], b = mesh.positions[Int(mesh.indices[i + 1])], c = mesh.positions[Int(mesh.indices[i + 2])]
            area += simd_length(simd_cross(b - a, c - a)) / 2
            i += 3
        }
        #expect(abs(area - 4 * .pi * radius * radius) / (4 * .pi * radius * radius) < 0.05, "area \(area)")
        // Normals point outward; triangles are wound counter-clockwise seen from outside.
        var outward = 0
        for (p, n) in zip(mesh.positions, mesh.normals) where simd_dot(p - center, n) > 0.9 * simd_length(p - center) { outward += 1 }
        #expect(Double(outward) / Double(mesh.vertexCount) > 0.98)
        var ccw = 0
        i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.positions[Int(mesh.indices[i])], b = mesh.positions[Int(mesh.indices[i + 1])], c = mesh.positions[Int(mesh.indices[i + 2])]
            if simd_dot(simd_cross(b - a, c - a), (a + b + c) / 3 - center) > 0 { ccw += 1 }
            i += 3
        }
        #expect(Double(ccw) / Double(mesh.triangleCount) > 0.99)
        // Vertex colors come from the fused color.
        #expect(mesh.colors.count == mesh.vertexCount)
        let meanRed = mesh.colors.reduce(0.0) { $0 + Double($1.x) } / Double(mesh.colors.count)
        #expect(meanRed > 150)
    }

    @Test func boxFusedFromEightPlusPosesLiesOnTheSurface() {
        let center = SIMD3<Float>(-0.1, 0.4, 0.2)
        let half = SIMD3<Float>(0.10, 0.06, 0.08)
        let scene = AnalyticScene(parts: [.init(.box(center: center, halfExtents: half), color: SIMD3(90, 90, 200))])
        let poses = AnalyticScene.orbitPoses(target: center, distance: 0.6, count: 8, elevationsDegrees: [-45, 0, 45])
        let volume = fuse(scene, poses: poses, config: .detail)
        let mesh = volume.extractMesh()
        let errors = mesh.positions.map { AnalyticScene.distance(.box(center: center, halfExtents: half), $0) }
        let r = rms(errors)
        print("TSDF box \(half * 2) m, \(poses.count) poses, 4 mm voxels: \(mesh.vertexCount) vertices, RMS \(String(format: "%.3f", r * 1000)) mm, p95 \(String(format: "%.3f", percentile(errors, 0.95) * 1000)) mm")
        #expect(mesh.triangleCount > 2000)
        #expect(r < 0.004, "RMS within one voxel")
        #expect(percentile(errors, 0.95) < 0.004)
        // Extents (0.5-99.5 percentile per axis, robust to the odd silhouette vertex) match the true box.
        func extent(_ k: Int) -> Float {
            let v = mesh.positions.map { $0[k] }.sorted()
            return v[Int(Double(v.count - 1) * 0.995)] - v[Int(Double(v.count - 1) * 0.005)]
        }
        let size = SIMD3(extent(0), extent(1), extent(2))
        let worst = errors.map(abs).max() ?? 0
        print("TSDF box extents \(size) vs \(half * 2), max |error| \(String(format: "%.2f", worst * 1000)) mm, outside 4 mm: \(errors.filter { abs($0) > 0.004 }.count) of \(errors.count)")
        #expect(simd_reduce_max(abs(size - half * 2)) < 0.006, "size \(size)")
    }

    @Test func noisyPlaneFusedOverThirtyFramesBeatsTheSensorNoise() {
        // A wall 0.8 m away, 3 mm Gaussian depth noise per pixel, 30 frames from slightly different poses.
        let wallZ: Float = -0.8
        let scene = AnalyticScene(parts: [.init(.plane(point: SIMD3(0, 0, wallZ), normal: SIMD3(0, 0, 1)), color: SIMD3(128, 128, 128))])
        var poses: [simd_float4x4] = []
        for k in 0..<30 {
            let a = Float(k) * 0.7
            poses.append(RigidTransform.lookAt(eye: SIMD3(0.01 * cos(a), 0.01 * sin(a), 0), target: SIMD3(0.005 * sin(a), 0, wallZ)))
        }
        let noisy = fuse(scene, poses: poses, config: .detail, noise: 0.003,
                         bounds: (SIMD3(-0.2, -0.15, -1), SIMD3(0.2, 0.15, -0.6)))
        let mesh = noisy.extractMesh()
        let errors = mesh.positions.filter { abs($0.x) < 0.15 && abs($0.y) < 0.1 }.map { $0.z - wallZ }
        let r = rms(errors)
        // Single-frame reference: the same wall from one noisy frame.
        let single = fuse(scene, poses: [poses[0]], config: .detail, noise: 0.003,
                          bounds: (SIMD3(-0.2, -0.15, -1), SIMD3(0.2, 0.15, -0.6))).extractMesh()
        let singleErrors = single.positions.filter { abs($0.x) < 0.15 && abs($0.y) < 0.1 }.map { $0.z - wallZ }
        print("TSDF noisy plane (sigma 3 mm): 1 frame RMS \(String(format: "%.3f", rms(singleErrors) * 1000)) mm -> 30 frames RMS \(String(format: "%.3f", r * 1000)) mm over \(errors.count) vertices")
        #expect(errors.count > 1000)
        #expect(r < 0.0012, "30-frame RMS well below the 3 mm sensor noise")
        #expect(r < rms(singleErrors) * 0.6)
    }

    @Test func lowConfidenceAndOutOfRangeDepthIsIgnored() {
        let scene = AnalyticScene(parts: [.init(.plane(point: SIMD3(0, 0, -0.6), normal: SIMD3(0, 0, 1)), color: SIMD3(1, 1, 1))])
        let r = scene.render(intrinsics: depthK, cameraToWorld: matrix_identity_float4x4)
        let low = [UInt8](repeating: 1, count: r.depth.count) // medium confidence everywhere
        let volume = TSDFVolume(configuration: .detail) // needs high (2)
        let result = volume.integrate(DepthFrame(width: 256, height: 192, depth: r.depth, confidence: low, intrinsics: depthK,
                                                 cameraToWorld: matrix_identity_float4x4))
        #expect(result.validPixels == 0 && volume.blockCount == 0)
        // Beyond max depth (1.5 m for Detail).
        let far = AnalyticScene(parts: [.init(.plane(point: SIMD3(0, 0, -2), normal: SIMD3(0, 0, 1)), color: SIMD3(1, 1, 1))])
        let f = far.render(intrinsics: depthK, cameraToWorld: matrix_identity_float4x4)
        volume.integrate(DepthFrame(width: 256, height: 192, depth: f.depth, intrinsics: depthK, cameraToWorld: matrix_identity_float4x4))
        #expect(volume.blockCount == 0)
        // NaN / garbage buffers never crash.
        let junk = [Float](repeating: .nan, count: 10)
        volume.integrate(DepthFrame(width: 256, height: 192, depth: junk, intrinsics: depthK, cameraToWorld: matrix_identity_float4x4))
        #expect(volume.extractMesh().triangleCount == 0)
    }

    @Test func memoryCapStopsAllocationAndReportsTheFraction() {
        var config = TSDFVolume.Configuration.detail
        config.memoryCapBytes = 200 * (512 * TSDFVolume.bytesPerVoxel + TSDFVolume.blockOverheadBytes)
        let scene = AnalyticScene(parts: [.init(.plane(point: SIMD3(0, 0, -0.7), normal: SIMD3(0, 0, 1)), color: SIMD3(1, 1, 1))])
        let volume = fuse(scene, poses: [matrix_identity_float4x4], config: config)
        #expect(volume.blockCount == 200)
        #expect(volume.stats.isFull)
        #expect(abs(volume.stats.memoryFraction - 1) < 1e-9)
        #expect(volume.stats.memoryBytes <= config.memoryCapBytes)
        // Still extracts what it has.
        #expect(volume.extractMesh().triangleCount > 0)
        volume.reset()
        #expect(volume.blockCount == 0 && !volume.stats.isFull && volume.framesIntegrated == 0)
    }

    @Test func integrationAndExtractionAreDeterministic() {
        let scene = DemoDetailScan.scene()
        let poses = Array(DemoDetailScan.poses(perBand: 3))
        func run() -> FusedMesh {
            fuse(scene, poses: poses, config: .detail, noise: 0.002, withColor: true, bounds: DemoDetailScan.bounds).extractMesh()
        }
        let a = run(), b = run()
        #expect(a.vertexCount > 0)
        #expect(a.positions == b.positions)
        #expect(a.normals == b.normals)
        #expect(a.colors == b.colors)
        #expect(a.indices == b.indices)
    }

    @Test func surfaceSamplesReportConfidence() {
        let scene = AnalyticScene(parts: [.init(.plane(point: SIMD3(0, 0, -0.7), normal: SIMD3(0, 0, 1)), color: SIMD3(1, 1, 1))])
        let once = fuse(scene, poses: [matrix_identity_float4x4], config: .detail)
        let many = fuse(scene, poses: Array(repeating: matrix_identity_float4x4, count: 20), config: .detail)
        let a = once.surfaceSamples()
        let b = many.surfaceSamples()
        #expect(!a.isEmpty && !b.isEmpty)
        let meanA = a.reduce(0) { $0 + $1.confidence } / Float(a.count)
        let meanB = b.reduce(0) { $0 + $1.confidence } / Float(b.count)
        #expect(meanA < 0.2 && meanB > 0.95)
        #expect(a.allSatisfy { abs($0.position.z + 0.7) < 0.01 })
    }

    @Test func demoDetailScanFusesTheUtilityCorner() {
        let start = Date()
        let result = DemoDetailScan.fuse()
        let elapsed = Date().timeIntervalSince(start)
        print("Demo Detail scan: \(result.stats.framesIntegrated) frames, \(result.stats.blockCount) blocks, \(result.mesh.vertexCount) vertices, \(result.mesh.triangleCount) triangles in \(String(format: "%.2f", elapsed)) s")
        #expect(result.mesh.triangleCount > 20_000)
        #expect(result.mesh.colors.count == result.mesh.vertexCount)
        // The 3/4" copper line (r = 11.1 mm) is resolved: vertices exist around it at its radius.
        let axisY: Float = 0.10, axisZ: Float = -0.065
        let onPipe = result.mesh.positions.filter { $0.x > 0.18 && $0.x < 0.2 && abs(((($0.y - axisY) * ($0.y - axisY) + ($0.z - axisZ) * ($0.z - axisZ))).squareRoot() - 0.0111) < 0.003 }
        #expect(onPipe.count > 20)
        // Prepared for export like any mesh scan: colors survive normalization.
        let prepared = MeshNormalizer.prepareForExport(result.mesh.classifiedMesh())
        #expect(prepared.mesh.hasVertexColors)
        #expect(prepared.measurements.width > 0.45 && prepared.measurements.width < 0.56)
    }

    @Test func performanceOfOneHundredFrames() {
        let scene = AnalyticScene(parts: [
            .init(.plane(point: SIMD3(0, 0, -0.9), normal: SIMD3(0, 0, 1)), color: SIMD3(1, 1, 1)),
            .init(.sphere(center: SIMD3(0, 0, -0.7), radius: 0.12), color: SIMD3(1, 1, 1)),
        ])
        var frames: [DepthFrame] = []
        for k in 0..<4 {
            let pose = RigidTransform.lookAt(eye: SIMD3(Float(k) * 0.02, 0, 0), target: SIMD3(0, 0, -0.8))
            let r = scene.render(intrinsics: depthK, cameraToWorld: pose, noise: 0.002, seed: UInt64(k))
            frames.append(DepthFrame(width: 256, height: 192, depth: r.depth, intrinsics: depthK, cameraToWorld: pose))
        }
        let volume = TSDFVolume(configuration: .detail)
        let start = Date()
        for k in 0..<100 { volume.integrate(frames[k % frames.count]) }
        let elapsed = Date().timeIntervalSince(start)
        let extractStart = Date()
        let mesh = volume.extractMesh()
        let extract = Date().timeIntervalSince(extractStart)
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        print("TSDF perf (\(build)): 100 frames 256x192 in \(String(format: "%.2f", elapsed)) s (\(String(format: "%.1f", elapsed * 10)) ms/frame), \(volume.blockCount) blocks, \(String(format: "%.1f", Double(volume.stats.memoryBytes) / 1_048_576)) MB; extract \(mesh.triangleCount) triangles in \(String(format: "%.2f", extract)) s")
        #expect(elapsed < 120)
        #expect(mesh.triangleCount > 0)
    }

    // MARK: Colored exports

    @Test func coloredExportsCarryVertexColors() throws {
        let fused = DemoDetailScan.fuse(perBand: 3)
        let prepared = MeshNormalizer.prepareForExport(fused.mesh.classifiedMesh())
        let output = LiDARMeshExporter.export(prepared, title: "Demo Detail scan", units: .imperial)
        let files = Dictionary(uniqueKeysWithValues: output.files.map { ($0.name, $0.data) })
        // OBJ: "v x y z r g b".
        let obj = String(decoding: try #require(files[LiDARMeshExporter.objName]), as: UTF8.self)
        let firstV = try #require(obj.split(separator: "\n").first { $0.hasPrefix("v ") })
        #expect(firstV.split(separator: " ").count == 7, "\(firstV)")
        // PLY: uchar red/green/blue with the fused colors (not the class palette).
        let ply = try #require(files[LiDARMeshExporter.plyName])
        let header = String(decoding: ply.prefix(400), as: UTF8.self)
        #expect(header.contains("property uchar red") && header.contains("property uchar blue"))
        // USDZ: displayColor primvar with vertex interpolation, wired into the material.
        let usda = String(decoding: USDAWriter.write(classifiedMesh: prepared.mesh, name: "Demo"), as: UTF8.self)
        #expect(usda.contains("color3f[] primvars:displayColor = ["))
        #expect(usda.contains("interpolation = \"vertex\""))
        #expect(usda.contains("UsdPrimvarReader_float3"))
        #expect(usda.contains("inputs:diffuseColor.connect"))
        // Uncolored meshes are unchanged (no displayColor).
        let plain = String(decoding: USDAWriter.write(classifiedMesh: DemoMeshScan.bedroomMesh().mesh, name: "Plain"), as: UTF8.self)
        #expect(!plain.contains("displayColor"))
        if let dir = ProcessInfo.processInfo.environment["ASBUILT_EXPORT_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("detail", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for file in output.files {
                let name = file.name == LiDARMeshExporter.usdzName ? "detail-scan.usdz" : "detail-" + file.name
                try file.data.write(to: url.appendingPathComponent(name))
            }
            try Data(usda.utf8).write(to: url.appendingPathComponent("detail-scan.usda"))
        }
    }
}
