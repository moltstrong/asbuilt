import SwiftUI
import AsBuiltCore

struct TakeoffView: View {
    let plan: FloorPlan
    let units: UnitSystem
    var scrollTarget: String?

    @AppStorage(Preferences.wasteKey) private var wastePercent: Double = 10
    @AppStorage(Preferences.coatsKey) private var coats: Int = 2

    var body: some View {
        let options = Preferences.options(wastePercent: wastePercent, coats: coats)
        let takeoff = TakeoffCalculator.calculate(plan, options: options)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summary(takeoff)
                    materials(takeoff).id("materials")
                    walls(takeoff).id("walls")
                    openings(takeoff).id("openings")
                    if !plan.fixtures.isEmpty { fixtures.id("fixtures") }
                    Text("Floor area source: \(takeoff.floorAreaSource.rawValue). Areas use interior wall faces; net wall area subtracts doors, windows and openings. Estimates include \(Int(wastePercent))% waste. Change assumptions in Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            .onAppear {
                if let scrollTarget {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { proxy.scrollTo(scrollTarget, anchor: .top) }
                }
            }
        }
        .accessibilityIdentifier("takeoffView")
    }

    private func summary(_ t: RoomTakeoff) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Room totals · \(plan.name)", systemImage: "square.dashed")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                StatTile(value: UnitFormatter.area(t.floorArea, units), label: "Floor area")
                StatTile(value: UnitFormatter.length(t.perimeter, units), label: "Perimeter")
                StatTile(value: UnitFormatter.length(t.ceilingHeight, units), label: "Ceiling height")
                StatTile(value: UnitFormatter.area(t.netWallArea, units), label: "Net wall area")
                StatTile(value: "\(t.doorCount) / \(t.windowCount) / \(t.openingCount)", label: "Doors / win / openings")
                StatTile(value: UnitFormatter.area(t.grossWallArea, units), label: "Gross wall area")
            }
        }
    }

    private func materials(_ t: RoomTakeoff) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Materials (+\(Int(wastePercent))% waste)", systemImage: "shippingbox")
            VStack(spacing: 0) {
                ForEach(Array(t.materials.enumerated()), id: \.element.id) { index, m in
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: icon(m.kind))
                            .font(.title3)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.name).font(.headline)
                            Text(m.formula(units)).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(m.orderQuantity(units))")
                                .font(.title2.weight(.heavy).monospacedDigit())
                            Text(m.unit(units)).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    if index < t.materials.count - 1 { Divider().padding(.leading, 56) }
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.card))
        }
    }

    private func walls(_ t: RoomTakeoff) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Walls", systemImage: "rectangle.split.3x1")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                GridRow {
                    header("Wall"); header("Length"); header("Height"); header("Net"); header("Gross")
                }
                .padding(.vertical, 8)
                Divider()
                ForEach(t.walls) { wall in
                    GridRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(wall.label).font(.headline)
                            if !wall.openingTags.isEmpty {
                                Text(wall.openingTags.joined(separator: " ")).font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                            }
                        }
                        cell(UnitFormatter.length(wall.length, units))
                        cell(UnitFormatter.length(wall.height, units))
                        cell(areaShort(wall.netArea)).fontWeight(.bold)
                        cell(areaShort(wall.grossArea)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 9)
                    Divider()
                }
                GridRow {
                    Text("Total").font(.headline)
                    cell(UnitFormatter.length(t.walls.reduce(0) { $0 + $1.length }, units))
                    cell("")
                    cell(areaShort(t.netWallArea)).fontWeight(.heavy)
                    cell(areaShort(t.grossWallArea)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 9)
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.card))
            Text("Areas in \(units.areaUnit). Net = gross minus openings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func openings(_ t: RoomTakeoff) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Doors, windows & openings", systemImage: "door.left.hand.open")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                GridRow { header("Tag"); header("Type"); header("Wall"); header("W x H"); header("Sill") }
                    .padding(.vertical, 8)
                Divider()
                ForEach(t.openings) { o in
                    GridRow {
                        Text(o.tag).font(.headline)
                        cell(o.kind.displayName)
                        cell(o.wallNumber.map { "W\($0)" } ?? "-")
                        cell("\(UnitFormatter.length(o.width, units)) x \(UnitFormatter.length(o.height, units))")
                        cell(o.kind == .window ? UnitFormatter.length(o.sillHeight, units) : "-")
                    }
                    .padding(.vertical, 9)
                    Divider()
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.card))
        }
    }

    private var fixtures: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Detected objects", systemImage: "cabinet")
            VStack(spacing: 0) {
                ForEach(plan.fixtures) { f in
                    HStack {
                        Text(f.label).font(.headline)
                        Spacer()
                        Text("\(UnitFormatter.length(f.width, units)) x \(UnitFormatter.length(f.depth, units)) x \(UnitFormatter.length(f.height, units)) h")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    Divider()
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.card))
        }
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption.weight(.heavy)).foregroundStyle(.secondary)
    }

    private func cell(_ text: String) -> Text {
        Text(text).font(.subheadline.monospacedDigit())
    }

    private func areaShort(_ m2: Double) -> String {
        UnitFormatter.decimal(UnitFormatter.areaValue(m2, units), units == .imperial ? 1 : 2)
    }

    private func icon(_ kind: MaterialKind) -> String {
        switch kind {
        case .drywall: return "square.stack.3d.up"
        case .paint: return "paintbrush.pointed"
        case .baseboard: return "ruler"
        case .flooring: return "square.grid.3x3"
        }
    }
}
