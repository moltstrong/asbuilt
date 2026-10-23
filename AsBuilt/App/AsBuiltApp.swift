import SwiftUI
import AsBuiltCore

@main
struct AsBuiltApp: App {
    @StateObject private var store: JobStore
    @StateObject private var router: Router

    init() {
        // Keep launch cheap and exception-free: read JSON and write the demo job/plan JSON only.
        // The demo's DXF/SVG/CSV/PDF/USDZ files are generated after the first frame (RootView .task).
        let launch = LaunchOptions.current
        let store = JobStore()
        store.ensureDemoJob(reset: launch.resetDemo)
        _store = StateObject(wrappedValue: store)
        _router = StateObject(wrappedValue: Router(launch: launch))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(router)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var store: JobStore

    var body: some View {
        NavigationStack(path: $router.path) {
            JobListView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .job(let id):
                        JobDetailView(jobID: id)
                    case .capture(let jobID, let captureID, let tab):
                        CaptureDetailView(jobID: jobID, captureID: captureID, initialTab: tab)
                    case .capabilities:
                        CapabilitiesView()
                    case .settings:
                        SettingsView()
                    case .measurements(let jobID):
                        MeasurementsView(jobID: jobID)
                    case .coachPreview(let name):
                        CoachPreviewView(scenario: CoachDemo.Scenario(rawValue: name) ?? .midScan)
                    }
                }
        }
        .task { await store.prepareDemoExports() }
    }
}
