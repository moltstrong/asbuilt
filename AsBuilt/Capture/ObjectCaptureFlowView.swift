import SwiftUI
import AsBuiltCore

#if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
import RealityKit

/// Guided Object Capture (iOS 17+, LiDAR devices) followed by on-device reconstruction to model.usdz
/// with an automatic retry chain (`ObjectReconstructor`). The photo folder is always kept, so the
/// model can be rebuilt later ("Retry 3D build") or on a Mac. If Apple's photogrammetry fails on
/// this phone, the crew is offered the LiDAR Mesh scan, which does not use photogrammetry.
struct ObjectCaptureFlowView: View {
    let jobID: UUID
    var onFinished: (UUID?) -> Void

    enum Phase: Equatable {
        case capturing
        case reconstructing
        case done
        /// Photos saved, every reconstruction attempt failed (plain-language message).
        case buildFailed(String)
        case failed(String)
    }

    @EnvironmentObject private var store: JobStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var reconstructor = ObjectReconstructor()
    @State private var session: ObjectCaptureSession?
    @State private var captureID = UUID()
    @State private var phase: Phase = .capturing
    @State private var shots = 0
    @State private var showingMeshScan = false
    @State private var savedMeshID: UUID?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session, phase == .capturing {
                ObjectCaptureView(session: session)
                    .ignoresSafeArea()
                ObjectCaptureControls(session: session, onCancel: cancel)
            }
            switch phase {
            case .capturing:
                if session == nil { ProgressView().tint(.white) }
            case .reconstructing:
                ReconstructionProgressCard(reconstructor: reconstructor, photos: shots)
                    .padding()
            case .done:
                resultCard(icon: "checkmark.circle.fill", color: Theme.ok, title: "Object saved", message: nil) {
                    Button("Open") { finish(open: captureID) }
                        .buttonStyle(BigButtonStyle())
                }
            case .buildFailed(let message):
                resultCard(icon: "exclamationmark.triangle.fill", color: Theme.warn, title: "Photos saved, no 3D model yet",
                           message: message) {
                    Button {
                        Task { await reconstruct(reason: "Retry 3D build (capture screen)") }
                    } label: {
                        Label("Retry 3D build", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(BigButtonStyle())
                    Button {
                        showingMeshScan = true
                    } label: {
                        Label("Scan it with LiDAR mesh instead", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    }
                    .buttonStyle(BigButtonStyle(filled: false))
                    .accessibilityIdentifier("meshInsteadButton")
                    Button("Close") { finish(open: captureID) }
                        .buttonStyle(BigButtonStyle(filled: false, color: .secondary))
                }
            case .failed(let message):
                resultCard(icon: "exclamationmark.triangle.fill", color: Theme.warn, title: "Capture stopped", message: message) {
                    Button {
                        showingMeshScan = true
                    } label: {
                        Label("Scan it with LiDAR mesh instead", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    }
                    .buttonStyle(BigButtonStyle(filled: false))
                    Button("Close") {
                        finish(open: store.capture(job: jobID, capture: captureID) == nil ? nil : captureID)
                    }
                    .buttonStyle(BigButtonStyle())
                }
            }
        }
        .task { start() }
        .onChange(of: session?.state) { _, newState in
            handle(newState)
        }
        .onChange(of: session?.numberOfShotsTaken) { _, count in
            if let count { shots = count }
        }
        .fullScreenCover(isPresented: $showingMeshScan, onDismiss: {
            // Open the new mesh scan once its cover is gone (never dismiss two covers at once).
            if let savedMeshID { finish(open: savedMeshID) }
        }) {
            MeshScanLauncher(jobID: jobID) { meshID in savedMeshID = meshID }
                .environmentObject(store)
        }
    }

    private func resultCard<Buttons: View>(icon: String, color: Color, title: String, message: String?,
                                           @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 52)).foregroundStyle(color)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            if let message {
                Text(message).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            buttons()
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding()
    }

    private var captureDirectory: URL { store.captureDirectory(job: jobID, capture: captureID) }
    private var imagesDirectory: URL { captureDirectory.appendingPathComponent(CaptureFile.images, isDirectory: true) }
    private var checkpointDirectory: URL { captureDirectory.appendingPathComponent(CaptureFile.checkpoint, isDirectory: true) }

    private func start() {
        guard session == nil, phase == .capturing else { return }
        guard ObjectCaptureSession.isSupported else {
            phase = .failed("Object Capture needs an iPhone or iPad with LiDAR running iOS 17 or later.")
            return
        }
        do {
            try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: checkpointDirectory, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Could not create the capture folder: \(error.localizedDescription)")
            return
        }
        var configuration = ObjectCaptureSession.Configuration()
        configuration.checkpointDirectory = checkpointDirectory
        configuration.isOverCaptureEnabled = false
        let newSession = ObjectCaptureSession()
        newSession.start(imagesDirectory: imagesDirectory, configuration: configuration)
        session = newSession
    }

    private func cancel() {
        session?.cancel()
        session = nil
        try? FileManager.default.removeItem(at: captureDirectory)
        onFinished(nil)
        dismiss()
    }

    private func finish(open id: UUID?) {
        onFinished(id)
        dismiss()
    }

    private func handle(_ state: ObjectCaptureSession.CaptureState?) {
        switch state {
        case .completed?:
            let count = session?.numberOfShotsTaken ?? shots
            shots = count
            // Release the capture session (camera + memory) before reconstruction starts.
            session = nil
            let number = (store.job(jobID)?.objectCaptures.count ?? 0) + 1
            let capture = Capture(id: captureID, kind: .object, origin: .objectCapture, title: "Object \(number)",
                                  status: .processing, imageCount: count)
            store.addCapture(capture, to: jobID)
            Task { await reconstruct(reason: "after capture, \(count) shots") }
        case .failed(let error)?:
            session = nil
            if let captureError = error as? ObjectCaptureSession.Error, case .cancelled = captureError { return }
            let ns = error as NSError
            let explanation = ReconstructionErrorExplainer.explain(domain: ns.domain, code: ns.code,
                                                                   description: String(reflecting: error), imageCount: shots)
            phase = .failed("\(explanation.message)\n\n(\(explanation.technical))")
        default:
            break
        }
    }

    private func reconstruct(reason: String) async {
        guard !reconstructor.isRunning, var capture = store.capture(job: jobID, capture: captureID) else { return }
        phase = .reconstructing
        capture.status = .processing
        capture.statusMessage = nil
        store.updateCapture(capture, in: jobID)
        let outcome = await reconstructor.run(captureDirectory: captureDirectory, reason: reason)
        capture = store.capture(job: jobID, capture: captureID) ?? capture
        capture.reconstructionAttempts = (capture.reconstructionAttempts ?? 0) + outcome.attempts
        if outcome.succeeded {
            capture.status = .complete
            capture.statusMessage = nil
            phase = .done
        } else {
            capture.status = .imagesOnly
            capture.statusMessage = outcome.message
            phase = .buildFailed(outcome.message ?? "Apple's 3D builder couldn't finish this model.")
        }
        store.updateCapture(capture, in: jobID)
        store.touchExports()
    }
}

/// "Building 3D model" card: attempt N of 3, stage, progress.
struct ReconstructionProgressCard: View {
    @ObservedObject var reconstructor: ObjectReconstructor
    var photos: Int?

    var body: some View {
        VStack(spacing: 14) {
            Text("Building 3D model").font(.title2.bold())
            ProgressView(value: reconstructor.progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 280)
            Text("\(Int(reconstructor.progress * 100))%\(photos.map { " · \($0) photos" } ?? "")")
                .monospacedDigit()
            Text("Attempt \(max(1, reconstructor.attemptNumber)) of \(reconstructor.attemptCount)\(reconstructor.stageText.isEmpty ? "" : " · \(reconstructor.stageText)")")
                .font(.subheadline.weight(.semibold))
            Text("Keep the app open. If Apple's builder fails, AsBuilt retries with different settings automatically. Photos are already saved to the job.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

/// Step-by-step controls over the camera feed: detect the object, capture, finish.
struct ObjectCaptureControls: View {
    let session: ObjectCaptureSession
    var onCancel: () -> Void

    @State private var passes = 1
    @State private var confirmEarlyFinish = false

    private var shots: Int { session.numberOfShotsTaken }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(BigButtonStyle(filled: false, color: .white))
                    .frame(width: 120)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(shots) photos").font(.headline.monospacedDigit())
                    if session.state == .capturing {
                        Text("Pass \(passes) of 3").font(.caption.weight(.semibold))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            if let hint = feedbackText {
                Text(hint)
                    .font(.headline)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            actionArea
        }
        .padding()
        .confirmationDialog(earlyFinishTitle, isPresented: $confirmEarlyFinish, titleVisibility: .visible) {
            Button("Keep capturing", role: .cancel) {}
            Button("Finish anyway", role: .destructive) { session.finish() }
        } message: {
            Text(earlyFinishMessage)
        }
    }

    private var earlyFinishTitle: String {
        shots < ObjectCaptureGuidance.minimumShots ? "Only \(shots) photos" : "Finish before the circle is complete?"
    }

    private var earlyFinishMessage: String {
        if shots < ObjectCaptureGuidance.minimumShots {
            return "With fewer than \(ObjectCaptureGuidance.minimumShots) photos the 3D build will very likely fail. Keep walking slowly around the object until the dial is complete."
        }
        return "Models line up best after a full circle (3 passes at different heights). Finishing now may produce no model."
    }

    @ViewBuilder
    private var actionArea: some View {
        switch session.state {
        case .ready:
            instruction("Point at the object you want to capture. Use good light and a textured surface under it.")
            Button("Continue") { _ = session.startDetecting() }
                .buttonStyle(BigButtonStyle())
        case .detecting:
            instruction("Adjust the box so it fits the object.")
            Button("Start capture") { session.startCapturing() }
                .buttonStyle(BigButtonStyle())
        case .capturing:
            if session.userCompletedScanPass {
                instruction(passes < 3
                            ? "Pass \(passes) complete. Do another circle \(passes == 1 ? "lower, aiming up" : "higher, aiming down") for a model that lines up."
                            : "Pass \(passes) complete. You can finish now.")
                HStack(spacing: 12) {
                    Button("Another pass") {
                        passes += 1
                        session.beginNewScanPass()
                    }
                    .buttonStyle(BigButtonStyle(filled: passes < 3, color: passes < 3 ? Theme.accent : .white))
                    Button("Finish") { session.finish() }
                        .buttonStyle(BigButtonStyle(filled: passes >= 3, color: passes >= 3 ? Theme.accent : .white))
                }
            } else {
                instruction(shots < ObjectCaptureGuidance.minimumShots
                            ? "Walk slowly all the way around the object. Keep going until the dial is complete."
                            : "Keep circling until the dial is complete.")
                Button(shots < ObjectCaptureGuidance.minimumShots ? "Finish early (\(shots)/\(ObjectCaptureGuidance.minimumShots))" : "Finish now") {
                    confirmEarlyFinish = true
                }
                .buttonStyle(BigButtonStyle(filled: false, color: .white))
            }
        case .finishing:
            ProgressView("Saving photos…").tint(.white).foregroundStyle(.white)
        default:
            EmptyView()
        }
    }

    private func instruction(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .shadow(radius: 4)
    }

    private var feedbackText: String? {
        for item in session.feedback {
            switch item {
            case .objectTooClose: return "Move back"
            case .objectTooFar: return "Move closer"
            case .movingTooFast: return "Slow down"
            case .environmentLowLight: return "More light needed"
            case .environmentTooDark: return "Too dark"
            case .outOfFieldOfView: return "Aim at the object"
            case .objectNotFlippable: return "Object can't be flipped"
            case .overCapturing: return "Enough photos here, keep moving"
            case .objectNotDetected: return "Object not detected"
            @unknown default: continue
            }
        }
        return nil
    }
}
#endif
