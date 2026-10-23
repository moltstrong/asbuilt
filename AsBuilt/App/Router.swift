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
}

/// Launch arguments used for demos, UI review and CI screenshots, e.g.
/// `xcrun simctl launch booted com.moltstrong.asbuilt -AsBuiltScreen plan`.
struct LaunchOptions {
    /// jobs | job | plan | takeoff | takeoff-walls | model | files | kitchen | capabilities | settings
    var screen: String?
    var resetDemo: Bool

    static var current: LaunchOptions {
        let defaults = UserDefaults.standard
        return LaunchOptions(screen: defaults.string(forKey: "AsBuiltScreen"),
                             resetDemo: defaults.bool(forKey: "AsBuiltResetDemo"))
    }

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
        case "capabilities": return [.capabilities]
        case "settings": return [.settings]
        default: return []
        }
    }
}
