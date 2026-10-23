import Foundation
import simd

/// Pinhole intrinsics in pixels for an image of `width` x `height`.
///
/// Conventions (shared by `TSDFVolume`, the synthetic depth renderer and the app's ARKit handoff):
///
/// - **Camera space is ARKit's**: +X right, +Y up, the camera looks down **-Z**. A point in front of
///   the camera has `z < 0`; its depth (what ARKit's `sceneDepth.depthMap` stores) is `-z`, the
///   distance along the optical axis (not the ray length).
/// - **Image space**: `u` grows to the right, `v` grows **downward**. Coordinates are continuous with
///   the origin at the top-left corner of the top-left pixel, so pixel `(i, j)` covers
///   `[i, i+1) x [j, j+1)` and its center is `(i + 0.5, j + 0.5)`.
/// - Projection of a camera-space point `p` (with `d = -p.z > 0`):
///
///       u = fx * ( p.x / d) + cx
///       v = fy * (-p.y / d) + cy
///
///   and unprojection of pixel `(i, j)` at depth `d`:
///
///       p = ( (i + 0.5 - cx) / fx * d,  -(j + 0.5 - cy) / fy * d,  -d )
///
/// - ARKit's `ARCamera.intrinsics` describe the **captured image** (e.g. 1920x1440). The LiDAR depth
///   map is much smaller (256x192), so the intrinsics must be scaled with `scaled(toWidth:height:)`
///   before projecting into the depth map. With continuous coordinates the scaling is exactly linear
///   (`fx * sx`, `cx * sx`, ...), which is also how ARKit's own sample code samples the depth texture
///   (normalized coordinates).
public struct PinholeIntrinsics: Hashable, Sendable, Codable {
    public var fx: Float
    public var fy: Float
    public var cx: Float
    public var cy: Float
    public var width: Int
    public var height: Int

    public init(fx: Float, fy: Float, cx: Float, cy: Float, width: Int, height: Int) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.width = width
        self.height = height
    }

    /// From ARKit's column-major `ARCamera.intrinsics` (`[[fx,0,0],[0,fy,0],[cx,cy,1]]`) for an image
    /// of `imageWidth` x `imageHeight` (`ARCamera.imageResolution`).
    public init(arkit m: simd_float3x3, imageWidth: Int, imageHeight: Int) {
        self.init(fx: m.columns.0.x, fy: m.columns.1.y, cx: m.columns.2.x, cy: m.columns.2.y,
                  width: imageWidth, height: imageHeight)
    }

    /// The same camera for an image resampled to `w` x `h` (e.g. capturedImage 1920x1440 -> depth
    /// map 256x192, or -> a 960x720 color copy).
    public func scaled(toWidth w: Int, height h: Int) -> PinholeIntrinsics {
        let sx = Float(w) / Float(max(1, width))
        let sy = Float(h) / Float(max(1, height))
        return PinholeIntrinsics(fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy, width: w, height: h)
    }

    /// Continuous pixel coordinates of a camera-space point, or nil when it is not in front.
    @inline(__always)
    public func project(_ p: SIMD3<Float>) -> SIMD2<Float>? {
        let d = -p.z
        guard d > 1e-6 else { return nil }
        return SIMD2(fx * (p.x / d) + cx, fy * (-p.y / d) + cy)
    }

    /// Camera-space point of pixel `(i, j)`'s center at depth `d`.
    @inline(__always)
    public func unproject(i: Int, j: Int, depth d: Float) -> SIMD3<Float> {
        SIMD3((Float(i) + 0.5 - cx) / fx * d, -(Float(j) + 0.5 - cy) / fy * d, -d)
    }

    /// Camera-space point of continuous pixel coordinates `(u, v)` at depth `d`.
    @inline(__always)
    public func unproject(u: Float, v: Float, depth d: Float) -> SIMD3<Float> {
        SIMD3((u - cx) / fx * d, -(v - cy) / fy * d, -d)
    }

    /// Horizontal field of view in degrees.
    public var horizontalFOVDegrees: Float { 2 * atan(Float(width) / 2 / fx) * 180 / .pi }
}

/// Rigid-transform helpers in ARKit's convention (column-major `simd_float4x4`, translation in
/// column 3).
public enum RigidTransform {
    /// Camera-to-world pose of a camera at `eye` looking at `target` (ARKit camera: looks down -Z,
    /// +Y up). `up` is the world up hint (+Y by default).
    public static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float> = SIMD3(0, 1, 0)) -> simd_float4x4 {
        let back = simd_normalize(eye - target)            // camera +Z points away from the target
        var right = simd_cross(up, back)
        if simd_length_squared(right) < 1e-10 { right = simd_cross(SIMD3(0, 0, 1), back) }
        right = simd_normalize(right)
        let trueUp = simd_cross(back, right)
        return simd_float4x4(columns: (SIMD4(right, 0), SIMD4(trueUp, 0), SIMD4(back, 0), SIMD4(eye, 1)))
    }

    @inline(__always)
    public static func translation(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// Rotation angle (radians, 0...pi) between the rotation parts of two poses.
    public static func rotationAngle(from a: simd_float4x4, to b: simd_float4x4) -> Float {
        let ra = simd_float3x3(SIMD3(a.columns.0.x, a.columns.0.y, a.columns.0.z),
                               SIMD3(a.columns.1.x, a.columns.1.y, a.columns.1.z),
                               SIMD3(a.columns.2.x, a.columns.2.y, a.columns.2.z))
        let rb = simd_float3x3(SIMD3(b.columns.0.x, b.columns.0.y, b.columns.0.z),
                               SIMD3(b.columns.1.x, b.columns.1.y, b.columns.1.z),
                               SIMD3(b.columns.2.x, b.columns.2.y, b.columns.2.z))
        // Via the relative quaternion: precise for the tiny per-frame rotations (acos of the trace
        // loses most of its precision below ~0.1 degrees in Float).
        let q = simd_quatf(ra.transpose * rb)
        return 2 * atan2(simd_length(q.imag), abs(q.real))
    }

    /// Forward (viewing) direction of a camera pose: its -Z axis in world space.
    @inline(__always)
    public static func forward(_ m: simd_float4x4) -> SIMD3<Float> {
        -SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
    }
}
