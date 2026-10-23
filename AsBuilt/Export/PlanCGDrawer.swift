import UIKit
import AsBuiltCore

/// Draws a `PlanDrawing` into any CoreGraphics context (PDF pages, images, on-screen views).
enum PlanCGDrawer {
    struct Options {
        var showFills = true
        var hiddenLayers: Set<PlanLayer> = []
        var lineScale: CGFloat = 1
        var textScale: CGFloat = 1
        var minFontSize: CGFloat = 6
    }

    static func draw(_ drawing: PlanDrawing, in ctx: CGContext, viewport: PlanViewport, options: Options = Options()) {
        func pt(_ p: Point2D) -> CGPoint {
            let s = viewport.project(p)
            return CGPoint(x: s.x, y: s.y)
        }

        if options.showFills && !options.hiddenLayers.contains(.walls) {
            ctx.setFillColor(UIColor(red: 0.82, green: 0.84, blue: 0.86, alpha: 1).cgColor)
            for fill in drawing.fills where !options.hiddenLayers.contains(fill.layer) {
                guard let first = fill.points.first else { continue }
                ctx.beginPath()
                ctx.move(to: pt(first))
                for p in fill.points.dropFirst() { ctx.addLine(to: pt(p)) }
                ctx.closePath()
                ctx.fillPath()
            }
        }

        ctx.setLineCap(.round)
        for layer in PlanLayer.allCases where !options.hiddenLayers.contains(layer) {
            ctx.setStrokeColor(layer.uiColor.cgColor)
            ctx.setLineWidth(CGFloat(layer.lineWeight) * options.lineScale)
            if layer.isDashed { ctx.setLineDash(phase: 0, lengths: [6, 4]) } else { ctx.setLineDash(phase: 0, lengths: []) }

            for line in drawing.lines where line.layer == layer {
                ctx.beginPath()
                ctx.move(to: pt(line.a))
                ctx.addLine(to: pt(line.b))
                ctx.strokePath()
            }
            for poly in drawing.polylines where poly.layer == layer {
                guard let first = poly.points.first else { continue }
                ctx.beginPath()
                ctx.move(to: pt(first))
                for p in poly.points.dropFirst() { ctx.addLine(to: pt(p)) }
                if poly.closed { ctx.closePath() }
                ctx.strokePath()
            }
            for arc in drawing.arcs where arc.layer == layer {
                ctx.saveGState()
                ctx.setLineDash(phase: 0, lengths: [4, 3])
                ctx.beginPath()
                let steps = 24
                var sweep = arc.endAngle - arc.startAngle
                if sweep <= 0 { sweep += 360 }
                for i in 0...steps {
                    let a = (arc.startAngle + sweep * Double(i) / Double(steps)) * .pi / 180
                    let p = pt(arc.center + Point2D(cos(a), sin(a)) * arc.radius)
                    if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
                }
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
        ctx.setLineDash(phase: 0, lengths: [])

        UIGraphicsPushContext(ctx)
        for text in drawing.texts where !options.hiddenLayers.contains(text.layer) {
            let size = max(options.minFontSize, CGFloat(text.height * viewport.scale * 1.35) * options.textScale)
            let weight: UIFont.Weight = (text.role == .roomName || text.role == .dimension) ? .bold : .regular
            let font = UIFont.systemFont(ofSize: size, weight: weight)
            let color: UIColor = text.layer == .fixtures ? PlanLayer.fixtures.uiColor : text.layer.uiColor
            let attributed = NSAttributedString(string: text.text, attributes: [.font: font, .foregroundColor: color])
            let bounds = attributed.size()
            let center = pt(text.position)
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: CGFloat(viewport.screenRotation(text.rotation) * .pi / 180))
            attributed.draw(at: CGPoint(x: -bounds.width / 2, y: -bounds.height / 2))
            ctx.restoreGState()
        }
        UIGraphicsPopContext()
    }
}
