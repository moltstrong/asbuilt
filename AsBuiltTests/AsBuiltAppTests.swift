import XCTest
import SceneKit
import AsBuiltCore
@testable import AsBuilt

/// App-level tests that need UIKit/SceneKit (run in the iOS Simulator in CI).
@MainActor
final class AsBuiltAppTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AsBuiltTests-\(UUID().uuidString)")
        suiteName = "AsBuiltTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore() -> JobStore { JobStore(rootURL: root, defaults: defaults) }

    func testDemoJobIsCreatedWithAllExports() async throws {
        let store = makeStore()
        store.ensureDemoJob()
        await store.prepareDemoExports()
        XCTAssertEqual(store.demoStatus, .ready)
        XCTAssertNil(defaults.string(forKey: JobStore.demoInFlightKey), "in-flight marker must be cleared")
        let job = try XCTUnwrap(store.job(SampleData.demoJobID))
        XCTAssertTrue(job.isDemo)
        XCTAssertEqual(job.roomCaptures.count, 2)

        let names = Set(store.files(job: job.id, capture: SampleData.demoCaptureID).map(\.lastPathComponent))
        for expected in [CaptureFile.modelUSDZ, CaptureFile.dxf, CaptureFile.pdf, CaptureFile.csv, CaptureFile.svg, CaptureFile.planJSON] {
            XCTAssertTrue(names.contains(expected), "missing \(expected), have \(names)")
        }
    }

    func testLaunchPathWritesOnlyJSON() throws {
        // App.init runs ensureDemoJob: it must not generate any export (no SceneKit/UIKit work at launch).
        let store = makeStore()
        store.ensureDemoJob()
        XCTAssertNotNil(store.job(SampleData.demoJobID))
        XCTAssertNotNil(store.plan(job: SampleData.demoJobID, capture: SampleData.demoCaptureID))
        let names = Set(store.files(job: SampleData.demoJobID, capture: SampleData.demoCaptureID).map(\.lastPathComponent))
        XCTAssertEqual(names, [CaptureFile.planJSON])
        XCTAssertNil(store.modelURL(job: SampleData.demoJobID, capture: SampleData.demoCaptureID))
    }

    func testCrashLoopBreakerSkipsTheStageThatDiedLastLaunch() async throws {
        // Simulate a previous launch that died while generating the 3D model.
        defaults.set(JobStore.DemoStage.model.rawValue, forKey: JobStore.demoInFlightKey)
        let store = makeStore()
        store.ensureDemoJob()
        await store.prepareDemoExports()
        XCTAssertNil(defaults.string(forKey: JobStore.demoInFlightKey))
        XCTAssertNotNil(store.demoNotice)
        XCTAssertNil(store.modelURL(job: SampleData.demoJobID, capture: SampleData.demoCaptureID), "model stage must be skipped")
        let names = Set(store.files(job: SampleData.demoJobID, capture: SampleData.demoCaptureID).map(\.lastPathComponent))
        XCTAssertTrue(names.isSuperset(of: [CaptureFile.dxf, CaptureFile.pdf, CaptureFile.csv, CaptureFile.svg]), "\(names)")

        // Still skipped on the next launch, until the user resets the demo.
        let relaunch = makeStore()
        relaunch.ensureDemoJob()
        await relaunch.prepareDemoExports()
        XCTAssertNil(relaunch.modelURL(job: SampleData.demoJobID, capture: SampleData.demoCaptureID))
        await relaunch.resetDemo()
        XCTAssertNil(relaunch.demoNotice)
        XCTAssertNotNil(relaunch.modelURL(job: SampleData.demoJobID, capture: SampleData.demoCaptureID))
    }

    func testStaleDemoModelFromOldBuildsIsReplaced() async throws {
        let store = makeStore()
        store.ensureDemoJob()
        let dir = store.captureDirectory(job: SampleData.demoJobID, capture: SampleData.demoCaptureID)
        let model = dir.appendingPathComponent(CaptureFile.modelUSDZ)
        try Data("PK\u{03}\u{04} truncated SceneKit export".utf8).write(to: model)
        XCTAssertFalse(JobStore.isCurrentRoomModel(model))
        await store.prepareDemoExports()
        XCTAssertTrue(JobStore.isCurrentRoomModel(model))
    }

    func testPersistenceRoundTrip() throws {
        let store = makeStore()
        let job = store.createJob(name: "Smith Kitchen", address: "1 Main St", client: "Smith", notes: "Gate code 1234")
        XCTAssertEqual(makeStore().job(job.id)?.name, "Smith Kitchen")
        store.deleteJob(job.id)
        XCTAssertNil(makeStore().job(job.id))
    }

    func testPDFHasTwoPages() throws {
        let plan = SampleData.bedroom()
        let context = ExportService.Context(jobName: "Test", address: "", client: "", roomTitle: plan.name,
                                            date: Date(), source: "Sample data")
        let data = PDFPlanRenderer.render(plan: plan, takeoff: TakeoffCalculator.calculate(plan), context: context, units: .imperial)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertEqual(document.numberOfPages, 2)
    }

    func testUSDZExportIsAnAlignedUSDZThatSceneKitLoads() throws {
        // model.usdz comes from AsBuiltCore's USDA writer + USDZ packager (never SCNScene.write).
        let url = try ExportService.writeRoomModel(plan: SampleData.kitchen(), to: root)
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 500)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04]) // "PK": USDZ is a zip package
        let nameLength = Int(data[26]) | Int(data[27]) << 8
        let extraLength = Int(data[28]) | Int(data[29]) << 8
        XCTAssertEqual((30 + nameLength + extraLength) % 64, 0, "USDZ payload must be 64-byte aligned")
        XCTAssertEqual(String(decoding: data[30..<(30 + nameLength)], as: UTF8.self), "model.usda")

        // The in-app viewer path: SceneKit's USD importer reads it back with real geometry.
        let scene = try SCNScene(url: url, options: [.checkConsistency: false])
        var geometryNodes = 0
        scene.rootNode.enumerateHierarchy { node, _ in if node.geometry != nil { geometryNodes += 1 } }
        XCTAssertEqual(geometryNodes, RoomModelBuilder.meshes(for: SampleData.kitchen()).count)
        let (minV, maxV) = scene.rootNode.boundingBox
        XCTAssertGreaterThan(maxV.x - minV.x, 3)
        XCTAssertGreaterThan(maxV.y - minV.y, 2.5)
    }

    func testZipBundlesFolders() async throws {
        let store = makeStore()
        store.ensureDemoJob()
        await store.prepareDemoExports()
        let files = store.files(job: SampleData.demoJobID, capture: SampleData.demoCaptureID)
        let zip = try ExportService.makeZip(files: files, archiveName: "Demo Bedroom", folderName: "Bedroom-2")
        let data = try Data(contentsOf: zip)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertNotNil(data.range(of: Data("Bedroom-2/floorplan.dxf".utf8)))
    }

    func testRouterLaunchPaths() {
        XCTAssertEqual(Router.initialPath(for: nil), [])
        XCTAssertEqual(Router.initialPath(for: "plan").count, 2)
        if case .capture(_, _, let tab) = Router.initialPath(for: "takeoff").last {
            XCTAssertEqual(tab, .takeoff)
        } else {
            XCTFail("takeoff route missing")
        }
    }

    func testCapabilitiesInSimulatorAreHonest() {
        let caps = DeviceCapabilities.current()
        #if targetEnvironment(simulator)
        XCTAssertTrue(caps.isSimulator)
        XCTAssertFalse(caps.roomPlanSupported)
        XCTAssertFalse(caps.objectCaptureSupported)
        XCTAssertNotNil(caps.roomScanBlocker)
        XCTAssertNotNil(caps.objectCaptureBlocker)
        #endif
    }

    // MARK: LiDAR Mesh scans and model decoding (build 5)

    /// job.json exactly as builds 1-4 wrote it (no mesh kind, no measurements/attempts keys).
    private static let build4JobJSON = """
    {
      "address" : "1 Main St",
      "captures" : [
        {
          "createdAt" : "2026-10-22T18:01:02Z",
          "id" : "11111111-2222-4333-8444-555555555555",
          "imageCount" : 14,
          "kind" : "object",
          "notes" : "",
          "origin" : "objectCapture",
          "status" : "imagesOnly",
          "statusMessage" : "Reconstruction failed (The operation couldn’t be completed. (CoreOC.PhotogrammetrySession.Error error 6.)). Photos saved: reconstruct on a Mac.",
          "title" : "Object 1"
        },
        {
          "createdAt" : "2026-10-22T17:00:00Z",
          "id" : "11111111-2222-4333-8444-666666666666",
          "kind" : "room",
          "notes" : "",
          "origin" : "roomPlan",
          "status" : "complete",
          "title" : "Kitchen"
        }
      ],
      "client" : "Smith",
      "createdAt" : "2026-10-22T16:00:00Z",
      "id" : "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
      "isDemo" : false,
      "name" : "Smith Kitchen",
      "notes" : "",
      "updatedAt" : "2026-10-22T18:05:00Z"
    }
    """

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func testBuild4JobJSONStillDecodes() throws {
        let job = try Self.decoder().decode(Job.self, from: Data(Self.build4JobJSON.utf8))
        XCTAssertEqual(job.captures.count, 2)
        XCTAssertEqual(job.objectCaptures.first?.status, .imagesOnly)
        XCTAssertEqual(job.objectCaptures.first?.imageCount, 14)
        XCTAssertNil(job.objectCaptures.first?.measurements)
        XCTAssertNil(job.objectCaptures.first?.reconstructionAttempts)
        XCTAssertEqual(job.roomCaptures.first?.origin, .roomPlan)
        XCTAssertTrue(job.meshCaptures.isEmpty)

        // And the store loads such a file from disk.
        let dir = root.appendingPathComponent(job.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(Self.build4JobJSON.utf8).write(to: dir.appendingPathComponent("job.json"))
        XCTAssertEqual(makeStore().job(job.id)?.captures.count, 2)
    }

    func testUnknownFutureValuesDoNotDropTheJob() throws {
        let json = Self.build4JobJSON
            .replacingOccurrences(of: "\"kind\" : \"object\"", with: "\"kind\" : \"pointCloud\"")
            .replacingOccurrences(of: "\"origin\" : \"roomPlan\"", with: "\"origin\" : \"satellite\"")
            .replacingOccurrences(of: "\"status\" : \"complete\"", with: "\"status\" : \"queued\"")
        let job = try Self.decoder().decode(Job.self, from: Data(json.utf8))
        XCTAssertEqual(job.captures.count, 2)
        XCTAssertEqual(job.captures[0].kind, .object)
        XCTAssertEqual(job.captures[1].origin, .unknown)
        XCTAssertEqual(job.captures[1].status, .failed)
    }

    func testMeshCaptureRoundTrip() throws {
        let m = DemoMeshScan.bedroomMesh().measurements
        let capture = Capture(kind: .mesh, origin: .lidarMesh, title: "Mech room", measurements: m, reconstructionAttempts: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let back = try Self.decoder().decode(Capture.self, from: encoder.encode(capture))
        XCTAssertEqual(back.kind, .mesh)
        XCTAssertEqual(back.origin, .lidarMesh)
        XCTAssertEqual(back.measurements, m)
        XCTAssertEqual(back.measurements?.triangleCount, m.triangleCount)
    }

    func testDemoJobHasLiDARMeshScanWithExports() async throws {
        let store = makeStore()
        store.ensureDemoJob()
        let job = try XCTUnwrap(store.job(SampleData.demoJobID))
        XCTAssertEqual(job.meshCaptures.map(\.id), [SampleData.demoMeshCaptureID, SampleData.demoDetailCaptureID])
        // Launch path: JSON only, no mesh files yet.
        XCTAssertNil(store.modelURL(job: job.id, capture: SampleData.demoMeshCaptureID))

        await store.prepareDemoExports()
        XCTAssertEqual(store.demoStatus, .ready)
        let names = Set(store.files(job: job.id, capture: SampleData.demoMeshCaptureID).map(\.lastPathComponent))
        for expected in [CaptureFile.modelUSDZ, CaptureFile.meshOBJ, CaptureFile.meshMTL, CaptureFile.meshPLY,
                         CaptureFile.meshCSV, CaptureFile.scanInfo] {
            XCTAssertTrue(names.contains(expected), "missing \(expected), have \(names)")
        }
        let m = try XCTUnwrap(store.meshMeasurements(job: job.id, capture: SampleData.demoMeshCaptureID))
        XCTAssertEqual(m.width, 14 * 0.3048, accuracy: 0.015)
        XCTAssertEqual(m.depth, 12 * 0.3048, accuracy: 0.015)
        XCTAssertEqual(m.height, 8 * 0.3048, accuracy: 0.015)
        XCTAssertNotNil(store.capture(job: job.id, capture: SampleData.demoMeshCaptureID)?.measurements)

        // The 3D tab viewer path: SceneKit loads the mesh USDZ with one node per surface class.
        let url = try XCTUnwrap(store.modelURL(job: job.id, capture: SampleData.demoMeshCaptureID))
        XCTAssertTrue(JobStore.isCurrentRoomModel(url))
        let scene = try SCNScene(url: url, options: [.checkConsistency: false])
        var geometryNodes = 0
        scene.rootNode.enumerateHierarchy { node, _ in if node.geometry != nil { geometryNodes += 1 } }
        XCTAssertGreaterThanOrEqual(geometryNodes, MeshClass.allCases.count - 1)
        let (minV, maxV) = scene.rootNode.boundingBox
        XCTAssertEqual(Double(maxV.y - minV.y), 8 * 0.3048, accuracy: 0.05)

        // Units switch rewrites measurements.csv.
        let csvURL = store.captureDirectory(job: job.id, capture: SampleData.demoMeshCaptureID).appendingPathComponent(CaptureFile.meshCSV)
        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        XCTAssertTrue(csv.contains("Width (X, longest side)"))
    }

    func testOldDemoJobGainsTheMeshScan() throws {
        let store = makeStore()
        store.ensureDemoJob()
        var job = try XCTUnwrap(store.job(SampleData.demoJobID))
        job.captures.removeAll { $0.kind == .mesh } // what builds <= 4 left on disk
        store.save(job, touch: false)
        XCTAssertTrue(makeStore().job(SampleData.demoJobID)?.meshCaptures.isEmpty == true)
        let relaunch = makeStore()
        relaunch.ensureDemoJob()
        XCTAssertEqual(relaunch.job(SampleData.demoJobID)?.meshCaptures.count, 2)
        XCTAssertEqual(relaunch.job(SampleData.demoJobID)?.roomCaptures.count, 2)
    }

    func testMeshStageCrashLoopBreaker() async throws {
        defaults.set(JobStore.DemoStage.mesh.rawValue, forKey: JobStore.demoInFlightKey)
        let store = makeStore()
        store.ensureDemoJob()
        await store.prepareDemoExports()
        XCTAssertNotNil(store.demoNotice)
        XCTAssertNil(store.modelURL(job: SampleData.demoJobID, capture: SampleData.demoMeshCaptureID))
        XCTAssertNotNil(store.modelURL(job: SampleData.demoJobID, capture: SampleData.demoCaptureID))
        XCTAssertEqual(Router.initialPath(for: "mesh").count, 2)
        XCTAssertEqual(Router.initialPath(for: "mesh-files").count, 2)
    }

    func testReconstructionMessageIsPlainLanguage() {
        let e = ReconstructionErrorExplainer.explain(domain: "CoreOC.PhotogrammetrySession.Error", code: 6, imageCount: 80)
        XCTAssertFalse(e.message.contains("CoreOC"))
        XCTAssertTrue(e.message.contains("line up the photos"))
        XCTAssertTrue(e.technical.contains("processError"))
    }

    // MARK: Build 6

    func testBuild5JobJSONDecodesWithoutMeasurements() throws {
        // build4JobJSON has neither `measurements` nor `measureScale` nor coach fields (builds 1-5).
        let job = try Self.decoder().decode(Job.self, from: Data(Self.build4JobJSON.utf8))
        XCTAssertTrue(job.measurements.isEmpty)
        XCTAssertNil(job.measureScale)
        XCTAssertEqual(job.effectiveMeasureScale, 1)
        XCTAssertNil(job.captures.first?.coachGrade)
        XCTAssertFalse(job.captures.contains { $0.isDetailScan })
    }

    func testMeasurementsAndCalibrationRoundTrip() throws {
        let store = makeStore()
        let job = Job(name: "Measure test")
        store.save(job)
        let m = PrecisionMeasurement(label: "Header", start: SIMD3(0, 0, 0), end: SIMD3(1.0, 0, 0),
                                     uncertaintyMeters: 0.002, samples: 24, method: "sceneDepth")
        store.addMeasurement(m, to: job.id)
        // Tape says 1.010 m: scale 1.01, raw value kept.
        XCTAssertTrue(store.calibrate(measurement: m.id, tapeMeters: 1.010, in: job.id))
        XCTAssertFalse(store.calibrate(measurement: m.id, tapeMeters: 3.0, in: job.id), "implausible tape length rejected")
        let reloaded = try XCTUnwrap(makeStore().job(job.id))
        XCTAssertEqual(reloaded.measurements.count, 1)
        XCTAssertEqual(reloaded.measureScale ?? 0, 1.01, accuracy: 1e-9)
        XCTAssertEqual(reloaded.measurements[0].rawMeters, 1.0, accuracy: 1e-6)
        XCTAssertEqual(reloaded.measurements[0].tapeMeters ?? 0, 1.010, accuracy: 1e-9)
        XCTAssertEqual(reloaded.measurements[0].calibratedMeters(scale: reloaded.measureScale), 1.01, accuracy: 1e-6)
        store.deleteMeasurement(m.id, in: job.id)
        XCTAssertNil(makeStore().job(job.id)?.measureScale, "calibration goes with its measurement")
    }

    func testJobZipContainsMeasurementsCSV() async throws {
        let store = makeStore()
        store.ensureDemoJob()
        let job = try XCTUnwrap(store.job(SampleData.demoJobID))
        XCTAssertFalse(job.measurements.isEmpty)
        let zip = try store.makeJobZip(job.id)
        let data = try Data(contentsOf: zip)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertNotNil(data.range(of: Data(PrecisionMeasurementsCSV.fileName.utf8)))
    }

    func testDemoDetailScanIsRealFusionWithColoredExports() async throws {
        let store = makeStore()
        store.ensureDemoJob()
        await store.prepareDemoExports()
        XCTAssertEqual(store.demoStatus, .ready)
        let id = SampleData.demoDetailCaptureID
        let capture = try XCTUnwrap(store.capture(job: SampleData.demoJobID, capture: id))
        XCTAssertTrue(capture.isDetailScan)
        let names = Set(store.files(job: SampleData.demoJobID, capture: id).map(\.lastPathComponent))
        for expected in [CaptureFile.modelUSDZ, CaptureFile.meshOBJ, CaptureFile.meshPLY, CaptureFile.meshCSV, CaptureFile.coachReport] {
            XCTAssertTrue(names.contains(expected), "missing \(expected), have \(names)")
        }
        let dir = store.captureDirectory(job: SampleData.demoJobID, capture: id)
        let ply = try Data(contentsOf: dir.appendingPathComponent(CaptureFile.meshPLY))
        XCTAssertNotNil(ply.range(of: Data("property uchar red".utf8)), "PLY carries vertex colors")
        let url = try XCTUnwrap(store.modelURL(job: SampleData.demoJobID, capture: id))
        let scene = try SCNScene(url: url, options: [.checkConsistency: false])
        var geometryNodes = 0
        scene.rootNode.enumerateHierarchy { node, _ in if node.geometry != nil { geometryNodes += 1 } }
        XCTAssertGreaterThanOrEqual(geometryNodes, 1)
        XCTAssertEqual(Router.initialPath(for: "detail").count, 2)
        XCTAssertEqual(Router.initialPath(for: "measurements").count, 2)
        XCTAssertEqual(Router.initialPath(for: "coach-grade").count, 1)
    }

    func testDetailStageCrashLoopBreaker() async throws {
        defaults.set(JobStore.DemoStage.detail.rawValue, forKey: JobStore.demoInFlightKey)
        let store = makeStore()
        store.ensureDemoJob()
        await store.prepareDemoExports()
        XCTAssertNotNil(store.demoNotice)
        XCTAssertNil(store.modelURL(job: SampleData.demoJobID, capture: SampleData.demoDetailCaptureID))
        XCTAssertNotNil(store.modelURL(job: SampleData.demoJobID, capture: SampleData.demoMeshCaptureID))
    }

    func testPhotoZipStreamsImages() throws {
        let dir = root.appendingPathComponent("oc", isDirectory: true)
        let images = dir.appendingPathComponent(CaptureFile.images, isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        for k in 0..<3 {
            try Data(repeating: UInt8(k), count: 200_000 + k).write(to: images.appendingPathComponent("IMG_\(k).HEIC"))
        }
        let zip = try ExportService.makePhotoZip(captureDirectory: dir, title: "Valve")
        let data = try Data(contentsOf: zip)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertNotNil(data.range(of: Data("Valve-photos/Images/IMG_2.HEIC".utf8)))
        XCTAssertGreaterThan(data.count, 600_000)
    }
}
