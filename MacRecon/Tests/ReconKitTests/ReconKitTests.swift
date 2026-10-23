import Foundation
import Testing
@testable import ReconKit

@Test func parsesDefaults() throws {
    let o = try BuildOptions.parse(["photos.zip"])
    #expect(o.input == "photos.zip")
    #expect(o.detail == .full)
    #expect(o.shouldAutoRetry)
    #expect(AttemptPlan.plan(for: o).count == 2)
    #expect(AttemptPlan.plan(for: o)[1] == AttemptPlan(number: 2, ordering: .sequential, sensitivity: .high, masking: false))
}

@Test func customFlagsImplyCustomDetail() throws {
    let o = try BuildOptions.parse(["in", "--texture", "8k", "--max-polys", "2m"])
    #expect(o.detail == .custom)
    #expect(o.effectiveMaxPolys == 2_000_000)
    #expect(o.effectiveTexture.pixels == 8192)
    #expect(o.effectiveMaps == TextureMap.allCases)
    #expect(throws: UsageError.self) { try BuildOptions.parse(["in", "--detail", "raw", "--texture", "8k"]) }
}

@Test func explicitAlignmentFlagsDisableRetry() throws {
    #expect(!(try BuildOptions.parse(["in", "--ordering", "sequential"])).shouldAutoRetry)
    #expect(!(try BuildOptions.parse(["in", "--no-masking"])).shouldAutoRetry)
    #expect(!(try BuildOptions.parse(["in", "--no-retry"])).shouldAutoRetry)
    #expect(AttemptPlan.plan(for: try BuildOptions.parse(["in", "--sensitivity", "high"])).count == 1)
}

@Test func rejectsBadInput() {
    #expect(throws: UsageError.self) { try BuildOptions.parse([]) }
    #expect(throws: UsageError.self) { try BuildOptions.parse(["a", "b"]) }
    #expect(throws: UsageError.self) { try BuildOptions.parse(["a", "--detail", "ultra"]) }
    #expect(throws: UsageError.self) { try BuildOptions.parse(["a", "--bogus"]) }
    #expect(BuildOptions.parseCount("500k") == 500_000)
    #expect(BuildOptions.parseCount("x") == nil)
}

@Test func errorTables() {
    #expect(ErrorExplainer.caseName(domain: "CoreOC.PhotogrammetrySession.Error", code: 6) == "processError")
    #expect(ErrorExplainer.caseName(domain: "CoreOC.PhotogrammetrySession.Error", code: 7) == "storageFull")
    #expect(ErrorExplainer.caseName(domain: "CoreOC.PhotogrammetrySession.Error", code: 8) == nil)
    #expect(ErrorExplainer.caseName(domain: "RealityFoundation.PhotogrammetrySession.Error", code: 2) == "insufficientStorage")
    let e = ErrorExplainer.explain(domain: "CoreOC.PhotogrammetrySession.Error", code: 6, imageCount: 60)
    #expect(e.kind == .alignment)
    #expect(e.technical == "CoreOC.PhotogrammetrySession.Error.processError (code 6)")
    #expect(!e.message.contains("CoreOC"))
    #expect(ErrorExplainer.explain(domain: "CoreOC.PhotogrammetrySession.Error", code: 6, imageCount: 8).kind == .tooFewImages)
    #expect(ErrorExplainer.explain(domain: "CoreOC.PhotogrammetrySession.Error", code: 7).kind == .storage)
}

@Test func objParser() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("objtest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let obj = dir.appendingPathComponent("m.obj")
    try "mtllib m.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nv 1 1 0\nvt 0 0\nvn 0 0 1\nf 1/1/1 2/1/1 3/1/1\nf 2 4 3 1\n".write(to: obj, atomically: true, encoding: .utf8)
    let s = ModelInspector.objStats(obj)
    #expect(s.faces == 2)
    #expect(s.points == 4)
    #expect(s.triangles == 3)
    #expect(s.extent == [0, 0, 0, 1, 1, 0])
}
