import Foundation
import simd

/// One depth frame for `TSDFVolume.integrate` (plain buffers copied out of an `ARFrame`, so the
/// fusion never retains ARKit objects and can run on any queue).
public struct DepthFrame: Sendable {
    public var width: Int
    public var height: Int
    /// Row-major depth in meters along the optical axis (ARKit `sceneDepth.depthMap`), `v` down.
    /// 0, NaN or infinity = no depth.
    public var depth: [Float]
    /// Optional ARKit confidence per depth pixel (0 low, 1 medium, 2 high).
    public var confidence: [UInt8]?
    /// Intrinsics at the DEPTH resolution (see `PinholeIntrinsics.scaled(toWidth:height:)`).
    public var intrinsics: PinholeIntrinsics
    /// ARKit `camera.transform` (camera-to-world; camera looks down -Z).
    public var cameraToWorld: simd_float4x4
    /// Optional color image (any resolution, own intrinsics). Voxel centers are projected into it.
    public var color: ColorImage?

    public init(width: Int, height: Int, depth: [Float], confidence: [UInt8]? = nil, intrinsics: PinholeIntrinsics,
                cameraToWorld: simd_float4x4, color: ColorImage? = nil) {
        self.width = width
        self.height = height
        self.depth = depth
        self.confidence = confidence
        self.intrinsics = intrinsics
        self.cameraToWorld = cameraToWorld
        self.color = color
    }
}

/// Packed RGB8 image (row-major, `v` down) with its own intrinsics. Used for voxel colors; it can be
/// sharper than the depth map (e.g. a 960x720 copy of the 1920x1440 / 4K captured image).
public struct ColorImage: Sendable {
    public var width: Int
    public var height: Int
    /// `width * height * 3` bytes, R G B.
    public var rgb: [UInt8]
    public var intrinsics: PinholeIntrinsics

    public init(width: Int, height: Int, rgb: [UInt8], intrinsics: PinholeIntrinsics) {
        self.width = width
        self.height = height
        self.rgb = rgb
        self.intrinsics = intrinsics
    }
}

/// Indexed triangle mesh extracted from a `TSDFVolume` (world space, meters).
public struct FusedMesh: Sendable {
    public var positions: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    /// Per-vertex sRGB colors (same count as positions) or empty when no color was fused.
    public var colors: [SIMD3<UInt8>]
    /// Counter-clockwise triangles (front faces point out of the surface, toward free space).
    public var indices: [UInt32]

    public init(positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], colors: [SIMD3<UInt8>] = [], indices: [UInt32] = []) {
        self.positions = positions
        self.normals = normals
        self.colors = colors
        self.indices = indices
    }

    public var vertexCount: Int { positions.count }
    public var triangleCount: Int { indices.count / 3 }

    /// As a `ClassifiedMesh` (one "Other" group) carrying the vertex colors, ready for
    /// `MeshNormalizer` and `LiDARMeshExporter`.
    public func classifiedMesh() -> ClassifiedMesh {
        ClassifiedMesh(positions: positions, normals: normals,
                       groups: indices.isEmpty ? [] : [.init(classification: .none, indices: indices)], colors: colors)
    }
}

/// Truncated signed distance field with sparse voxel hashing (Niessner et al. 2013 style): 8x8x8
/// voxel blocks, allocated only along the observed surfaces, in an open-addressing hash table keyed
/// by block coordinates. Pure Swift + simd, deterministic (no randomness, no unordered iteration).
///
/// Per voxel: Int16 normalized TSDF (-1...1 of the truncation distance), UInt8 weight (quarter units,
/// capped), RGB8 running-average color and a UInt8 color weight: 7 bytes.
///
/// Positive TSDF = in front of the surface (free space), negative = behind it. The surface is the
/// zero crossing; `extractMesh()` runs marching cubes over it.
public final class TSDFVolume: @unchecked Sendable {
    public struct Configuration: Sendable, Hashable {
        /// Voxel edge length in meters.
        public var voxelSize: Float
        /// Truncation distance in voxels (the band around the surface that gets updated).
        public var truncationVoxels: Float
        public var maxWeight: UInt8
        /// Memory budget for voxel blocks; allocation stops (and `isFull` turns true) at the cap.
        public var memoryCapBytes: Int
        /// Depth pixels with confidence below this are ignored (ARKit: 0 low, 1 medium, 2 high).
        public var minConfidence: UInt8
        public var minDepth: Float
        public var maxDepth: Float
        /// Only every `allocationStride`-th depth pixel (in x and y) allocates blocks; every voxel of
        /// an allocated block is still updated from the full-resolution depth map.
        public var allocationStride: Int

        public init(voxelSize: Float, truncationVoxels: Float = 5, maxWeight: UInt8 = 64, memoryCapBytes: Int = 384 << 20,
                    minConfidence: UInt8 = 2, minDepth: Float = 0.1, maxDepth: Float = 1.5, allocationStride: Int = 2) {
            self.voxelSize = voxelSize
            self.truncationVoxels = truncationVoxels
            self.maxWeight = maxWeight
            self.memoryCapBytes = memoryCapBytes
            self.minConfidence = minConfidence
            self.minDepth = minDepth
            self.maxDepth = maxDepth
            self.allocationStride = max(1, allocationStride)
        }

        /// Detail scan: 4 mm voxels, 1.5 m range, high-confidence depth only.
        public static let detail = Configuration(voxelSize: 0.004, truncationVoxels: 5, maxWeight: 64,
                                                 memoryCapBytes: 384 << 20, minConfidence: 2, minDepth: 0.1, maxDepth: 1.5)
        /// Room-scale fusion: 10 mm voxels, 3 m range, medium confidence and up.
        public static let room = Configuration(voxelSize: 0.010, truncationVoxels: 4, maxWeight: 64,
                                               memoryCapBytes: 384 << 20, minConfidence: 1, minDepth: 0.1, maxDepth: 3.0)

        public var truncation: Float { voxelSize * truncationVoxels }
        public var blockSide: Float { voxelSize * Float(TSDFVolume.blockDim) }
    }

    public struct Stats: Sendable, Hashable {
        public var framesIntegrated: Int
        public var blockCount: Int
        public var voxelCount: Int
        public var memoryBytes: Int
        public var memoryFraction: Double
        public var isFull: Bool

        public init(framesIntegrated: Int = 0, blockCount: Int = 0, voxelCount: Int = 0, memoryBytes: Int = 0,
                    memoryFraction: Double = 0, isFull: Bool = false) {
            self.framesIntegrated = framesIntegrated
            self.blockCount = blockCount
            self.voxelCount = voxelCount
            self.memoryBytes = memoryBytes
            self.memoryFraction = memoryFraction
            self.isFull = isFull
        }
    }

    public struct FrameResult: Sendable, Hashable {
        public var validPixels: Int
        public var blocksTouched: Int
        public var newBlocks: Int
        public var voxelsUpdated: Int
    }

    public static let blockDim = 8
    public static let voxelsPerBlock = 512
    /// Bytes per voxel (tsdf 2 + weight 1 + rgb 3 + color weight 1).
    public static let bytesPerVoxel = 7
    /// Rough per-block bookkeeping (hash slots at <= 50 % load, key, frame stamp).
    public static let blockOverheadBytes = 48
    static let blockBytes = voxelsPerBlock * bytesPerVoxel + blockOverheadBytes
    /// Block coordinates are limited to +-2^16 (+-2 km at 4 mm voxels) so vertex keys pack into 64 bits.
    static let blockCoordLimit: Int32 = 1 << 16

    public let configuration: Configuration
    public let maxBlocks: Int

    // Voxel storage, block-major (block b owns [b*512, (b+1)*512)), x fastest, then y, then z.
    private(set) var tsdf: [Int16] = []
    private(set) var weight: [UInt8] = []
    private(set) var rgb: [UInt8] = []
    private(set) var colorWeight: [UInt8] = []
    /// Block coordinates in allocation order.
    private(set) var blockCoords: [SIMD3<Int32>] = []
    private var blockStamp: [Int32] = []
    private var table = BlockHashTable()
    public private(set) var framesIntegrated = 0
    public private(set) var isFull = false
    public private(set) var hasColor = false

    public init(configuration: Configuration = .detail) {
        self.configuration = configuration
        self.maxBlocks = max(1, configuration.memoryCapBytes / Self.blockBytes)
    }

    public var blockCount: Int { blockCoords.count }

    public var stats: Stats {
        let memory = blockCoords.count * Self.blockBytes
        return Stats(framesIntegrated: framesIntegrated, blockCount: blockCoords.count,
                     voxelCount: blockCoords.count * Self.voxelsPerBlock, memoryBytes: memory,
                     memoryFraction: Double(blockCoords.count) / Double(maxBlocks), isFull: isFull)
    }

    public func reset() {
        tsdf = []
        weight = []
        rgb = []
        colorWeight = []
        blockCoords = []
        blockStamp = []
        table = BlockHashTable()
        framesIntegrated = 0
        isFull = false
        hasColor = false
    }

    // MARK: Block bookkeeping

    @inline(__always)
    static func blockKey(_ c: SIMD3<Int32>) -> UInt64 {
        let m: UInt64 = (1 << 21) - 1
        return (UInt64(bitPattern: Int64(c.x) + (1 << 20)) & m) << 42
            | (UInt64(bitPattern: Int64(c.y) + (1 << 20)) & m) << 21
            | (UInt64(bitPattern: Int64(c.z) + (1 << 20)) & m)
    }

    /// Index of the block at `c`, or -1.
    @inline(__always)
    @_optimize(speed)
    func blockIndex(_ c: SIMD3<Int32>) -> Int {
        table.find(Self.blockKey(c))
    }

    /// Finds or allocates the block at `c`. Returns -1 when the memory cap is reached.
    @_optimize(speed)
    private func allocateBlock(_ c: SIMD3<Int32>) -> Int {
        let key = Self.blockKey(c)
        let found = table.find(key)
        if found >= 0 { return found }
        guard blockCoords.count < maxBlocks else {
            isFull = true
            return -1
        }
        let index = blockCoords.count
        blockCoords.append(c)
        blockStamp.append(-1)
        tsdf.append(contentsOf: repeatElement(Int16.max, count: Self.voxelsPerBlock))
        weight.append(contentsOf: repeatElement(0, count: Self.voxelsPerBlock))
        rgb.append(contentsOf: repeatElement(0, count: Self.voxelsPerBlock * 3))
        colorWeight.append(contentsOf: repeatElement(0, count: Self.voxelsPerBlock))
        table.insert(key, value: Int32(index))
        return index
    }

    // MARK: Integration

    /// Weights are stored in quarter units (UInt8, so up to 63.75), which lets observations behind the
    /// surface count less (see `integrate`).
    static let weightScale: Float = 4

    /// Fuses one depth frame (standard projective TSDF):
    /// 1. every `allocationStride`-th valid depth pixel allocates the blocks along its truncation band
    ///    (`depth - truncation ... depth + truncation` on its ray);
    /// 2. every voxel of those blocks is projected into the depth map and updated with
    ///    `sdf = depth(pixel) - voxelDepth`, clamped to the truncation, as a weighted running average.
    ///    Observations behind the surface (`sdf < -voxel`) get a weight that drops linearly to 0 at
    ///    `-truncation` (as in voxblox), which keeps sharp edges and corners from bulging out.
    /// 3. with a color image, voxels near the surface (`|sdf| < truncation / 2`) are projected into it
    ///    (its own intrinsics; it may be sharper than the depth map) and their color averaged.
    ///
    /// `bounds` (world AABB) limits allocation, e.g. to the object being scanned. Malformed input
    /// (short buffers, NaN poses) is ignored, never trapped on.
    // `@_optimize(speed)`: the hot loops stay fast in Debug / Simulator builds too (demo job, tests).
    @_optimize(speed)
    @discardableResult
    public func integrate(_ frame: DepthFrame, bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? = nil) -> FrameResult {
        let w = frame.width, h = frame.height
        let empty = FrameResult(validPixels: 0, blocksTouched: 0, newBlocks: 0, voxelsUpdated: 0)
        guard w > 0, h > 0, frame.depth.count >= w * h else { return empty }
        let T = frame.cameraToWorld
        let K = frame.intrinsics
        for c in [T.columns.0, T.columns.1, T.columns.2, T.columns.3] where !(c.x.isFinite && c.y.isFinite && c.z.isFinite && c.w.isFinite) {
            return empty
        }
        guard K.fx.isFinite, K.fy.isFinite, K.cx.isFinite, K.cy.isFinite, abs(K.fx) > 1e-6, abs(K.fy) > 1e-6 else { return empty }
        let cfg = configuration
        let W2C = T.inverse
        let tau = cfg.truncation
        let blockSide = cfg.blockSide
        let invBlock = 1 / blockSide
        let minConf = cfg.minConfidence
        let useConfidence = frame.confidence.map { $0.count >= w * h } ?? false
        let stamp = Int32(truncatingIfNeeded: framesIntegrated)
        let blocksBefore = blockCoords.count
        var touched: [Int] = []
        var validPixels = 0
        let minD = cfg.minDepth, maxD = cfg.maxDepth
        let fx = K.fx, fy = K.fy, cx = K.cx, cy = K.cy

        // 1. Allocation along each sampled pixel's truncation band (scalar math: fast in debug too).
        let samplesPerRay = max(2, Int((2 * tau / (blockSide * 0.5)).rounded(.up)) + 1)
        let r00 = T.columns.0.x, r01 = T.columns.0.y, r02 = T.columns.0.z
        let r10 = T.columns.1.x, r11 = T.columns.1.y, r12 = T.columns.1.z
        let r20 = T.columns.2.x, r21 = T.columns.2.y, r22 = T.columns.2.z
        let ox = T.columns.3.x, oy = T.columns.3.y, oz = T.columns.3.z
        let stride = cfg.allocationStride
        let limit = Float(Self.blockCoordLimit - 1)
        let hasBounds = bounds != nil
        let bmin = bounds?.min ?? SIMD3(repeating: 0), bmax = bounds?.max ?? SIMD3(repeating: 0)
        let bminX = bmin.x, bminY = bmin.y, bminZ = bmin.z, bmaxX = bmax.x, bmaxY = bmax.y, bmaxZ = bmax.z
        frame.depth.withUnsafeBufferPointer { depth in
            (frame.confidence ?? []).withUnsafeBufferPointer { conf in
                var lastX = Int32.min, lastY = Int32.min, lastZ = Int32.min
                var j = stride / 2
                while j < h {
                    var i = stride / 2
                    while i < w {
                        let pix = j * w + i
                        let d = depth[pix]
                        if d.isFinite, d >= minD, d <= maxD, !useConfidence || conf[pix] >= minConf {
                            validPixels += 1
                            let xn = (Float(i) + 0.5 - cx) / fx
                            let yn = -(Float(j) + 0.5 - cy) / fy
                            // Camera ray (xn, yn, -1) in world space.
                            let dx = r00 * xn + r10 * yn - r20
                            let dy = r01 * xn + r11 * yn - r21
                            let dz = r02 * xn + r12 * yn - r22
                            for s in 0..<samplesPerRay {
                                let t = d - tau + 2 * tau * Float(s) / Float(samplesPerRay - 1)
                                if t <= 0 { continue }
                                let px = ox + dx * t, py = oy + dy * t, pz = oz + dz * t
                                if hasBounds && (px < bminX || py < bminY || pz < bminZ || px > bmaxX || py > bmaxY || pz > bmaxZ) { continue }
                                let fbx = (px * invBlock).rounded(.down), fby = (py * invBlock).rounded(.down), fbz = (pz * invBlock).rounded(.down)
                                guard abs(fbx) < limit, abs(fby) < limit, abs(fbz) < limit else { continue }
                                let bx = Int32(fbx), by = Int32(fby), bz = Int32(fbz)
                                if bx == lastX && by == lastY && bz == lastZ { continue }
                                lastX = bx; lastY = by; lastZ = bz
                                let b = allocateBlock(SIMD3(bx, by, bz))
                                if b >= 0, blockStamp[b] != stamp {
                                    blockStamp[b] = stamp
                                    touched.append(b)
                                }
                            }
                        }
                        i += stride
                    }
                    j += stride
                }
            }
        }

        // 2. Projective update of every voxel in the touched blocks.
        let voxel = cfg.voxelSize
        let scale = Self.weightScale
        let maxStored = Float(min(255, Int(cfg.maxWeight) * Int(scale)))
        // World-to-camera rotation (row-major scalars) and translation.
        let a00 = W2C.columns.0.x, a10 = W2C.columns.0.y, a20 = W2C.columns.0.z
        let a01 = W2C.columns.1.x, a11 = W2C.columns.1.y, a21 = W2C.columns.1.z
        let a02 = W2C.columns.2.x, a12 = W2C.columns.2.y, a22 = W2C.columns.2.z
        let t0 = W2C.columns.3.x, t1 = W2C.columns.3.y, t2 = W2C.columns.3.z
        let color = frame.color
        let colorOK = color.map { $0.width > 0 && $0.height > 0 && $0.rgb.count >= $0.width * $0.height * 3 } ?? false
        let cw = colorOK ? color!.width : 0, chh = colorOK ? color!.height : 0
        let cfx = color?.intrinsics.fx ?? 1, cfy = color?.intrinsics.fy ?? 1
        let ccx = color?.intrinsics.cx ?? 0, ccy = color?.intrinsics.cy ?? 0
        let fcw = Float(cw), fch = Float(chh)
        let colorBand = tau * 0.5
        if colorOK { hasColor = true }
        let maxColorW = cfg.maxWeight
        let fw = Float(w), fh = Float(h)
        let dropStart = -voxel
        let dropSpan = max(1e-6, tau - voxel)
        var updated = 0
        let dim = Self.blockDim

        frame.depth.withUnsafeBufferPointer { depth in
            (frame.confidence ?? []).withUnsafeBufferPointer { conf in
                (colorOK ? color!.rgb : []).withUnsafeBufferPointer { crgb in
                    tsdf.withUnsafeMutableBufferPointer { tsdfBuf in
                        weight.withUnsafeMutableBufferPointer { weightBuf in
                            rgb.withUnsafeMutableBufferPointer { rgbBuf in
                                colorWeight.withUnsafeMutableBufferPointer { cwBuf in
                                    for b in touched {
                                        let bc = blockCoords[b]
                                        // World position of voxel (0,0,0)'s center in this block.
                                        let wx0 = Float(bc.x) * blockSide + voxel * 0.5
                                        let wy0 = Float(bc.y) * blockSide + voxel * 0.5
                                        let wz0 = Float(bc.z) * blockSide + voxel * 0.5
                                        let blockBase = b * Self.voxelsPerBlock
                                        for z in 0..<dim {
                                            let wz = wz0 + Float(z) * voxel
                                            for y in 0..<dim {
                                                let wy = wy0 + Float(y) * voxel
                                                // Camera-space position of voxel (0, y, z); x steps add column 0.
                                                let rx = a01 * wy + a02 * wz + t0
                                                let ry = a11 * wy + a12 * wz + t1
                                                let rz = a21 * wy + a22 * wz + t2
                                                for x in 0..<dim {
                                                    let wx = wx0 + Float(x) * voxel
                                                    let px = a00 * wx + rx
                                                    let py = a10 * wx + ry
                                                    let vd = -(a20 * wx + rz)
                                                    if !(vd > minD && vd <= maxD + tau) { continue }
                                                    let u = fx * (px / vd) + cx
                                                    let v = fy * (-py / vd) + cy
                                                    if !(u >= 0 && v >= 0 && u < fw && v < fh) { continue }
                                                    let pix = Int(v) * w + Int(u)
                                                    let d = depth[pix]
                                                    if !(d.isFinite && d >= minD && d <= maxD) { continue }
                                                    if useConfidence && conf[pix] < minConf { continue }
                                                    let sdf = d - vd
                                                    if sdf < -tau { continue }
                                                    // Observation weight: 1, dropping to 0 behind the surface.
                                                    let obsW = sdf >= dropStart ? scale : scale * (tau + sdf) / dropSpan
                                                    if obsW < 0.5 { continue }
                                                    let observed = sdf >= tau ? 1 : sdf / tau
                                                    let vi = blockBase + (z * dim + y) * dim + x
                                                    let w0 = Float(weightBuf[vi])
                                                    let old: Float = w0 == 0 ? 0 : Float(tsdfBuf[vi]) / 32767
                                                    let fused = (old * w0 + observed * obsW) / (w0 + obsW)
                                                    let q = (fused * 32767).rounded()
                                                    tsdfBuf[vi] = Int16(q > 32767 ? 32767 : (q < -32767 ? -32767 : q))
                                                    let nw = (w0 + obsW).rounded()
                                                    weightBuf[vi] = UInt8(nw > maxStored ? maxStored : nw)
                                                    updated += 1
                                                    if colorOK, sdf < colorBand, sdf > -colorBand {
                                                        let cu = cfx * (px / vd) + ccx
                                                        let cv = cfy * (-py / vd) + ccy
                                                        if cu >= 0, cv >= 0, cu < fcw, cv < fch {
                                                            let src = (Int(cv) * cw + Int(cu)) * 3
                                                            let cw0 = cwBuf[vi]
                                                            let n0 = Float(cw0)
                                                            let dst = vi * 3
                                                            let r = (Float(rgbBuf[dst]) * n0 + Float(crgb[src])) / (n0 + 1)
                                                            let g = (Float(rgbBuf[dst + 1]) * n0 + Float(crgb[src + 1])) / (n0 + 1)
                                                            let bl = (Float(rgbBuf[dst + 2]) * n0 + Float(crgb[src + 2])) / (n0 + 1)
                                                            rgbBuf[dst] = UInt8(min(255, max(0, r.rounded())))
                                                            rgbBuf[dst + 1] = UInt8(min(255, max(0, g.rounded())))
                                                            rgbBuf[dst + 2] = UInt8(min(255, max(0, bl.rounded())))
                                                            cwBuf[vi] = cw0 < maxColorW ? cw0 + 1 : maxColorW
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        framesIntegrated += 1
        return FrameResult(validPixels: validPixels, blocksTouched: touched.count,
                           newBlocks: blockCoords.count - blocksBefore, voxelsUpdated: updated)
    }

    // MARK: Voxel access

    /// Normalized TSDF and weight of the voxel at global voxel coordinate `g`, or nil when unobserved.
    @inline(__always)
    func voxel(_ g: SIMD3<Int32>) -> (tsdf: Float, weight: UInt8)? { // weight in quarter units
        let bc = SIMD3<Int32>(g.x >> 3, g.y >> 3, g.z >> 3)
        let b = blockIndex(bc)
        guard b >= 0 else { return nil }
        let l = g &- bc &* 8
        let vi = b * Self.voxelsPerBlock + Int((l.z * 8 + l.y) * 8 + l.x)
        let w = weight[vi]
        guard w > 0 else { return nil }
        return (Float(tsdf[vi]) / 32767, w)
    }

    /// Signed distance in meters (trilinear) at a world point, or nil if any of the 8 voxels is unobserved.
    public func signedDistance(at p: SIMD3<Float>) -> Float? {
        let s = configuration.voxelSize
        let q = p / s - 0.5
        let f = floor(q)
        let lim = Float(Self.blockCoordLimit) * 8 - 2
        guard abs(f.x) < lim, abs(f.y) < lim, abs(f.z) < lim else { return nil }
        let g0 = SIMD3<Int32>(Int32(f.x), Int32(f.y), Int32(f.z))
        let t = q - f
        var acc: Float = 0
        for dz: Int32 in 0...1 {
            for dy: Int32 in 0...1 {
                for dx: Int32 in 0...1 {
                    guard let v = voxel(g0 &+ SIMD3(dx, dy, dz)) else { return nil }
                    let wx = dx == 0 ? 1 - t.x : t.x
                    let wy = dy == 0 ? 1 - t.y : t.y
                    let wz = dz == 0 ? 1 - t.z : t.z
                    acc += v.tsdf * wx * wy * wz
                }
            }
        }
        return acc * configuration.truncation
    }

    /// Central-difference TSDF gradient at a voxel (one-sided where a neighbor is unobserved).
    @_optimize(speed)
    private func gradient(_ g: SIMD3<Int32>, center: Float) -> SIMD3<Float> {
        var out = SIMD3<Float>(0, 0, 0)
        let axes: [SIMD3<Int32>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        for k in 0..<3 {
            let plus = voxel(g &+ axes[k])?.tsdf
            let minus = voxel(g &- axes[k])?.tsdf
            switch (plus, minus) {
            case let (p?, m?): out[k] = (p - m) / 2
            case let (p?, nil): out[k] = p - center
            case let (nil, m?): out[k] = center - m
            default: out[k] = 0
            }
        }
        return out
    }

    // MARK: Surface samples (live coverage overlay)

    /// One point per block that contains surface (near-zero TSDF): the mean position of its
    /// near-surface voxels and their mean weight (0...1 of `solidWeight`). The app projects these
    /// into the camera view and tints them red -> green, so users "paint" thin areas until solid.
    public func surfaceSamples(solidWeight: Float = 12, maxCount: Int = 6000) -> [(position: SIMD3<Float>, confidence: Float)] {
        var out: [(SIMD3<Float>, Float)] = []
        out.reserveCapacity(min(maxCount, blockCoords.count))
        let s = configuration.voxelSize
        let side = configuration.blockSide
        let step = max(1, blockCoords.count / max(1, maxCount))
        var b = 0
        while b < blockCoords.count {
            let base = b * Self.voxelsPerBlock
            var sum = SIMD3<Float>(0, 0, 0)
            var wsum: Float = 0
            var n = 0
            for vi in 0..<Self.voxelsPerBlock where weight[base + vi] > 0 && abs(Int(tsdf[base + vi])) < 9830 {
                let x = vi & 7, y = (vi >> 3) & 7, z = vi >> 6
                sum += SIMD3(Float(x), Float(y), Float(z))
                wsum += Float(weight[base + vi]) / Self.weightScale
                n += 1
            }
            if n > 0 {
                let bc = blockCoords[b]
                let origin = SIMD3<Float>(Float(bc.x), Float(bc.y), Float(bc.z)) * side
                let p = origin + (sum / Float(n) + 0.5) * s
                out.append((p, min(1, wsum / Float(n) / solidWeight)))
            }
            b += step
        }
        return out
    }

    // MARK: Mesh extraction

    /// Marching cubes over every allocated block. Cells spanning block borders read the +x/+y/+z
    /// neighbor blocks; vertices on shared edges are welded (one vertex per voxel edge). Normals come
    /// from the TSDF gradient, colors from the fused voxel colors (interpolated along the edge).
    ///
    /// - `minWeight`: corners observed fewer times are treated as unknown (no faces).
    /// - `progress` gets 0...1.
    @_optimize(speed)
    public func extractMesh(minWeight: UInt8 = 1, progress: ((Double) -> Void)? = nil) -> FusedMesh {
        let dim = Self.blockDim
        let s = configuration.voxelSize
        let minW = UInt8(min(255, max(1, Int(minWeight) * Int(Self.weightScale) - 1)))
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var colors: [SIMD3<UInt8>] = []
        var indices: [UInt32] = []
        var edgeVertex = BlockHashTable()
        let withColor = hasColor
        let cornerOffsets = MarchingCubesTables.cornerOffsets.map { SIMD3<Int32>(Int32($0.0), Int32($0.1), Int32($0.2)) }
        let edgeCorners = MarchingCubesTables.edgeCorners
        let tris = MarchingCubesTables.triangles
        let edgeMasks = MarchingCubesTables.edgeMasks
        let blockTotal = blockCoords.count
        var cornerT = [Float](repeating: 0, count: 8)
        var cornerVI = [Int](repeating: 0, count: 8)
        var edgeIndex = [UInt32](repeating: 0, count: 12)

        for b in 0..<blockTotal {
            if let progress, b % 256 == 0 { progress(Double(b) / Double(max(1, blockTotal))) }
            let bc = blockCoords[b]
            // Neighbor blocks (dx, dy, dz) in {0,1}^3, index dx + 2 dy + 4 dz (0 = this block).
            var neighbors = [Int](repeating: -1, count: 8)
            for n in 0..<8 {
                neighbors[n] = n == 0 ? b : blockIndex(bc &+ SIMD3(Int32(n & 1), Int32((n >> 1) & 1), Int32((n >> 2) & 1)))
            }
            let blockOrigin = bc &* 8
            for z in 0..<dim {
                for y in 0..<dim {
                    cell: for x in 0..<dim {
                        var cube = 0
                        var lo: Float = 2, hi: Float = -2
                        for k in 0..<8 {
                            let o = cornerOffsets[k]
                            var lx = x + Int(o.x), ly = y + Int(o.y), lz = z + Int(o.z)
                            var n = 0
                            if lx == dim { lx = 0; n |= 1 }
                            if ly == dim { ly = 0; n |= 2 }
                            if lz == dim { lz = 0; n |= 4 }
                            let nb = neighbors[n]
                            if nb < 0 { continue cell }
                            let vi = nb * Self.voxelsPerBlock + (lz * dim + ly) * dim + lx
                            if weight[vi] < minW { continue cell }
                            let t = Float(tsdf[vi]) / 32767
                            cornerT[k] = t
                            cornerVI[k] = vi
                            if t < 0 { cube |= 1 << k }
                            lo = min(lo, t)
                            hi = max(hi, t)
                        }
                        if cube == 0 || cube == 255 { continue }
                        // A jump of more than one truncation between neighbors is an occlusion edge
                        // (e.g. +1 free space next to -1 behind a silhouette), not a surface.
                        if hi - lo > 1.0 { continue }
                        let mask = edgeMasks[cube]
                        let cellOrigin = blockOrigin &+ SIMD3(Int32(x), Int32(y), Int32(z))
                        for e in 0..<12 where mask & (1 << UInt16(e)) != 0 {
                            let (ca, cb) = edgeCorners[e]
                            let oa = cornerOffsets[ca], ob = cornerOffsets[cb]
                            // Edges are axis-aligned: key = lower corner + axis (shared by up to 4 cells).
                            let gLow = cellOrigin &+ SIMD3(min(oa.x, ob.x), min(oa.y, ob.y), min(oa.z, ob.z))
                            let axis: UInt64 = oa.x != ob.x ? 0 : (oa.y != ob.y ? 1 : 2)
                            let key = Self.edgeKey(gLow, axis: axis)
                            let existing = edgeVertex.find(key)
                            if existing >= 0 {
                                edgeIndex[e] = UInt32(existing)
                                continue
                            }
                            let ta = cornerT[ca], tb = cornerT[cb]
                            let denom = ta - tb
                            let mu = abs(denom) > 1e-9 ? max(0, min(1, ta / denom)) : 0.5
                            let ga = cellOrigin &+ oa, gb = cellOrigin &+ ob
                            let pa = (SIMD3<Float>(Float(ga.x), Float(ga.y), Float(ga.z)) + 0.5) * s
                            let pb = (SIMD3<Float>(Float(gb.x), Float(gb.y), Float(gb.z)) + 0.5) * s
                            let p = pa + (pb - pa) * mu
                            let na = gradient(ga, center: ta)
                            let nbv = gradient(gb, center: tb)
                            var nrm = na * (1 - mu) + nbv * mu
                            let len = simd_length(nrm)
                            nrm = len > 1e-12 ? nrm / len : SIMD3(0, 0, 0)
                            let index = UInt32(positions.count)
                            positions.append(p)
                            normals.append(nrm)
                            if withColor {
                                // Blend only corners that actually received color; else any colored
                                // corner of the cell; else neutral gray (never black).
                                let va = cornerVI[ca], vb = cornerVI[cb]
                                let wa: Float = colorWeight[va] > 0 ? 1 - mu : 0
                                let wb: Float = colorWeight[vb] > 0 ? mu : 0
                                var c = SIMD3<Float>(repeating: 0)
                                var wsum = wa + wb
                                if wsum > 0 {
                                    c = (SIMD3<Float>(Float(rgb[va * 3]), Float(rgb[va * 3 + 1]), Float(rgb[va * 3 + 2])) * wa
                                        + SIMD3<Float>(Float(rgb[vb * 3]), Float(rgb[vb * 3 + 1]), Float(rgb[vb * 3 + 2])) * wb) / wsum
                                } else {
                                    for k in 0..<8 where colorWeight[cornerVI[k]] > 0 {
                                        let v = cornerVI[k] * 3
                                        c += SIMD3<Float>(Float(rgb[v]), Float(rgb[v + 1]), Float(rgb[v + 2]))
                                        wsum += 1
                                    }
                                    c = wsum > 0 ? c / wsum : SIMD3(repeating: 180)
                                }
                                colors.append(SIMD3<UInt8>(UInt8(max(0, min(255, c.x.rounded()))),
                                                           UInt8(max(0, min(255, c.y.rounded()))),
                                                           UInt8(max(0, min(255, c.z.rounded())))))
                            }
                            edgeVertex.insert(key, value: Int32(index))
                            edgeIndex[e] = index
                        }
                        let list = tris[cube]
                        var t = 0
                        while t + 2 < list.count {
                            let i0 = edgeIndex[Int(list[t])], i1 = edgeIndex[Int(list[t + 1])], i2 = edgeIndex[Int(list[t + 2])]
                            t += 3
                            if i0 == i1 || i1 == i2 || i0 == i2 { continue }
                            let a = positions[Int(i0)], bb = positions[Int(i1)], c = positions[Int(i2)]
                            let g = simd_cross(bb - a, c - a)
                            if simd_length_squared(g) < 1e-16 { continue }
                            // Front face toward +TSDF (free space): the gradient direction.
                            let avg = normals[Int(i0)] + normals[Int(i1)] + normals[Int(i2)]
                            if simd_dot(g, avg) < 0 {
                                indices.append(contentsOf: [i0, i2, i1])
                            } else {
                                indices.append(contentsOf: [i0, i1, i2])
                            }
                        }
                    }
                }
            }
        }
        // Vertices whose gradient was degenerate get their area-weighted face normal.
        var fix: [Int] = []
        for i in normals.indices where normals[i] == SIMD3(0, 0, 0) { fix.append(i) }
        if !fix.isEmpty {
            var acc = [SIMD3<Float>](repeating: .zero, count: positions.count)
            var i = 0
            while i + 2 < indices.count {
                let a = Int(indices[i]), bb = Int(indices[i + 1]), c = Int(indices[i + 2])
                let g = simd_cross(positions[bb] - positions[a], positions[c] - positions[a])
                acc[a] += g; acc[bb] += g; acc[c] += g
                i += 3
            }
            for k in fix {
                let l = simd_length(acc[k])
                normals[k] = l > 1e-12 ? acc[k] / l : SIMD3(0, 1, 0)
            }
        }
        progress?(1)
        return FusedMesh(positions: positions, normals: normals, colors: withColor ? colors : [], indices: indices)
    }

    @inline(__always)
    static func edgeKey(_ g: SIMD3<Int32>, axis: UInt64) -> UInt64 {
        let m: UInt64 = (1 << 20) - 1
        return (UInt64(bitPattern: Int64(g.x) + (1 << 19)) & m) << 42
            | (UInt64(bitPattern: Int64(g.y) + (1 << 19)) & m) << 22
            | (UInt64(bitPattern: Int64(g.z) + (1 << 19)) & m) << 2
            | axis
    }
}

/// Open-addressing (linear probing) hash table UInt64 -> Int32 with Fibonacci hashing. Deterministic
/// and allocation-light; used for block lookup and vertex welding.
struct BlockHashTable {
    private var keys: [UInt64]
    private var values: [Int32]
    private var mask: Int
    private var shift: UInt64
    private(set) var count = 0
    private static let empty = UInt64.max

    init(capacity: Int = 1024) {
        var cap = 16
        while cap < capacity * 2 { cap <<= 1 }
        keys = [UInt64](repeating: Self.empty, count: cap)
        values = [Int32](repeating: -1, count: cap)
        mask = cap - 1
        shift = UInt64(64 - cap.trailingZeroBitCount)
    }

    @inline(__always)
    private func slot(_ key: UInt64) -> Int {
        Int(truncatingIfNeeded: (key &* 0x9E37_79B9_7F4A_7C15) >> shift)
    }

    @inline(__always)
    @_optimize(speed)
    func find(_ key: UInt64) -> Int {
        var i = slot(key)
        while true {
            let k = keys[i]
            if k == key { return Int(values[i]) }
            if k == Self.empty { return -1 }
            i = (i + 1) & mask
        }
    }

    @_optimize(speed)
    mutating func insert(_ key: UInt64, value: Int32) {
        if (count + 1) * 2 > keys.count { grow() }
        var i = slot(key)
        while true {
            let k = keys[i]
            if k == Self.empty {
                keys[i] = key
                values[i] = value
                count += 1
                return
            }
            if k == key {
                values[i] = value
                return
            }
            i = (i + 1) & mask
        }
    }

    private mutating func grow() {
        let oldKeys = keys, oldValues = values
        let cap = keys.count * 2
        keys = [UInt64](repeating: Self.empty, count: cap)
        values = [Int32](repeating: -1, count: cap)
        mask = cap - 1
        shift = UInt64(64 - cap.trailingZeroBitCount)
        count = 0
        for (k, v) in zip(oldKeys, oldValues) where k != Self.empty { insert(k, value: v) }
    }
}
