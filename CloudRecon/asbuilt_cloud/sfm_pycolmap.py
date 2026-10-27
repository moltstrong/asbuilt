"""SfM with pycolmap (COLMAP 4.2.1 python bindings), tuned for hard object captures (few photos, plain, shiny or
dark objects): SIFT on separate high-resolution, contrast-normalized copies of the photos -> exhaustive guided
matching -> global mapper (GLOMAP, merged into COLMAP 4.x), plus the incremental mapper with relaxed thresholds
whenever the global model is weak -> the model with the most registered photos / points, rescaled to the MVS photo
size -> undistort to PINHOLE.

Why: the real iPhone scan "Object 1" (23 photos, plain object) registered 13/23 photos with 54 points at 2000 px
and default SIFT, so OpenMVS fused nothing. Finer features (3200 px, 16k, affine shape + domain-size pooling),
contrast normalization (CLAHE on the SfM copies only) and a second mapper fix most such sets; see
tests/test_cloudrecon.py and the README's hard-set numbers.

    /opt/sfm/bin/python -m asbuilt_cloud.sfm_pycolmap <images> <work> [--mvs-images DIR] [--gpu]
Prints one JSON line with the summary at the end (`registered`, `images`, `points`, `mapper`, `tried`).
"""
import argparse
import json
import os
import shutil
import sys
import time

# A global model is "weak" (so the incremental mapper runs too) below these.
MIN_REGISTERED_FRACTION = 0.85
MIN_POINTS_PER_IMAGE = 100


def group_by_size(images, work, name="images_by_size"):
    """One shared camera per image size. Upright (EXIF-rotated) photos of one phone come in two sizes when some
    were taken in portrait and some in landscape; a single shared camera would leave one group unregistered
    (5 of 41 on the stump dataset). One size -> SINGLE camera on the flat folder (names unchanged); several ->
    PER_FOLDER on <W>x<H>/ symlink folders (image names then carry that prefix)."""
    import pycolmap
    from PIL import Image
    names = sorted(n for n in os.listdir(images) if not n.startswith("."))
    by_size = {}
    for n in names:
        with Image.open(os.path.join(images, n)) as im:
            by_size.setdefault("%dx%d" % im.size, []).append(n)
    if len(by_size) <= 1:
        return images, pycolmap.CameraMode.SINGLE
    grouped = os.path.join(work, name)
    shutil.rmtree(grouped, ignore_errors=True)
    for size, group in by_size.items():
        os.makedirs(os.path.join(grouped, size))
        for n in group:
            os.symlink(os.path.realpath(os.path.join(images, n)), os.path.join(grouped, size, n))
    return grouped, pycolmap.CameraMode.PER_FOLDER


def mirror_layout(sfm_images, mvs_images, work):
    """MVS image folder with exactly the SfM folder's relative names (flat, or <W>x<H>/ of the SfM size)."""
    if os.path.realpath(sfm_images) == os.path.realpath(mvs_images):
        return mvs_images
    subdirs = [d for d in os.listdir(sfm_images) if os.path.isdir(os.path.join(sfm_images, d))]
    if not subdirs:
        return mvs_images
    out = os.path.join(work, "mvs_by_size")
    shutil.rmtree(out, ignore_errors=True)
    for d in subdirs:
        os.makedirs(os.path.join(out, d))
        for n in os.listdir(os.path.join(sfm_images, d)):
            os.symlink(os.path.realpath(os.path.join(mvs_images, n)), os.path.join(out, d, n))
    return out


def rescale_to(rec, mvs_root, log=print):
    """Rescale cameras + 2D observations of a model made on the SfM copies to the MVS photos' pixel size."""
    from PIL import Image
    done = {}
    for iid in rec.reg_image_ids():
        im = rec.images[iid]
        cid = im.camera_id
        if cid not in done:
            cam = rec.cameras[cid]
            with Image.open(os.path.join(mvs_root, im.name)) as m:
                w, h = m.size
            done[cid] = (w / cam.width, h / cam.height, cam.width, cam.height)
            if (w, h) != (cam.width, cam.height):
                cam.rescale(w, h)
        sx, sy, _, _ = done[cid]
        if sx == 1 and sy == 1:
            continue
        for p in im.points2D:
            x, y = p.xy
            p.xy = (x * sx, y * sy)
    if any(v[0] != 1 for v in done.values()):
        log("sfm: rescaled %d camera(s) from %s to the MVS photo size" % (
            len(done), ", ".join("%dx%d x%.3f" % (v[2], v[3], v[0]) for v in done.values())))


def _mapper_options(pycolmap, relaxed):
    o = pycolmap.IncrementalPipelineOptions()
    o.multiple_models = True
    o.min_model_size = 3
    if relaxed:
        # few photos / weak texture: accept smaller initial pairs and thinner registrations
        o.min_num_matches = 10
        o.mapper.init_min_num_inliers = 50
        o.mapper.abs_pose_min_num_inliers = 15
        o.mapper.abs_pose_min_inlier_ratio = 0.15
        o.mapper.init_min_tri_angle = 8.0
    return o


def _score(rec):
    return (rec.num_reg_images(), rec.num_points3D())


def _extract_match(pycolmap, db, images, mode, reader, device, cfg, max_image_size, gpu):
    if os.path.exists(db):
        os.remove(db)
    ext = pycolmap.FeatureExtractionOptions()
    ext.sift.max_num_features = cfg["features"]
    ext.max_image_size = max_image_size
    if max_image_size > 2400:
        # no 2x upsampling of big photos: at first_octave -1 a 3200 px photo's scale space is 6400 px, ~1.3 GB per
        # extraction thread (swapped a 16 GB Mac to a crawl); octave 0 of 3200 px already beats -1 of 2000 px
        ext.sift.first_octave = 0
    if cfg.get("affine") and not gpu:
        # viewpoint-robust descriptors (CPU SIFT only): more and better matches on curved / glossy objects
        ext.sift.estimate_affine_shape = True
        ext.sift.domain_size_pooling = True
    t0 = time.time()
    pycolmap.extract_features(db, images, camera_mode=mode, reader_options=reader, extraction_options=ext, device=device)
    t_ext = time.time() - t0
    mopt = pycolmap.FeatureMatchingOptions()
    if cfg.get("guided"):
        mopt.guided_matching = True
    mopt.max_num_matches = max(32768, 2 * cfg["features"])
    pycolmap.match_exhaustive(db, matching_options=mopt, device=device)
    return t_ext, time.time() - t0 - t_ext


def _map(pycolmap, db, images, out, n_imgs, robust, log, label):
    """Global mapper; when its model is weak also the incremental one (plain, then relaxed). -> [(name, rec)], tried."""
    candidates, tried = [], []
    try:
        os.makedirs(os.path.join(out, "global"), exist_ok=True)
        recs = pycolmap.global_mapping(db, images, os.path.join(out, "global"))
        candidates += [(label + "global", r) for r in recs.values()]
        sc = max((_score(r) for r in recs.values()), default=(0, 0))
        tried.append({"mapper": label + "global", "registered": sc[0], "points": sc[1]})
        log("sfm: %sglobal mapper %d/%d photos, %d points" % (label, sc[0], n_imgs, sc[1]))
    except Exception as e:  # noqa: BLE001
        log("%sglobal mapper failed (%r)" % (label, e))
        tried.append({"mapper": label + "global", "error": repr(e)[:200]})
    if not _weak(candidates, n_imgs):
        return candidates, tried
    for relaxed in ((False, True) if robust else (False,)):
        name = label + ("incremental-relaxed" if relaxed else "incremental")
        try:
            d = os.path.join(out, name)
            os.makedirs(d, exist_ok=True)
            recs = pycolmap.incremental_mapping(db, images, d, options=_mapper_options(pycolmap, relaxed))
        except Exception as e:  # noqa: BLE001
            log("%s mapper failed (%r)" % (name, e))
            tried.append({"mapper": name, "error": repr(e)[:200]})
            continue
        candidates += [(name, r) for r in recs.values()]
        sc = max((_score(r) for r in recs.values()), default=(0, 0))
        tried.append({"mapper": name, "registered": sc[0], "points": sc[1]})
        log("sfm: %s mapper %d/%d photos, %d points" % (name, sc[0], n_imgs, sc[1]))
        if not _weak(candidates, n_imgs):
            break
    return candidates, tried


def _weak(candidates, n_imgs):
    if not candidates:
        return True
    reg, pts = max(_score(r) for _, r in candidates)
    return reg < MIN_REGISTERED_FRACTION * n_imgs or pts < MIN_POINTS_PER_IMAGE * reg


# Feature/matching passes. "fast" runs on every scan (seconds); "robust" only when the fast pass gives a weak model
# and the set is small enough for 16k affine/DSP features with guided matching (CPU matching is ~quadratic).
PASSES = [
    {"name": "fast", "features": 8192, "affine": False, "guided": False},
    {"name": "robust", "features": 16384, "affine": True, "guided": False},
]
ROBUST_MAX_PHOTOS = int(os.environ.get("SFM_ROBUST_MAX_PHOTOS", "80"))


def run_sfm(images, work, gpu=False, single_camera=True, max_features=None, log=print, mvs_images=None,
            max_image_size=3200, robust=True, passes=None):
    """images: the photos for feature extraction (may be larger than / contrast-normalized vs mvs_images);
    mvs_images: the photos OpenMVS and the bake use (same file names). The output model is in mvs_images pixels.
    robust=False: one plain pass (global mapper, incremental only if it fails) - the pre-2026-10-27 behaviour."""
    import pycolmap
    t0 = time.time()
    os.makedirs(work, exist_ok=True)
    device = pycolmap.Device.cuda if gpu else pycolmap.Device.cpu
    reader = pycolmap.ImageReaderOptions()
    reader.camera_model = "OPENCV"
    images, mode = group_by_size(images, work) if single_camera else (images, pycolmap.CameraMode.AUTO)
    n_imgs = sum(1 for _, _, fs in os.walk(images) for n in fs if not n.startswith("."))
    sparse = os.path.join(work, "sparse")
    shutil.rmtree(sparse, ignore_errors=True)
    os.makedirs(sparse)
    passes = passes or (PASSES if robust else [dict(PASSES[0], name="plain")])
    if max_features:
        passes = [dict(p, features=max_features) for p in passes]
    candidates, tried, secs, feats = [], [], {}, {}
    for i, cfg in enumerate(passes):
        if i > 0 and not _weak(candidates, n_imgs):
            break
        if i > 0 and n_imgs > ROBUST_MAX_PHOTOS:
            log("sfm: weak model but %d photos is too many for the %s pass" % (n_imgs, cfg["name"]))
            break
        db = os.path.join(work, "db-%s.db" % cfg["name"])
        t_ext, t_match = _extract_match(pycolmap, db, images, mode, reader, device, cfg, max_image_size, gpu)
        feats[cfg["name"]] = _feature_stats(db)
        log("sfm: %s pass: features per photo median %d (min %d), verified pairs %d of %d (%.0fs + %.0fs)" % (
            cfg["name"], feats[cfg["name"]]["medianFeatures"], feats[cfg["name"]]["minFeatures"],
            feats[cfg["name"]]["verifiedPairs"], feats[cfg["name"]]["pairs"], t_ext, t_match))
        tm = time.time()
        c, t = _map(pycolmap, db, images, os.path.join(sparse, cfg["name"]), n_imgs, robust,
                    log, "" if i == 0 else cfg["name"] + "-")
        candidates += c
        tried += t
        secs[cfg["name"]] = {"extract": round(t_ext, 1), "match": round(t_match, 1), "map": round(time.time() - tm, 1)}
    if not candidates:
        raise RuntimeError("no reconstruction: the photos could not be aligned")
    mapper, rec = max(candidates, key=lambda c: _score(c[1]))
    log("sfm: kept the %s model: %d/%d photos, %d points, %.2f px" % (
        mapper, rec.num_reg_images(), n_imgs, rec.num_points3D(), rec.compute_mean_reprojection_error()))
    mvs_root = mirror_layout(images, mvs_images or images, work)
    rescale_to(rec, mvs_root, log)
    model_dir = os.path.join(sparse, "best")
    os.makedirs(model_dir, exist_ok=True)
    rec.write(model_dir)
    undist = os.path.join(work, "undist")
    shutil.rmtree(undist, ignore_errors=True)
    pycolmap.undistort_images(undist, model_dir, mvs_root, output_type="COLMAP")
    # gsplat's COLMAP parser reads <data>/sparse/0; Brush and our reader take either layout.
    s0 = os.path.join(undist, "sparse", "0")
    os.makedirs(s0, exist_ok=True)
    for f in os.listdir(os.path.join(undist, "sparse")):
        p = os.path.join(undist, "sparse", f)
        if os.path.isfile(p):
            shutil.copy2(p, os.path.join(s0, f))
    reg_names = sorted(os.path.basename(rec.images[i].name) for i in rec.reg_image_ids())
    total = {k: round(sum(s[k] for s in secs.values()), 1) for k in ("extract", "match", "map")}
    total["total"] = round(time.time() - t0, 1)
    summary = {"mapper": mapper, "registered": rec.num_reg_images(), "images": n_imgs,
               "points": rec.num_points3D(), "meanReprojErrorPx": round(float(rec.compute_mean_reprojection_error()), 3),
               "seconds": total, "passSeconds": secs, "passes": list(secs),
               "gpu": bool(gpu), "undist": undist, "model": model_dir, "tried": tried, "features": feats,
               "registeredNames": reg_names, "maxImageSize": max_image_size, "robust": bool(robust)}
    return summary


def _feature_stats(db):
    """Keypoints per photo and verified pairs straight from the COLMAP database (for the build log)."""
    import sqlite3
    try:
        con = sqlite3.connect(db)
        rows = [r[0] for r in con.execute("SELECT rows FROM keypoints")]
        pairs = con.execute("SELECT COUNT(*) FROM two_view_geometries").fetchone()[0]
        verified = con.execute("SELECT COUNT(*) FROM two_view_geometries WHERE rows >= 15").fetchone()[0]
        con.close()
    except Exception:  # noqa: BLE001  stats are cosmetic
        return {"medianFeatures": 0, "minFeatures": 0, "pairs": 0, "verifiedPairs": 0}
    rows = sorted(rows) or [0]
    return {"medianFeatures": int(rows[len(rows) // 2]), "minFeatures": int(rows[0]), "pairs": int(pairs),
            "verifiedPairs": int(verified)}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("images")
    ap.add_argument("work")
    ap.add_argument("--mvs-images", default=None)
    ap.add_argument("--gpu", action="store_true")
    ap.add_argument("--max-features", type=int, default=None, help="override every pass's feature count")
    ap.add_argument("--max-image-size", type=int, default=3200)
    ap.add_argument("--plain", action="store_true", help="one 8k pass, global mapper (incremental only on failure)")
    a = ap.parse_args(argv)
    s = run_sfm(a.images, a.work, gpu=a.gpu, max_features=a.max_features, log=lambda m: print(m, file=sys.stderr),
                mvs_images=a.mvs_images, max_image_size=a.max_image_size, robust=not a.plain)
    print(json.dumps(s))


if __name__ == "__main__":
    main()
