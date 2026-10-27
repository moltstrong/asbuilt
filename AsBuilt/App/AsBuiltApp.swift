import SwiftUI
import UIKit
import AsBuiltCore

/// Receives background URLSession wake-ups (cloud build chunk uploads, and "is the model ready?" checks,
/// finishing while AsBuilt was suspended or killed) and hands iOS's completion handler to their owner.
final class AsBuiltAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier == ReconReadyNotifier.sessionID {
            // A "is the cloud model ready?" check finished while AsBuilt was suspended.
            Task { @MainActor in
                ReconReadyNotifier.shared.backgroundEventsCompletion = completionHandler
                ReconReadyNotifier.shared.activate()
            }
            return
        }
        guard identifier == RemoteBuildService.backgroundSessionID else {
            completionHandler()
            return
        }
        Task { @MainActor in
            RemoteBuildService.shared.backgroundEventsCompletion = completionHandler
        }
    }
}

@main
struct AsBuiltApp: App {
    @UIApplicationDelegateAdaptor(AsBuiltAppDelegate.self) private var appDelegate
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
    @Environment(\.scenePhase) private var scenePhase

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
                    case .objectPlacePreview:
                        ObjectPlacePreviewView()
                    case .remoteBuildPreview(let name):
                        RemoteBuildPreviewView(scenario: name)
                    }
                }
        }
        .task {
            // Cloud full-detail builds pick up where they stopped (app killed, network lost, server moved).
            RemoteBuildService.shared.attach(store)
            RemoteBuildService.shared.resumeActive()
            ReconReadyNotifier.shared.activate()  // receive pending background "model ready?" checks
            await store.prepareDemoExports()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { RemoteBuildService.shared.resumeActive() }
            if phase == .background { RemoteBuildService.shared.scheduleReadyChecks() }
        }
    }
}
