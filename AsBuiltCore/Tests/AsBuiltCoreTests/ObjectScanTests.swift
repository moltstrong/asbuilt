import Foundation
import Testing
import simd
@testable import AsBuiltCore

/// A yawed 20 x 15 x 12 cm box standing on a table (top at 0.72 m), with a ball and a can beside it
/// and the floor below.
private enum BoxOnTable {
    static let top: Float = 0.72
    static let yaw: Float = 25 * .pi / 180
    static let size = SIMD3<Float>(0.20, 0.15, 0.12)
    static let center = SIMD3<Float>(0.05, top + size.y / 2, -0.03)
    static let ball = SIMD3<Float>(-0.25, top + 0.05, 0.15)
    static let canAxis = SIMD2<Float>(0.30, -0.20)
    static var truth: ObjectBox { ObjectBox(center: center, halfExtents: size / 2, yaw: yaw) }

    static func scene(clutter: Bool = true, table: Bool = true) -> AnalyticScene {
        var parts: [AnalyticScene.Part] = [
            .init(.plane(point: .zero, normal: SIMD3(0, 1, 0)), color: SIMD3(100, 100, 100)),
            .init(.orientedBox(center: center, halfExtents: size / 2, yaw: yaw), color: SIMD3(60, 120, 200)),
        ]
        if table { parts.append(.init(.box(center: SIMD3(0, top - 0.02, 0), halfExtents: SIMD3(0.8, 0.02, 0.6)), color: SIMD3(170, 130, 90))) }
        if clutter {
            parts.append(.init(.sphere(center: ball, radius: 0.05), color: SIMD3(200, 60, 60)))
            parts.append(.init(.cylinder(a: SIMD3(canAxis.x, top, canAxis.y), b: SIMD3(canAxis.x, top + 0.12, canAxis.y), radius: 0.035),
                               color: SIMD3(60, 160, 60)))
        }
        return AnalyticScene(parts: parts)
    }

    static let K = DemoDetailScan.depthIntrinsics

    static func frame(_ scene: AnalyticScene, pose: simd_float4x4, seed: UInt64, color: Bool = false) -> DepthFrame {
        let r = scene.render(intrinsics: K, cameraToWorld: pose, maxDistance: 2.5, noise: 0.0015, seed: seed, withColor: color)
        return DepthFrame(width: K.width, height: K.height, depth: r.depth, intrinsics: K, cameraToWorld: pose,
                          color: color ? ColorImage(width: K.width, height: K.height, rgb: r.rgb, intrinsics: K) : nil)
    }

    /// Standing in front and to the side, looking down at 35 degrees from 55 cm.
    static let placement = AnalyticScene.orbitPoses(target: center, distance: 0.55, count: 1, elevationsDegrees: [35],
                                                    azimuthRangeDegrees: 40...40)[0]

    struct Scan {
        var fit: ObjectBoxFitter.Result
        var configuration: TSDFVolume.Configuration
        var margin: Float
        var raw: FusedMesh
        var cleaned: FusedMesh
        var report: ObjectMeshCleaner.Report
    }

    /// Fit from the placement view, fuse a 3-band orbit inside the box, clean.
    static func scan() -> Scan? {
        let s = scene()
        guard let fit = ObjectBoxFitter.fit(frame: frame(s, pose: placement, seed: 5)) else { return nil }
        let cfg = TSDFVolume.Configuration.object(for: fit.box)
        let margin = ObjectScan.margin(voxelSize: cfg.voxelSize)
        let volume = TSDFVolume(configuration: cfg)
        let poses = AnalyticScene.orbitPoses(target: center, distance: 0.45, count: 12, elevationsDegrees: [10, 30, 55])
        for (k, pose) in poses.enumerated() {
            volume.integrate(frame(s, pose: pose, seed: UInt64(k + 11), color: true), bounds: fit.box.aabb(margin: margin))
        }
        let raw = volume.extractMesh(minWeight: 3)
        let cleaned = ObjectMeshCleaner.clean(raw, box: fit.box, margin: margin, planeY: fit.planeY, voxelSize: cfg.voxelSize)
        return Scan(fit: fit, configuration: cfg, margin: margin, raw: raw, cleaned: cleaned.mesh, report: cleaned.report)
    }
}

private func angleDiffDegrees(_ a: Float, _ b: Float) -> Float {
    // Boxes are symmetric under half turns.
    var d = (a - b) * 180 / .pi
    while d > 90 { d -= 180 }
    while d < -90 { d += 180 }
    return abs(d)
}

@Suite("Object Detail scan")
struct ObjectScanTests {
    // MARK: Box geometry

    @Test func boxGeometry() {
        let box = ObjectBox(bottomCenter: SIMD3(0.1, 0.7, -0.2), size: SIMD3(0.3, 0.1, 0.2), yaw: 0.6)
        #expect(abs(box.bottomY - 0.7) < 1e-6 && abs(box.topY - 0.8) < 1e-6)
        let p = SIMD3<Float>(0.23, 0.74, -0.31)
        #expect(simd_distance(box.world(box.local(p)), p) < 1e-5)
        // Local X is the box's width axis.
        #expect(simd_distance(box.local(box.center + box.axisX * 0.1), SIMD3(0.1, 0, 0)) < 1e-5)
        #expect(simd_distance(box.local(box.center + box.axisZ * 0.05), SIMD3(0, 0, 0.05)) < 1e-5)
        #expect(box.contains(box.world(SIMD3(0.149, 0.049, 0.099))))
        #expect(!box.contains(box.world(SIMD3(0.151, 0, 0))))
        #expect(box.contains(box.world(SIMD3(0.16, 0, 0)), margin: 0.02))
        #expect(box.corners.count == 8 && ObjectBox.edges.count == 12)
        for (i, j) in ObjectBox.edges {
            let len = simd_distance(box.corners[i], box.corners[j])
            #expect([0.3, 0.1, 0.2].contains { abs($0 - len) < 1e-5 }, "edge \(i)-\(j) length \(len)")
        }
        let aabb = box.aabb(margin: 0.01)
        for c in box.corners {
            #expect(c.x >= aabb.min.x && c.y >= aabb.min.y && c.z >= aabb.min.z)
            #expect(c.x <= aabb.max.x && c.y <= aabb.max.y && c.z <= aabb.max.z)
        }

        // Height changes keep the bottom on the table; width changes keep the center.
        let taller = box.resized(axis: 1, by: 0.05)
        #expect(abs(taller.bottomY - 0.7) < 1e-6 && abs(taller.size.y - 0.15) < 1e-6)
        let narrower = box.resized(axis: 0, by: -0.5)
        #expect(abs(narrower.size.x - 0.02) < 1e-6, "clamped to the minimum side")
        #expect(simd_distance(narrower.center, box.center) < 1e-6)
        let pinched = box.scaled(by: 2)
        #expect(abs(pinched.bottomY - 0.7) < 1e-6 && abs(pinched.size.x - 0.6) < 1e-5)

        // Ray entry, distance to the box.
        let eye = box.world(SIMD3(0, 0, 0.5))
        let t = box.intersect(origin: eye, direction: -box.axisZ)
        #expect(t.map { abs($0 - 0.4) < 1e-4 } == true)
        #expect(box.intersect(origin: eye, direction: box.axisZ) == nil)
        #expect(box.intersect(origin: box.center, direction: SIMD3(0, 1, 0)) == 0)
        #expect(abs(box.distance(to: eye) - 0.4) < 1e-4 && box.distance(to: box.center) == 0)
    }

    @Test func successiveFitsBlendWithoutFlippingAxes() {
        let a = ObjectBox(center: SIMD3(0, 0.8, 0), halfExtents: SIMD3(0.10, 0.05, 0.08), yaw: 0.1)
        // The same box described a quarter turn and a half turn later.
        let quarter = ObjectBox(center: a.center, halfExtents: SIMD3(0.08, 0.05, 0.10), yaw: 0.1 + .pi / 2)
        let half = ObjectBox(center: a.center, halfExtents: a.halfExtents, yaw: 0.1 + .pi)
        for other in [quarter, half] {
            let r = other.reoriented(near: a)
            #expect(abs(r.yaw - a.yaw) < 1e-5 && simd_distance(r.halfExtents, a.halfExtents) < 1e-6)
            for (p, q) in zip(r.corners.sorted { ($0.x, $0.z, $0.y) < ($1.x, $1.z, $1.y) },
                              other.corners.sorted { ($0.x, $0.z, $0.y) < ($1.x, $1.z, $1.y) }) {
                #expect(simd_distance(p, q) < 1e-4, "same box in space")
            }
        }
        // Blending moves part of the way; blending with an equivalent box changes nothing.
        let b = ObjectBox(center: SIMD3(0.03, 0.8, 0), halfExtents: SIMD3(0.12, 0.05, 0.08), yaw: 0.2)
        let m = a.blended(toward: b, weight: 0.5)
        #expect(abs(m.center.x - 0.015) < 1e-6 && abs(m.halfExtents.x - 0.11) < 1e-6 && abs(m.yaw - 0.15) < 1e-6)
        let same = a.blended(toward: quarter, weight: 0.5)
        #expect(simd_distance(same.halfExtents, a.halfExtents) < 1e-6 && abs(same.yaw - a.yaw) < 1e-5)
    }

    @Test func wireframeEdgesAreClippedToTheFrontOfTheCamera() {
        let box = ObjectBox(center: SIMD3(0, 0, -0.5), halfExtents: SIMD3(repeating: 0.1))
        let looking = RigidTransform.lookAt(eye: .zero, target: SIMD3(0, 0, -1))
        #expect(box.visibleEdges(cameraToWorld: looking).count == 12)
        // Camera inside the box near its front face: edges cross the near plane and are cut there.
        let inside = RigidTransform.lookAt(eye: SIMD3(0, 0, -0.45), target: SIMD3(0, 0, -1))
        let edges = inside.columns.3
        let clipped = box.visibleEdges(cameraToWorld: inside, near: 0.05)
        #expect(!clipped.isEmpty && clipped.count < 12)
        for (a, b) in clipped {
            #expect(a.z <= edges.z - 0.05 + 1e-4 && b.z <= edges.z - 0.05 + 1e-4)
        }
        // Looking away: nothing to draw.
        let away = RigidTransform.lookAt(eye: .zero, target: SIMD3(0, 0, 1))
        #expect(box.visibleEdges(cameraToWorld: away).isEmpty)
    }

    // MARK: Box fit

    @Test func boxFitFindsTheObjectOnTheTableAndIgnoresClutter() throws {
        let frame = BoxOnTable.frame(BoxOnTable.scene(), pose: BoxOnTable.placement, seed: 5)
        let fit = try #require(ObjectBoxFitter.fit(frame: frame))
        let truth = BoxOnTable.truth
        print("Box fit: plane \(String(describing: fit.planeY)) size \(fit.box.size) yaw \(fit.box.yaw * 180 / .pi) deg, \(fit.objectPoints) points")
        let plane = try #require(fit.planeY)
        #expect(abs(plane - BoxOnTable.top) < 0.002, "support plane = the table top")
        #expect(abs(fit.box.bottomY - BoxOnTable.top) < 0.002, "box stands on the table")
        #expect(angleDiffDegrees(fit.box.yaw, truth.yaw) < 3)
        #expect(abs(fit.box.size.y - truth.size.y) < 0.01)
        // The box covers the whole object (visible sides tight, room on the hidden side) ...
        for c in truth.corners { #expect(fit.box.contains(c, margin: 0.006), "corner \(c) outside the fitted box") }
        #expect(fit.box.size.x < truth.size.x + 0.06 && fit.box.size.z < truth.size.z + 0.06)
        // ... and nothing beside it.
        #expect(!fit.box.contains(BoxOnTable.ball, margin: 0.03))
        #expect(!fit.box.contains(SIMD3(BoxOnTable.canAxis.x, BoxOnTable.top + 0.06, BoxOnTable.canAxis.y), margin: 0.03))
        // Small object: 2 mm voxels.
        #expect(TSDFVolume.Configuration.object(for: fit.box).voxelSize == 0.002)
    }

    @Test func boxFitPrefersTheTableOverTheFloorAndUsesARKitPlanes() throws {
        let frame = BoxOnTable.frame(BoxOnTable.scene(), pose: BoxOnTable.placement, seed: 6)
        // ARKit planes: the floor, the table (slightly off, as ARKit reports it) and a bogus one above.
        let fit = try #require(ObjectBoxFitter.fit(frame: frame, planeCandidates: [0.0, BoxOnTable.top + 0.004, 1.2]))
        #expect(fit.planeY.map { abs($0 - BoxOnTable.top) < 0.002 } == true, "refined to the depth points: \(String(describing: fit.planeY))")
        // Only the floor offered: it has no depth support near the object, so the depth estimate wins.
        let floorOnly = try #require(ObjectBoxFitter.fit(frame: frame, planeCandidates: [0.0]))
        #expect(floorOnly.planeY.map { abs($0 - BoxOnTable.top) < 0.002 } == true)
        // Deterministic.
        #expect(ObjectBoxFitter.fit(frame: frame) == ObjectBoxFitter.fit(frame: frame))
    }

    @Test func noPlaneFallsBackToTheBlobAtTheAimPoint() throws {
        // A ball held in the air: no support plane anywhere.
        let ball = SIMD3<Float>(0.1, 1.2, -0.3)
        let scene = AnalyticScene(parts: [.init(.sphere(center: ball, radius: 0.06), color: SIMD3(1, 2, 3))])
        let pose = RigidTransform.lookAt(eye: ball + SIMD3(0.1, 0.15, 0.4), target: ball)
        let frame = BoxOnTable.frame(scene, pose: pose, seed: 3)
        let fit = try #require(ObjectBoxFitter.fit(frame: frame))
        print("No-plane fit: size \(fit.box.size) center \(fit.box.center)")
        #expect(fit.planeY == nil)
        #expect(simd_distance(SIMD2(fit.box.center.x, fit.box.center.z), SIMD2(ball.x, ball.z)) < 0.03)
        #expect(abs(fit.box.center.y - ball.y) < 0.03)
        #expect(simd_reduce_max(fit.box.size) < 0.2 && simd_reduce_min(fit.box.size) > 0.05)
        // Nothing in front of the camera: no box.
        let empty = DepthFrame(width: 256, height: 192, depth: [Float](repeating: 0, count: 256 * 192),
                               intrinsics: BoxOnTable.K, cameraToWorld: pose)
        #expect(ObjectBoxFitter.fit(frame: empty) == nil)
    }

    // MARK: Fusion settings

    @Test func voxelFollowsTheBoxSizeWithinTheMemoryCap() {
        func box(_ side: Float) -> ObjectBox { ObjectBox(center: .zero, halfExtents: SIMD3(side / 2, side / 4, side / 3)) }
        #expect(TSDFVolume.Configuration.object(for: box(0.12)).voxelSize == 0.002)
        #expect(TSDFVolume.Configuration.object(for: box(0.30)).voxelSize == 0.002)
        #expect(TSDFVolume.Configuration.object(for: box(0.31)).voxelSize == 0.003)
        #expect(TSDFVolume.Configuration.object(for: box(0.60)).voxelSize == 0.003)
        #expect(TSDFVolume.Configuration.object(for: box(0.61)).voxelSize == 0.004)
        let c = TSDFVolume.Configuration.object(for: box(0.25))
        #expect(c.minDepth == 0.12 && c.maxDepth == 1.0 && c.minConfidence == 2)
        #expect(abs(c.truncation - 0.012) < 1e-6)
        // A 1 m box at 4 mm fits comfortably; a tiny memory cap steps the voxel up instead of filling.
        let big = box(1.0)
        #expect(TSDFVolume.Configuration.estimatedObjectBytes(box: big, voxelSize: 0.004) < (384 << 20) / 2)
        #expect(TSDFVolume.Configuration.object(for: box(0.25), memoryCapBytes: 8 << 20).voxelSize > 0.002)
        #expect(abs(ObjectScan.margin(voxelSize: 0.002) - 0.015) < 1e-6 && abs(ObjectScan.margin(voxelSize: 0.004) - 0.02) < 1e-6)
    }

    // MARK: Cleanup and dimensions

    @Test func cleanupCropsRemovesTheTableAndKeepsTheObject() throws {
        let scan = try #require(BoxOnTable.scan())
        let plane = try #require(scan.fit.planeY)
        let mesh = scan.cleaned
        let voxel = scan.configuration.voxelSize
        print("Cleanup: \(scan.report)")
        #expect(scan.report.croppedOut > 0 && scan.report.planeRemoved > 0)
        #expect(scan.report.componentsKept == 1)
        #expect(mesh.triangleCount > 20_000)
        #expect(mesh.colors.count == mesh.vertexCount && mesh.normals.count == mesh.vertexCount)
        // Everything inside the box (+ margin), no table: every triangle reaches above plane + 1.5 voxels.
        #expect(mesh.positions.allSatisfy { scan.fit.box.contains($0, margin: scan.margin) })
        var t = 0
        var flat = 0
        while t + 2 < mesh.indices.count {
            let ys = (0..<3).map { mesh.positions[Int(mesh.indices[t + $0])].y }
            if ys.max()! < plane + 1.5 * voxel { flat += 1 }
            t += 3
        }
        #expect(flat == 0)
        // Only the box: every vertex lies on its surface (no clutter, no table rim).
        let truth = BoxOnTable.truth
        let far = mesh.positions.filter { truth.distance(to: $0) > 0.004 || !truth.contains($0, margin: 0.004) }
        #expect(far.isEmpty, "\(far.count) vertices off the object, e.g. \(far.prefix(3))")
        // Welded and compact: no unused vertices, no degenerate triangles.
        var used = [Bool](repeating: false, count: mesh.vertexCount)
        for i in mesh.indices { used[Int(i)] = true }
        #expect(used.allSatisfy { $0 })
        t = 0
        while t + 2 < mesh.indices.count {
            #expect(mesh.indices[t] != mesh.indices[t + 1] && mesh.indices[t + 1] != mesh.indices[t + 2] && mesh.indices[t] != mesh.indices[t + 2])
            t += 3
        }
    }

    @Test func objectDimensionsAreWithinOneVoxelOfTruth() throws {
        let scan = try #require(BoxOnTable.scan())
        let prepared = ObjectScan.prepareForExport(scan.cleaned, planeY: scan.fit.planeY)
        let m = prepared.measurements
        let voxel = Double(scan.configuration.voxelSize)
        let truth = BoxOnTable.size
        let errors = SIMD3(m.width - Double(truth.x), m.depth - Double(truth.z), m.height - Double(truth.y))
        print("Object box \(truth) at \(voxel * 1000) mm voxels: measured W \(m.width) D \(m.depth) H \(m.height), errors mm \(errors * 1000), yaw \(m.alignmentYawDegrees)")
        #expect(abs(errors.x) <= voxel && abs(errors.y) <= voxel && abs(errors.z) <= voxel)
        // The export turns the box square to the axes and puts the table at y = 0.
        #expect(abs(abs(m.alignmentYawDegrees) - 25) < 1 || abs(abs(m.alignmentYawDegrees) - 65) < 1)
        let minY = prepared.mesh.positions.map(\.y).min() ?? -1
        #expect(minY > -0.001 && minY < 2 * Float(voxel), "lowest vertex just above the table: \(minY)")
        let expectedArea = 0.12 // two 20 x 15 sides + two 12 x 15 sides + the 20 x 12 top (no bottom)
        #expect(abs(m.surfaceArea - expectedArea) < 0.01, "surface \(m.surfaceArea) m²")
        let mm = [m.width, m.depth, m.height].map { "\(Int(($0 * 1000).rounded())) mm" }
        #expect(m.objectDimensionsText(.metric) == mm.joined(separator: " × "))
        // measurements.csv for objects: inches / millimeters and the object note.
        let csv = MeshMeasurementsCSV.write(m, title: "Box", units: .imperial, object: true)
        #expect(csv.contains("\"Width (X, longest side)\",\(UnitFormatter.decimal(m.width / UnitFormatter.metersPerInch, 2)),in,"))
        #expect(csv.contains("Height (Y, from the surface it stands on)") && csv.contains("Object Detail scan"))
        let metric = MeshMeasurementsCSV.write(m, title: "Box", units: .metric, object: true)
        #expect(metric.contains(",\(UnitFormatter.decimal(m.depth * 1000, 1)),mm,"))
    }

    @Test func demoValveIsMeasuredWithinOneVoxelAndIsDeterministic() throws {
        let a = try #require(DemoDetailScan.fuse())
        let b = try #require(DemoDetailScan.fuse())
        #expect(a.mesh.positions == b.mesh.positions && a.mesh.indices == b.mesh.indices && a.mesh.colors == b.mesh.colors)
        #expect(a.fit == b.fit)
        let m = ObjectScan.prepareForExport(a.mesh, planeY: a.fit.planeY).measurements
        let truth = DemoDetailScan.trueSize
        let voxel = Double(a.configuration.voxelSize)
        let errors = SIMD3(m.width - Double(truth.x), m.depth - Double(truth.y), m.height - Double(truth.z))
        print("Demo valve at \(voxel * 1000) mm: W \(m.width) D \(m.depth) H \(m.height) vs \(truth); errors mm \(errors * 1000); fit \(a.fit.box.size); \(a.cleanup)")
        #expect(abs(voxel - 0.002) < 1e-6)
        #expect(abs(errors.x) <= voxel && abs(errors.y) <= voxel && abs(errors.z) <= voxel)
        #expect(a.cleanup.componentsKept == 1)
        // The mug and the tape measure stay out of the model.
        let mug = SIMD2<Float>(-0.24, -0.20), tape = SIMD2<Float>(0.26, 0.12)
        #expect(!a.mesh.positions.contains { simd_distance(SIMD2($0.x, $0.z), mug) < 0.06 || simd_distance(SIMD2($0.x, $0.z), tape) < 0.06 })
    }

    // MARK: Coach

    @Test func coachMeasuresCoverageAroundTheBoxCenter() {
        let box = ObjectBox(bottomCenter: SIMD3(0.4, 0.75, -0.2), size: SIMD3(0.2, 0.1, 0.1))
        var coach = CaptureCoach(mode: .detail)
        coach.setOrbitCenter(box.center)
        #expect(coach.orbitCenter == box.center)
        coach.beginScanning()
        var t = 0.0
        var out: CoachOutput?
        // A slow full circle in the middle band, 45 cm out. The center depth is junk (background);
        // the object metrics replace it with the distance to the box.
        for k in 0...600 {
            let az = Float(k) / 600 * 360 * .pi / 180, el: Float = 25 * .pi / 180
            let eye = box.center + SIMD3(cos(el) * sin(az), sin(el), cos(el) * cos(az)) * 0.45
            let raw = CoachFrame(timestamp: t, cameraToWorld: RigidTransform.lookAt(eye: eye, target: box.center),
                                 ambientIntensity: 900, centerDepth: 3.5, highConfidenceFraction: 0.8, featureCount: 300)
            let frame = ObjectScan.coachFrame(raw, box: box)
            out = coach.update(frame)
            t += 1.0 / 30
        }
        let o = out!
        #expect(o.distanceZone == .good)
        #expect(o.coverage.bandsComplete[CoachBand.mid.rawValue])
        #expect(o.coverage.fill[CoachBand.mid.rawValue].allSatisfy { $0 >= 1 })
        #expect(o.coverage.fill[CoachBand.low.rawValue].allSatisfy { $0 == 0 })
        #expect(o.guidance == .nextBand(.low, lower: true))
        // Thresholds: arm's length.
        #expect(coach.thresholds.minDistance == 0.25 && coach.thresholds.maxDistance == 0.8)
    }

    @Test func objectMetricsAndAimCue() {
        let box = ObjectBox(center: SIMD3(0, 0.8, 0), halfExtents: SIMD3(0.1, 0.05, 0.05))
        let eye = SIMD3<Float>(0, 0.8, 0.5)
        let on = ObjectScan.coachMetrics(box: box, cameraToWorld: RigidTransform.lookAt(eye: eye, target: box.center))
        #expect(abs(on.distance - 0.45) < 1e-4 && !on.offTarget)
        // Looking 60 degrees to the side: the box is out of view, distance = nearest point of the box.
        let side = RigidTransform.lookAt(eye: eye, target: eye + SIMD3(sin(1.05), 0, -cos(1.05)))
        let off = ObjectScan.coachMetrics(box: box, cameraToWorld: side)
        #expect(off.offTarget && abs(off.distance - 0.45) < 1e-4)
        // Slightly off the box edge still counts as on target (no nagging).
        let near = RigidTransform.lookAt(eye: eye, target: SIMD3(0.14, 0.8, 0))
        #expect(!ObjectScan.coachMetrics(box: box, cameraToWorld: near).offTarget)

        // The cue: "Aim at object" after the enter delay, gating progress, then clears.
        var coach = CaptureCoach(mode: .detail)
        coach.setOrbitCenter(box.center)
        coach.beginScanning()
        var t = 0.0
        func step(_ pose: simd_float4x4) -> CoachOutput {
            let f = ObjectScan.coachFrame(CoachFrame(timestamp: t, cameraToWorld: pose, ambientIntensity: 900, centerDepth: 2,
                                                     highConfidenceFraction: 0.8, featureCount: 300), box: box)
            t += 1.0 / 30
            return coach.update(f)
        }
        let onPose = RigidTransform.lookAt(eye: eye, target: box.center)
        for _ in 0..<30 { _ = step(onPose) }
        let first = step(side)
        #expect(first.guidance != .aimAtObject, "a glance away does not flash the cue")
        var out = first
        // (Turning that fast also trips "Slow down" first; hold still until it settles.)
        for _ in 0..<90 { out = step(side) }
        #expect(out.guidance == .aimAtObject && !out.shouldIntegrate)
        #expect(out.guidance.label() == "Aim at object" && out.guidance.isProblem)
        for _ in 0..<120 { out = step(onPose) }
        #expect(out.guidance != .aimAtObject && out.shouldIntegrate)
    }

    @Test func objectLengthsReadLikeATape() {
        #expect(UnitFormatter.objectLength(0.2508, .imperial) == "9 7/8\"")
        #expect(UnitFormatter.objectLength(0.0254 * 3, .imperial) == "3\"")
        #expect(UnitFormatter.objectLength(0.3048 * 2.5, .imperial) == "2' 6\"")
        #expect(UnitFormatter.objectLength(0.2508, .metric) == "251 mm")
        #expect(UnitFormatter.objectLength(1.234, .metric) == "1.23 m")
    }
}
