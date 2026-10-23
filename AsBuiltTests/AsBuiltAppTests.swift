import XCTest
import AsBuiltCore
@testable import AsBuilt

/// App-level tests that need UIKit/SceneKit (run in the iOS Simulator in CI).
@MainActor
final class AsBuiltAppTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AsBuiltTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDemoJobIsCreatedWithAllExports() throws {
        let store = JobStore(rootURL: root)
        store.ensureDemoJob()
        let job = try XCTUnwrap(store.job(SampleData.demoJobID))
        XCTAssertTrue(job.isDemo)
        XCTAssertEqual(job.roomCaptures.count, 2)

        let names = Set(store.files(job: job.id, capture: SampleData.demoCaptureID).map(\.lastPathComponent))
        for expected in [CaptureFile.modelUSDZ, CaptureFile.dxf, CaptureFile.pdf, CaptureFile.csv, CaptureFile.svg, CaptureFile.planJSON] {
            XCTAssertTrue(names.contains(expected), "missing \(expected), have \(names)")
        }
    }

    func testPersistenceRoundTrip() throws {
        let store = JobStore(rootURL: root)
        let job = store.createJob(name: "Smith Kitchen", address: "1 Main St", client: "Smith", notes: "Gate code 1234")
        XCTAssertEqual(JobStore(rootURL: root).job(job.id)?.name, "Smith Kitchen")
        store.deleteJob(job.id)
        XCTAssertNil(JobStore(rootURL: root).job(job.id))
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

    func testUSDZExportIsAZipPackage() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("room.usdz")
        try SceneModelBuilder.writeUSDZ(plan: SampleData.kitchen(), to: url)
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 500)
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B]) // "PK": USDZ is a zip package
    }

    func testZipBundlesFolders() throws {
        let store = JobStore(rootURL: root)
        store.ensureDemoJob()
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
