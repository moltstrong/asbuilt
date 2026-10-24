// meshrender: render a USDZ from explicit cameras (Apple/SceneKit frame), unlit (texture only) or lit.
// usage: meshrender <model.usdz> <cameras.json> <outDir> [constant|app]
//        meshrender <model.usdz> --bbox
// cameras.json: [{"name": "...", "c2w": [16 floats, row-major 4x4, camera looks down -Z, +Y up],
//                 "fovY": degrees, "width": W, "height": H}]
// Output: <outDir>/<name>.png (RGBA; alpha = mesh coverage).
import AppKit
import Foundation
import SceneKit

let a = CommandLine.arguments
let scene = try SCNScene(url: URL(fileURLWithPath: a[1]), options: [.checkConsistency: false])
var tris = 0
scene.rootNode.enumerateHierarchy { n, _ in
    if let g = n.geometry { tris += g.elements.map(\.primitiveCount).reduce(0, +) }
}
let (mn, mx) = scene.rootNode.boundingBox
if a.count > 2 && a[2] == "--bbox" {
    print("{\"min\": [\(mn.x), \(mn.y), \(mn.z)], \"max\": [\(mx.x), \(mx.y), \(mx.z)], \"triangles\": \(tris)}")
    exit(0)
}
let mode = a.count > 4 ? a[4] : "constant"
scene.rootNode.enumerateHierarchy { n, _ in
    guard let g = n.geometry else { return }
    for m in g.materials where mode == "constant" { m.lightingModel = .constant }
}
let outDir = URL(fileURLWithPath: a[3], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let cams = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: a[2]))) as! [[String: Any]]
let camNode = SCNNode()
camNode.camera = SCNCamera()
camNode.camera!.zNear = 0.001
camNode.camera!.zFar = 1000
camNode.camera!.projectionDirection = .vertical
scene.rootNode.addChildNode(camNode)
if mode == "app" {
    let amb = SCNNode(); amb.light = SCNLight(); amb.light!.type = .ambient; amb.light!.intensity = 450
    scene.rootNode.addChildNode(amb)
}
scene.background.contents = NSColor.clear
let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
r.scene = scene
r.pointOfView = camNode
r.autoenablesDefaultLighting = (mode == "app")
print("triangles \(tris) bbox \(mn) \(mx)")
for c in cams {
    let name = c["name"] as! String
    let m = (c["c2w"] as! [Double]).map { Float($0) }
    // row-major -> simd columns
    let t = simd_float4x4(columns: (
        SIMD4(m[0], m[4], m[8], m[12]), SIMD4(m[1], m[5], m[9], m[13]),
        SIMD4(m[2], m[6], m[10], m[14]), SIMD4(m[3], m[7], m[11], m[15])))
    camNode.simdTransform = t
    camNode.camera!.fieldOfView = CGFloat(c["fovY"] as! Double)
    let w = c["width"] as! Int, h = c["height"] as! Int
    let t0 = Date()
    let img = r.snapshot(atTime: 0, with: CGSize(width: w, height: h), antialiasingMode: .multisampling4X)
    guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("no cgimage"); continue }
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = NSSize(width: w, height: h)
    try rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name + ".png"))
    print(String(format: "%@ %dx%d (cg %dx%d) %.2fs", name, w, h, cg.width, cg.height, Date().timeIntervalSince(t0)))
}
