"""The cloud build: photos -> COLMAP SfM (pycolmap) -> undistort -> mesh -> photo-baked texture -> metric scale
from the photos' LiDAR depth -> Y-up, object resting at the origin -> exports.

Two mesh paths ($CLOUD_MESHER):
  openmvs (default, CPU only)  OpenMVS v2.4.0 densify/mesh/refine + automatic crop + CloudRecon two-band bake
                               (the bake-off recipe that ties Apple Object Capture: bakeoff/RESULTS.md)
  splat   (optional, GPU)      gsplat 3DGS -> splat depth -> TSDF -> bake (+ splat.ply); worse mesh than Apple

Every stage is a function taking/returning paths so tests can swap the heavy stages for fakes
(`Stages` below). All external tools are invoked as subprocesses with logs appended to recon-log.txt.

Output directory layout (same as the Mac CLI, so recon_server.py works unchanged):
  out/result.json  out/model.usdz  out/obj/  out/model-obj.zip (with --obj)  out/recon-log.txt
  out/thumbnail.png  + cloud extras: out/splat.ply (3DGS, INRIA layout), out/cameras.json
"""
import json
import os
import shutil
import subprocess
import sys
import time
import zipfile

IMAGE_EXTS = (".heic", ".heif", ".jpg", ".jpeg", ".png", ".tif", ".tiff")

MESHER = os.environ.get("CLOUD_MESHER", "openmvs")

# Stage names reuse Apple's so both apps already have human labels for them.
STAGES_OPENMVS = [
    ("extracting", 0.00, 0.02),
    ("preProcessing", 0.02, 0.05),      # HEIC->JPEG (+ LiDAR depth stays in the HEICs), resize
    ("imageAlignment", 0.05, 0.15),     # COLMAP features + matching + global mapper
    ("pointCloudGeneration", 0.15, 0.50),  # OpenMVS DensifyPointCloud (depth map per photo)
    ("meshGeneration", 0.50, 0.80),     # ReconstructMesh + crop + RefineMesh
    ("textureMapping", 0.80, 0.95),     # decimate + unwrap + two-band bake
    ("optimization", 0.95, 0.99),       # scale, orient, exports
]
STAGES = [
    ("extracting", 0.00, 0.02),
    ("preProcessing", 0.02, 0.05),      # HEIC->JPEG, resize
    ("imageAlignment", 0.05, 0.20),     # COLMAP features + matching + global mapper
    ("pointCloudGeneration", 0.20, 0.70),  # splat training
    ("meshGeneration", 0.70, 0.85),     # splat depth -> TSDF -> cleanup -> decimate
    ("textureMapping", 0.85, 0.95),     # unwrap + bake
    ("optimization", 0.95, 0.99),       # exports
]


class Status:
    """Writes the same live status.json the Mac CLI writes (state/fraction/stage/message/etaSeconds)."""

    def __init__(self, path, t0=None, stages=None):
        self.path, self.t0 = path, t0 or time.time()
        self.table = stages or STAGES
        self.s = {"state": "starting", "attempt": 1, "fraction": 0.0, "stage": None, "message": "", "pid": os.getpid()}
        self.write()

    def write(self):
        if not self.path:
            return
        self.s["updatedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.s, f, sort_keys=True)
        os.replace(tmp, self.path)

    def stage(self, name, sub=0.0, message=None, eta=None):
        lo, hi = next((a, b) for n, a, b in self.table if n == name)
        frac = lo + (hi - lo) * max(0.0, min(1.0, sub))
        self.s.update(state="extracting" if name == "extracting" else "processing", stage=name,
                      fraction=round(frac, 4), message=message or self.s.get("message", ""))
        el = time.time() - self.t0
        self.s["etaSeconds"] = eta if eta is not None else (int(el / frac - el) if frac > 0.05 else None)
        self.write()

    def done(self, ok, message):
        self.s.update(state="done" if ok else "failed", fraction=1.0, message=message, etaSeconds=None)
        self.write()


class Log:
    def __init__(self, path, echo=True):
        self.path, self.echo, self.t0 = path, echo, time.time()

    def __call__(self, *parts):
        line = "[%7.1fs] %s" % (time.time() - self.t0, " ".join(str(p) for p in parts))
        with open(self.path, "a") as f:
            f.write(line + "\n")
        if self.echo:
            print(line, flush=True)


def run(cmd, log, cwd=None, env=None, timeout=None):
    log("$ " + " ".join(cmd))
    t0 = time.time()
    p = subprocess.run(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout)
    tail = "\n".join(p.stdout.strip().splitlines()[-15:])
    log("  rc=%d in %.1fs\n%s" % (p.returncode, time.time() - t0, tail))
    if p.returncode != 0:
        raise PipelineError("command failed: %s (rc %d)" % (cmd[0] if len(cmd) == 1 else " ".join(cmd[:2]), p.returncode), tail)
    return p.stdout


class PipelineError(Exception):
    def __init__(self, message, technical=""):
        super().__init__(message)
        self.message, self.technical = message, technical


# ---------------------------------------------------------------------------------------------
# Input


def find_image_dir(root):
    """The folder holding the most images anywhere under root (same rule as the Mac server)."""
    best, best_n = None, 0
    for d, _, files in os.walk(root):
        n = sum(1 for f in files if f.lower().endswith(IMAGE_EXTS) and not f.startswith("._"))
        if n > best_n:
            best, best_n = d, n
    return best, best_n


def extract_input(src, work, log):
    """src: a .zip (the app's upload) or a folder. Returns the image folder."""
    if os.path.isdir(src):
        d, n = find_image_dir(src)
    else:
        dest = os.path.join(work, "input")
        os.makedirs(dest, exist_ok=True)
        with zipfile.ZipFile(src) as z:
            for m in z.infolist():
                name = os.path.normpath(m.filename)
                if name.startswith("..") or os.path.isabs(name):
                    raise PipelineError("zip contains an unsafe path: %s" % m.filename)
            z.extractall(dest)
        d, n = find_image_dir(dest)
    if not d or n < 3:
        raise PipelineError("The upload has %d photos; at least 3 (ideally 20-200) are needed." % (n or 0))
    log("input: %d images in %s" % (n, d))
    return d


def prepare_images(src_dir, dst_dir, max_side, log):
    """Decode HEIC/JPEG (EXIF-rotated to upright pixels), resize so the long side <= max_side, write JPEG q95.
    EXIF orientation is applied, so COLMAP sees upright pixels with no orientation tag.
    Returns (original names, set of sizes, {prepared jpg name: (original name, (w, h))})."""
    from PIL import Image, ImageOps
    try:
        import pillow_heif  # noqa: F401
        pillow_heif.register_heif_opener()
    except Exception:
        pass
    os.makedirs(dst_dir, exist_ok=True)
    names = sorted(n for n in os.listdir(src_dir) if n.lower().endswith(IMAGE_EXTS) and not n.startswith("._"))
    sizes = set()
    mapping = {}
    for n in names:
        im = ImageOps.exif_transpose(Image.open(os.path.join(src_dir, n))).convert("RGB")
        s = max_side / max(im.size)
        if s < 1:
            im = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
        out = os.path.splitext(n)[0] + ".jpg"
        if out in mapping:  # IMG_1.HEIC + IMG_1.JPG in one upload: keep both
            out = n.replace(".", "_") + ".jpg"
        im.save(os.path.join(dst_dir, out), quality=95)
        sizes.add(im.size)
        mapping[out] = (n, im.size)
    log("prepared %d images, sizes %s" % (len(names), sorted(sizes)[:4]))
    return names, sizes, mapping


# ---------------------------------------------------------------------------------------------
# GPU stages (real implementations)


class Stages:
    """Real stage implementations. Tests subclass and override the GPU/heavy ones."""

    sfm_python = os.environ.get("SFM_PYTHON", sys.executable)   # venv with pycolmap(-cuda12)
    python = sys.executable

    def sfm(self, images, work, log, use_gpu=None):
        """pycolmap 4.2.1 in a subprocess (own venv in the image): SIFT, exhaustive match, global mapper."""
        if use_gpu is None:
            use_gpu = os.environ.get("SFM_GPU", "1") == "1"
        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        cmd = [self.sfm_python, "-m", "asbuilt_cloud.sfm_pycolmap", images, os.path.join(work, "sfm")]
        if use_gpu:
            cmd.append("--gpu")
        env = dict(os.environ, PYTHONPATH=here + os.pathsep + os.environ.get("PYTHONPATH", ""))
        out = run(cmd, log, env=env, timeout=3600)
        summary = json.loads(out.strip().splitlines()[-1])
        log("sfm: %(registered)d/%(images)d registered with the %(mapper)s mapper, %(meanReprojErrorPx).2f px" % summary)
        if summary["registered"] < max(3, 0.5 * summary["images"]):
            raise PipelineError("Only %d of %d photos could be lined up. Take more overlapping photos all around the object."
                                % (summary["registered"], summary["images"]))
        self.sfm_summary = summary
        return summary["undist"]

    def train_splat(self, undist, work, log, steps=30000, progress=None):
        """gsplat (Apache-2.0) MCMC 3DGS, SH degree 3, capped at $SPLAT_CAP_MAX Gaussians (default 1.5M)."""
        res = os.path.join(work, "gsplat")
        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        cmd = [self.python, "-u", "-m", "asbuilt_cloud.gsplat_train", undist, res, "--steps", str(steps),
               "--cap", os.environ.get("SPLAT_CAP_MAX", "1500000")]
        env = dict(os.environ, PYTHONPATH=here + os.pathsep + os.environ.get("PYTHONPATH", ""))
        log("$ " + " ".join(cmd))
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
        tail = []
        for line in p.stdout:
            if line.startswith("PROGRESS "):
                k, n = line.split()[1:3]
                if progress:
                    progress(int(k) / max(1, int(n)))
                continue
            tail = (tail + [line.rstrip()])[-30:]
        rc = p.wait()
        log("  gsplat rc=%d\n%s" % (rc, "\n".join(tail[-12:])))
        if rc != 0:
            raise PipelineError("Training the photoreal model failed.", "\n".join(tail))
        plys = sorted(os.listdir(os.path.join(res, "ply")))
        return os.path.join(res, "ply", plys[-1])

    def splat_to_mesh(self, ply, undist, work, log, max_tris, texture, progress=None):
        from . import splatmesh
        return splatmesh.splat_to_mesh(ply, undist, work, log, max_tris=max_tris, texture=texture, progress=progress)

    def mvs_mesh(self, undist, work, log, progress=None):
        """OpenMVS densify -> mesh -> crop -> refine (CPU). Returns (V, F, info) in the SfM world frame."""
        from . import openmvs_mesh
        return openmvs_mesh.openmvs_mesh(undist, work, log, progress=progress)


# ---------------------------------------------------------------------------------------------


def _reset_out(out):
    os.makedirs(out, exist_ok=True)
    for stale in ("model.usdz", "model-obj.zip", "obj", "thumbnail.png", "result.json", "splat.ply", "recon-log.txt"):
        p = os.path.join(out, stale)
        shutil.rmtree(p, ignore_errors=True) if os.path.isdir(p) else (os.path.exists(p) and os.remove(p))


def camera_up(cams):
    """Gravity 'up' from the photos themselves. People hold the phone level (no roll) while they tilt it up or down,
    so every camera's x axis (image right) is horizontal: up is the direction most perpendicular to all of them
    (smallest eigenvector of sum x x^T). Unlike the mean camera 'up', this has no bias when the photos look down at
    the object from one side. Falls back to the mean camera up when all x axes are parallel (one viewpoint)."""
    import numpy as np
    X = np.array([c.R[0] for c in cams])
    mean_up = np.mean([c.R.T @ np.array([0, -1.0, 0]) for c in cams], axis=0)
    mean_up /= np.linalg.norm(mean_up)
    w, v = np.linalg.eigh(X.T @ X)
    w = w / max(w.sum(), 1e-12)
    if w[1] < 0.05:  # x axes all (nearly) parallel: the null direction is ill-defined
        return mean_up, "mean camera up"
    up = v[:, 0]
    return (up if up @ mean_up >= 0 else -up), "camera x axes"


def output_frame(cams, sparse_xyz, V):
    """Y-up frame with the object resting at the origin: up = gravity estimated from the camera x axes (see
    camera_up); origin = the cameras' look-at point dropped onto the ground plane when one is found perpendicular
    to that up (within 10 deg), else onto the lowest 0.5 % of the mesh.
    Returns (Rw 3x3 rows = new x/y/z axes in SfM coords, origin, info)."""
    import numpy as np
    from . import meshing
    reg = meshing.object_region(cams, sparse_xyz)
    center = reg["center"]
    up, source = camera_up(cams)
    info = {"upFrom": source, "originFrom": "lowest mesh points"}
    h = (V - center) @ up
    origin = center + up * float(np.percentile(h, 0.5))
    g = meshing.fit_ground(V, up, center) if len(V) >= 100 else None
    if g is not None:
        n, d = g
        n = n / np.linalg.norm(n)
        tilt = float(np.degrees(np.arccos(np.clip(abs(n @ up), -1, 1))))
        info["groundTiltDeg"] = round(tilt, 1)
        if tilt <= 10:
            origin = center - ((center @ n + d) / (up @ n)) * up  # along up onto the plane
            info["originFrom"] = "ground plane"
    ref = np.array([0, 0, 1.0]) if abs(up[2]) < 0.9 else np.array([1.0, 0, 0])
    x = np.cross(up, ref)
    x /= np.linalg.norm(x)
    z = np.cross(x, up)
    return np.stack([x, up, z]), origin, info


def build(src, out, detail="phone", texture="8k", max_polys=None, obj=False, status_file=None, title=None,
          stages=None, max_side=None, steps=None, echo=True, tris_override=None, texture_px_override=None,
          mesher=None):
    mesher = mesher or MESHER
    if mesher == "splat":
        return build_splat(src, out, detail=detail, texture=texture, max_polys=max_polys, obj=obj,
                           status_file=status_file, title=title, stages=stages, max_side=max_side, steps=steps,
                           echo=echo, tris_override=tris_override, texture_px_override=texture_px_override)
    return build_openmvs(src, out, detail=detail, texture=texture, max_polys=max_polys, obj=obj,
                         status_file=status_file, title=title, stages=stages, max_side=max_side, echo=echo,
                         tris_override=tris_override, texture_px_override=texture_px_override)


def _tris_for(detail, max_polys):
    # Same caps as the Mac: phone = 250k (iPhone-friendly), full ~ 250k, raw = all the detail we have.
    return {"phone": 250000, "full": 250000, "custom": max_polys or 1000000, "raw": 2000000}.get(detail, 250000)


def _finish_result(out, result, t0, work):
    result["totalSeconds"] = round(time.time() - t0, 1)
    result["files"] = [{"name": n, "bytes": os.path.getsize(os.path.join(out, n))} for n in sorted(os.listdir(out))
                       if os.path.isfile(os.path.join(out, n)) and n != "result.json"]
    with open(os.path.join(out, "result.json"), "w") as f:
        json.dump(result, f, indent=1, sort_keys=True)
    if os.environ.get("CLOUD_KEEP_WORK") != "1":
        shutil.rmtree(work, ignore_errors=True)
    return result


def _fail(result, log, st, e):
    if isinstance(e, PipelineError):
        log("FAILED: %s\n%s" % (e.message, e.technical))
        result.update(errorMessage=e.message, errorTechnical=e.technical)
        st.done(False, e.message)
    else:
        import traceback
        tb = traceback.format_exc()
        log("FAILED (internal): %s" % tb)
        result.update(errorMessage="The cloud build hit an internal error.", errorTechnical=tb[-2000:])
        st.done(False, "internal error")


def build_openmvs(src, out, detail="phone", texture="8k", max_polys=None, obj=False, status_file=None, title=None,
                  stages=None, max_side=None, echo=True, tris_override=None, texture_px_override=None):
    """Default cloud build (CPU): SfM -> OpenMVS mesh -> crop -> two-band photo bake -> LiDAR scale -> exports."""
    import numpy as np
    from . import colmap_io, export, lidar_scale, openmvs_mesh
    t0 = time.time()
    _reset_out(out)
    log = Log(os.path.join(out, "recon-log.txt"), echo=echo)
    st = Status(status_file, t0, STAGES_OPENMVS)
    stages = stages or Stages()
    work = os.path.join(out, "..", "cloud-work")
    os.makedirs(work, exist_ok=True)
    tex_px = texture_px_override or (8192 if texture == "8k" else 4096)
    tris = tris_override or _tris_for(detail, max_polys)
    max_side = max_side or int(os.environ.get("CLOUD_MAX_SIDE", "2000"))
    result = {"ok": False, "detail": detail, "engine": "asbuilt-cloud", "mesher": "openmvs", "polygons": None,
              "textures": [], "files": []}
    secs = {}
    try:
        log("asbuilt-cloud build (OpenMVS, CPU) detail=%s texture=%s maxTris=%d maxSide=%d title=%s" % (
            detail, texture, tris, max_side, title))
        st.stage("extracting", 0, "Unpacking photos")
        img_src = extract_input(src, work, log)
        st.stage("preProcessing", 0, "Preparing photos")
        ts = time.time()
        images = os.path.join(work, "images")
        names, _, prepared = prepare_images(img_src, images, max_side, log)
        result["photos"] = len(names)
        secs["prepare"] = time.time() - ts
        st.stage("imageAlignment", 0, "Lining up photos")
        ts = time.time()
        undist = stages.sfm(images, work, log)
        secs["sfm"] = time.time() - ts
        summary = getattr(stages, "sfm_summary", {}) or {}
        result["sfm"] = {k: summary.get(k) for k in ("mapper", "registered", "images", "points", "meanReprojErrorPx")}
        st.stage("pointCloudGeneration", 0, "Measuring depth in every photo")
        ts = time.time()
        V, F, minfo = stages.mvs_mesh(undist, work, log, progress=lambda name, f, msg: st.stage(name, f, msg))
        secs["mesh"] = time.time() - ts
        st.stage("textureMapping", 0, "Painting the texture from your photos")
        ts = time.time()
        cams = colmap_io.load_pinhole_model(os.path.join(undist, "sparse"))
        V2, F2, UV, tex, cov = openmvs_mesh.texture_mesh(
            V, F, cams, os.path.join(undist, "images"), log, tris=tris, tex=tex_px,
            progress=lambda f: st.stage("textureMapping", f, "Painting the texture from your photos"))
        secs["texture"] = time.time() - ts
        st.stage("optimization", 0, "Sizing the model")
        ts = time.time()
        # metric scale from the LiDAR depth inside iPhone Object Capture HEICs
        try:
            sc = lidar_scale.lidar_scale(img_src, prepared, summary.get("model") or os.path.join(undist, "sparse"), log)
        except Exception as e:  # noqa: BLE001  scale is best-effort; never fail the build over it
            log("lidar scale failed: %r" % (e,))
            sc = {"ok": False, "reason": "error: %r" % (e,)}
        xyz, _, _, _ = colmap_io.read_points3d_bin(os.path.join(undist, "sparse", "points3D.bin"))
        Rw, origin, finfo = output_frame(cams, xyz, V2)
        cam_dist = float(np.median([np.linalg.norm(c.center - origin) for c in cams]))
        if sc.get("ok"):
            s, scale_source = sc["metersPerUnit"], "lidar"
            log("scale: LiDAR %.5f m per SfM unit (%s, MAD %.1f%%, %d samples in %d photos)" % (
                s, sc["reading"], 100 * sc["mad"], sc["samples"], sc["images"]))
        else:
            # No metric data: size it as if the photos were taken ~1 m away, so AR shows a plausible object.
            s, scale_source = 1.0 / max(cam_dist, 1e-9), "none"
            log("scale: none (%s); assuming the photos were taken about 1 m away" % sc.get("reason"))
        Vout = (V2 - origin) @ Rw.T * s
        ext = Vout.max(0) - Vout.min(0)
        log("frame: Y-up from %s, origin on the %s %s; size %.3f x %.3f x %.3f m (scale %s)" % (
            finfo["upFrom"], finfo["originFrom"], finfo.get("groundTiltDeg", ""), ext[0], ext[1], ext[2], scale_source))
        st.stage("optimization", 0.3, "Packing the model")
        export.write_usdz(os.path.join(out, "model.usdz"), Vout, F2, UV, tex, os.path.join(work, "usd"),
                          title=title or "AsBuilt scan")
        passed, msgs = export.check_usdz(os.path.join(out, "model.usdz"))
        result["usdcheckerPassed"] = passed
        result["usdcheckerOutput"] = "\n".join(str(x) for x in msgs)[:4000]
        log("usd validators: %s %s" % ("PASSED" if passed else "FAILED", msgs[:5]))
        export.write_obj(os.path.join(out, "obj"), Vout, F2, UV, tex)
        if obj:
            export.zip_dir(os.path.join(out, "obj"), os.path.join(out, "model-obj.zip"))
        try:
            c0 = max(cams, key=lambda c: float(np.linalg.norm(c.center - origin)))  # widest view of the object
            thumb = colmap_io.Camera(c0.name, c0.R @ Rw.T, s * (c0.t + c0.R @ origin), c0.fx, c0.fy, c0.cx, c0.cy,
                                     c0.width, c0.height)
            export.thumbnail(os.path.join(out, "thumbnail.png"), Vout, F2, UV, tex, thumb)
        except Exception as e:  # thumbnails are cosmetic
            log("thumbnail failed: %r" % e)
        secs["export"] = time.time() - ts
        result.update(ok=True, polygons=int(len(F2)),
                      textures=[{"name": "diffuse", "width": tex_px, "height": tex_px,
                                 "bytes": os.path.getsize(os.path.join(out, "obj", "model_diffuse.jpg"))}],
                      metersPerUnit=1.0, scaleSource=scale_source,
                      scale={k: sc.get(k) for k in ("ok", "metersPerUnit", "mad", "samples", "images", "reading",
                                                    "photosWithDepth", "reason") if k in sc},
                      dimensionsMeters=[round(float(x), 4) for x in ext], textureCoverage=round(float(cov), 4),
                      openmvs=minfo, frame=finfo)
        st.done(True, "Model ready")
    except Exception as e:  # noqa: BLE001  never die without a result.json
        _fail(result, log, st, e)
    result["stageSeconds"] = {k: round(v, 1) for k, v in secs.items()}
    if result.get("ok"):
        log("stage seconds: %s, total %.1fs" % (result["stageSeconds"], time.time() - t0))
    return _finish_result(out, result, t0, work)


def build_splat(src, out, detail="phone", texture="8k", max_polys=None, obj=False, status_file=None, title=None,
                stages=None, max_side=None, steps=None, echo=True, tris_override=None, texture_px_override=None):
    """Optional GPU path: SfM -> gsplat 3DGS -> splat->mesh (TSDF) -> bake. Ships splat.ply too."""
    t0 = time.time()
    _reset_out(out)
    log = Log(os.path.join(out, "recon-log.txt"), echo=echo)
    st = Status(status_file, t0)
    stages = stages or Stages()
    work = os.path.join(out, "..", "cloud-work")
    os.makedirs(work, exist_ok=True)
    tex_px = texture_px_override or (8192 if texture == "8k" else 4096)
    tris = tris_override or _tris_for(detail, max_polys)
    max_side = max_side or int(os.environ.get("CLOUD_MAX_SIDE", "3000"))
    steps = steps or int(os.environ.get("SPLAT_STEPS", "30000"))
    result = {"ok": False, "detail": detail, "engine": "asbuilt-cloud", "mesher": "splat", "polygons": None,
              "textures": [], "files": []}
    try:
        log("asbuilt-cloud build (splat, GPU) detail=%s texture=%s maxTris=%d title=%s" % (detail, texture, tris, title))
        st.stage("extracting", 0, "Unpacking photos")
        img_src = extract_input(src, work, log)
        st.stage("preProcessing", 0, "Preparing photos")
        images = os.path.join(work, "images")
        names, _, _ = prepare_images(img_src, images, max_side, log)
        result["photos"] = len(names)
        st.stage("imageAlignment", 0, "Lining up photos")
        undist = stages.sfm(images, work, log)
        st.stage("pointCloudGeneration", 0, "Training the photoreal splat")
        ply = stages.train_splat(undist, work, log, steps=steps,
                                 progress=lambda f: st.stage("pointCloudGeneration", f, "Training the photoreal splat"))
        shutil.copy2(ply, os.path.join(out, "splat.ply"))
        st.stage("meshGeneration", 0, "Building mesh")
        m = stages.splat_to_mesh(ply, undist, work, log, tris, tex_px,
                                 progress=lambda name, f, msg: st.stage(name, f, msg))
        st.stage("optimization", 0, "Packing the model")
        from . import export
        export.write_usdz(os.path.join(out, "model.usdz"), m["V"], m["F"], m["UV"], m["texture"], os.path.join(work, "usd"),
                          title=title or "AsBuilt scan")
        passed, msgs = export.check_usdz(os.path.join(out, "model.usdz"))
        result["usdcheckerPassed"] = passed
        result["usdcheckerOutput"] = "\n".join(str(x) for x in msgs)[:4000]
        log("usd ComplianceChecker(arkit): %s %s" % ("PASSED" if passed else "FAILED", msgs[:5]))
        export.write_obj(os.path.join(out, "obj"), m["V"], m["F"], m["UV"], m["texture"])
        if obj:
            export.zip_dir(os.path.join(out, "obj"), os.path.join(out, "model-obj.zip"))
        try:
            export.thumbnail(os.path.join(out, "thumbnail.png"), m["V"], m["F"], m["UV"], m["texture"], m["thumbCam"])
        except Exception as e:  # thumbnails are cosmetic
            log("thumbnail failed: %r" % e)
        result.update(ok=True, polygons=int(len(m["F"])),
                      textures=[{"name": "diffuse", "width": tex_px, "height": tex_px,
                                 "bytes": os.path.getsize(os.path.join(out, "obj", "model_diffuse.jpg"))}],
                      splat={"file": "splat.ply", "gaussians": m.get("gaussians"), "bytes": os.path.getsize(os.path.join(out, "splat.ply"))},
                      metersPerUnit=m.get("metersPerUnit"), scaleSource="none")
        st.done(True, "Model ready")
    except Exception as e:  # noqa: BLE001  never die without a result.json
        _fail(result, log, st, e)
    return _finish_result(out, result, t0, work)
