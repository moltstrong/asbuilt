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
}
