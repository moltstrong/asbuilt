import SwiftUI
import AsBuiltCore

#if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
import RealityKit

/// Guided Object Capture (iOS 17+, LiDAR devices) followed by on-device reconstruction to model.usdz.
/// The photo folder is kept so the office can rebuild a higher-detail model on a Mac.
struct ObjectCaptureFlowView: View {
    let jobID: UUID
    var onFinished: (UUID?) -> Void

    enum Phase: Equatable {
        case capturing
        case reconstructing
        case done
        case failed(String)
    }

    @EnvironmentObject private var store: JobStore
    @Environment(\.dismiss) private var dismiss
    @State private var session: ObjectCaptureSession?
    @State private var captureID = UUID()
    @State private var phase: Phase = .capturing
    @State private var progress: Double = 0
    @State private var shots = 0

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
                VStack(spacing: 16) {
                    Text("Building 3D model").font(.title2.bold())
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 280)
                    Text("\(Int(progress * 100))% · \(shots) photos").monospacedDigit()
                    Text("Keep the app open. Photos are already saved to the job.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding()
            case .done:
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(Theme.ok)
                    Text("Object saved").font(.title2.bold())
                    Button("Open") {
                        onFinished(captureID)
                        dismiss()
                    }
                    .buttonStyle(BigButtonStyle())
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding()
            case .failed(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 48)).foregroundStyle(Theme.warn)
                    Text(message).multilineTextAlignment(.center)
                    Button("Close") {
                        onFinished(store.capture(job: jobID, capture: captureID) == nil ? nil : captureID)
                        dismiss()
                    }
                    .buttonStyle(BigButtonStyle())
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding()
            }
        }
        .task { start() }
        .onChange(of: session?.state) { _, newState in
            handle(newState)
        }
        .onChange(of: session?.numberOfShotsTaken) { _, count in
            if let count { shots = count }
        }
    }

    private var captureDirectory: URL { store.captureDirectory(job: jobID, capture: captureID) }
    private var imagesDirectory: URL { captureDirectory.appendingPathComponent(CaptureFile.images, isDirectory: true) }
    private var checkpointDirectory: URL { captureDirectory.appendingPathComponent(CaptureFile.checkpoint, isDirectory: true) }

    private func start() {
        guard session == nil else { return }
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

    private func handle(_ state: ObjectCaptureSession.CaptureState?) {
        switch state {
        case .completed?:
            let count = session?.numberOfShotsTaken ?? shots
            shots = count
            // Release the capture session (camera + memory) before reconstruction starts.
            session = nil
            Task { await reconstruct(imageCount: count) }
        case .failed(let error)?:
            session = nil
            if let captureError = error as? ObjectCaptureSession.Error, case .cancelled = captureError { return }
            phase = .failed("Capture stopped: \(error.localizedDescription)")
        default:
            break
        }
    }

    private func reconstruct(imageCount: Int) async {
        phase = .reconstructing
        let number = (store.job(jobID)?.objectCaptures.count ?? 0) + 1
        var capture = Capture(id: captureID, kind: .object, origin: .objectCapture, title: "Object \(number)",
                              status: .processing, imageCount: imageCount)
        store.addCapture(capture, to: jobID)
        let modelURL = captureDirectory.appendingPathComponent(CaptureFile.modelUSDZ)

        guard PhotogrammetrySession.isSupported else {
            capture.status = .imagesOnly
            capture.statusMessage = "On-device reconstruction is not supported here. Photos saved: reconstruct on a Mac."
            store.updateCapture(capture, in: jobID)
            phase = .done
            return
        }
        do {
            var configuration = PhotogrammetrySession.Configuration()
            configuration.checkpointDirectory = checkpointDirectory
            let photogrammetry = try PhotogrammetrySession(input: imagesDirectory, configuration: configuration)
            try photogrammetry.process(requests: [.modelFile(url: modelURL)])
            outputs: for try await output in photogrammetry.outputs {
                switch output {
                case .requestProgress(_, let fraction):
                    progress = fraction
                case .requestError(_, let error):
                    throw error
                case .processingCancelled:
                    throw CancellationError()
                case .processingComplete:
                    break outputs
                default:
                    break
                }
            }
            if FileManager.default.fileExists(atPath: modelURL.path) {
                capture.status = .complete
                capture.statusMessage = nil
            } else {
                capture.status = .imagesOnly
                capture.statusMessage = "No model was produced. Photos saved: reconstruct on a Mac."
            }
        } catch {
            capture.status = .imagesOnly
            capture.statusMessage = "Reconstruction failed (\(error.localizedDescription)). Photos saved: reconstruct on a Mac."
        }
        store.updateCapture(capture, in: jobID)
        phase = .done
    }
}

/// Step-by-step controls over the camera feed: detect the object, capture, finish.
struct ObjectCaptureControls: View {
    let session: ObjectCaptureSession
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(BigButtonStyle(filled: false, color: .white))
                    .frame(width: 120)
                Spacer()
                Text("\(session.numberOfShotsTaken) photos")
                    .font(.headline.monospacedDigit())
                    .padding(.horizontal, 14).padding(.vertical, 10)
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
    }

    @ViewBuilder
    private var actionArea: some View {
        switch session.state {
        case .ready:
            instruction("Point at the object you want to capture.")
            Button("Continue") { _ = session.startDetecting() }
                .buttonStyle(BigButtonStyle())
        case .detecting:
            instruction("Adjust the box so it fits the object.")
            Button("Start capture") { session.startCapturing() }
                .buttonStyle(BigButtonStyle())
        case .capturing:
            if session.userCompletedScanPass {
                instruction("Scan pass complete.")
                HStack(spacing: 12) {
                    Button("Another pass") { session.beginNewScanPass() }
                        .buttonStyle(BigButtonStyle(filled: false, color: .white))
                    Button("Finish") { session.finish() }
                        .buttonStyle(BigButtonStyle())
                }
            } else {
                instruction("Walk slowly all the way around the object.")
                Button("Finish now") { session.finish() }
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
