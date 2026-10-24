"""CPU mesh stages shared by the cloud worker and the local bake-off.

  object_region()      : where the scanned object is (camera look-at, gravity/up, crop cylinder)
  tsdf_mesh()          : fuse per-view depth maps (splat median depth or MVS depth) into a mesh (Open3D)
  clean_mesh()         : crop to the object region, cut the ground, keep big components, decimate
  unwrap()             : xatlas UV atlas
  bake_texture()       : project the undistorted photos onto the atlas (z-buffer visibility, view weighting)
  raster_depth()       : z-buffer a mesh into a camera (visibility + thumbnails)

Everything here runs on CPU (numpy + numba + open3d + xatlas); only SfM/MVS/splat training need a GPU.
"""
import math

import numpy as np
from numba import njit, prange

# ---------------------------------------------------------------------------------------------
# Object region


def object_region(cams, points=None, radius_factor=1.35):
    """Estimate the object's center/up/crop cylinder from an object-centric capture.

    center: least-squares point closest to all optical axes; up: mean camera 'up' (-y in OpenCV axes).
    Crop cylinder around the up axis through the center: radius = radius_factor * median horizontal
    camera distance; vertical extent: from the lowest sparse point near the axis to the highest camera.
    """
    C = np.array([c.center for c in cams])
    D = np.array([c.R.T @ np.array([0, 0, 1.0]) for c in cams])
    A = np.zeros((3, 3)); b = np.zeros(3)
    for c, d in zip(C, D):
        P = np.eye(3) - np.outer(d, d)
        A += P; b += P @ c
    center = np.linalg.solve(A, b)
    up = np.mean([c.R.T @ np.array([0, -1.0, 0]) for c in cams], axis=0)
    up /= np.linalg.norm(up)
    rel = C - center
    h = rel @ up
    horiz = np.linalg.norm(rel - np.outer(h, up), axis=1)
    radius = radius_factor * float(np.median(horiz))
    top = float(h.max()) + 0.25 * radius
    bottom = -2.0 * radius
    if points is not None and len(points):
        pr = points - center
        ph = pr @ up
        pd = np.linalg.norm(pr - np.outer(ph, up), axis=1)
        inside = pd < radius
        if inside.sum() > 50:
            bottom = float(np.percentile(ph[inside], 0.5)) - 0.05 * radius
    return {"center": center, "up": up, "radius": radius, "top": top, "bottom": bottom,
            "cameraDistanceMedian": float(np.median(np.linalg.norm(rel, axis=1)))}


def in_region(P, reg):
    r = P - reg["center"]
    h = r @ reg["up"]
    d = np.linalg.norm(r - np.outer(h, reg["up"]), axis=1)
    return (d <= reg["radius"]) & (h <= reg["top"]) & (h >= reg["bottom"])


def fit_ground(P, up, center, iters=300, thresh=None, seed=0):
    """RANSAC plane among the lowest points whose normal is within 25 deg of `up`. Returns (n, d) with n.x + d = 0,
    n pointing up, or None."""
    if len(P) < 100:
        return None
    h = (P - center) @ up
    low = P[h < np.percentile(h, 35)]
    if len(low) < 50:
        return None
    rng = np.random.default_rng(seed)
    if thresh is None:
        thresh = 0.01 * (np.percentile(h, 99) - np.percentile(h, 1))
    best, best_n = None, 0
    for _ in range(iters):
        a, b, c = low[rng.choice(len(low), 3, replace=False)]
        n = np.cross(b - a, c - a)
        nn = np.linalg.norm(n)
        if nn < 1e-12:
            continue
        n /= nn
        if n @ up < 0:
            n = -n
        if n @ up < math.cos(math.radians(25)):
            continue
        d = -n @ a
        cnt = int((np.abs(low @ n + d) < thresh).sum())
        if cnt > best_n:
            best_n, best = cnt, (n, d)
    if best is None or best_n < 0.15 * len(low):
        return None
    return best


# ---------------------------------------------------------------------------------------------
# TSDF fusion (numba, dense grid over the object box) + marching cubes (scikit-image).
# (Open3D 0.20's ScalableTSDFVolume returns empty meshes on macOS arm64 even for a synthetic plane,
#  so we use this small, dependency-light implementation everywhere.)


@njit(parallel=True, cache=True)
def _tsdf_integrate(tsdf, weight, behind, origin, voxel, R, t, fx, fy, cx, cy, depth, trunc):
    nx, ny, nz = tsdf.shape
    H, W = depth.shape
    for i in prange(nx):
        x = origin[0] + (i + 0.5) * voxel
        for j in range(ny):
            y = origin[1] + (j + 0.5) * voxel
            for k in range(nz):
                z = origin[2] + (k + 0.5) * voxel
                xc = R[0, 0] * x + R[0, 1] * y + R[0, 2] * z + t[0]
                yc = R[1, 0] * x + R[1, 1] * y + R[1, 2] * z + t[1]
                zc = R[2, 0] * x + R[2, 1] * y + R[2, 2] * z + t[2]
                if zc <= 1e-6:
                    continue
                u = int(fx * xc / zc + cx)
                v = int(fy * yc / zc + cy)
                if u < 0 or v < 0 or u >= W or v >= H:
                    continue
                d = depth[v, u]
                if d < 0:
                    continue  # unknown (e.g. depth discontinuity): no evidence either way
                if d == 0:
                    d = 1e30  # no surface along this ray (transparent / background): free space
                sdf = d - zc
                if sdf < -trunc:
                    behind[i, j, k] += 1  # occluded by the surface from this view (likely inside)
                    continue
                val = min(1.0, sdf / trunc)
                w0 = weight[i, j, k]
                tsdf[i, j, k] = (tsdf[i, j, k] * w0 + val) / (w0 + 1.0)
                weight[i, j, k] = w0 + 1.0


def tsdf_mesh(cams, depth_iter, voxel, trunc_voxels=4.0, bounds=None, min_weight=2.0, max_voxels=400_000_000):
    """depth_iter yields (cam, depth HxW float32 camera-z, color). bounds = (lo, hi) world box.
    depth 0 means "no surface on this ray" (space carving), depth < 0 means unknown (skipped); pass real depths
    for background surfaces outside `bounds` rather than zeroing them, so the air in front of them is carved.
    Returns (V, F, n_views)."""
    from skimage.measure import marching_cubes
    lo, hi = np.asarray(bounds[0], float), np.asarray(bounds[1], float)
    dims = np.ceil((hi - lo) / voxel).astype(int)
    while np.prod(dims) > max_voxels:
        voxel *= 1.15
        dims = np.ceil((hi - lo) / voxel).astype(int)
    tsdf = np.ones(tuple(dims), np.float32)
    weight = np.zeros(tuple(dims), np.float32)
    behind = np.zeros(tuple(dims), np.uint16)
    trunc = trunc_voxels * voxel
    n = 0
    for cam, depth, _ in depth_iter:
        _tsdf_integrate(tsdf, weight, behind, lo, float(voxel), np.ascontiguousarray(cam.R), np.ascontiguousarray(cam.t),
                        cam.fx, cam.fy, cam.cx, cam.cy, np.ascontiguousarray(depth, dtype=np.float32), float(trunc))
        n += 1
    observed = weight >= min_weight
    # Never inside the truncation band: interior if some view saw it behind the surface, else empty space.
    # (Leaving the interior at +1 would turn the inner edge of the band into a spurious inverted shell.)
    tsdf[~observed] = np.where(behind[~observed] > 0, -1.0, 1.0)
    del behind
    if tsdf.min() >= 0 or tsdf.max() <= 0:
        return np.zeros((0, 3)), np.zeros((0, 3), np.int64), n
    verts, faces, _, _ = marching_cubes(tsdf, level=0.0, spacing=(voxel, voxel, voxel), allow_degenerate=False,
                                        gradient_direction="ascent")
    V = verts + lo + 0.5 * voxel
    F = faces[:, ::-1].astype(np.int64)  # counter-clockwise seen from outside (verified on a synthetic sphere)
    return V, F, n


def mask_depth_edges(depth, rel=0.02, grow=2):
    """EXPERIMENTAL (off by default): on the stump bake-off this *hurt* (held-out PSNR 19.2 -> 15.8) because
    unknown pixels stop carving free space, so more background debris survives. Kept for future tuning.
    Mark pixels at depth discontinuities (and at surface/empty borders) as unknown (-1).
    Splat depth there mixes foreground and background ("mixed pixels"); fused into a TSDF they become the
    familiar streaky fins/fringes along silhouettes. Other views see those surfaces head-on."""
    from scipy.ndimage import binary_dilation
    d = depth.astype(np.float32).copy()
    valid = d > 0
    p = np.pad(d, 1, mode="edge")
    pv = np.pad(valid, 1, mode="edge")
    edge = np.zeros(d.shape, bool)
    for dy, dx in ((0, 1), (2, 1), (1, 0), (1, 2)):
        nb = p[dy:dy + d.shape[0], dx:dx + d.shape[1]]
        nbv = pv[dy:dy + d.shape[0], dx:dx + d.shape[1]]
        edge |= valid & nbv & (np.abs(nb - d) > rel * np.maximum(d, 1e-6))
        edge |= valid ^ nbv
    if grow:
        edge = binary_dilation(edge, iterations=int(grow))
    d[edge & valid] = -1.0
    return d


def region_bounds(reg, points=None, margin=0.05):
    """Axis-aligned world box for the TSDF: sparse points inside the crop region (robust percentiles) + margin."""
    if points is not None and len(points):
        P = points[in_region(points, reg)]
        if len(P) > 50:
            lo = np.percentile(P, 0.5, axis=0); hi = np.percentile(P, 99.5, axis=0)
            pad = margin * (hi - lo).max()
            return lo - pad, hi + pad
    r = reg["radius"]
    c = reg["center"]
    return c - r, c + r


# ---------------------------------------------------------------------------------------------
# Mesh cleanup


def clean_mesh(V, F, region=None, ground=None, ground_margin=0.0, min_component_frac=0.02, target_tris=None):
    import open3d as o3d
    m = o3d.geometry.TriangleMesh(o3d.utility.Vector3dVector(V), o3d.utility.Vector3iVector(F))
    if region is not None:
        keep_v = in_region(V, region)
        m.remove_vertices_by_mask(~keep_v)
    if ground is not None:
        n, d = ground
        Vv = np.asarray(m.vertices)
        m.remove_vertices_by_mask((Vv @ n + d) < ground_margin)
    m.remove_degenerate_triangles(); m.remove_duplicated_triangles(); m.remove_duplicated_vertices()
    m.remove_non_manifold_edges()
    if len(m.triangles):
        labels, counts, _ = m.cluster_connected_triangles()
        labels = np.asarray(labels); counts = np.asarray(counts)
        big = np.nonzero(counts >= max(min_component_frac * counts.max(), 1))[0]
        m.remove_triangles_by_mask(~np.isin(labels, big))
        m.remove_unreferenced_vertices()
    for _ in range(3):  # Open3D's QEM can stop short of the target on noisy meshes; a second pass gets there
        if not target_tris or len(m.triangles) <= target_tris * 1.02:
            break
        m = m.simplify_quadric_decimation(int(target_tris))
        m.remove_degenerate_triangles(); m.remove_unreferenced_vertices()
    if target_tris and len(m.triangles) > target_tris * 1.5:
        # QEM stalls on non-manifold marching-cubes patches (seen at 500x reduction ratios): cluster vertices
        # on a grid sized for ~target/2 vertices (≈ target triangles), then finish with QEM.
        area = m.get_surface_area()
        cell = float(np.sqrt(2.0 * area / max(1, target_tris)))
        m = m.simplify_vertex_clustering(voxel_size=cell, contraction=o3d.geometry.SimplificationContraction.Quadric)
        m.remove_degenerate_triangles(); m.remove_duplicated_triangles(); m.remove_unreferenced_vertices()
        if len(m.triangles) > target_tris:
            m = m.simplify_quadric_decimation(int(target_tris))
            m.remove_degenerate_triangles(); m.remove_unreferenced_vertices()
    return np.asarray(m.vertices).copy(), np.asarray(m.triangles).astype(np.int64).copy()


def unwrap(V, F, resolution, padding=4, chunks=None, log=None):
    """xatlas atlas -> (V2, F2, UV, vmap) with UV in [0,1] (v up, OBJ convention).

    The mesh is split spatially into `chunks` sub-meshes (k-means on face centroids) that go into ONE atlas as
    separate meshes: xatlas charts meshes in parallel and chart growing is superlinear in mesh size, so a
    250k-triangle noisy TSDF mesh drops from >17 min (single mesh, unlimited chart area) to about a minute.
    Chunk borders become chart borders, which the bake's dilation hides."""
    import time
    import xatlas
    t0 = time.time()
    if chunks is None:
        chunks = max(1, min(32, len(F) // 12000))
    labels = np.zeros(len(F), np.int64)
    if chunks > 1:
        from scipy.cluster.vq import kmeans2
        cen = V[F].mean(1)
        rng = np.random.default_rng(0)
        sample = cen[rng.choice(len(cen), min(len(cen), 50000), replace=False)]
        centers, _ = kmeans2(sample, chunks, minit="++", seed=0)
        from scipy.spatial import cKDTree
        labels = cKDTree(centers).query(cen)[1]
    atlas = xatlas.Atlas()
    parts = []
    total_area = 0.5 * np.linalg.norm(np.cross(V[F[:, 1]] - V[F[:, 0]], V[F[:, 2]] - V[F[:, 0]]), axis=1).sum()
    for k in range(chunks):
        fk = F[labels == k]
        if len(fk) == 0:
            continue
        used, inv = np.unique(fk, return_inverse=True)
        atlas.add_mesh(V[used].astype(np.float32), inv.reshape(-1, 3).astype(np.uint32))
        parts.append(used)
    co = xatlas.ChartOptions()
    co.max_chart_area = float(total_area / 400.0)  # bounded charts: fast growing, decent packing
    co.max_iterations = 1
    po = xatlas.PackOptions()
    po.resolution = int(resolution)
    po.padding = int(padding)
    po.bilinear = True
    po.blockAlign = True
    atlas.generate(co, po)
    if atlas.atlas_count > 1:
        # charts overflowed one page: pack into a single (larger) page instead; UVs are normalized either way
        po.resolution = 0
        po.texels_per_unit = float(np.sqrt(0.55 * resolution * resolution / max(total_area, 1e-12)))
        atlas.generate(co, po)
    Vs, Fs, UVs, maps = [], [], [], []
    off = 0
    for i, used in enumerate(parts):
        vmap, f2, uv = atlas[i]
        gm = used[vmap]
        Vs.append(V[gm]); Fs.append(f2.astype(np.int64) + off); UVs.append(uv); maps.append(gm)
        off += len(vmap)
    if log:
        log("unwrap: %d tris in %d chunks -> %d verts, atlas %dx%d, %.1fs" % (len(F), len(parts), off, atlas.width,
                                                                              atlas.height, time.time() - t0))
    return np.concatenate(Vs), np.concatenate(Fs), np.concatenate(UVs).astype(np.float64), np.concatenate(maps)


# ---------------------------------------------------------------------------------------------
# Rasterizers (numba)


@njit(cache=True)
def _zbuffer(px, py, pz, F, W, H, zbuf):
    for f in range(F.shape[0]):
        i0, i1, i2 = F[f, 0], F[f, 1], F[f, 2]
        z0, z1, z2 = pz[i0], pz[i1], pz[i2]
        if z0 <= 1e-9 or z1 <= 1e-9 or z2 <= 1e-9:
            continue
        x0, y0, x1, y1, x2, y2 = px[i0], py[i0], px[i1], py[i1], px[i2], py[i2]
        area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
        if abs(area) < 1e-12:
            continue
        xmin = max(int(math.floor(min(x0, min(x1, x2)))), 0)
        xmax = min(int(math.ceil(max(x0, max(x1, x2)))), W - 1)
        ymin = max(int(math.floor(min(y0, min(y1, y2)))), 0)
        ymax = min(int(math.ceil(max(y0, max(y1, y2)))), H - 1)
        if xmin > xmax or ymin > ymax:
            continue
        inv = 1.0 / area
        for y in range(ymin, ymax + 1):
            cy = y + 0.5
            for x in range(xmin, xmax + 1):
                cx = x + 0.5
                w0 = ((x1 - cx) * (y2 - cy) - (x2 - cx) * (y1 - cy)) * inv
                w1 = ((x2 - cx) * (y0 - cy) - (x0 - cx) * (y2 - cy)) * inv
                w2 = 1.0 - w0 - w1
                if w0 < 0 or w1 < 0 or w2 < 0:
                    continue
                z = 1.0 / (w0 / z0 + w1 / z1 + w2 / z2)
                if z < zbuf[y, x]:
                    zbuf[y, x] = z


def raster_depth(V, F, cam, W=None, H=None):
    W = W or cam.width; H = H or cam.height
    sx, sy = W / cam.width, H / cam.height
    Xc = V @ cam.R.T + cam.t
    z = Xc[:, 2].copy()
    zs = np.where(z > 1e-9, z, 1e-9)
    px = (cam.fx * Xc[:, 0] / zs + cam.cx) * sx
    py = (cam.fy * Xc[:, 1] / zs + cam.cy) * sy
    zbuf = np.full((H, W), np.inf)
    _zbuffer(px, py, z, F.astype(np.int64), W, H, zbuf)
    return zbuf


@njit(cache=True)
def _uv_raster(uvx, uvy, F, FT, V, T, fid, bary):
    for f in range(F.shape[0]):
        a, b, c = FT[f, 0], FT[f, 1], FT[f, 2]
        x0, y0, x1, y1, x2, y2 = uvx[a], uvy[a], uvx[b], uvy[b], uvx[c], uvy[c]
        area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
        if abs(area) < 1e-14:
            continue
        inv = 1.0 / area
        xmin = max(int(math.floor(min(x0, min(x1, x2)))) - 1, 0)
        xmax = min(int(math.ceil(max(x0, max(x1, x2)))) + 1, T - 1)
        ymin = max(int(math.floor(min(y0, min(y1, y2)))) - 1, 0)
        ymax = min(int(math.ceil(max(y0, max(y1, y2)))) + 1, T - 1)
        for y in range(ymin, ymax + 1):
            cy = y + 0.5
            for x in range(xmin, xmax + 1):
                cx = x + 0.5
                w0 = ((x1 - cx) * (y2 - cy) - (x2 - cx) * (y1 - cy)) * inv
                w1 = ((x2 - cx) * (y0 - cy) - (x0 - cx) * (y2 - cy)) * inv
                w2 = 1.0 - w0 - w1
                # texel centers strictly inside; chart borders are filled afterwards by _dilate()
                if w0 < 0 or w1 < 0 or w2 < 0:
                    continue
                fid[y, x] = f
                bary[y, x, 0] = w0
                bary[y, x, 1] = w1


@njit(parallel=True, cache=True)
def _bake_view(P, N, zbuf, img, fx, cx, cy, fy, R, t, camc, acc, wsum, best_w, depth_tol, power):
    H, W = zbuf.shape
    n = P.shape[0]
    for i in prange(n):
        X = P[i]
        xc0 = R[0, 0] * X[0] + R[0, 1] * X[1] + R[0, 2] * X[2] + t[0]
        xc1 = R[1, 0] * X[0] + R[1, 1] * X[1] + R[1, 2] * X[2] + t[1]
        xc2 = R[2, 0] * X[0] + R[2, 1] * X[1] + R[2, 2] * X[2] + t[2]
        if xc2 <= 1e-6:
            continue
        u = fx * xc0 / xc2 + cx
        v = fy * xc1 / xc2 + cy
        if u < 1.0 or v < 1.0 or u > W - 2.0 or v > H - 2.0:
            continue
        zb = zbuf[int(v), int(u)]
        if not (abs(zb - xc2) <= depth_tol * xc2):
            continue
        dx = camc[0] - X[0]; dy = camc[1] - X[1]; dz = camc[2] - X[2]
        dist = math.sqrt(dx * dx + dy * dy + dz * dz)
        cosang = (N[i, 0] * dx + N[i, 1] * dy + N[i, 2] * dz) / dist
        if cosang <= 0.2:
            continue
        # weight: grazing angle + pixel footprint (closer = sharper)
        w = (cosang ** 2) * (fx / xc2) ** 2
        w = w ** power
        # bilinear sample
        x = u - 0.5; y = v - 0.5
        x0 = int(x); y0 = int(y)
        ax = x - x0; ay = y - y0
        for ch in range(3):
            c = (img[y0, x0, ch] * (1 - ax) * (1 - ay) + img[y0, x0 + 1, ch] * ax * (1 - ay)
                 + img[y0 + 1, x0, ch] * (1 - ax) * ay + img[y0 + 1, x0 + 1, ch] * ax * ay)
            acc[i, ch] += w * c
        wsum[i] += w
        if w > best_w[i]:
            best_w[i] = w


def bake_texture(V, F, UV, FT, cams, load_image, size, depth_res=None, depth_tol=0.01, power=2.0, log=None):
    """Project photos onto the atlas. load_image(cam) -> HxWx3 float32 in [0,1] at cam.width x cam.height.
    Returns (texture uint8 size x size x 3, coverage fraction of atlas texels that got a color)."""
    T = int(size)
    uvx = UV[:, 0] * T
    uvy = (1.0 - UV[:, 1]) * T  # image rows go down
    fid = np.full((T, T), -1, np.int64)
    bary = np.zeros((T, T, 2), np.float32)
    _uv_raster(uvx, uvy, F.astype(np.int64), FT.astype(np.int64), V, T, fid, bary)
    ys, xs = np.nonzero(fid >= 0)
    f = fid[ys, xs]
    w0 = bary[ys, xs, 0].astype(np.float64); w1 = bary[ys, xs, 1].astype(np.float64); w2 = 1 - w0 - w1
    P = V[F[f, 0]] * w0[:, None] + V[F[f, 1]] * w1[:, None] + V[F[f, 2]] * w2[:, None]
    e1 = V[F[:, 1]] - V[F[:, 0]]; e2 = V[F[:, 2]] - V[F[:, 0]]
    FN = np.cross(e1, e2)
    FN /= np.maximum(np.linalg.norm(FN, axis=1, keepdims=True), 1e-20)
    N = FN[f]
    del fid, bary
    acc = np.zeros((len(P), 3)); wsum = np.zeros(len(P)); best = np.zeros(len(P))
    for k, cam in enumerate(cams):
        img = load_image(cam)
        zbuf = raster_depth(V, F, cam)
        _bake_view(P, N, zbuf, np.ascontiguousarray(img, dtype=np.float32), cam.fx, cam.cx, cam.cy, cam.fy,
                   np.ascontiguousarray(cam.R), np.ascontiguousarray(cam.t), np.ascontiguousarray(cam.center),
                   acc, wsum, best, depth_tol, power)
        if log:
            log("bake view %d/%d %s" % (k + 1, len(cams), cam.name))
    tex = np.zeros((T, T, 3), np.float32)
    ok = wsum > 0
    tex[ys[ok], xs[ok]] = (acc[ok] / wsum[ok, None]).astype(np.float32)
    filled = np.zeros((T, T), bool); filled[ys[ok], xs[ok]] = True
    tex = _dilate(tex, filled, 8)
    cov = float(ok.mean()) if len(ok) else 0.0
    return (np.clip(tex, 0, 1) * 255 + 0.5).astype(np.uint8), cov


def _dilate(tex, filled, iters):
    """Grow colors into empty texels (gutter padding so mip-maps/bilinear don't bleed black)."""
    for _ in range(iters):
        if filled.all():
            break
        acc = np.zeros_like(tex); cnt = np.zeros(filled.shape, np.float32)
        for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            sh_f = np.roll(filled, (dy, dx), (0, 1))
            sh_t = np.roll(tex, (dy, dx), (0, 1))
            acc += sh_t * sh_f[..., None]; cnt += sh_f
        grow = (~filled) & (cnt > 0)
        tex[grow] = acc[grow] / cnt[grow, None]
        filled = filled | grow
    return tex


def vertex_normals(V, F):
    n = np.zeros_like(V)
    fn = np.cross(V[F[:, 1]] - V[F[:, 0]], V[F[:, 2]] - V[F[:, 0]])
    for k in range(3):
        np.add.at(n, F[:, k], fn)
    return n / np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-20)
