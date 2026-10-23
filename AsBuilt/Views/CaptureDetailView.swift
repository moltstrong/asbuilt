import SwiftUI
import AsBuiltCore

struct CaptureDetailView: View {
    let jobID: UUID
    let captureID: UUID
    @State var initialTab: CaptureTab

    @EnvironmentObject private var store: JobStore
    @AppStorage(Preferences.unitsKey) private var unitsRaw = UnitSystem.imperial.rawValue
    @State private var tab: CaptureTab = .plan
    @State private var didSetTab = false

    init(jobID: UUID, captureID: UUID, initialTab: CaptureTab) {
        self.jobID = jobID
        self.captureID = captureID
        _initialTab = State(initialValue: initialTab)
    }

    private var units: UnitSystem { UnitSystem(rawValue: unitsRaw) ?? .imperial }

    var body: some View {
        Group {
            if let capture = store.capture(job: jobID, capture: captureID) {
                content(capture)
            } else {
                ContentUnavailableView("Capture not found", systemImage: "questionmark.square.dashed")
            }
        }
        .background(Theme.background)
        .onAppear {
            if !didSetTab {
                tab = initialTab
                didSetTab = true
            }
        }
    }

    private func availableTabs(_ capture: Capture) -> [CaptureTab] {
        capture.kind == .room ? [.plan, .takeoff, .model, .files] : [.model, .files]
    }

    private func content(_ capture: Capture) -> some View {
        let plan = store.plan(job: jobID, capture: captureID)
        let tabs = availableTabs(capture)
        return VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(tabs) { t in Label(t.rawValue, systemImage: t.icon).tag(t) }
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.background)

            switch tab {
            case .plan:
                if let plan {
                    PlanView(plan: plan, units: units)
                } else {
                    ContentUnavailableView("No plan data", systemImage: "square.dashed")
                }
            case .takeoff:
                if let plan {
                    TakeoffView(plan: plan, units: units, scrollTarget: LaunchOptions.takeoffScrollTarget)
                } else {
                    ContentUnavailableView("No plan data", systemImage: "list.number")
                }
            case .model:
                ModelTabView(jobID: jobID, capture: capture)
            case .files:
                FilesTabView(jobID: jobID, capture: capture)
            }
        }
        .navigationTitle(capture.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Units", selection: $unitsRaw) {
                        ForEach(UnitSystem.allCases) { u in Text(u.displayName).tag(u.rawValue) }
                    }
                } label: {
                    Text(units == .imperial ? "ft-in" : "m")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 36)
                        .background(Theme.accentSoft, in: Capsule())
                }
                .accessibilityLabel("Units")
            }
        }
        .onChange(of: unitsRaw) { _, _ in
            if capture.kind == .room { store.regenerateExports(job: jobID, capture: captureID) }
            if capture.kind == .mesh { store.regenerateMeshCSV(job: jobID, capture: captureID) }
        }
    }
}

// MARK: - Plan

struct PlanView: View {
    let plan: FloorPlan
    let units: UnitSystem

    @State private var zoom: CGFloat = 1
    @State private var steadyZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var steadyPan: CGSize = .zero
    @State private var hidden: Set<PlanLayer> = []

    var body: some View {
        let takeoff = TakeoffCalculator.calculate(plan, options: Preferences.takeoffOptions)
        let drawing = PlanGeometryBuilder.build(plan, units: units)
        VStack(spacing: 0) {
            GeometryReader { geo in
                Canvas { context, size in
                    let viewport = PlanViewport(bounds: drawing.bounds, width: size.width, height: size.height, padding: 14)
                    context.translateBy(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
                    context.scaleBy(x: zoom, y: zoom)
                    context.translateBy(x: -size.width / 2, y: -size.height / 2)
                    context.withCGContext { cg in
                        PlanCGDrawer.draw(drawing, in: cg, viewport: viewport,
                                          options: .init(hiddenLayers: hidden, lineScale: 1 / max(zoom, 0.5) * 1.1,
                                                         textScale: 1, minFontSize: 7))
                    }
                }
                .background(Color.white)
                .gesture(
                    MagnificationGesture()
                        .onChanged { zoom = min(6, max(0.6, steadyZoom * $0)) }
                        .onEnded { _ in steadyZoom = zoom }
                        .simultaneously(with: DragGesture()
                            .onChanged { pan = CGSize(width: steadyPan.width + $0.translation.width,
                                                      height: steadyPan.height + $0.translation.height) }
                            .onEnded { _ in steadyPan = pan })
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring) {
                        zoom = 1; steadyZoom = 1; pan = .zero; steadyPan = .zero
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .accessibilityIdentifier("planCanvas")
                .accessibilityLabel("Floor plan of \(plan.name)")
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline, lineWidth: 0.5))
            .padding(.horizontal, 12)

            layerToggles.padding(.top, 8)

            HStack(spacing: 8) {
                StatTile(value: UnitFormatter.area(takeoff.floorArea, units), label: "Floor", systemImage: "square.dashed")
                StatTile(value: UnitFormatter.length(takeoff.perimeter, units), label: "Perimeter", systemImage: "ruler")
                StatTile(value: UnitFormatter.length(takeoff.ceilingHeight, units), label: "Ceiling", systemImage: "arrow.up.and.down")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private var layerToggles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach([PlanLayer.dimensions, .fixtures, .doors, .windows, .openings, .text], id: \.self) { layer in
                    let on = !hidden.contains(layer)
                    Button {
                        if on { hidden.insert(layer) } else { hidden.remove(layer) }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(layer.color).frame(width: 10, height: 10)
                            Text(layer.legendName).font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 40)
                        .background(on ? Theme.card : Color.clear, in: Capsule())
                        .overlay(Capsule().stroke(on ? layer.color : Theme.hairline, lineWidth: on ? 1.5 : 1))
                        .opacity(on ? 1 : 0.5)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
    }
}
