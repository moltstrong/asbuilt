"""The GPU pipeline: images -> COLMAP SfM -> undistort -> splat training (gsplat) -> splat->mesh -> exports.

Every stage is a function taking/returning paths so tests can swap the GPU stages for fakes
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

# Stage names reuse Apple's so both apps already have human labels for them.
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

    def __init__(self, path, t0=None):
        self.path, self.t0 = path, t0 or time.time()
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
        lo, hi = next((a, b) for n, a, b in STAGES if n == name)
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
    EXIF orientation is applied, so COLMAP sees upright pixels with no orientation tag."""
    from PIL import Image, ImageOps
    try:
        import pillow_heif  # noqa: F401
        pillow_heif.register_heif_opener()
    except Exception:
        pass
    os.makedirs(dst_dir, exist_ok=True)
    names = sorted(n for n in os.listdir(src_dir) if n.lower().endswith(IMAGE_EXTS) and not n.startswith("._"))
    sizes = set()
    for n in names:
        im = ImageOps.exif_transpose(Image.open(os.path.join(src_dir, n))).convert("RGB")
        s = max_side / max(im.size)
        if s < 1:
            im = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
        out = os.path.splitext(n)[0] + ".jpg"
        im.save(os.path.join(dst_dir, out), quality=95)
        sizes.add(im.size)
    log("prepared %d images, sizes %s" % (len(names), sorted(sizes)[:4]))
    return names, sizes


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


# ---------------------------------------------------------------------------------------------


def build(src, out, detail="phone", texture="8k", max_polys=None, obj=False, status_file=None, title=None,
          stages=None, max_side=None, steps=None, echo=True, tris_override=None, texture_px_override=None):
    t0 = time.time()
    os.makedirs(out, exist_ok=True)
    for stale in ("model.usdz", "model-obj.zip", "obj", "thumbnail.png", "result.json", "splat.ply", "recon-log.txt"):
        p = os.path.join(out, stale)
        shutil.rmtree(p, ignore_errors=True) if os.path.isdir(p) else (os.path.exists(p) and os.remove(p))
    log = Log(os.path.join(out, "recon-log.txt"), echo=echo)
    st = Status(status_file, t0)
    stages = stages or Stages()
    work = os.path.join(out, "..", "cloud-work")
    os.makedirs(work, exist_ok=True)
    tex_px = 8192 if texture == "8k" else 4096
    # Same caps as the Mac: phone = 250k (iPhone-friendly), full ~ 250k, raw = all the detail we have.
    tris = {"phone": 250000, "full": 250000, "custom": max_polys or 1000000, "raw": 2000000}[detail]
    tris = tris_override or tris
    tex_px = texture_px_override or tex_px
    max_side = max_side or int(os.environ.get("CLOUD_MAX_SIDE", "3000"))
    steps = steps or int(os.environ.get("SPLAT_STEPS", "30000"))
    result = {"ok": False, "detail": detail, "engine": "asbuilt-cloud", "polygons": None, "textures": [], "files": []}
    try:
        log("asbuilt-cloud build detail=%s texture=%s maxTris=%d title=%s" % (detail, texture, tris, title))
        st.stage("extracting", 0, "Unpacking photos")
        img_src = extract_input(src, work, log)
        st.stage("preProcessing", 0, "Preparing photos")
        images = os.path.join(work, "images")
        names, _ = prepare_images(img_src, images, max_side, log)
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
                      metersPerUnit=m.get("metersPerUnit"), scaleSource=m.get("scaleSource"))
        st.done(True, "Model ready")
    except PipelineError as e:
        log("FAILED: %s\n%s" % (e.message, e.technical))
        result.update(errorMessage=e.message, errorTechnical=e.technical)
        st.done(False, e.message)
    except Exception as e:  # never die without a result.json
        import traceback
        tb = traceback.format_exc()
        log("FAILED (internal): %s" % tb)
        result.update(errorMessage="The cloud build hit an internal error.", errorTechnical=tb[-2000:])
        st.done(False, "internal error")
    result["totalSeconds"] = round(time.time() - t0, 1)
    result["files"] = [{"name": n, "bytes": os.path.getsize(os.path.join(out, n))} for n in sorted(os.listdir(out))
                       if os.path.isfile(os.path.join(out, n)) and n != "result.json"]
    with open(os.path.join(out, "result.json"), "w") as f:
        json.dump(result, f, indent=1, sort_keys=True)
    if os.environ.get("CLOUD_KEEP_WORK") != "1":
        shutil.rmtree(work, ignore_errors=True)
    return result
