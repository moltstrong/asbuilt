import Foundation
import simd

// MARK: - Inputs

/// Capture flows the coach supports. Thresholds differ per mode (`CoachThresholds.for(_:)`).
public enum CoachMode: String, Sendable, CaseIterable, Codable {
    /// TSDF Detail scan: close range, slow, three height passes around the object.
    case detail
    /// ARKit LiDAR Mesh (room/space scale).
    case mesh
    /// RoomPlan room scan (issues come from RoomPlan's instructions).
    case room
    /// Object Capture (issues come from Apple's `ObjectCaptureSession.feedback`).
    case objectCapture
    /// Point-to-point measure: steadiness only.
    case measure
}

/// ARKit tracking state, framework-free.
public enum CoachTracking: Sendable, Hashable {
    case normal
    case initializing
    case excessiveMotion
    case insufficientFeatures
    case relocalizing
    case notAvailable
}

/// Height band of the camera relative to the target (orbit) or of the camera's pitch (look-around).
public enum CoachBand: Int, Sendable, CaseIterable, Comparable, Codable {
    case low = 0, mid = 1, high = 2

    public static func < (a: CoachBand, b: CoachBand) -> Bool { a.rawValue < b.rawValue }

    public var name: String {
        switch self {
        case .low: return "Low"
        case .mid: return "Middle"
        case .high: return "High"
        }
    }
}

/// Technique problems, in priority order (raw value: lower = shown first).
public enum CoachIssue: Int, Sendable, CaseIterable, Comparable, Hashable {
    case tracking = 0
    case tooDark = 1
    case tooFast = 2
    case tooFar = 3
    case tooClose = 4
    case lowTexture = 5

    public static func < (a: CoachIssue, b: CoachIssue) -> Bool { a.rawValue < b.rawValue }

    /// Issues that pause integration / progress (lowTexture only advises).
    public var gates: Bool { self != .lowTexture }
}

/// One frame of metrics. Every field except the timestamp is optional so each flow can feed what it has.
public struct CoachFrame: Sendable {
    /// Seconds (ARFrame.timestamp or any monotonic clock).
    public var timestamp: Double
    /// Camera pose (ARKit convention: camera looks down -Z).
    public var cameraToWorld: simd_float4x4?
    /// `ARLightEstimate.ambientIntensity` (ARKit reports ~1000 for neutral, well-lit scenes).
    public var ambientIntensity: Float?
    /// Median depth (m) of the central region of the depth map.
    public var centerDepth: Float?
    /// Fraction (0...1) of depth pixels with high confidence.
    public var highConfidenceFraction: Float?
    public var tracking: CoachTracking
    /// `ARFrame.rawFeaturePoints` count.
    public var featureCount: Int?
    /// Issues reported by Apple's own guidance (Object Capture feedback, RoomPlan instructions).
    /// They are combined with the metric checks and go through the same hysteresis.
    public var external: Set<CoachIssue>

    public init(timestamp: Double, cameraToWorld: simd_float4x4? = nil, ambientIntensity: Float? = nil,
                centerDepth: Float? = nil, highConfidenceFraction: Float? = nil, tracking: CoachTracking = .normal,
                featureCount: Int? = nil, external: Set<CoachIssue> = []) {
        self.timestamp = timestamp
        self.cameraToWorld = cameraToWorld
        self.ambientIntensity = ambientIntensity
        self.centerDepth = centerDepth
        self.highConfidenceFraction = highConfidenceFraction
        self.tracking = tracking
        self.featureCount = featureCount
        self.external = external
    }
}

// MARK: - Thresholds

public enum CoverageKind: String, Sendable, Hashable {
    /// Camera position around the scan centroid (objects): 12 azimuth sectors x 3 elevation bands.
    case orbit
    /// Camera heading (spaces): 12 compass sectors x 3 pitch bands (floor / level / ceiling).
    case lookAround
    /// No coverage model (Object Capture tracks its own; Measure and RoomPlan don't need one).
    case none
}

public struct CoachThresholds: Sendable, Hashable {
    /// Sweet-spot distance to the surface in front of the camera (m).
    public var minDistance: Float
    public var maxDistance: Float
    /// "Too fast" above either (m/s, deg/s).
    public var maxLinearSpeed: Float
    public var maxAngularSpeed: Float
    /// tooDark below `darkIntensity`, cleared above `brightIntensity` (ARKit ambient intensity units).
    public var darkIntensity: Float
    public var brightIntensity: Float
    /// lowTexture when the high-confidence depth fraction stays below this (or features below
    /// `lowFeatureCount`) for `lowTextureSeconds`.
    public var lowConfidenceFraction: Float
    public var lowFeatureCount: Int
    public var lowTextureSeconds: Double
    public var usesDistance: Bool
    public var usesLight: Bool
    public var usesTexture: Bool
    public var coverage: CoverageKind
    /// Good frames needed before a coverage cell counts as done.
    public var framesPerCell: Int
    /// Band edges in degrees: elevation (orbit) or camera pitch (look-around).
    public var bandEdges: (low: Float, high: Float)
    /// Sectors (of 12) needed to call a band complete.
    public var sectorsPerBand: Int
    /// Fraction of cells that triggers "Looks complete — Finish".
    public var finishFraction: Float
    /// Relative hysteresis on the speed and distance thresholds (0.15 = clear at 15 % inside).
    public var hysteresis: Float

    public static func == (a: CoachThresholds, b: CoachThresholds) -> Bool {
        a.minDistance == b.minDistance && a.maxDistance == b.maxDistance && a.maxLinearSpeed == b.maxLinearSpeed
            && a.maxAngularSpeed == b.maxAngularSpeed && a.darkIntensity == b.darkIntensity && a.coverage == b.coverage
            && a.framesPerCell == b.framesPerCell && a.bandEdges == b.bandEdges
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(minDistance)
        hasher.combine(maxDistance)
        hasher.combine(maxLinearSpeed)
        hasher.combine(coverage)
    }

    public static func `for`(_ mode: CoachMode) -> CoachThresholds {
        switch mode {
        case .detail:
            return CoachThresholds(minDistance: 0.25, maxDistance: 1.0, maxLinearSpeed: 0.25, maxAngularSpeed: 30,
                                   darkIntensity: 250, brightIntensity: 400, lowConfidenceFraction: 0.35,
                                   lowFeatureCount: 40, lowTextureSeconds: 2.5, usesDistance: true, usesLight: true,
                                   usesTexture: true, coverage: .orbit, framesPerCell: 10, bandEdges: (12, 40),
                                   sectorsPerBand: 10, finishFraction: 0.9, hysteresis: 0.15)
        case .mesh:
            return CoachThresholds(minDistance: 0.3, maxDistance: 3.0, maxLinearSpeed: 0.6, maxAngularSpeed: 60,
                                   darkIntensity: 150, brightIntensity: 260, lowConfidenceFraction: 0.25,
                                   lowFeatureCount: 30, lowTextureSeconds: 3, usesDistance: true, usesLight: true,
                                   usesTexture: true, coverage: .lookAround, framesPerCell: 12, bandEdges: (-25, 15),
                                   sectorsPerBand: 10, finishFraction: 0.9, hysteresis: 0.15)
        case .room:
            return CoachThresholds(minDistance: 0.5, maxDistance: 4.0, maxLinearSpeed: 0.6, maxAngularSpeed: 60,
                                   darkIntensity: 150, brightIntensity: 260, lowConfidenceFraction: 0,
                                   lowFeatureCount: 0, lowTextureSeconds: 3, usesDistance: false, usesLight: true,
                                   usesTexture: false, coverage: .none, framesPerCell: 12, bandEdges: (-25, 15),
                                   sectorsPerBand: 10, finishFraction: 0.9, hysteresis: 0.15)
        case .objectCapture:
            // Apple's feedback drives the issues; the coach adds hysteresis, haptics and the pass bands.
            return CoachThresholds(minDistance: 0, maxDistance: .greatestFiniteMagnitude, maxLinearSpeed: .greatestFiniteMagnitude,
                                   maxAngularSpeed: .greatestFiniteMagnitude, darkIntensity: 0, brightIntensity: 0,
                                   lowConfidenceFraction: 0, lowFeatureCount: 0, lowTextureSeconds: 3, usesDistance: false,
                                   usesLight: false, usesTexture: false, coverage: .none, framesPerCell: 10,
                                   bandEdges: (12, 40), sectorsPerBand: 10, finishFraction: 0.9, hysteresis: 0.15)
        case .measure:
            return CoachThresholds(minDistance: 0, maxDistance: .greatestFiniteMagnitude, maxLinearSpeed: 0.05,
                                   maxAngularSpeed: 8, darkIntensity: 0, brightIntensity: 0, lowConfidenceFraction: 0,
                                   lowFeatureCount: 0, lowTextureSeconds: 3, usesDistance: false, usesLight: false,
                                   usesTexture: false, coverage: .none, framesPerCell: 10, bandEdges: (12, 40),
                                   sectorsPerBand: 10, finishFraction: 0.9, hysteresis: 0.25)
        }
    }
}

// MARK: - Outputs

/// The single cue on screen.
public enum Guidance: Sendable, Hashable {
    case gettingReady
    case trackingLost
    case tooDark
    case tooFast
    case tooFar
    case tooClose
    case lowTexture
    case holdSteady
    /// Next height band (orbit: move the phone; look-around: aim the phone).
    case nextBand(CoachBand, lower: Bool)
    case complete
    case good

    /// At most three words.
    public func label(coverage: CoverageKind = .orbit) -> String {
        switch self {
        case .gettingReady: return "Getting ready"
        case .trackingLost: return "Aim back"
        case .tooDark: return "More light"
        case .tooFast: return "Slow down"
        case .tooFar: return "Closer"
        case .tooClose: return "Back up"
        case .lowTexture: return "Shiny or plain"
        case .holdSteady: return "Hold steady"
        case .nextBand(_, let lower):
            if coverage == .lookAround { return lower ? "Aim lower" : "Aim higher" }
            return lower ? "Now lower" : "Now higher"
        case .complete: return "Looks complete"
        case .good: return "Good"
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .gettingReady: return "hourglass"
        case .trackingLost: return "scope"
        case .tooDark: return "lightbulb.max.fill"
        case .tooFast: return "tortoise.fill"
        case .tooFar: return "arrow.down.right.and.arrow.up.left"
        case .tooClose: return "arrow.up.left.and.arrow.down.right"
        case .lowTexture: return "sparkles"
        case .holdSteady: return "hand.raised.fill"
        case .nextBand(_, let lower): return lower ? "arrow.down.circle.fill" : "arrow.up.circle.fill"
        case .complete: return "checkmark.seal.fill"
        case .good: return "checkmark.circle.fill"
        }
    }

    /// Bad technique (red/orange cue, progress paused).
    public var isProblem: Bool {
        switch self {
        case .trackingLost, .tooDark, .tooFast, .tooFar, .tooClose, .holdSteady: return true
        default: return false
        }
    }

    init(issue: CoachIssue, tracking: CoachTracking, mode: CoachMode) {
        switch issue {
        case .tracking: self = tracking == .initializing ? .gettingReady : (tracking == .excessiveMotion ? .tooFast : .trackingLost)
        case .tooDark: self = .tooDark
        case .tooFast: self = mode == .measure ? .holdSteady : .tooFast
        case .tooFar: self = .tooFar
        case .tooClose: self = .tooClose
        case .lowTexture: self = .lowTexture
        }
    }
}

public enum CoachHaptic: String, Sendable, Hashable {
    case none
    /// Soft "Geiger counter" tick while good data is captured.
    case tick
    /// Distinct double buzz on crossing into a bad state.
    case warning
    /// A band / pass completed.
    case success
    /// Coverage reached the finish threshold.
    case complete
    /// Pre-flight checks passed (Start turns green).
    case ready
}

public enum DistanceZone: String, Sendable, Hashable {
    case unknown, tooClose, good, tooFar
}

/// Read-only coverage state for the ring HUD.
public struct CoverageSnapshot: Sendable, Hashable {
    public static let sectors = 12
    /// [band][sector] fill 0...1 (band 0 = low).
    public var fill: [[Float]]
    public var currentBand: CoachBand?
    public var currentSector: Int?
    /// Band the coach is asking for next (nil = keep going / done).
    public var targetBand: CoachBand?
    public var bandsComplete: [Bool]
    public var fraction: Float

    public init(fill: [[Float]], currentBand: CoachBand?, currentSector: Int?, targetBand: CoachBand?,
                bandsComplete: [Bool], fraction: Float) {
        self.fill = fill
        self.currentBand = currentBand
        self.currentSector = currentSector
        self.targetBand = targetBand
        self.bandsComplete = bandsComplete
        self.fraction = fraction
    }

    public static let empty = CoverageSnapshot(fill: Array(repeating: Array(repeating: 0, count: 12), count: 3),
                                               currentBand: nil, currentSector: nil, targetBand: nil,
                                               bandsComplete: [false, false, false], fraction: 0)

    /// Cells not yet done, as (band, sector), for the "Fill gaps" highlight.
    public var gaps: [(band: CoachBand, sector: Int)] {
        var out: [(CoachBand, Int)] = []
        for band in CoachBand.allCases {
            for s in 0..<Self.sectors where fill[band.rawValue][s] < 1 { out.append((band, s)) }
        }
        return out
    }

    public static func == (a: CoverageSnapshot, b: CoverageSnapshot) -> Bool {
        a.fill == b.fill && a.currentBand == b.currentBand && a.currentSector == b.currentSector
            && a.targetBand == b.targetBand && a.bandsComplete == b.bandsComplete
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(fraction)
        hasher.combine(currentSector)
    }
}

public struct CoachOutput: Sendable, Hashable {
    public var guidance: Guidance
    /// Feed this frame to fusion / count it as progress.
    public var shouldIntegrate: Bool
    /// 0...1 (0 when gated).
    public var quality: Float
    public var haptic: CoachHaptic
    /// Smoothed speeds.
    public var linearSpeed: Float
    public var angularSpeed: Float
    /// max(linear / max, angular / max): > 1 is too fast (speed bar).
    public var speedFraction: Float
    public var distance: Float?
    public var distanceZone: DistanceZone
    public var coverage: CoverageSnapshot
    /// True exactly once per scan: show the "Shiny or plain surface" chip.
    public var showSurfaceTip: Bool
    /// Turn the torch on (latched until `reset()`).
    public var wantsTorch: Bool
    /// Pre-flight: tracking normal and light OK.
    public var isReady: Bool
    /// Coverage reached the finish threshold: offer "Finish".
    public var suggestFinish: Bool
}

extension CoachReport {
    /// coach-report.txt: grade, the one fix, and the technique breakdown.
    public func text(mode: CoachMode, title: String, thresholds: CoachThresholds) -> String {
        func pct(_ f: Float) -> String { "\(Int((f * 100).rounded()))%" }
        var lines = [
            "AsBuilt Capture Coach report",
            "Scan: \(title)",
            "Mode: \(mode.rawValue)",
            "Grade: \(grade.rawValue)  (score \(String(format: "%.2f", score)))",
            "Fix next time: \(fix ?? "nothing, clean scan")",
            "",
            "Coverage: \(pct(coverageFraction)) of 36 cells (12 directions x 3 heights)",
            "Good technique: \(pct(goodFraction)) of \(Int(seconds.rounded())) s tracked",
            "Too fast: \(pct(tooFastFraction))",
            "Too dark: \(pct(tooDarkFraction))",
            "Out of range: \(pct(distanceFraction))",
            "Shiny/plain surface: \(pct(lowTextureFraction))",
            "",
        ]
        if thresholds.maxDistance < 100 {
            lines.append(String(format: "Sweet spot: %.2f-%.2f m", thresholds.minDistance, thresholds.maxDistance))
        }
        if thresholds.maxLinearSpeed < 100 {
            lines.append(String(format: "Speed limit: %.2f m/s, %.0f deg/s", thresholds.maxLinearSpeed, thresholds.maxAngularSpeed))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Final grade card.
public struct CoachReport: Sendable, Hashable {
    public enum Grade: String, Sendable, Hashable, CaseIterable {
        case a = "A", b = "B", c = "C", d = "D", f = "F"
    }

    public var grade: Grade
    /// 0...1
    public var score: Float
    /// The single most useful fix (nil for a clean scan).
    public var fix: String?
    public var coverageFraction: Float
    /// Fraction of tracked time with good technique.
    public var goodFraction: Float
    public var tooFastFraction: Float
    public var tooDarkFraction: Float
    public var distanceFraction: Float
    public var lowTextureFraction: Float
    public var seconds: Double
}

// MARK: - Coach

/// Turns per-frame metrics into one glanceable cue, a gate for fusion, a quality score, haptics and a
/// coverage model; pure Swift so it is unit tested and shared by every capture flow.
///
/// Anti-flicker: each issue is latched with value hysteresis (`CoachThresholds.hysteresis`) and time
/// hysteresis (on after `enterSeconds`, off after `exitSeconds`), and the displayed guidance only changes
/// after it has been shown for `minDisplaySeconds` (problems may replace "good" cues immediately).
public struct CaptureCoach: Sendable {
    public let mode: CoachMode
    public var thresholds: CoachThresholds

    public var enterSeconds: Double = 0.25
    public var exitSeconds: Double = 0.45
    public var minDisplaySeconds: Double = 0.8
    /// EMA time constant for speeds.
    public var speedTimeConstant: Double = 0.25
    /// Seconds without new cells (with good frames) after which an orbit pass of >= 5 sectors counts as done.
    public var passStallSeconds: Double = 5
    public var warningCooldown: Double = 2
    public var torchDelay: Double = 1

    /// Scanning (progress, haptics, stats) vs pre-flight.
    public private(set) var isScanning = false

    // Speed.
    private var lastPose: simd_float4x4?
    private var lastTime: Double?
    private var linearEMA: Float = 0
    private var angularEMA: Float = 0
    private var speedSamples = 0

    // Latches.
    private struct Latch: Sendable {
        var active = false
        var conditionSince: Double?
        var clearSince: Double?
    }

    private var latches: [CoachIssue: Latch] = [:]
    private var lowTextureSince: Double?
    private var trackingState: CoachTracking = .normal

    // Display.
    private var displayed: Guidance = .gettingReady
    private var displayedSince: Double = -.greatestFiniteMagnitude
    private var lastWarning: Double = -.greatestFiniteMagnitude
    private var lastTick: Double = -.greatestFiniteMagnitude
    private var wasGated = false
    private var surfaceTipShownAt: Double?
    private var torchLatched = false
    private var darkSince: Double?
    private var readySince: Double?
    private var announcedReady = false

    // Coverage.
    private var counts: [[Int]] = Array(repeating: Array(repeating: 0, count: 12), count: 3)
    private var centroid: SIMD3<Float>?
    private var centroidSamples = 0
    private var currentBand: CoachBand?
    private var currentSector: Int?
    private var targetBand: CoachBand?
    private var bandDone = [false, false, false]
    private var passDone = [false, false, false]
    private var lastNewCellTime: Double?
    private var finishAnnounced = false
    private var finishDismissed = false

    // Stats (seconds).
    private var trackedSeconds: Double = 0
    private var goodSeconds: Double = 0
    private var issueSeconds: [CoachIssue: Double] = [:]
    private var scanStart: Double?
    private var lastStatTime: Double?

    public init(mode: CoachMode, thresholds: CoachThresholds? = nil) {
        self.mode = mode
        self.thresholds = thresholds ?? .for(mode)
    }

    /// Back to pre-flight (keeps nothing).
    public mutating func reset() {
        self = CaptureCoach(mode: mode, thresholds: thresholds)
    }

    /// Starts counting progress (call on Start).
    public mutating func beginScanning() {
        isScanning = true
        scanStart = nil
        lastStatTime = nil
    }

    /// Stops counting (Stop / pause).
    public mutating func endScanning() {
        isScanning = false
    }

    /// "Fill gaps": scanning resumes with coverage kept; the finish prompt may show again later.
    public mutating func resumeForGaps() {
        isScanning = true
        finishAnnounced = false
        finishDismissed = false
        lastStatTime = nil
        targetBand = firstIncompleteBand(after: currentBand)
    }

    /// The user dismissed "Looks complete" and keeps scanning.
    public mutating func dismissFinish() { finishDismissed = true }

    /// Object Capture: Apple reports a finished pass (`userCompletedScanPass`). Marks `band` complete and
    /// returns the next band to ask for.
    @discardableResult
    public mutating func completePass(_ band: CoachBand) -> CoachBand? {
        bandDone[band.rawValue] = true
        passDone[band.rawValue] = true
        for s in 0..<12 { counts[band.rawValue][s] = max(counts[band.rawValue][s], thresholds.framesPerCell) }
        currentBand = band
        targetBand = firstIncompleteBand(after: band)
        return targetBand
    }

    /// Object Capture: the user started the next pass (Another pass / Flip) at `band`; clears the
    /// "Now lower/higher" cue until that pass completes.
    public mutating func beginPass(_ band: CoachBand) {
        currentBand = band
        targetBand = nil
    }

    /// Speed from two poses `dt` seconds apart: (m/s, deg/s).
    public static func speeds(from a: simd_float4x4, to b: simd_float4x4, dt: Double) -> (linear: Float, angular: Float) {
        guard dt > 1e-6 else { return (0, 0) }
        let linear = simd_distance(RigidTransform.translation(a), RigidTransform.translation(b)) / Float(dt)
        let angular = RigidTransform.rotationAngle(from: a, to: b) * 180 / .pi / Float(dt)
        return (linear, angular)
    }

    // MARK: Update

    public mutating func update(_ frame: CoachFrame) -> CoachOutput {
        let t = frame.timestamp
        let th = thresholds
        trackingState = frame.tracking

        // 1. Speeds (EMA).
        if let pose = frame.cameraToWorld, let lastPose, let lastTime, t > lastTime {
            let dt = t - lastTime
            if dt < 1 {
                let (lin, ang) = Self.speeds(from: lastPose, to: pose, dt: dt)
                let alpha = Float(1 - exp(-dt / speedTimeConstant))
                if speedSamples == 0 {
                    linearEMA = lin
                    angularEMA = ang
                } else {
                    linearEMA += alpha * (lin - linearEMA)
                    angularEMA += alpha * (ang - angularEMA)
                }
                speedSamples += 1
            }
        }
        if let pose = frame.cameraToWorld {
            lastPose = pose
            lastTime = t
        }
        let speedFraction = max(linearEMA / th.maxLinearSpeed, angularEMA / th.maxAngularSpeed)

        // 2. Raw conditions with value hysteresis (enter at the threshold, clear `hysteresis` inside it).
        let h = th.hysteresis
        func cond(_ issue: CoachIssue) -> Bool? {
            let active = latches[issue]?.active ?? false
            if frame.external.contains(issue) { return true }
            switch issue {
            case .tracking:
                return frame.tracking != .normal
            case .tooDark:
                guard th.usesLight, let lux = frame.ambientIntensity else { return false }
                return active ? lux < th.brightIntensity : lux < th.darkIntensity
            case .tooFast:
                guard speedSamples > 0 else { return false }
                return active ? speedFraction > 1 - h : speedFraction > 1
            case .tooFar:
                guard th.usesDistance, let d = frame.centerDepth, d > 0 else { return th.usesDistance && frame.centerDepth == 0 ? true : false }
                return active ? d > th.maxDistance * (1 - h) : d > th.maxDistance
            case .tooClose:
                guard th.usesDistance, let d = frame.centerDepth, d > 0 else { return false }
                return active ? d < th.minDistance * (1 + h) : d < th.minDistance
            case .lowTexture:
                guard th.usesTexture else { return false }
                let lowConf = frame.highConfidenceFraction.map { $0 < th.lowConfidenceFraction } ?? false
                let lowFeat = frame.featureCount.map { $0 < th.lowFeatureCount } ?? false
                let low = lowConf || lowFeat
                if low {
                    if lowTextureSince == nil { lowTextureSince = t }
                } else {
                    lowTextureSince = nil
                }
                return low && t - (lowTextureSince ?? t) >= th.lowTextureSeconds
            }
        }

        // 3. Time hysteresis.
        var active: Set<CoachIssue> = []
        for issue in CoachIssue.allCases {
            let c = cond(issue) ?? false
            var latch = latches[issue] ?? Latch()
            if c {
                latch.clearSince = nil
                if latch.conditionSince == nil { latch.conditionSince = t }
                // Tracking and external issues show without delay; metric issues need `enterSeconds`.
                let immediate = issue == .tracking || frame.external.contains(issue) || issue == .lowTexture
                if !latch.active && (immediate || t - latch.conditionSince! >= enterSeconds) { latch.active = true }
            } else {
                latch.conditionSince = nil
                if latch.active {
                    if latch.clearSince == nil { latch.clearSince = t }
                    if t - latch.clearSince! >= exitSeconds { latch.active = false }
                }
            }
            latches[issue] = latch
            if latch.active { active.insert(issue) }
        }
        // Distance issues are mutually exclusive; keep the one the raw depth supports.
        if active.contains(.tooFar) && active.contains(.tooClose) {
            if let d = frame.centerDepth, d < (th.minDistance + th.maxDistance) / 2 { active.remove(.tooFar) } else { active.remove(.tooClose) }
        }
        // Low texture is advice: its chip shows once per scan (only when it is the top cue), then the
        // cue is suppressed 6 s later so it never nags.
        var showSurfaceTip = false
        if active.contains(.lowTexture) {
            let blockedByGate = active.contains { $0.gates }
            if let shown = surfaceTipShownAt {
                if t - shown > 6 { active.remove(.lowTexture) }
            } else if isScanning && !blockedByGate {
                surfaceTipShownAt = t
                showSurfaceTip = true
            } else if !isScanning {
                active.remove(.lowTexture)
            }
        }
        let gated = active.contains { $0.gates }
        let shouldIntegrate = isScanning && !gated

        // 4. Torch: latched on after sustained darkness (pre-flight too).
        if active.contains(.tooDark) || (th.usesLight && (frame.ambientIntensity ?? .greatestFiniteMagnitude) < th.darkIntensity) {
            if darkSince == nil { darkSince = t }
            if t - darkSince! >= torchDelay { torchLatched = true }
        } else {
            darkSince = nil
        }

        // 5. Readiness (pre-flight).
        var haptic: CoachHaptic = .none
        let readyNow = frame.tracking == .normal && !active.contains(.tracking) && !active.contains(.tooDark)
        if readyNow {
            if readySince == nil { readySince = t }
        } else {
            readySince = nil
        }
        let isReady = readyNow && t - (readySince ?? t) >= 0.5
        if isReady && !announcedReady && !isScanning {
            announcedReady = true
            haptic = .ready
        }

        // 6. Distance zone and quality.
        var zone = DistanceZone.unknown
        if let d = frame.centerDepth, d > 0, th.usesDistance {
            zone = active.contains(.tooFar) ? .tooFar : (active.contains(.tooClose) ? .tooClose : .good)
        } else if th.usesDistance, frame.centerDepth != nil {
            zone = .tooFar
        }
        var quality: Float = 0
        if !gated && frame.tracking == .normal {
            let speedQ = speedFraction <= 0.5 ? 1 : max(0, 1 - (speedFraction - 0.5) * 2)
            var distQ: Float = 1
            if th.usesDistance, let d = frame.centerDepth, d > 0 {
                let mid = (th.minDistance + th.maxDistance) / 2
                distQ = max(0.4, 1 - abs(d - mid) / (th.maxDistance - th.minDistance))
            }
            var lightQ: Float = 1
            if th.usesLight, let lux = frame.ambientIntensity {
                lightQ = min(1, max(0.3, lux / (th.brightIntensity * 1.5)))
            }
            var confQ: Float = 1
            if th.usesTexture, let f = frame.highConfidenceFraction { confQ = min(1, max(0.2, f / 0.7)) }
            quality = max(0.05, speedQ * distQ * lightQ * confQ)
        }

        // 7. Coverage (only good scanning frames count).
        var newCell = false
        var bandEvent = false
        if isScanning, th.coverage != .none, shouldIntegrate, let pose = frame.cameraToWorld {
            (newCell, bandEvent) = updateCoverage(pose: pose, depth: frame.centerDepth, time: t)
        } else if th.coverage != .none, let pose = frame.cameraToWorld {
            locate(pose: pose, depth: frame.centerDepth)
        }
        let snapshot = coverageSnapshot()
        var suggestFinish = false
        if isScanning, th.coverage != .none, snapshot.fraction >= th.finishFraction, !finishDismissed {
            suggestFinish = true
            if !finishAnnounced {
                finishAnnounced = true
                if haptic == .none { haptic = .complete }
            }
        }

        // 8. Stats.
        if isScanning {
            if scanStart == nil { scanStart = t }
            if let last = lastStatTime, t > last, t - last < 1 {
                let dt = t - last
                if frame.tracking == .normal || active.contains(.tracking) {
                    trackedSeconds += dt
                    if !gated { goodSeconds += dt }
                    if let primary = active.min() { issueSeconds[primary, default: 0] += dt }
                    if active.contains(.lowTexture) || (lowTextureSince.map { t - $0 > 1 } ?? false) {
                        issueSeconds[.lowTexture, default: 0] += active.min() == .lowTexture ? 0 : dt
                    }
                }
            }
            lastStatTime = t
        }

        // 9. Primary guidance + display dwell.
        var candidate: Guidance
        if let issue = active.min() {
            candidate = Guidance(issue: issue, tracking: frame.tracking, mode: mode)
        } else if !isScanning && !isReady {
            candidate = .gettingReady
        } else if suggestFinish {
            candidate = .complete
        } else if let target = targetBand, let current = currentBand, target != current, isScanning {
            candidate = .nextBand(target, lower: target < current)
        } else {
            candidate = .good
        }
        if candidate != displayed {
            let shownFor = t - displayedSince
            let urgent = candidate.isProblem && !displayed.isProblem
            if urgent || shownFor >= minDisplaySeconds {
                displayed = candidate
                displayedSince = t
            }
        }

        // 10. Haptics (one per frame, most important wins).
        if isScanning {
            if gated && !wasGated && active.contains(where: { $0 != .tracking || frame.tracking != .initializing }) {
                if t - lastWarning >= warningCooldown {
                    haptic = .warning
                    lastWarning = t
                }
            } else if bandEvent {
                haptic = .success
            } else if haptic == .none, shouldIntegrate {
                // Geiger counter: faster with quality, fastest while filling new cells.
                let rate = 2 + 6 * Double(quality) + (newCell ? 4 : 0)
                if t - lastTick >= 1 / rate {
                    haptic = .tick
                    lastTick = t
                }
            }
        }
        wasGated = gated && isScanning

        return CoachOutput(guidance: displayed, shouldIntegrate: shouldIntegrate, quality: quality, haptic: haptic,
                           linearSpeed: linearEMA, angularSpeed: angularEMA, speedFraction: speedFraction,
                           distance: frame.centerDepth, distanceZone: zone, coverage: snapshot,
                           showSurfaceTip: showSurfaceTip, wantsTorch: torchLatched, isReady: isReady,
                           suggestFinish: suggestFinish)
    }

    // MARK: Coverage

    private func cell(pose: simd_float4x4, center: SIMD3<Float>?) -> (CoachBand, Int)? {
        let th = thresholds
        let position = RigidTransform.translation(pose)
        var v: SIMD3<Float>
        switch th.coverage {
        case .orbit:
            guard let center else { return nil }
            v = position - center
        case .lookAround:
            v = RigidTransform.forward(pose)
        case .none:
            return nil
        }
        let len = simd_length(v)
        guard len > 1e-4 else { return nil }
        v /= len
        let elevation = asin(max(-1, min(1, v.y))) * 180 / .pi
        var azimuth = atan2(v.x, v.z) * 180 / .pi
        if azimuth < 0 { azimuth += 360 }
        let sector = min(11, Int(azimuth / 30))
        let band: CoachBand = elevation < th.bandEdges.low ? .low : (elevation < th.bandEdges.high ? .mid : .high)
        return (band, sector)
    }

    private mutating func locate(pose: simd_float4x4, depth: Float?) {
        if let (band, sector) = cell(pose: pose, center: centroid) {
            currentBand = band
            currentSector = sector
        }
    }

    /// Returns (new cell done, band/pass event).
    private mutating func updateCoverage(pose: simd_float4x4, depth: Float?, time t: Double) -> (Bool, Bool) {
        let th = thresholds
        if th.coverage == .orbit, let d = depth, d > 0 {
            // The point the camera looks at; the centroid settles over the first 90 good frames, then drifts slowly.
            let target = RigidTransform.translation(pose) + RigidTransform.forward(pose) * d
            if let c = centroid {
                centroidSamples += 1
                let alpha: Float = centroidSamples < 90 ? 1 / Float(centroidSamples + 1) : 0.005
                centroid = c + (target - c) * alpha
            } else {
                centroid = target
                centroidSamples = 1
            }
        }
        guard let (band, sector) = cell(pose: pose, center: centroid) else { return (false, false) }
        let previousBand = currentBand
        currentBand = band
        currentSector = sector
        if lastNewCellTime == nil { lastNewCellTime = t }
        var newCell = false
        var event = false
        if counts[band.rawValue][sector] < th.framesPerCell {
            counts[band.rawValue][sector] += 1
            if counts[band.rawValue][sector] == th.framesPerCell {
                newCell = true
                lastNewCellTime = t
            }
        }
        let doneSectors = counts[band.rawValue].filter { $0 >= th.framesPerCell }.count
        if !bandDone[band.rawValue], doneSectors >= th.sectorsPerBand {
            bandDone[band.rawValue] = true
            passDone[band.rawValue] = true
            event = true
            targetBand = firstIncompleteBand(after: band)
        } else if !passDone[band.rawValue], th.coverage == .orbit, doneSectors >= 5,
                  let last = lastNewCellTime, t - last >= passStallSeconds {
            // One-sided objects (wall-mounted): a stalled pass of >= 150 degrees counts as a pass.
            passDone[band.rawValue] = true
            event = true
            targetBand = firstIncompleteBand(after: band)
        }
        if let target = targetBand, band == target, previousBand != band {
            targetBand = nil // arrived in the requested band
        }
        if let target = targetBand, passDone[target.rawValue] {
            targetBand = firstIncompleteBand(after: band)
        }
        return (newCell, event)
    }

    /// Next band without a finished pass: from mid go lower first, from low go higher.
    private func firstIncompleteBand(after band: CoachBand?) -> CoachBand? {
        let order: [CoachBand]
        switch band {
        case .low?: order = [.mid, .high]
        case .mid?, nil: order = [.low, .high]
        case .high?: order = [.mid, .low]
        }
        return order.first { !passDone[$0.rawValue] }
    }

    public func coverageSnapshot() -> CoverageSnapshot {
        let n = Float(max(1, thresholds.framesPerCell))
        let fill = counts.map { $0.map { min(1, Float($0) / n) } }
        let done = counts.joined().filter { $0 >= thresholds.framesPerCell }.count
        return CoverageSnapshot(fill: fill, currentBand: currentBand, currentSector: currentSector, targetBand: targetBand,
                                bandsComplete: bandDone, fraction: Float(done) / 36)
    }

    // MARK: Report

    public func report() -> CoachReport {
        let tracked = max(trackedSeconds, 1e-6)
        let fast = Float((issueSeconds[.tooFast] ?? 0) / tracked)
        let dark = Float((issueSeconds[.tooDark] ?? 0) / tracked)
        let dist = Float(((issueSeconds[.tooFar] ?? 0) + (issueSeconds[.tooClose] ?? 0)) / tracked)
        let texture = Float((issueSeconds[.lowTexture] ?? 0) / tracked)
        let lost = Float((issueSeconds[.tracking] ?? 0) / tracked)
        let good = trackedSeconds > 0 ? Float(goodSeconds / tracked) : 0
        let snapshot = coverageSnapshot()
        let usesCoverage = thresholds.coverage != .none

        // Coverage: full orbit, or a solid one-sided (front) scan for wall-mounted items.
        var coverageScore: Float = 1
        var coverageFix: String?
        var frontOnly = false
        if usesCoverage {
            let full = snapshot.fraction
            let front = frontHalfFraction()
            coverageScore = min(1, full / thresholds.finishFraction)
            if thresholds.coverage == .orbit, front >= 0.8, full < 0.65 {
                frontOnly = true
                coverageScore = max(coverageScore, 0.85)
            }
            let bandFill = CoachBand.allCases.map { b in Float(counts[b.rawValue].filter { $0 >= thresholds.framesPerCell }.count) / 12 }
            if let weakest = CoachBand.allCases.min(by: { bandFill[$0.rawValue] < bandFill[$1.rawValue] }),
               bandFill[weakest.rawValue] < 0.4, bandFill.max()! >= 0.4 {
                switch (thresholds.coverage, weakest) {
                case (.lookAround, .low): coverageFix = "Gaps low down: aim at the floor"
                case (.lookAround, .high): coverageFix = "Gaps up high: aim at the ceiling"
                case (_, .low): coverageFix = "Gaps low down: scan from lower"
                case (_, .high): coverageFix = "Gaps on top: scan from higher"
                default: coverageFix = "Gaps at mid height"
                }
            } else if frontOnly {
                coverageFix = "Back side not scanned (fine if wall-mounted)"
            } else if thresholds.coverage == .orbit {
                coverageFix = "Gaps on the back side"
            } else {
                coverageFix = "Gaps: turn all the way around"
            }
        }
        let techniqueScore = trackedSeconds > 0 ? good : 0
        let score = usesCoverage ? 0.55 * coverageScore + 0.45 * techniqueScore : techniqueScore
        let grade: CoachReport.Grade = score >= 0.85 ? .a : score >= 0.7 ? .b : score >= 0.55 ? .c : score >= 0.4 ? .d : .f

        // The single most useful fix: a technique problem that ruined a big share of the scan comes
        // first (it is also why coverage is missing); otherwise the biggest loss.
        let technique: [(Float, String)] = [
            (fast, "Mostly scanned too fast"),
            (dark, "Low light: turn on lights"),
            (dist, thresholds.coverage == .orbit ? "Mostly too far: stay within 1 m" : "Mostly out of range"),
            (lost, "Tracking lost often: move slower, add light"),
            (texture * 0.7, "Shiny or plain surface: matte spray helps"),
        ]
        let worstTechnique = technique.max { $0.0 < $1.0 }!
        var fix: String?
        if worstTechnique.0 >= 0.3 {
            fix = worstTechnique.1
        } else if usesCoverage, let coverageFix, (1 - coverageScore) * 0.55 > worstTechnique.0 * 0.45 {
            fix = coverageScore >= 0.999 ? nil : coverageFix
        } else if worstTechnique.0 >= 0.05 {
            fix = worstTechnique.1
        }
        if frontOnly, fix == nil || grade == .a { fix = coverageFix }
        return CoachReport(grade: grade, score: score, fix: fix, coverageFraction: snapshot.fraction, goodFraction: good,
                           tooFastFraction: fast, tooDarkFraction: dark, distanceFraction: dist,
                           lowTextureFraction: texture, seconds: trackedSeconds)
    }

    /// Best coverage over any 6 contiguous sectors (a half orbit), all bands.
    private func frontHalfFraction() -> Float {
        var best: Float = 0
        for start in 0..<12 {
            var done = 0
            for k in 0..<6 {
                for b in 0..<3 where counts[b][(start + k) % 12] >= thresholds.framesPerCell { done += 1 }
            }
            best = max(best, Float(done) / 18)
        }
        return best
    }
}
