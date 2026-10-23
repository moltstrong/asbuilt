import SwiftUI
import UIKit
import AsBuiltCore

// MARK: - Driver

/// Main-actor wrapper around `CaptureCoach`: feeds frames, plays haptics, drives the torch, and
/// publishes the output at most ~15 times a second (plus every haptic or cue change).
@MainActor
final class CoachDriver: ObservableObject {
    @Published private(set) var output: CoachOutput?
    @Published private(set) var report: CoachReport?
    @Published private(set) var isFillingGaps = false
    private(set) var coach: CaptureCoach
    let haptics = CoachHaptics()
    /// Object Capture ticks per kept photo instead of the coach's rate-based ticks.
    var ticksEnabled = true
    /// Called with true once the coach wants the torch (latched) and false on stop/reset.
    var onTorch: ((Bool) -> Void)?
    private var torchOn = false
    private var lastPublish: Double = -1

    init(mode: CoachMode) {
        coach = CaptureCoach(mode: mode)
    }

    var mode: CoachMode { coach.mode }
    var thresholds: CoachThresholds { coach.thresholds }

    @discardableResult
    func update(_ frame: CoachFrame) -> CoachOutput {
        let out = coach.update(frame)
        if out.haptic != .tick || ticksEnabled { haptics.play(out.haptic) }
        if out.wantsTorch && !torchOn {
            torchOn = true
            onTorch?(true)
        }
        let changed = output?.guidance != out.guidance || output?.isReady != out.isReady
            || output?.suggestFinish != out.suggestFinish || out.showSurfaceTip || out.haptic == .success
        if changed || frame.timestamp - lastPublish >= 1.0 / 15 || frame.timestamp < lastPublish {
            lastPublish = frame.timestamp
            output = out
        }
        return out
    }

    func begin() {
        report = nil
        isFillingGaps = false
        coach.beginScanning()
    }

    /// Stops progress and grades the scan.
    @discardableResult
    func finish() -> CoachReport {
        coach.endScanning()
        let r = coach.report()
        report = r
        setTorch(false)
        return r
    }

    func pause() { coach.endScanning() }

    func resumeForGaps() {
        report = nil
        isFillingGaps = true
        coach.resumeForGaps()
    }

    func dismissFinish() { coach.dismissFinish() }

    func reset() {
        coach.reset()
        output = nil
        report = nil
        isFillingGaps = false
        setTorch(false)
    }

    /// Object Capture: Apple finished a pass at `band`.
    @discardableResult
    func completePass(_ band: CoachBand) -> CoachBand? {
        let next = coach.completePass(band)
        haptics.play(.success)
        return next
    }

    func setTorch(_ on: Bool) {
        if torchOn != on || !on {
            torchOn = on
            onTorch?(on)
        }
    }
}

// MARK: - Haptics

/// Geiger-counter ticks, a double buzz for bad technique, success patterns for passes.
@MainActor
final class CoachHaptics {
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let notify = UINotificationFeedbackGenerator()
    var isEnabled = true

    init() {
        soft.prepare()
        heavy.prepare()
    }

    func play(_ haptic: CoachHaptic) {
        guard isEnabled else { return }
        switch haptic {
        case .none:
            break
        case .tick:
            soft.impactOccurred(intensity: 0.45)
        case .warning:
            // Distinct double buzz.
            heavy.impactOccurred(intensity: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { [heavy] in heavy.impactOccurred(intensity: 1) }
        case .success:
            notify.notificationOccurred(.success)
        case .complete:
            notify.notificationOccurred(.success)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [rigid] in rigid.impactOccurred(intensity: 1) }
        case .ready:
            rigid.impactOccurred(intensity: 0.8)
        }
    }
}

// MARK: - Colors

enum CoachColors {
    static let good = Color(red: 0.20, green: 0.80, blue: 0.35)
    static let warn = Color(red: 1.0, green: 0.62, blue: 0.10)
    static let bad = Color(red: 0.95, green: 0.25, blue: 0.22)
    static let info = Color(red: 0.25, green: 0.60, blue: 1.0)

    static func color(for guidance: Guidance) -> Color {
        switch guidance {
        case .good, .complete: return good
        case .nextBand, .gettingReady: return info
        case .lowTexture: return warn
        case .tooFar, .tooClose: return warn
        default: return bad
        }
    }

    /// Red -> orange -> green by fused confidence (0...1).
    static func confidence(_ c: Float) -> Color {
        let t = Double(max(0, min(1, c)))
        if t < 0.5 {
            return Color(red: 0.95, green: 0.25 + 0.75 * t, blue: 0.15)
        }
        return Color(red: 0.95 - 1.5 * (t - 0.5), green: 0.62 + 0.3 * (t - 0.5), blue: 0.15 + 0.3 * (t - 0.5))
    }
}

// MARK: - Overlay

/// Everything the coach shows while scanning: one big cue, the distance reticle, the speed bar, the
/// coverage rings and the one-time surface tip. Shared by LiDAR Mesh, Detail scan, Object Capture,
/// RoomPlan and Measure (each turns parts off).
struct CoachOverlay: View {
    let output: CoachOutput?
    let thresholds: CoachThresholds
    var showsReticle = true
    var showsSpeed = true
    var showsRings = true
    var highlightGaps = false
    var isScanning = true
    /// Only show the cue for problems (flows with their own instructions, e.g. Object Capture).
    var problemsOnly = false

    @State private var tipVisible = false
    @State private var tipShown = false

    var body: some View {
        ZStack {
            if showsReticle, let output {
                DistanceReticle(output: output, thresholds: thresholds)
                    .allowsHitTesting(false)
            }
            VStack(spacing: 10) {
                if let output, !problemsOnly || output.guidance.isProblem,
                   isScanning || output.guidance != .good {
                    CoachCue(guidance: output.guidance, coverage: thresholds.coverage)
                        .transition(.scale.combined(with: .opacity))
                }
                if tipVisible {
                    SurfaceTipChip()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            // Below the 56 pt top bar + 16 pt padding that every capture screen uses.
            .padding(.top, 84)
            .allowsHitTesting(false)
            HStack {
                Spacer()
                if showsSpeed, let output {
                    SpeedBar(fraction: output.speedFraction)
                        .padding(.trailing, 10)
                }
            }
            .allowsHitTesting(false)
            if showsRings, thresholds.coverage != .none, let output {
                VStack {
                    Spacer()
                    HStack {
                        CoverageRings(coverage: output.coverage, kind: thresholds.coverage, highlightGaps: highlightGaps)
                            .frame(width: 104, height: 104)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                        Spacer()
                    }
                }
                .padding(.leading, 12)
                .padding(.bottom, 150)
                .allowsHitTesting(false)
            }
        }
        .animation(.spring(duration: 0.3), value: output?.guidance)
        .onChange(of: output?.showSurfaceTip ?? false) { _, show in
            guard show, !tipShown else { return }
            tipShown = true
            withAnimation { tipVisible = true }
            Task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                withAnimation { tipVisible = false }
            }
        }
    }
}

/// The single cue: big icon + at most three words.
struct CoachCue: View {
    let guidance: Guidance
    var coverage: CoverageKind = .orbit

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: guidance.symbol)
                .font(.system(size: 26, weight: .bold))
                .symbolEffect(.pulse, options: .repeating, isActive: guidance.isProblem || isNextBand)
            Text(guidance.label(coverage: coverage))
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(CoachColors.color(for: guidance).opacity(0.92), in: Capsule())
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("coachCue")
    }

    private var isNextBand: Bool {
        if case .nextBand = guidance { return true }
        return false
    }
}

/// Distance ring at the screen center: green in the sweet spot, orange with a closer/farther arrow.
struct DistanceReticle: View {
    let output: CoachOutput
    let thresholds: CoachThresholds

    var body: some View {
        let zone = output.distanceZone
        let color: Color = zone == .good ? CoachColors.good : (zone == .unknown ? .white.opacity(0.6) : CoachColors.warn)
        ZStack {
            Circle()
                .stroke(color, style: StrokeStyle(lineWidth: zone == .good ? 6 : 4, dash: zone == .unknown ? [6, 6] : []))
                .frame(width: 132, height: 132)
                .shadow(color: .black.opacity(0.4), radius: 3)
            // Sweet-spot gauge: where the distance sits between min and max.
            if let d = output.distance, d > 0, thresholds.maxDistance < 100 {
                let span = thresholds.maxDistance - thresholds.minDistance
                let f = Double(max(0, min(1, (d - thresholds.minDistance + span * 0.25) / (span * 1.5))))
                Circle()
                    .trim(from: 0, to: f)
                    .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 104, height: 104)
                    .opacity(0.35)
                Text(distanceText(d))
                    .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(radius: 3)
                    .offset(y: 30)
            }
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(color)
                .shadow(radius: 2)
            if zone == .tooFar || zone == .tooClose {
                Image(systemName: zone == .tooFar ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 30, weight: .black))
                    .foregroundStyle(color)
                    .shadow(radius: 3)
                    .offset(y: -96)
                    .symbolEffect(.pulse, options: .repeating)
            }
        }
        .accessibilityIdentifier("distanceReticle")
    }

    private func distanceText(_ d: Float) -> String {
        Preferences.units == .imperial
            ? UnitFormatter.feetInches(Double(d))
            : UnitFormatter.decimal(Double(d), 2) + " m"
    }
}

/// Vertical speed bar: green, yellow near the limit, red past it (the tick marks the limit).
struct SpeedBar: View {
    let fraction: Float

    var body: some View {
        let shown = Double(max(0, min(1.4, fraction))) / 1.4
        let color: Color = fraction >= 1 ? CoachColors.bad : (fraction >= 0.75 ? CoachColors.warn : CoachColors.good)
        VStack(spacing: 6) {
            Image(systemName: fraction >= 1 ? "hare.fill" : "tortoise.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(color)
            ZStack(alignment: .bottom) {
                Capsule().fill(.black.opacity(0.35))
                Capsule().fill(color).frame(height: 170 * shown)
                // Limit tick.
                Rectangle().fill(.white).frame(width: 22, height: 3).offset(y: -170 / 1.4 + 1.5)
            }
            .frame(width: 16, height: 170)
            .overlay(Capsule().stroke(.white.opacity(0.7), lineWidth: 1))
        }
        .padding(8)
        .background(.ultraThinMaterial, in: Capsule())
        .animation(.easeOut(duration: 0.15), value: shown)
        .accessibilityIdentifier("speedBar")
    }
}

/// 3 concentric rings (inner = low, outer = high) x 12 sectors, filling as the user walks around.
struct CoverageRings: View {
    let coverage: CoverageSnapshot
    var kind: CoverageKind = .orbit
    var highlightGaps = false

    @State private var pulse = false

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let maxR = min(size.width, size.height) / 2
            let ringWidth = maxR * 0.27
            for band in CoachBand.allCases {
                let rOuter = maxR * (0.46 + 0.27 * CGFloat(band.rawValue)) + ringWidth * 0.5
                let rInner = rOuter - ringWidth + 2
                for s in 0..<CoverageSnapshot.sectors {
                    // Sector 0 at the top (12 o'clock), clockwise.
                    let a0 = Angle.degrees(Double(s) * 30 - 90 + 1.5)
                    let a1 = Angle.degrees(Double(s + 1) * 30 - 90 - 1.5)
                    var path = Path()
                    path.addArc(center: center, radius: rOuter, startAngle: a0, endAngle: a1, clockwise: false)
                    path.addArc(center: center, radius: rInner, startAngle: a1, endAngle: a0, clockwise: true)
                    path.closeSubpath()
                    let fill = CGFloat(coverage.fill[band.rawValue][s])
                    let base: Color = fill >= 1 ? CoachColors.good : (fill > 0 ? CoachColors.warn.opacity(0.4 + 0.5 * fill) : Color.white.opacity(0.18))
                    var color = base
                    if highlightGaps && fill < 1 { color = CoachColors.bad.opacity(pulse ? 0.85 : 0.45) }
                    context.fill(path, with: .color(color))
                    if coverage.currentBand == band && coverage.currentSector == s {
                        context.stroke(path, with: .color(.white), lineWidth: 2.5)
                    }
                }
                if coverage.targetBand == band {
                    let r = maxR * (0.46 + 0.27 * CGFloat(band.rawValue))
                    let ring = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
                    context.stroke(ring, with: .color(CoachColors.info.opacity(pulse ? 1 : 0.4)), lineWidth: ringWidth * 0.95)
                }
            }
            let label = Text("\(Int((coverage.fraction * 100).rounded()))%")
                .font(.system(size: maxR * 0.3, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
            context.draw(label, at: center)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityLabel("Coverage \(Int(coverage.fraction * 100)) percent")
        .accessibilityIdentifier("coverageRings")
    }
}

/// One-time "shiny or plain" tip.
struct SurfaceTipChip: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
            Text("Shiny or plain surface: matte spray or painter's tape helps")
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(CoachColors.warn, in: Capsule())
        .frame(maxWidth: 340)
        .accessibilityIdentifier("surfaceTip")
    }
}

/// Start button that waits for tracking + light ("Getting ready…"), then pulses green.
struct ReadyStartButton: View {
    let isReady: Bool
    var title = "Start"
    var action: () -> Void

    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isReady {
                    Image(systemName: "record.circle")
                } else {
                    ProgressView().tint(.white)
                }
                Text(isReady ? title : "Getting ready…")
            }
            .font(.title3.weight(.bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(isReady ? CoachColors.good : Color.gray.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
            .scaleEffect(isReady && pulse ? 1.04 : 1)
            .shadow(color: isReady ? CoachColors.good.opacity(0.6) : .clear, radius: pulse ? 14 : 4)
        }
        .disabled(!isReady)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityIdentifier("readyStartButton")
    }
}

/// "Hold steady" ring for the Measure tool: fills while samples are collected; yellow until locked.
struct HoldSteadyRing: View {
    let fill: Double
    let locked: Bool

    var body: some View {
        let color = locked ? CoachColors.good : Color.yellow
        ZStack {
            Circle().stroke(.white.opacity(0.35), lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, fill)))
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: locked ? "checkmark" : "plus")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(width: 64, height: 64)
        .shadow(radius: 3)
        .accessibilityIdentifier("holdSteadyRing")
    }
}

/// End-of-scan grade with the single most useful fix and one action.
struct GradeCard: View {
    let report: CoachReport
    var fillGapsTitle = "Fill gaps"
    var onFillGaps: (() -> Void)?
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                Text(report.grade.rawValue)
                    .font(.system(size: 64, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 96, height: 96)
                    .background(gradeColor, in: Circle())
                    .accessibilityIdentifier("gradeLetter")
                VStack(alignment: .leading, spacing: 6) {
                    Text(report.fix ?? "Clean scan")
                        .font(.title3.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    // Stacked, not side by side: "69% covered" / "92% good motion" truncated on 402 pt phones.
                    VStack(alignment: .leading, spacing: 4) {
                        stat("\(Int((report.coverageFraction * 100).rounded()))%", "covered", "circle.dashed")
                        stat("\(Int((report.goodFraction * 100).rounded()))%", "good motion", "hand.thumbsup.fill")
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                if let onFillGaps {
                    Button(action: onFillGaps) {
                        Label(fillGapsTitle, systemImage: "circle.dashed.inset.filled")
                    }
                    .buttonStyle(BigButtonStyle(filled: report.grade != .a, color: Theme.accent))
                    .accessibilityIdentifier("fillGapsButton")
                }
                Button(action: onDone) {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(BigButtonStyle(filled: onFillGaps == nil || report.grade == .a))
                .accessibilityIdentifier("gradeDoneButton")
            }
        }
        .padding(20)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .accessibilityIdentifier("gradeCard")
    }

    private var gradeColor: Color {
        switch report.grade {
        case .a: return CoachColors.good
        case .b: return Color(red: 0.45, green: 0.75, blue: 0.25)
        case .c: return CoachColors.warn
        case .d, .f: return CoachColors.bad
        }
    }

    private func stat(_ value: String, _ label: String, _ icon: String) -> some View {
        Label {
            Text("\(value) \(label)").font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } icon: {
            Image(systemName: icon)
        }
        .foregroundStyle(.secondary)
    }
}

/// "Looks complete — Finish" prompt (coverage >= 90 %).
struct FinishPrompt: View {
    var onFinish: () -> Void
    var onKeepGoing: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(CoachColors.good)
            Text("Looks complete").font(.headline)
            Spacer(minLength: 8)
            Button("Keep going", action: onKeepGoing).font(.subheadline.weight(.semibold))
            Button(action: onFinish) {
                Text("Finish").font(.headline).padding(.horizontal, 16).padding(.vertical, 8)
                    .background(CoachColors.good, in: Capsule()).foregroundStyle(.white)
            }
            .accessibilityIdentifier("finishPromptButton")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 460)
    }
}

// MARK: - First-run intro

/// One skippable, mostly visual 3-card intro per mode, shown once; the "?" button reopens it.
struct CoachIntro: View {
    let mode: CoachMode
    var onDone: () -> Void
    @State private var page = 0

    static func seenKey(_ mode: CoachMode) -> String { "coachIntroSeen.\(mode.rawValue)" }

    struct Card: Hashable {
        var symbol: String
        var title: String
        var color: Color
    }

    static func cards(for mode: CoachMode) -> [Card] {
        switch mode {
        case .detail:
            return [Card(symbol: "lightbulb.max.fill", title: "Bright, even light", color: .yellow),
                    Card(symbol: "tortoise.fill", title: "Slow, within 1 m", color: CoachColors.good),
                    Card(symbol: "circle.circle", title: "3 heights, all around", color: CoachColors.info)]
        case .mesh:
            return [Card(symbol: "lightbulb.max.fill", title: "Lights on", color: .yellow),
                    Card(symbol: "tortoise.fill", title: "Slow sweeps", color: CoachColors.good),
                    Card(symbol: "arrow.up.and.down.circle", title: "Floor, walls, ceiling", color: CoachColors.info)]
        case .room:
            return [Card(symbol: "lightbulb.max.fill", title: "Lights on", color: .yellow),
                    Card(symbol: "figure.walk", title: "Walk the walls", color: CoachColors.good),
                    Card(symbol: "door.left.hand.open", title: "Doors & windows", color: CoachColors.info)]
        case .objectCapture:
            return [Card(symbol: "sun.max.fill", title: "Even light, no glare", color: .yellow),
                    Card(symbol: "circle.circle", title: "3 circles: mid, low, high", color: CoachColors.info),
                    Card(symbol: "sparkles", title: "Shiny? Matte spray", color: CoachColors.warn)]
        case .measure:
            return [Card(symbol: "plus.viewfinder", title: "Aim the cross", color: CoachColors.info),
                    Card(symbol: "hand.raised.fill", title: "Hold until green", color: CoachColors.good),
                    Card(symbol: "ruler", title: "Check with tape", color: .yellow)]
        }
    }

    var body: some View {
        let cards = Self.cards(for: mode)
        VStack(spacing: 18) {
            HStack {
                Spacer()
                Button("Skip") { finish() }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("introSkip")
            }
            TabView(selection: $page) {
                ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                    VStack(spacing: 22) {
                        Image(systemName: card.symbol)
                            .font(.system(size: 96, weight: .bold))
                            .foregroundStyle(card.color)
                            .frame(width: 180, height: 180)
                            .background(card.color.opacity(0.18), in: Circle())
                        Text(card.title)
                            .font(.system(size: 30, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .frame(maxHeight: 380)
            Button(page < cards.count - 1 ? "Next" : "Got it") {
                if page < cards.count - 1 { withAnimation { page += 1 } } else { finish() }
            }
            .buttonStyle(BigButtonStyle())
            .frame(maxWidth: 360)
        }
        .padding(24)
        .background(Color.black.opacity(0.88).ignoresSafeArea())
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.seenKey(mode))
        onDone()
    }
}

/// "?" button that reopens the intro.
struct CoachHelpButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(radius: 3)
                .frame(width: 48, height: 48)
        }
        .accessibilityLabel("How to scan")
        .accessibilityIdentifier("coachHelpButton")
    }
}

extension View {
    /// Shows the mode's intro once (never during CI/UI screenshots launched with -AsBuiltScreen).
    func coachIntro(_ mode: CoachMode, isPresented: Binding<Bool>) -> some View {
        self
            .onAppear {
                if !UserDefaults.standard.bool(forKey: CoachIntro.seenKey(mode)), LaunchOptions.current.screen == nil {
                    isPresented.wrappedValue = true
                }
            }
            .fullScreenCover(isPresented: isPresented) {
                CoachIntro(mode: mode) { isPresented.wrappedValue = false }
            }
    }
}
