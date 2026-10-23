import Foundation
import AsBuiltCore

#if os(iOS) && !targetEnvironment(simulator)
import ARKit
import AVFoundation
import simd

/// Plain-buffer copies of ARFrame data. Copy them in `session(_:didUpdate:)` and never keep the
/// ARFrame itself: ARKit recycles a small pool of frames and holding one stalls capture
/// ("delegate is retaining N ARFrames").
enum ARFrameCopy {
    /// Runs main-actor work from an ARSessionDelegate callback (ARKit's default delegate queue is the
    /// main queue); returns nil instead of trapping if a callback ever arrives on another thread.
    static func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated { body() }
    }

    /// Coach metrics for one frame (cheap: ~300 depth samples + strided confidence count).
    static func coachFrame(_ frame: ARFrame, external: Set<CoachIssue> = [], includeFeatures: Bool = true) -> CoachFrame {
        var center: Float?
        var highFraction: Float?
        if let depth = frame.smoothedSceneDepth ?? frame.sceneDepth {
            center = centerMedianDepth(depth.depthMap)
            if let conf = depth.confidenceMap { highFraction = highConfidenceFraction(conf) }
        }
        return CoachFrame(timestamp: frame.timestamp, cameraToWorld: frame.camera.transform,
                          ambientIntensity: frame.lightEstimate.map { Float($0.ambientIntensity) },
                          centerDepth: center, highConfidenceFraction: highFraction,
                          tracking: CoachTracking(frame.camera.trackingState),
                          featureCount: includeFeatures ? frame.rawFeaturePoints?.points.count : nil,
                          external: external)
    }

    /// Median depth of the central ~20 % of the depth map (15 x 15 samples).
    static func centerMedianDepth(_ buffer: CVPixelBuffer) -> Float? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        guard w > 8, h > 8 else { return nil }
        var values: [Float] = []
        values.reserveCapacity(225)
        for sj in 0..<15 {
            let j = h * 2 / 5 + sj * (h / 5) / 15
            for si in 0..<15 {
                let i = w * 2 / 5 + si * (w / 5) / 15
                let d = base.advanced(by: j * row + i * 4).assumingMemoryBound(to: Float32.self).pointee
                if d.isFinite && d > 0.05 { values.append(d) }
            }
        }
        guard values.count >= 20 else { return nil }
        values.sort()
        return values[values.count / 2]
    }

    /// Fraction of pixels at ARConfidenceLevel.high (every 4th pixel in both directions).
    static func highConfidenceFraction(_ buffer: CVPixelBuffer) -> Float? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        var high = 0, total = 0
        var j = 0
        while j < h {
            var i = 0
            while i < w {
                if base[j * row + i] >= UInt8(ARConfidenceLevel.high.rawValue) { high += 1 }
                total += 1
                i += 4
            }
            j += 4
        }
        return total > 0 ? Float(high) / Float(total) : nil
    }

    /// Depth (m) and confidence copied row by row (pixel buffers have row padding).
    static func depth(_ frame: ARFrame) -> (width: Int, height: Int, depth: [Float], confidence: [UInt8]?)? {
        guard let data = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let map = data.depthMap
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        let row = CVPixelBufferGetBytesPerRow(map)
        guard w > 0, h > 0, row >= w * 4 else { return nil }
        var depth = [Float](repeating: 0, count: w * h)
        depth.withUnsafeMutableBytes { dst in
            for j in 0..<h {
                memcpy(dst.baseAddress!.advanced(by: j * w * 4), base.advanced(by: j * row), w * 4)
            }
        }
        var confidence: [UInt8]?
        if let conf = data.confidenceMap, CVPixelBufferGetWidth(conf) == w, CVPixelBufferGetHeight(conf) == h,
           CVPixelBufferGetPixelFormatType(conf) == kCVPixelFormatType_OneComponent8 {
            CVPixelBufferLockBaseAddress(conf, .readOnly)
            if let cb = CVPixelBufferGetBaseAddress(conf) {
                let crow = CVPixelBufferGetBytesPerRow(conf)
                var c = [UInt8](repeating: 0, count: w * h)
                c.withUnsafeMutableBytes { dst in
                    for j in 0..<h { memcpy(dst.baseAddress!.advanced(by: j * w), cb.advanced(by: j * crow), w) }
                }
                confidence = c
            }
            CVPixelBufferUnlockBaseAddress(conf, .readOnly)
        }
        return (w, h, depth, confidence)
    }

    /// Downsampled luma + chroma copy of `capturedImage` (biplanar 420f/420v), about `targetWidth`
    /// pixels wide. Main thread work is a strided byte copy; RGB conversion happens later on the
    /// fusion queue (`YCbCrImage.rgb()`).
    static func color(_ frame: ARFrame, targetWidth: Int = 960) -> YCbCrImage? {
        let image = frame.capturedImage
        let format = CVPixelBufferGetPixelFormatType(image)
        let fullRange: Bool
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: fullRange = true
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: fullRange = false
        default: return nil
        }
        guard CVPixelBufferGetPlaneCount(image) == 2 else { return nil }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(image, 0)?.assumingMemoryBound(to: UInt8.self),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(image, 1)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let fw = CVPixelBufferGetWidthOfPlane(image, 0), fh = CVPixelBufferGetHeightOfPlane(image, 0)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let cRow = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        let cw = CVPixelBufferGetWidthOfPlane(image, 1), ch = CVPixelBufferGetHeightOfPlane(image, 1)
        guard fw >= 2, fh >= 2, cw > 0, ch > 0 else { return nil }
        let step = max(1, fw / max(1, targetWidth))
        let w = fw / step, h = fh / step
        var y = [UInt8](repeating: 0, count: w * h)
        var cbcr = [UInt8](repeating: 128, count: w * h * 2)
        y.withUnsafeMutableBufferPointer { yd in
            cbcr.withUnsafeMutableBufferPointer { cd in
                for j in 0..<h {
                    let sy = j * step
                    let yr = yBase.advanced(by: sy * yRow)
                    let cr = cBase.advanced(by: min(ch - 1, sy / 2) * cRow)
                    let o = j * w
                    for i in 0..<w {
                        let sx = i * step
                        yd[o + i] = yr[sx]
                        let c = min(cw - 1, sx / 2) * 2
                        cd[(o + i) * 2] = cr[c]
                        cd[(o + i) * 2 + 1] = cr[c + 1]
                    }
                }
            }
        }
        let intrinsics = PinholeIntrinsics(arkit: frame.camera.intrinsics, imageWidth: fw, imageHeight: fh)
            .scaled(toWidth: w, height: h)
        return YCbCrImage(width: w, height: h, y: y, cbcr: cbcr, fullRange: fullRange, intrinsics: intrinsics)
    }
}

/// Downsampled 4:2:0-derived image (chroma duplicated per pixel) waiting for RGB conversion.
struct YCbCrImage: Sendable {
    var width: Int
    var height: Int
    var y: [UInt8]
    var cbcr: [UInt8]
    var fullRange: Bool
    var intrinsics: PinholeIntrinsics

    /// BT.601 YCbCr -> sRGB (ARKit's capturedImage matrix), run on the fusion queue.
    func rgb() -> ColorImage {
        var out = [UInt8](repeating: 0, count: width * height * 3)
        let n = width * height
        out.withUnsafeMutableBufferPointer { o in
            y.withUnsafeBufferPointer { yb in
                cbcr.withUnsafeBufferPointer { cb in
                    for k in 0..<n {
                        var yy = Float(yb[k])
                        if !fullRange { yy = (yy - 16) * (255 / 219) }
                        let u = Float(cb[2 * k]) - 128
                        let v = Float(cb[2 * k + 1]) - 128
                        let r = yy + 1.402 * v
                        let g = yy - 0.344136 * u - 0.714136 * v
                        let b = yy + 1.772 * u
                        o[3 * k] = UInt8(max(0, min(255, r)))
                        o[3 * k + 1] = UInt8(max(0, min(255, g)))
                        o[3 * k + 2] = UInt8(max(0, min(255, b)))
                    }
                }
            }
        }
        return ColorImage(width: width, height: height, rgb: out, intrinsics: intrinsics)
    }
}

extension CoachTracking {
    init(_ state: ARCamera.TrackingState) {
        switch state {
        case .normal: self = .normal
        case .notAvailable: self = .notAvailable
        case .limited(let reason):
            switch reason {
            case .initializing: self = .initializing
            case .excessiveMotion: self = .excessiveMotion
            case .insufficientFeatures: self = .insufficientFeatures
            case .relocalizing: self = .relocalizing
            @unknown default: self = .notAvailable
            }
        }
    }
}

/// Auto torch through ARKit's configurable capture device (iOS 16+). Every failure is silent: no
/// torch hardware, device busy, or the session not owning the camera all just leave it off.
enum ARTorch {
    static func set(_ on: Bool, level: Float = 0.6) {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera,
              device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if on {
                guard device.isTorchModeSupported(.on), device.isTorchAvailable else { return }
                try device.setTorchModeOn(level: max(0.05, min(level, AVCaptureDevice.maxAvailableTorchLevel)))
            } else if device.torchMode != .off, device.isTorchModeSupported(.off) {
                device.torchMode = .off
            }
        } catch {
            // Fail silently: the coach keeps showing "More light".
        }
    }
}
#endif
