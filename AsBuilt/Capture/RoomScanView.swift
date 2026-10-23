import SwiftUI
import AsBuiltCore

#if canImport(RoomPlan) && !targetEnvironment(simulator)
import RoomPlan

/// Full-screen RoomPlan scanner with Apple's built-in coaching.
struct RoomScanView: View {
    let jobID: UUID
    var onFinished: (UUID?) -> Void

    @EnvironmentObject private var store: JobStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = RoomScanModel()
    @State private var roomName = ""
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        ZStack {
            RoomCaptureRepresentable(model: model)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Button("Cancel") {
                        model.cancel()
                        dismiss()
                    }
                    .buttonStyle(BigButtonStyle(filled: false, color: .white))
                    .frame(width: 120)
                    Spacer()
                    if model.phase == .scanning {
                        Button("Done") { model.finish() }
                            .buttonStyle(BigButtonStyle())
                            .frame(width: 120)
                    }
                }
                .padding()
                Spacer()
                if let hint = model.instruction, model.phase == .scanning {
                    Text(hint)
                        .font(.headline)
                        .padding()
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 40)
                }
                if model.phase == .processing {
                    ProgressView("Building room model…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.bottom, 40)
                }
                if model.phase == .review {
                    VStack(spacing: 12) {
                        Text("Scan complete").font(.title2.bold())
                        TextField("Room name (e.g. Kitchen)", text: $roomName)
                            .textFieldStyle(.roundedBorder)
                            .font(.title3)
                        if let errorText { Text(errorText).foregroundStyle(Theme.bad) }
                        Button(saving ? "Saving…" : "Save room & export") { save() }
                            .buttonStyle(BigButtonStyle())
                            .disabled(saving)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .padding()
                }
                if case .failed(let message) = model.phase {
                    Text(message)
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding()
                }
            }
        }
        .statusBarHidden()
    }

    private func save() {
        guard let room = model.finalRoom else { return }
        saving = true
        let title = roomName.trimmingCharacters(in: .whitespaces).isEmpty ? "Room \((store.job(jobID)?.roomCaptures.count ?? 0) + 1)" : roomName
        do {
            let capture = try RoomScanSaver.save(room: room, rawData: model.rawData, title: title, jobID: jobID, store: store)
            onFinished(capture.id)
            dismiss()
        } catch {
            errorText = error.localizedDescription
            saving = false
        }
    }
}

enum RoomScanSaver {
    /// Writes room.usdz (parametric), room.json, plan.json, DXF/SVG/PDF/CSV and registers the capture.
    @MainActor
    static func save(room: CapturedRoom, rawData: CapturedRoomData?, title: String, jobID: UUID, store: JobStore) throws -> Capture {
        let capture = Capture(kind: .room, origin: .roomPlan, title: title)
        let dir = store.captureDirectory(job: jobID, capture: capture.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try room.export(to: dir.appendingPathComponent(CaptureFile.roomUSDZ), exportOptions: .parametric)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(room).write(to: dir.appendingPathComponent(CaptureFile.roomJSON), options: .atomic)
        if let rawData {
            try? encoder.encode(rawData).write(to: dir.appendingPathComponent("roomdata.json"), options: .atomic)
        }

        let plan = RoomPlanAdapter.floorPlan(from: room, name: title)
        try store.setPlan(plan, job: jobID, capture: capture.id)
        store.addCapture(capture, to: jobID)
        if let job = store.job(jobID) {
            try ExportService.writePlanExports(plan: plan, to: dir, context: .init(job: job, capture: capture),
                                               units: Preferences.units, options: Preferences.takeoffOptions)
        }
        return capture
    }
}

@MainActor
final class RoomScanModel: ObservableObject {
    enum Phase: Equatable {
        case scanning, processing, review
        case failed(String)
    }

    @Published var phase: Phase = .scanning
    @Published var instruction: String?
    var finalRoom: CapturedRoom?
    var rawData: CapturedRoomData?
    weak var captureView: RoomCaptureView?

    func finish() {
        phase = .processing
        captureView?.captureSession.stop()
    }

    func cancel() {
        captureView?.captureSession.stop()
    }

    func text(for instruction: RoomCaptureSession.Instruction) -> String? {
        switch instruction {
        case .moveCloseToWall: return "Move closer to the wall"
        case .moveAwayFromWall: return "Move away from the wall"
        case .slowDown: return "Slow down"
        case .turnOnLight: return "Turn on more light"
        case .lowTexture: return "Point at an area with more detail"
        case .normal: return nil
        @unknown default: return nil
        }
    }
}

struct RoomCaptureRepresentable: UIViewControllerRepresentable {
    let model: RoomScanModel

    func makeUIViewController(context: Context) -> RoomCaptureViewController {
        RoomCaptureViewController(model: model)
    }

    func updateUIViewController(_ controller: RoomCaptureViewController, context: Context) {}
}

/// Hosts `RoomCaptureView`. The view controller is the view's delegate (RoomCaptureViewDelegate
/// requires NSCoding, which UIViewController already provides) and the session delegate.
final class RoomCaptureViewController: UIViewController, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    private let model: RoomScanModel
    private var captureView: RoomCaptureView!

    init(model: RoomScanModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        captureView = RoomCaptureView(frame: view.bounds)
        captureView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        captureView.delegate = self
        captureView.captureSession.delegate = self
        view.addSubview(captureView)
        model.captureView = captureView
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        var configuration = RoomCaptureSession.Configuration()
        configuration.isCoachingEnabled = true
        captureView.captureSession.run(configuration: configuration)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureView.captureSession.stop()
    }

    // MARK: RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        Task { @MainActor in
            if let error {
                // RoomCaptureView's internal processing failed; retry explicitly with RoomBuilder.
                await self.rebuild(after: error)
            } else {
                self.model.finalRoom = processedResult
                self.model.phase = .review
            }
        }
    }

    // MARK: RoomCaptureSessionDelegate

    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        Task { @MainActor in self.model.instruction = self.model.text(for: instruction) }
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        Task { @MainActor in self.model.rawData = data }
    }

    @MainActor
    private func rebuild(after error: Error) async {
        guard let data = model.rawData else {
            model.phase = .failed("Scan could not be processed: \(error.localizedDescription)")
            return
        }
        do {
            let builder = RoomBuilder(options: [.beautifyObjects])
            model.finalRoom = try await builder.capturedRoom(from: data)
            model.phase = .review
        } catch {
            model.phase = .failed("Scan could not be processed: \(error.localizedDescription)")
        }
    }
}
#endif
