"""OpenMVS mesh stage (CPU only): the bake-off's best recipe (bakeoff/openmvs/run_best.sh, variant "omvs_fsc_mb2")
as library code for the cloud worker.

  undistorted COLMAP workspace (images/ + sparse/)
    -> InterfaceCOLMAP                         scene.mvs
    -> DensifyPointCloud  RL0, tower-mode 0, crop-to-roi 0          dense.mvs / dense.ply
    -> ReconstructMesh    -f 1 --close-holes 300 --remove-spurious 0 mesh.ply
    -> crop (training cameras only: frustum fraction >= 0.1, sphere 1.6 x median camera distance, big components)
    -> RefineMesh         RL0 --decimate 0.25                         refined.ply
    -> CloudRecon bake    QEM 250k -> drop faces no photo sees -> xatlas -> two-band 8K photo bake (sigma 2 texels)

OpenMVS v2.4.0 is AGPL-3.0 and runs here as separate programs (built in modal_app.cpu_image with the upstream
TextureMesh seam-leveling fix applied). Nothing in this module links against it.
"""
import os
import re
import subprocess
import time

import numpy as np

from . import colmap_io, meshing


def omvs_bin(name):
    return os.path.join(os.environ.get("OMVS_BIN", "/opt/openmvs/bin/OpenMVS"), name)


def available_cpus():
    """CPU cores this container may use (cgroup v2 quota, else affinity, else os.cpu_count())."""
    try:
        quota, period = open("/sys/fs/cgroup/cpu.max").read().split()[:2]
        if quota != "max":
            return max(1, int(round(int(quota) / int(period))))
    except (OSError, ValueError):
        pass
    try:
        return max(1, len(os.sched_getaffinity(0)))
    except AttributeError:
        return os.cpu_count() or 1


_PCT = re.compile(r"\((\d{1,3}(?:\.\d+)?)%")


class PhaseProgress:
    """Progress of one OpenMVS program for the app's bar: only ever moves forward.

    OpenMVS prints several phases that each count 0-100 % ("Estimated depth-maps 12 (29%, ..)", then filtering,
    fusion, ...), and some short ones finish in a second, so raw percentages jump around. The bar uses the larger of
      * elapsed / expected seconds (expected from measured per-photo times), capped at 95 %, and
      * the percentage of the program's main phase (lines matching `main`), capped at 95 %.
    Distinct phase labels are kept in `labels` for the build log."""

    def __init__(self, report, expected_seconds=None, main=None, clock=time.time):
        self.report, self.expected, self.clock = report, expected_seconds, clock
        self.main = re.compile(main, re.I) if main else None
        self.t0, self.last, self.labels = clock(), 0.0, []

    def _emit(self, f):
        f = min(0.95, f)
        if f > self.last + 1e-3:
            self.last = f
            if self.report:
                self.report(f)

    def tick(self):
        if self.expected:
            self._emit((self.clock() - self.t0) / self.expected)

    def line(self, line):
        """Returns the line's percentage (0-100) if it is a progress line, else None."""
        m = _PCT.search(line)
        self.tick()
        if not m:
            return None
        label = re.sub(r"[\d\s]+$", "", line[:m.start()].split("]")[-1]).strip()
        if label not in self.labels and len(self.labels) < 20:
            self.labels.append(label)
        pct = float(m.group(1))
        if self.main and self.main.search(label):
            self._emit(pct / 100.0)
        return pct


def run_tool(cmd, log, cwd, progress=None, timeout=4 * 3600, expected_seconds=None, main=None):
    """Run one OpenMVS program, streaming its output into `progress(fraction)` (see PhaseProgress).
    The last lines go to the build log; a non-zero exit raises PipelineError."""
    from .pipeline import PipelineError
    log("$ " + " ".join(os.path.basename(c) if i == 0 else c for i, c in enumerate(cmd)))
    t0 = time.time()
    p = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    tail, buf = [], b""
    phases = PhaseProgress(progress, expected_seconds, main)
    while True:
        chunk = p.stdout.read1(65536) if hasattr(p.stdout, "read1") else p.stdout.read(4096)
        if not chunk:
            break
        buf += chunk
        parts = re.split(rb"[\r\n]", buf)
        buf = parts.pop()
        for raw in parts:
            line = raw.decode("utf-8", "replace").strip()
            if not line:
                continue
            if phases.line(line) is None:
                tail = (tail + [line])[-25:]
        if time.time() - t0 > timeout:
            p.kill()
            raise PipelineError("%s took too long" % os.path.basename(cmd[0]))
    rc = p.wait()
    log("  rc=%d in %.1fs (progress phases: %s)\n%s" % (rc, time.time() - t0, "; ".join(phases.labels) or "-",
                                                         "\n".join(tail[-12:])))
    if rc != 0:
        raise PipelineError("Building the mesh failed (%s)." % os.path.basename(cmd[0]), "\n".join(tail))
    return time.time() - t0


def make_workspace(undist, ws):
    """COLMAP dense workspace for InterfaceCOLMAP: images/ (symlinks to the undistorted photos) + sparse/ as a TEXT
    model, exactly what the bake-off fed it (pycolmap 4.x text export; frames/rigs files are ignored)."""
    import pycolmap
    os.makedirs(os.path.join(ws, "images"), exist_ok=True)
    os.makedirs(os.path.join(ws, "sparse"), exist_ok=True)
    src = os.path.join(undist, "images")
    for n in sorted(os.listdir(src)):
        d = os.path.join(ws, "images", n)
        if not os.path.exists(d):
            os.symlink(os.path.realpath(os.path.join(src, n)), d)
    pycolmap.Reconstruction(os.path.join(undist, "sparse")).write_text(os.path.join(ws, "sparse"))
    return ws


# ---------------------------------------------------------------------------------------------
# Mesh I/O + automatic crop (bakeoff/openmvs/crop_mesh.py)


def read_ply_mesh(path):
    from plyfile import PlyData
    p = PlyData.read(path)
    v = p["vertex"]
    V = np.stack([v["x"], v["y"], v["z"]], 1).astype(np.float64)
    fk = p["face"].data.dtype.names[0]
    F = np.stack(p["face"].data[fk]).astype(np.int64)
    return V, F


def write_ply_mesh(path, V, F):
    from plyfile import PlyData, PlyElement
    ve = np.empty(len(V), [("x", "f4"), ("y", "f4"), ("z", "f4")])
    ve["x"], ve["y"], ve["z"] = V[:, 0], V[:, 1], V[:, 2]
    fe = np.empty(len(F), [("vertex_indices", "i4", (3,))])
    fe["vertex_indices"] = F
    PlyData([PlyElement.describe(ve, "vertex"), PlyElement.describe(fe, "face")], text=False).write(path)


def look_at_center(cams):
    A = np.zeros((3, 3)); b = np.zeros(3)
    for c in cams:
        d = c.R.T @ np.array([0, 0, 1.0])
        P = np.eye(3) - np.outer(d, d)
        A += P; b += P @ c.center
    return np.linalg.solve(A, b)


def frustum_fraction(V, cams, margin=0.0):
    cnt = np.zeros(len(V), np.int32)
    for c in cams:
        X = V @ c.R.T + c.t
        z = X[:, 2]
        with np.errstate(divide="ignore", invalid="ignore"):
            u = c.fx * X[:, 0] / z + c.cx
            v = c.fy * X[:, 1] / z + c.cy
        mx, my = margin * c.width, margin * c.height
        cnt += ((z > 0) & (u >= -mx) & (u < c.width + mx) & (v >= -my) & (v < c.height + my)).astype(np.int32)
    return cnt / float(len(cams))


def _compact(V, F):
    used = np.unique(F)
    remap = -np.ones(len(V), np.int64)
    remap[used] = np.arange(len(used))
    return V[used], remap[F]


def crop(V, F, cams, min_frac=0.1, radius_factor=1.6, min_component=0.05):
    """Keep vertices seen by >= min_frac of the cameras and within radius_factor x the median camera distance of
    the cameras' common look-at point, then the connected components with >= min_component of the largest."""
    from scipy.sparse import coo_matrix
    from scipy.sparse.csgraph import connected_components
    c = look_at_center(cams)
    dist_cam = float(np.median([np.linalg.norm(cm.center - c) for cm in cams]))
    keep_v = (frustum_fraction(V, cams) >= min_frac) & (np.linalg.norm(V - c, axis=1) <= radius_factor * dist_cam)
    F1 = F[keep_v[F].all(1)]
    info = {"center": c.tolist(), "medianCameraDistance": dist_cam, "radius": radius_factor * dist_cam,
            "minFrac": min_frac, "facesIn": int(len(F))}
    if len(F1) == 0:
        info.update(facesOut=0, components=0, componentsKept=0)
        return np.zeros((0, 3)), np.zeros((0, 3), np.int64), info
    V1, F1 = _compact(V, F1)
    e = np.concatenate([F1[:, [0, 1]], F1[:, [1, 2]], F1[:, [2, 0]]])
    n, lab = connected_components(coo_matrix((np.ones(len(e)), (e[:, 0], e[:, 1])), shape=(len(V1), len(V1))),
                                  directed=False)
    flab = lab[F1[:, 0]]
    sizes = np.bincount(flab, minlength=n)
    good = sizes >= min_component * sizes.max()
    V2, F2 = _compact(V1, F1[good[flab]])
    info.update(facesOut=int(len(F2)), components=int(n), componentsKept=int(good.sum()))
    return V2, F2, info


# ---------------------------------------------------------------------------------------------
# Texture (bakeoff/openmvs/bake_cloudrecon.py)


def face_view_counts(V, F, cams, scale=0.5, depth_tol=0.01, min_cos=0.1):
    """How many cameras see each face (centroid in frame, in front, facing the camera, passes a z-buffer test)."""
    C = V[F].mean(1)
    N = np.cross(V[F[:, 1]] - V[F[:, 0]], V[F[:, 2]] - V[F[:, 0]])
    N /= np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-20)
    cnt = np.zeros(len(F), np.int32)
    for cam in cams:
        W, H = int(cam.width * scale), int(cam.height * scale)
        zb = meshing.raster_depth(V, F, cam, W, H)
        X = C @ cam.R.T + cam.t
        z = X[:, 2]
        ok = z > 1e-6
        u = (cam.fx * X[:, 0] / np.where(ok, z, 1) + cam.cx) * scale
        v = (cam.fy * X[:, 1] / np.where(ok, z, 1) + cam.cy) * scale
        ok &= (u >= 0) & (v >= 0) & (u < W) & (v < H)
        d = cam.center - C
        ok &= (N * d).sum(1) / np.maximum(np.linalg.norm(d, axis=1), 1e-20) > min_cos
        iu, iv = np.clip(u.astype(int), 0, W - 1), np.clip(v.astype(int), 0, H - 1)
        ok &= np.abs(zb[iv, iu] - z) <= depth_tol * z + 1e-9
        cnt += ok
    return cnt


def texture_mesh(V, F, cams, image_dir, log, tris=250000, tex=8192, min_views=1, power=2.0, multiband=2.0,
                 sharp_power=16.0, progress=None):
    """Decimate -> drop unseen faces -> xatlas -> multi-view bake; with multiband > 0 the two-band blend:
    low frequencies from the smooth multi-view average, high frequencies from a near-best-view bake."""
    from PIL import Image
    from .pipeline import PipelineError
    t0 = time.time()
    V, F = meshing.clean_mesh(V, F, target_tris=tris)
    log("bake: decimated to %d tris (%.1fs)" % (len(F), time.time() - t0))
    if progress:
        progress(0.1)
    if min_views > 0 and len(F):
        keep = face_view_counts(V, F, cams) >= min_views
        log("bake: dropped %d faces no photo sees, %d left" % ((~keep).sum(), keep.sum()))
        F = F[keep]
        if len(F):
            V, F = _compact(V, F)
    if len(F) < 100:
        raise PipelineError("The mesh came out empty. Try more photos all around the object, with good light.")
    V2, F2, UV, _ = meshing.unwrap(V, F, tex, log=log)
    if progress:
        progress(0.3)

    def load_image(cam):
        return np.asarray(Image.open(os.path.join(image_dir, cam.name)).convert("RGB"), dtype=np.float32) / 255.0

    texture, cov = meshing.bake_texture(V2, F2, UV, F2, cams, load_image, tex, power=power)
    log("bake: %dpx average pass, %.1f%% of atlas texels seen (%.1fs)" % (tex, 100 * cov, time.time() - t0))
    if progress:
        progress(0.65)
    if multiband > 0:
        from scipy.ndimage import gaussian_filter
        sharp, _ = meshing.bake_texture(V2, F2, UV, F2, cams, load_image, tex, power=sharp_power)

        def lo(x):
            return np.stack([gaussian_filter(x[..., c], multiband) for c in range(3)], -1)

        b, s = texture.astype(np.float32), sharp.astype(np.float32)
        texture = np.clip(lo(b) + (s - lo(s)), 0, 255).astype(np.uint8)
        del b, s, sharp
        log("bake: two-band blend sigma %.1f, sharp power %.0f (%.1fs)" % (multiband, sharp_power, time.time() - t0))
    if progress:
        progress(1.0)
    return V2, F2, UV, texture, cov


# ---------------------------------------------------------------------------------------------


def openmvs_mesh(undist, work, log, progress=None, threads=None):
    """Raw OpenMVS mesh (COLMAP world frame) of the object: (V, F, info). `progress(stage, fraction, message)`."""
    from .pipeline import PipelineError
    T = str(threads if threads is not None else int(os.environ.get("OMVS_THREADS", "0")) or available_cpus())
    mvs = os.path.join(work, "mvs")
    os.makedirs(mvs, exist_ok=True)
    ws = make_workspace(undist, os.path.join(mvs, "ws"))
    times = {}

    def prog(stage, lo, hi, msg):
        return (lambda f: progress(stage, lo + (hi - lo) * f, msg)) if progress else None

    times["import"] = run_tool([omvs_bin("InterfaceCOLMAP"), "-i", ws, "-o", "scene.mvs",
                                "--image-folder", os.path.join(ws, "images") + "/"], log, mvs)
    n = max(1, sum(len(fs) for _, _, fs in os.walk(os.path.join(undist, "images"))))  # photos (flat or <W>x<H>/)
    # expected seconds per photo, measured on the stump (41 photos, 2000 px, 16 cores): 13.2 / 2.8 / 7.1
    times["densify"] = run_tool([omvs_bin("DensifyPointCloud"), "-i", "scene.mvs", "-o", "dense.mvs",
                                 "--max-threads", T, "--resolution-level", "0", "--tower-mode", "0",
                                 "--crop-to-roi", "0"], log, mvs,
                                prog("pointCloudGeneration", 0.0, 1.0, "Measuring depth in every photo"),
                                expected_seconds=13.5 * n, main=r"depth-?maps?")
    if progress:
        progress("meshGeneration", 0.0, "Building the mesh")
    times["mesh"] = run_tool([omvs_bin("ReconstructMesh"), "-i", "dense.mvs", "-p", "dense.ply", "-o", "mesh.mvs",
                              "--max-threads", T, "--crop-to-roi", "0", "-f", "1", "--close-holes", "300",
                              "--remove-spurious", "0"], log, mvs, prog("meshGeneration", 0.0, 0.3, "Building the mesh"),
                             expected_seconds=3.0 * n)
    t0 = time.time()
    cams = colmap_io.load_pinhole_model(os.path.join(undist, "sparse"))
    V, F = read_ply_mesh(os.path.join(mvs, "mesh.ply"))
    V, F, cinfo = crop(V, F, cams, min_frac=0.1, radius_factor=1.6)
    log("crop: %s" % cinfo)
    if len(F) < 100:
        raise PipelineError("The mesh came out empty. Try more photos all around the object, with good light.")
    write_ply_mesh(os.path.join(mvs, "crop.ply"), V, F)
    times["crop"] = time.time() - t0
    if progress:
        progress("meshGeneration", 0.35, "Refining the surface")
    times["refine"] = run_tool([omvs_bin("RefineMesh"), "-i", "dense.mvs", "-m", "crop.ply", "-o", "refined.mvs",
                                "--max-threads", T, "--resolution-level", "0", "--decimate", "0.25"], log, mvs,
                               prog("meshGeneration", 0.35, 1.0, "Refining the surface"), expected_seconds=7.5 * n)
    V, F = read_ply_mesh(os.path.join(mvs, "refined.ply"))
    log("openmvs: refined mesh %d verts %d tris; stage seconds %s" % (len(V), len(F),
                                                                     {k: round(v, 1) for k, v in times.items()}))
    return V, F, {"crop": cinfo, "seconds": {k: round(v, 1) for k, v in times.items()}, "threads": int(T)}
