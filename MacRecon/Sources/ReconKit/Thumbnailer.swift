import AppKit
import Foundation
import Metal
import SceneKit

/// Offscreen SceneKit render of a model from four angles into one PNG, for a quick visual check
/// (qlmanage can hang in headless sessions; this needs only Metal).
public enum Thumbnailer {
    public static func render(model: URL, to png: URL, size: Int = 1024) throws {
        let scene = try SCNScene(url: model, options: [.checkConsistency: false])
        let (mn, mx) = scene.rootNode.boundingBox
        let c = SCNVector3((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, (mn.z + mx.z) / 2)
        let ext = max(mx.x - mn.x, mx.y - mn.y, mx.z - mn.z, 1e-4)
        guard let device = MTLCreateSystemDefaultDevice() else { throw UsageError("no Metal device for thumbnail") }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = true
        scene.background.contents = NSColor(white: 0.93, alpha: 1)

        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera!.zNear = Double(ext) * 0.01
        cam.camera!.zFar = Double(ext) * 50
        cam.camera!.fieldOfView = 40
        scene.rootNode.addChildNode(cam)
        renderer.pointOfView = cam

        let tile = size / 2
        let d = ext * 1.6
        // front-left high, front-right high, back, top-down
        let dirs: [SCNVector3] = [
            SCNVector3(-0.7, 0.5, 1.0), SCNVector3(0.9, 0.4, 0.8), SCNVector3(0.2, 0.3, -1.0), SCNVector3(0.01, 1.0, 0.05),
        ]
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw UsageError("no CGContext") }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        for (i, v) in dirs.enumerated() {
            let len = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
            cam.position = SCNVector3(c.x + v.x / len * d, c.y + v.y / len * d, c.z + v.z / len * d)
            cam.look(at: c, up: abs(v.y / len) > 0.95 ? SCNVector3(0, 0, -1) : SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
            let img = renderer.snapshot(atTime: 0, with: CGSize(width: tile, height: tile), antialiasingMode: .multisampling4X)
            guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let x = (i % 2) * tile, y = (1 - i / 2) * tile
            ctx.draw(cg, in: CGRect(x: x, y: y, width: tile, height: tile))
        }
        guard let out = ctx.makeImage() else { throw UsageError("thumbnail compose failed") }
        let rep = NSBitmapImageRep(cgImage: out)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw UsageError("png encode failed") }
        try data.write(to: png)
    }
}
