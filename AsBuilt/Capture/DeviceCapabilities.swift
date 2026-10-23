import SwiftUI
import AVFoundation
import AsBuiltCore

#if canImport(ARKit) && !targetEnvironment(simulator)
import ARKit
#endif
#if canImport(RoomPlan) && !targetEnvironment(simulator)
import RoomPlan
#endif
#if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
import RealityKit
#endif

/// What this device can do. Every check degrades to `false` in the Simulator.
struct DeviceCapabilities {
    var isSimulator: Bool
    var deviceModel: String
    var systemVersion: String
    var hasLiDAR: Bool
    var roomPlanSupported: Bool
    var objectCaptureSupported: Bool
    var onDeviceReconstruction: Bool
    var cameraStatus: AVAuthorizationStatus

    @MainActor
    static func current() -> DeviceCapabilities {
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif

        var lidar = false
        #if canImport(ARKit) && !targetEnvironment(simulator)
        lidar = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        #endif

        var roomPlan = false
        #if canImport(RoomPlan) && !targetEnvironment(simulator)
        roomPlan = RoomCaptureSession.isSupported
        #endif

        var objectCapture = false
        var reconstruction = false
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        objectCapture = ObjectCaptureSession.isSupported
        reconstruction = PhotogrammetrySession.isSupported
        #endif

        return DeviceCapabilities(isSimulator: simulator, deviceModel: modelIdentifier(),
                                  systemVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
                                  hasLiDAR: lidar, roomPlanSupported: roomPlan, objectCaptureSupported: objectCapture,
                                  onDeviceReconstruction: reconstruction,
                                  cameraStatus: AVCaptureDevice.authorizationStatus(for: .video))
    }

    static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "\(simulated) (Simulator)"
        }
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        let id = mirror.children.reduce(into: "") { result, element in
            if let value = element.value as? Int8, value != 0 { result.append(Character(UnicodeScalar(UInt8(value)))) }
        }
        return id.isEmpty ? UIDevice.current.model : id
    }

    var roomScanBlocker: String? {
        if isSimulator { return "Room scanning needs a real iPhone or iPad with LiDAR. The Simulator has no camera or depth sensor." }
        if !roomPlanSupported { return "Room scanning needs LiDAR (iPhone 12 Pro or later Pro model, or iPad Pro 2020 or later)." }
        if cameraStatus == .denied || cameraStatus == .restricted { return "Camera access is off. Enable it in Settings > AsBuilt." }
        return nil
    }

    var objectCaptureBlocker: String? {
        if isSimulator { return "Object capture needs a real iPhone or iPad with LiDAR. The Simulator has no camera." }
        if !objectCaptureSupported { return "Object capture needs a LiDAR iPhone/iPad Pro on iOS 17 or later." }
        if cameraStatus == .denied || cameraStatus == .restricted { return "Camera access is off. Enable it in Settings > AsBuilt." }
        return nil
    }
}
