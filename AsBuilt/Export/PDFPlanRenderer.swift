import UIKit
import AsBuiltCore

/// Two-page US Letter landscape PDF: (1) plan sheet with title block and legend, (2) takeoff.
enum PDFPlanRenderer {
    static let pageSize = CGSize(width: 792, height: 612)

    static func render(plan: FloorPlan, takeoff: RoomTakeoff, context: ExportService.Context, units: UnitSystem) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "\(context.jobName) - \(context.roomTitle)",
            kCGPDFContextCreator as String: "AsBuilt",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize), format: format)
        return renderer.pdfData { pdf in
            pdf.beginPage()
            drawPlanPage(pdf.cgContext, plan: plan, takeoff: takeoff, context: context, units: units)
            pdf.beginPage()
            drawTakeoffPage(pdf.cgContext, takeoff: takeoff, context: context, units: units)
        }
    }

    // MARK: Page 1

    static func drawPlanPage(_ ctx: CGContext, plan: FloorPlan, takeoff: RoomTakeoff,
                             context: ExportService.Context, units: UnitSystem) {
        let margin: CGFloat = 28
        let titleBlockWidth: CGFloat = 200
        let frame = CGRect(x: margin, y: margin, width: pageSize.width - 2 * margin, height: pageSize.height - 2 * margin)
        ctx.setStrokeColor(UIColor.black.cgColor)
        ctx.setLineWidth(1.2)
        ctx.stroke(frame)

        // Plan area.
        let planRect = CGRect(x: frame.minX, y: frame.minY, width: frame.width - titleBlockWidth, height: frame.height)
        let drawing = PlanGeometryBuilder.build(plan, units: units)
        let viewport = PlanViewport(bounds: drawing.bounds, width: Double(planRect.width), height: Double(planRect.height),
                                    padding: 24, originX: Double(planRect.minX), originY: Double(planRect.minY))
        PlanCGDrawer.draw(drawing, in: ctx, viewport: viewport, options: .init(lineScale: 0.9, textScale: 1, minFontSize: 5))

        // Scale bar (5 ft or 1 m).
        let barMeters = units == .imperial ? UnitFormatter.meters(feet: 5) : 1.0
        let barLength = CGFloat(barMeters * viewport.scale)
        let barOrigin = CGPoint(x: planRect.minX + 18, y: planRect.maxY - 22)
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(x: barOrigin.x, y: barOrigin.y, width: barLength / 2, height: 4))
        ctx.stroke(CGRect(x: barOrigin.x, y: barOrigin.y, width: barLength, height: 4))
        text(units == .imperial ? "0     5 ft" : "0     1 m", at: CGPoint(x: barOrigin.x, y: barOrigin.y - 12), size: 7)
        text("N ↑", at: CGPoint(x: planRect.minX + 18, y: planRect.minY + 14), size: 10, weight: .bold)

        // Title block.
        let tb = CGRect(x: planRect.maxX, y: frame.minY, width: titleBlockWidth, height: frame.height)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: tb.minX, y: tb.minY))
        ctx.addLine(to: CGPoint(x: tb.minX, y: tb.maxY))
        ctx.strokePath()

        var y = tb.minY + 12
        let x = tb.minX + 12
        let w = tb.width - 24
        y = block("ASBUILT", value: "Field-measured floor plan", x: x, y: y, width: w, titleSize: 15)
        y = rule(ctx, y: y, from: tb.minX, to: tb.maxX)
        y = block("PROJECT", value: context.jobName, x: x, y: y, width: w)
        if !context.address.isEmpty { y = block("ADDRESS", value: context.address, x: x, y: y, width: w) }
        if !context.client.isEmpty { y = block("CLIENT", value: context.client, x: x, y: y, width: w) }
        y = rule(ctx, y: y, from: tb.minX, to: tb.maxX)
        y = block("ROOM", value: context.roomTitle, x: x, y: y, width: w)
        y = block("CAPTURED", value: context.dateText, x: x, y: y, width: w)
        y = block("SOURCE", value: context.source, x: x, y: y, width: w)
        y = rule(ctx, y: y, from: tb.minX, to: tb.maxX)
        y = block("FLOOR AREA", value: UnitFormatter.area(takeoff.floorArea, units), x: x, y: y, width: w)
        y = block("PERIMETER", value: UnitFormatter.length(takeoff.perimeter, units), x: x, y: y, width: w)
        y = block("CEILING", value: UnitFormatter.length(takeoff.ceilingHeight, units), x: x, y: y, width: w)
        y = block("OPENINGS", value: "\(takeoff.doorCount) door · \(takeoff.windowCount) window · \(takeoff.openingCount) opening",
                  x: x, y: y, width: w)
        y = rule(ctx, y: y, from: tb.minX, to: tb.maxX)

        // Legend.
        text("LAYERS", at: CGPoint(x: x, y: y), size: 7, weight: .bold, color: .darkGray)
        y += 12
        for layer in PlanLayer.allCases where layer != .text {
            ctx.setStrokeColor(layer.uiColor.cgColor)
            ctx.setLineWidth(2)
            if layer.isDashed { ctx.setLineDash(phase: 0, lengths: [4, 2]) }
            ctx.move(to: CGPoint(x: x, y: y + 5))
            ctx.addLine(to: CGPoint(x: x + 22, y: y + 5))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            text(layer.rawValue, at: CGPoint(x: x + 30, y: y), size: 8)
            y += 13
        }
        let footer = "Dimensions are interior wall faces. Verify on site before fabrication. Sheet 1 of 2."
        let attributed = NSAttributedString(string: footer, attributes: [.font: UIFont.systemFont(ofSize: 6.5), .foregroundColor: UIColor.darkGray])
        attributed.draw(with: CGRect(x: x, y: tb.maxY - 34, width: w, height: 30), options: .usesLineFragmentOrigin, context: nil)
    }

    // MARK: Page 2

    static func drawTakeoffPage(_ ctx: CGContext, takeoff: RoomTakeoff, context: ExportService.Context, units: UnitSystem) {
        let margin: CGFloat = 36
        var y = margin
        text("Quantity Takeoff — \(context.roomTitle)", at: CGPoint(x: margin, y: y), size: 18, weight: .bold)
        y += 24
        text("\(context.jobName) · \(context.address) · \(context.dateText)", at: CGPoint(x: margin, y: y), size: 9, color: .darkGray)
        y += 22

        let summary = [
            ("Floor area", UnitFormatter.area(takeoff.floorArea, units)),
            ("Perimeter", UnitFormatter.length(takeoff.perimeter, units)),
            ("Ceiling height", UnitFormatter.length(takeoff.ceilingHeight, units)),
            ("Gross wall area", UnitFormatter.area(takeoff.grossWallArea, units)),
            ("Net wall area", UnitFormatter.area(takeoff.netWallArea, units)),
            ("Doors / windows / openings", "\(takeoff.doorCount) / \(takeoff.windowCount) / \(takeoff.openingCount)"),
        ]
        let colW = (pageSize.width - 2 * margin) / 3
        for (i, item) in summary.enumerated() {
            let cx = margin + CGFloat(i % 3) * colW
            let cy = y + CGFloat(i / 3) * 34
            text(item.0.uppercased(), at: CGPoint(x: cx, y: cy), size: 7, weight: .bold, color: .darkGray)
            text(item.1, at: CGPoint(x: cx, y: cy + 10), size: 13, weight: .semibold)
        }
        y += 76

        // Walls table.
        let headers = ["Wall", "Length", "Height", "Gross", "Openings", "Net", "Hosted"]
        let widths: [CGFloat] = [50, 90, 90, 100, 100, 100, 190]
        y = table(ctx, title: "WALLS", headers: headers, widths: widths, rows: takeoff.walls.map { wall in
            [wall.label, UnitFormatter.length(wall.length, units), UnitFormatter.length(wall.height, units),
             UnitFormatter.area(wall.grossArea, units), UnitFormatter.area(wall.openingArea, units),
             UnitFormatter.area(wall.netArea, units), wall.openingTags.joined(separator: ", ")]
        } + [["Total", UnitFormatter.length(takeoff.walls.reduce(0) { $0 + $1.length }, units), "",
              UnitFormatter.area(takeoff.grossWallArea, units), UnitFormatter.area(takeoff.openingArea, units),
              UnitFormatter.area(takeoff.netWallArea, units), ""]], x: margin, y: y, boldLast: true)
        y += 12

        let materialHeaders = ["Material", "Quantity", "Order", "Basis"]
        let materialWidths: [CGFloat] = [130, 90, 80, 420]
        y = table(ctx, title: "MATERIALS (INCLUDES \(Int((takeoff.options.wasteFactor * 100).rounded()))% WASTE)",
                  headers: materialHeaders, widths: materialWidths, rows: takeoff.materials.map { m in
            [m.name, "\(UnitFormatter.decimal(m.displayQuantity(units), 1)) \(m.unit(units))",
             "\(m.orderQuantity(units)) \(m.unit(units))", m.formula(units)]
        }, x: margin, y: y)
        y += 12

        if !takeoff.openings.isEmpty {
            let oh = ["Tag", "Type", "Wall", "Width", "Height", "Sill"]
            let ow: [CGFloat] = [60, 90, 60, 100, 100, 100]
            _ = table(ctx, title: "DOORS, WINDOWS & OPENINGS", headers: oh, widths: ow, rows: takeoff.openings.map { o in
                [o.tag, o.kind.displayName, o.wallNumber.map { "W\($0)" } ?? "-", UnitFormatter.length(o.width, units),
                 UnitFormatter.length(o.height, units), o.kind == .window ? UnitFormatter.length(o.sillHeight, units) : "-"]
            }, x: margin, y: y)
        }
        text("Generated by AsBuilt. Estimates are for budgeting; confirm quantities before ordering. Sheet 2 of 2.",
             at: CGPoint(x: margin, y: pageSize.height - margin), size: 7, color: .darkGray)
    }

    // MARK: Helpers

    @discardableResult
    static func text(_ string: String, at point: CGPoint, size: CGFloat, weight: UIFont.Weight = .regular,
                     color: UIColor = .black) -> CGSize {
        let attributed = NSAttributedString(string: string, attributes: [.font: UIFont.systemFont(ofSize: size, weight: weight),
                                                                          .foregroundColor: color])
        attributed.draw(at: point)
        return attributed.size()
    }

    static func block(_ title: String, value: String, x: CGFloat, y: CGFloat, width: CGFloat, titleSize: CGFloat = 10) -> CGFloat {
        text(title, at: CGPoint(x: x, y: y), size: title == "ASBUILT" ? titleSize : 6.5, weight: .bold,
             color: title == "ASBUILT" ? UIColor(red: 0.88, green: 0.33, blue: 0, alpha: 1) : .darkGray)
        let attributed = NSAttributedString(string: value, attributes: [.font: UIFont.systemFont(ofSize: 9, weight: .medium),
                                                                         .foregroundColor: UIColor.black])
        let top = y + (title == "ASBUILT" ? titleSize + 6 : 9)
        let rect = attributed.boundingRect(with: CGSize(width: width, height: 60), options: .usesLineFragmentOrigin, context: nil)
        attributed.draw(with: CGRect(x: x, y: top, width: width, height: rect.height + 2), options: .usesLineFragmentOrigin, context: nil)
        return top + ceil(rect.height) + 7
    }

    static func rule(_ ctx: CGContext, y: CGFloat, from x0: CGFloat, to x1: CGFloat) -> CGFloat {
        ctx.setStrokeColor(UIColor.black.cgColor)
        ctx.setLineWidth(0.6)
        ctx.move(to: CGPoint(x: x0, y: y))
        ctx.addLine(to: CGPoint(x: x1, y: y))
        ctx.strokePath()
        return y + 8
    }

    static func table(_ ctx: CGContext, title: String, headers: [String], widths: [CGFloat], rows: [[String]],
                      x: CGFloat, y: CGFloat, boldLast: Bool = false) -> CGFloat {
        var y = y
        text(title, at: CGPoint(x: x, y: y), size: 8, weight: .bold, color: UIColor(red: 0.88, green: 0.33, blue: 0, alpha: 1))
        y += 14
        let total = widths.reduce(0, +)
        ctx.setFillColor(UIColor(white: 0.92, alpha: 1).cgColor)
        ctx.fill(CGRect(x: x, y: y - 2, width: total, height: 15))
        var cx = x
        for (h, w) in zip(headers, widths) {
            text(h, at: CGPoint(x: cx + 4, y: y), size: 8, weight: .bold)
            cx += w
        }
        y += 16
        for (index, row) in rows.enumerated() {
            let bold = boldLast && index == rows.count - 1
            if index % 2 == 1 {
                ctx.setFillColor(UIColor(white: 0.97, alpha: 1).cgColor)
                ctx.fill(CGRect(x: x, y: y - 2, width: total, height: 14))
            }
            cx = x
            for (value, w) in zip(row, widths) {
                let attributed = NSAttributedString(string: value, attributes: [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 8, weight: bold ? .bold : .regular),
                    .foregroundColor: UIColor.black])
                attributed.draw(with: CGRect(x: cx + 4, y: y, width: w - 6, height: 12),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
                cx += w
            }
            y += 14
        }
        ctx.setStrokeColor(UIColor(white: 0.7, alpha: 1).cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: x, y: y))
        ctx.addLine(to: CGPoint(x: x + total, y: y))
        ctx.strokePath()
        return y + 6
    }
}
