import SceneKit
import UIKit
import AsBuiltCore

/// Builds a simple 3D massing model of a `FloorPlan` (extruded walls with real openings, floor slab,
/// fixture blocks) and writes it as USDZ. Used for sample rooms and as a fallback when a RoomPlan
/// USDZ export is unavailable. Coordinates: plan (x, y) -> SceneKit (x, -z), y up, meters.
enum SceneModelBuilder {
    static func scene(for plan: FloorPlan) -> SCNScene {
        let scene = SCNScene()
        let root = scene.rootNode

        let wallMaterial = material(UIColor(white: 0.93, alpha: 1))
        let floorMaterial = material(UIColor(red: 0.74, green: 0.62, blue: 0.48, alpha: 1))
        let glassMaterial = material(UIColor(red: 0.55, green: 0.75, blue: 0.9, alpha: 0.45))
        let doorMaterial = material(UIColor(red: 0.62, green: 0.42, blue: 0.26, alpha: 1))
        let fixtureMaterial = material(UIColor(red: 0.45, green: 0.50, blue: 0.56, alpha: 1))

        // Floor slab from the resolved outline.
        let outline = plan.effectiveFloorPolygon
        if outline.count >= 3 {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: outline[0].x, y: outline[0].y))
            for p in outline.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
            path.close()
            let shape = SCNShape(path: path, extrusionDepth: 0.02)
            shape.materials = [floorMaterial]
            let node = SCNNode(geometry: shape)
            node.name = "Floor"
            // SCNShape lies in XY; rotate so plan +y maps to world -z.
            node.eulerAngles.x = -.pi / 2
            node.position.y = -0.01
            root.addChildNode(node)
        }

        let reference = plan.interiorReferencePoint
        for (index, wall) in plan.walls.enumerated() {
            let wallNode = SCNNode()
            wallNode.name = "W\(index + 1)"
            let dir = wall.direction
            let left = dir.leftNormal
            let inward = (reference - wall.midpoint).dot(left) >= 0 ? left : -left
            // Centerline is pushed outward by half the thickness from the interior face.
            let origin = wall.start - inward * (wall.thickness / 2)
            wallNode.simdPosition = SIMD3(Float(origin.x), 0, Float(-origin.y))
            wallNode.eulerAngles.y = Float(atan2(dir.y, dir.x))
            root.addChildNode(wallNode)

            let openings = plan.openings(onWall: wall.id)
            for piece in WallElevation.pieces(for: wall, openings: openings) {
                let box = SCNBox(width: CGFloat(piece.end - piece.start), height: CGFloat(piece.top - piece.bottom),
                                 length: CGFloat(wall.thickness), chamferRadius: 0)
                box.materials = [wallMaterial]
                let node = SCNNode(geometry: box)
                node.position = SCNVector3(Float((piece.start + piece.end) / 2), Float((piece.bottom + piece.top) / 2), 0)
                wallNode.addChildNode(node)
            }
            for opening in openings {
                guard let iv = WallElevation.interval(of: opening, wallLength: wall.length),
                      let v = WallElevation.verticalCut(of: opening, wallHeight: wall.height) else { continue }
                let width = CGFloat(iv.upperBound - iv.lowerBound)
                let height = CGFloat(v.upperBound - v.lowerBound)
                let cx = Float((iv.lowerBound + iv.upperBound) / 2)
                let cy = Float((v.lowerBound + v.upperBound) / 2)
                switch opening.kind {
                case .window:
                    let pane = SCNBox(width: width, height: height, length: 0.012, chamferRadius: 0)
                    pane.materials = [glassMaterial]
                    let node = SCNNode(geometry: pane)
                    node.position = SCNVector3(cx, cy, 0)
                    wallNode.addChildNode(node)
                case .door:
                    // Leaf shown open 70 degrees into the room.
                    let leaf = SCNBox(width: width, height: height, length: 0.04, chamferRadius: 0)
                    leaf.materials = [doorMaterial]
                    let hinge = SCNNode()
                    hinge.position = SCNVector3(Float(iv.lowerBound), 0, 0)
                    let toRoom: Float = dir.cross(inward) > 0 ? 1 : -1
                    hinge.eulerAngles.y = -toRoom * 70 * .pi / 180 * -1
                    let node = SCNNode(geometry: leaf)
                    node.position = SCNVector3(Float(width / 2), Float(height / 2), 0)
                    hinge.addChildNode(node)
                    wallNode.addChildNode(hinge)
                case .opening:
                    break
                }
            }
        }

        for fixture in plan.fixtures {
            let box = SCNBox(width: CGFloat(fixture.width), height: CGFloat(fixture.height),
                             length: CGFloat(fixture.depth), chamferRadius: 0.01)
            box.materials = [fixtureMaterial]
            let node = SCNNode(geometry: box)
            node.name = fixture.label
            node.simdPosition = SIMD3(Float(fixture.center.x), Float(fixture.height / 2), Float(-fixture.center.y))
            node.eulerAngles.y = Float(fixture.rotation)
            root.addChildNode(node)
        }
        return scene
    }

    static func writeUSDZ(plan: FloorPlan, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let ok = scene(for: plan).write(to: url, options: nil, delegate: nil, progressHandler: nil)
        if !ok || !FileManager.default.fileExists(atPath: url.path) {
            throw NSError(domain: "AsBuilt", code: 10, userInfo: [NSLocalizedDescriptionKey: "SceneKit could not write USDZ"])
        }
    }

    private static func material(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .physicallyBased
        m.roughness.contents = 0.8
        m.isDoubleSided = true
        if color.cgColor.alpha < 1 { m.transparency = color.cgColor.alpha }
        return m
    }
}
