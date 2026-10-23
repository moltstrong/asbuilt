import SwiftUI
import AsBuiltCore

enum CaptureTab: String, CaseIterable, Identifiable, Hashable {
    case plan = "Plan"
    case takeoff = "Takeoff"
    case model = "3D"
    case files = "Files"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .plan: return "square.split.bottomrightquarter"
        case .takeoff: return "list.number"
        case .model: return "cube"
        case .files: return "square.and.arrow.up"
        }
    }
}

enum Route: Hashable {
    case job(UUID)
    case capture(job: UUID, capture: UUID, tab: CaptureTab)
    case capabilities
    case settings
    /// Measure-tool measurements of a job (list, tape calibration, CSV).
    case measurements(UUID)
    /// Capture Coach HUD driven by synthetic metrics (CI screenshots; the Simulator has no AR).
    case coachPreview(String)
    /// "Full detail on your Mac" progress card with synthetic states (CI screenshots).
    case remoteBuildPreview(String)
}

/// Launch arguments used for demos, UI review and CI screenshots, e.g.
/// `xcrun simctl launch booted com.moltstrong.asbuilt -AsBuiltScreen plan`.
struct LaunchOptions {
    /// jobs | job | plan | takeoff | takeoff-walls | model | files | kitchen | mesh | mesh-files | mesh-quicklook |
    /// detail | detail-files | measurements | coach | coach-fast | coach-far | coach-band | coach-grade |
    /// mac-build | mac-build-done | mac-build-offline | mac-build-upload | capabilities | settings
    var screen: String?
    var resetDemo: Bool

    static var current: LaunchOptions {
        let defaults = UserDefaults.standard
        return LaunchOptions(screen: defaults.string(forKey: "AsBuiltScreen"),
                             resetDemo: defaults.bool(forKey: "AsBuiltResetDemo"))
    }

    /// `-AsBuiltScreen mesh-quicklook`: the 3D tab opens AR Quick Look on the model once (CI screenshots).
    static var autoOpenQuickLook: Bool { LaunchOptions.current.screen == "mesh-quicklook" }

    /// Section the takeoff screen should scroll to on appear (CI screenshots).
    static var takeoffScrollTarget: String? {
        LaunchOptions.current.screen == "takeoff-walls" ? "walls" : nil
    }
}

@MainActor
final class Router: ObservableObject {
    @Published var path: [Route] = []

    init(launch: LaunchOptions = .current) {
        path = Router.initialPath(for: launch.screen)
    }

    static func initialPath(for screen: String?) -> [Route] {
        let job = SampleData.demoJobID
        let bedroom = SampleData.demoCaptureID
        let kitchen = SampleData.demoKitchenCaptureID
        switch screen {
        case "job": return [.job(job)]
        case "plan": return [.job(job), .capture(job: job, capture: bedroom, tab: .plan)]
        case "takeoff", "takeoff-walls": return [.job(job), .capture(job: job, capture: bedroom, tab: .takeoff)]
        case "model": return [.job(job), .capture(job: job, capture: bedroom, tab: .model)]
        case "files": return [.job(job), .capture(job: job, capture: bedroom, tab: .files)]
        case "kitchen": return [.job(job), .capture(job: job, capture: kitchen, tab: .plan)]
        case "mesh", "mesh-quicklook": return [.job(job), .capture(job: job, capture: SampleData.demoMeshCaptureID, tab: .model)]
        case "mesh-files": return [.job(job), .capture(job: job, capture: SampleData.demoMeshCaptureID, tab: .files)]
        case "detail": return [.job(job), .capture(job: job, capture: SampleData.demoDetailCaptureID, tab: .model)]
        case "detail-files": return [.job(job), .capture(job: job, capture: SampleData.demoDetailCaptureID, tab: .files)]
        case "measurements": return [.job(job), .measurements(job)]
        case "coach", "coach-fast", "coach-far", "coach-band", "coach-grade": return [.coachPreview(screen ?? "coach")]
        case "mac-build", "mac-build-done", "mac-build-offline", "mac-build-upload": return [.remoteBuildPreview(screen ?? "mac-build")]
        case "capabilities": return [.capabilities]
        case "settings": return [.settings]
        default: return []
        }
    }
}
