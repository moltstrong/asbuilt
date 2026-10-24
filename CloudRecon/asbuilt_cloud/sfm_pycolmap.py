"""SfM with pycolmap (COLMAP 4.2.1 python bindings): SIFT -> exhaustive matching -> global mapper (GLOMAP,
merged into COLMAP 4.x) with incremental fallback -> undistort to PINHOLE for splat training.

In the cloud image this runs in its own venv (/opt/sfm, `pycolmap-cuda12` wheel = CUDA SIFT + matching),
separate from the torch/gsplat venv, so it never fights torch over CUDA/numpy pins:
    /opt/sfm/bin/python -m asbuilt_cloud.sfm_pycolmap <images> <work> [--gpu]
On a Mac `pip install pycolmap` (CPU) runs the very same code; that's how it was tested.
Prints one JSON line with the summary at the end.
"""
import argparse
import json
import os
import shutil
import sys
import time


def run_sfm(images, work, gpu=False, single_camera=True, max_features=16384, log=print):
    import pycolmap
    t0 = time.time()
    os.makedirs(work, exist_ok=True)
    db = os.path.join(work, "db.db")
    if os.path.exists(db):
        os.remove(db)
    device = pycolmap.Device.cuda if gpu else pycolmap.Device.cpu
    reader = pycolmap.ImageReaderOptions()
    reader.camera_model = "OPENCV"
    ext = pycolmap.FeatureExtractionOptions()
    ext.sift.max_num_features = max_features
    pycolmap.extract_features(db, images, camera_mode=pycolmap.CameraMode.SINGLE if single_camera else pycolmap.CameraMode.AUTO,
                              reader_options=reader, extraction_options=ext, device=device)
    t_ext = time.time() - t0
    pycolmap.match_exhaustive(db, device=device)
    t_match = time.time() - t0 - t_ext
    sparse = os.path.join(work, "sparse")
    shutil.rmtree(sparse, ignore_errors=True)
    os.makedirs(sparse)
    mapper = "global"
    try:
        recs = pycolmap.global_mapping(db, images, sparse)
    except Exception as e:  # noqa: BLE001
        log("global mapper failed (%r); trying incremental" % (e,))
        recs = {}
    if not recs:
        mapper = "incremental"
        shutil.rmtree(sparse, ignore_errors=True)
        os.makedirs(sparse)
        recs = pycolmap.incremental_mapping(db, images, sparse)
    if not recs:
        raise RuntimeError("no reconstruction: the photos could not be aligned")
    t_map = time.time() - t0 - t_ext - t_match
    best_id = max(recs, key=lambda k: recs[k].num_reg_images())
    rec = recs[best_id]
    model_dir = os.path.join(sparse, "best")
    os.makedirs(model_dir, exist_ok=True)
    rec.write(model_dir)
    undist = os.path.join(work, "undist")
    shutil.rmtree(undist, ignore_errors=True)
    pycolmap.undistort_images(undist, model_dir, images, output_type="COLMAP")
    # gsplat's COLMAP parser reads <data>/sparse/0; Brush and our reader take either layout.
    s0 = os.path.join(undist, "sparse", "0")
    os.makedirs(s0, exist_ok=True)
    for f in os.listdir(os.path.join(undist, "sparse")):
        p = os.path.join(undist, "sparse", f)
        if os.path.isfile(p):
            shutil.copy2(p, os.path.join(s0, f))
    n_imgs = len([n for n in os.listdir(images) if not n.startswith(".")])
    summary = {"mapper": mapper, "registered": rec.num_reg_images(), "images": n_imgs,
               "points": rec.num_points3D(), "meanReprojErrorPx": round(float(rec.compute_mean_reprojection_error()), 3),
               "seconds": {"extract": round(t_ext, 1), "match": round(t_match, 1), "map": round(t_map, 1),
                           "total": round(time.time() - t0, 1)},
               "gpu": bool(gpu), "undist": undist}
    return summary


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("images")
    ap.add_argument("work")
    ap.add_argument("--gpu", action="store_true")
    ap.add_argument("--max-features", type=int, default=16384)
    a = ap.parse_args(argv)
    s = run_sfm(a.images, a.work, gpu=a.gpu, max_features=a.max_features, log=lambda m: print(m, file=sys.stderr))
    print(json.dumps(s))
    if s["registered"] < max(3, 0.5 * s["images"]):
        sys.exit(3)


if __name__ == "__main__":
    main()
