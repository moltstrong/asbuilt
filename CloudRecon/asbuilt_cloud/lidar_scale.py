"""Metric scale from the LiDAR depth that iPhone Object Capture embeds in its HEIC photos.

An ObjectCaptureSession HEIC (LiDAR iPhone) carries a small depth image next to the photo, e.g.

    image: 3024x4032 primary, transformations: angle (ccw) 270
    depth channel: 192x256, 8 bits, z-near 1.17, z-far 2.55, representation "uniform Z"

(libheif `heif-info` on a real capture). libheif applies the same rotation to both, so the decoded depth grid lines
up with the decoded photo. SfM is scale-free; its feature tracks give, per photo, pixels with a known SfM camera
depth z_sfm. Sampling the LiDAR depth at those pixels gives d_lidar, and

    meters per SfM unit = median(d_lidar / z_sfm)

The decoding is not guessed blindly: every plausible reading (value -> depth direction, uniform Z vs inverse Z,
grid orientation) is scored by how constant the ratio is over thousands of points, and a scale is only reported
when the best reading is tight (MAD of log-ratio < 6 %) and physically plausible. Otherwise scaleSource = "none".
"""
import os

import numpy as np

from . import colmap_io

MAX_MAD = 0.06          # robust spread of log(d_lidar / z_sfm) for an accepted scale
MIN_SAMPLES = 200
MIN_IMAGES = 3


def read_heic_depth(path):
    """-> dict(values float32 HxW (raw sample values), max, meta, mode, primary_size (w,h)) or None."""
    try:
        import pillow_heif
    except ImportError:
        return None
    if not path.lower().endswith((".heic", ".heif")):
        return None
    try:
        hf = pillow_heif.open_heif(path, convert_hdr_to_8bit=False)
        im = hf[getattr(hf, "primary_index", 0)]
        depths = [d for d in (im.info.get("depth_images") or []) if d is not None]
        if not depths:
            return None
        d = depths[0]
        pil = d.to_pillow()
        arr = np.asarray(pil)
        if arr.ndim == 3:
            arr = arr[..., 0]
        if arr.dtype.kind == "f":
            vmax = None
        elif arr.dtype == np.uint8:
            vmax = 255.0
        else:
            vmax = float(2 ** 16 - 1)
        meta = dict(d.info.get("metadata") or {})
        return {"values": arr.astype(np.float32), "max": vmax, "meta": meta, "mode": pil.mode,
                "primary_size": tuple(im.size)}
    except Exception:  # noqa: BLE001  corrupt/unsupported depth: no scale from this photo
        return None


def _meta(meta, *names):
    for n in names:
        v = meta.get(n)
        if v is not None:
            try:
                return float(v)
            except (TypeError, ValueError):
                pass
    return None


def depth_readings(dep):
    """Candidate decodings of one depth image: list of (name, depth-in-meters array, valid mask)."""
    v = dep["values"]
    meta = dep["meta"]
    out = []
    if dep["max"] is None:  # float samples: meters, or 1/meters (disparity)
        valid = np.isfinite(v) & (v > 0)
        out.append(("float-depth", v, valid))
        with np.errstate(divide="ignore"):
            out.append(("float-inverse", np.where(valid, 1.0 / np.maximum(v, 1e-12), 0), valid))
        return out
    zn, zf = _meta(meta, "z_near", "zNear", "z-near"), _meta(meta, "z_far", "zFar", "z-far")
    if zn is None or zf is None or not (0 < zn < zf < 1000):
        return out  # integer samples without a depth range: relative only, no metric scale
    n = v / dep["max"]
    valid = (v > 0) & (v < dep["max"])  # end codes are often "no data"
    rep = meta.get("representation_type")
    rep = int(rep) if isinstance(rep, (int, float)) or (isinstance(rep, str) and rep.isdigit()) else None
    if rep in (None, 2):  # uniform Z (what Object Capture writes)
        out.append(("uniformZ", zn + n * (zf - zn), valid))
        out.append(("uniformZ-flipped", zf - n * (zf - zn), valid))
    if rep in (None, 0):  # uniform inverse Z
        out.append(("inverseZ", 1.0 / (1.0 / zf + n * (1.0 / zn - 1.0 / zf)), valid))
        out.append(("inverseZ-flipped", 1.0 / (1.0 / zn - n * (1.0 / zn - 1.0 / zf)), valid))
    return out


def _orient(a, k, flip):
    a = np.rot90(a, k)
    return a[:, ::-1] if flip else a


def _grid_variants(shape_hw, img_wh):
    """(k, flip) grid transforms whose aspect matches the photo (identity first: libheif already aligns them)."""
    h, w = shape_hw
    W, H = img_wh
    same = abs(w / h - W / H) < 0.05
    swapped = abs(h / w - W / H) < 0.05
    ks = ([0, 2] if same else []) + ([1, 3] if swapped else [])
    return [(k, f) for k in ks for f in (False, True)]


def sample_ratios(depth_m, valid, xy, z_sfm, img_wh, edge_rel=0.08):
    """log(d_lidar / z_sfm) at the observation pixels (nearest depth sample, depth edges rejected)."""
    H, W = depth_m.shape
    Wi, Hi = img_wh
    u = np.floor(xy[:, 0] * W / Wi).astype(int)
    v = np.floor(xy[:, 1] * H / Hi).astype(int)
    ok = (u >= 1) & (v >= 1) & (u < W - 1) & (v < H - 1) & (z_sfm > 0)
    u, v, z = u[ok], v[ok], z_sfm[ok]
    d = depth_m[v, u]
    good = valid[v, u] & (d > 0)
    # reject depth discontinuities (mixed foreground/background samples)
    nb = np.stack([depth_m[v + dv, u + du] for dv in (-1, 0, 1) for du in (-1, 0, 1)], 1)
    nbv = np.stack([valid[v + dv, u + du] for dv in (-1, 0, 1) for du in (-1, 0, 1)], 1)
    good &= nbv.all(1) & ((nb.max(1) - nb.min(1)) <= edge_rel * np.maximum(d, 1e-9))
    return np.log(d[good] / z[good])


def robust(lr):
    if len(lr) == 0:
        return None, None
    m = float(np.median(lr))
    return m, float(np.median(np.abs(lr - m)))


def estimate_scale(per_image, log=None, max_samples_per_image=4000):
    """per_image: list of dict(depth=read_heic_depth(...), xy, z, img_wh). Picks the decoding + grid orientation
    with the most constant ratio. Returns dict(ok, metersPerUnit, mad, samples, images, reading, reason)."""
    usable = [p for p in per_image if p.get("depth") is not None and len(p["z"])]
    res = {"ok": False, "images": len(usable), "photosWithDepth": len(usable), "photos": len(per_image)}
    if len(usable) < MIN_IMAGES:
        res["reason"] = "%d of %d photos carry LiDAR depth" % (len(usable), len(per_image))
        return res
    scores = {}
    for p in usable:
        dep = p["depth"]
        readings = depth_readings(dep)
        if not readings:
            continue
        for k, flip in _grid_variants(dep["values"].shape, p["img_wh"]):
            for name, dm, valid in readings:
                lr = sample_ratios(_orient(dm, k, flip), _orient(valid, k, flip), p["xy"], p["z"], p["img_wh"])
                if len(lr) > max_samples_per_image:
                    lr = lr[np.linspace(0, len(lr) - 1, max_samples_per_image).astype(int)]
                key = (name, k, flip)
                s = scores.setdefault(key, {"lr": [], "images": 0})
                if len(lr):
                    s["lr"].append(lr)
                    s["images"] += 1
    best = None
    for key, s in scores.items():
        lr = np.concatenate(s["lr"]) if s["lr"] else np.zeros(0)
        m, mad = robust(lr)
        if m is None:
            continue
        cand = {"reading": key[0], "rot90": key[1], "flip": key[2], "metersPerUnit": float(np.exp(m)), "mad": mad,
                "samples": int(len(lr)), "images": s["images"],
                "within10pct": float(np.mean(np.abs(lr - m) < np.log(1.1)))}
        if log:
            log("lidar scale candidate %s: %.5f m/unit, MAD %.3f, %d samples in %d photos" % (
                key, cand["metersPerUnit"], mad, cand["samples"], cand["images"]))
        if cand["samples"] >= MIN_SAMPLES and cand["images"] >= MIN_IMAGES and (best is None or mad < best["mad"]):
            best = cand
    if best is None:
        res["reason"] = "too few LiDAR samples at matched points"
        return res
    res.update(best)
    if best["mad"] > MAX_MAD:
        res["reason"] = "LiDAR depth disagrees with the photo geometry (spread %.1f%%)" % (100 * best["mad"])
        return res
    res["ok"] = True
    return res


def lidar_scale(original_dir, prepared, sparse_model_dir, log):
    """original_dir: uploaded photos; prepared: {prepared jpg name -> (original name, (w, h) prepared size)};
    sparse_model_dir: COLMAP model in prepared-image pixels (the distorted SfM model)."""
    imgs = colmap_io.read_images_bin_points(os.path.join(sparse_model_dir, "images.bin"))
    ids, xyz = colmap_io.read_points3d_bin_ids(os.path.join(sparse_model_dir, "points3D.bin"))
    order = np.argsort(ids)
    ids_sorted, xyz_sorted = ids[order], xyz[order]
    per_image = []
    for name, im in imgs.items():
        key = name if name in prepared else os.path.basename(name)  # SfM may prefix "<W>x<H>/" (one camera per size)
        if key not in prepared:
            continue
        orig, wh = prepared[key]
        dep = read_heic_depth(os.path.join(original_dir, orig))
        m = im["pid"] >= 0
        pid = im["pid"][m]
        j = np.searchsorted(ids_sorted, pid)
        j = np.clip(j, 0, len(ids_sorted) - 1)
        hit = ids_sorted[j] == pid
        P = xyz_sorted[j[hit]]
        z = (P @ im["R"].T + im["t"])[:, 2]
        per_image.append({"depth": dep, "xy": im["xy"][m][hit], "z": z, "img_wh": wh, "name": name})
    with_depth = sum(1 for p in per_image if p["depth"] is not None)
    if with_depth:
        d0 = next(p["depth"] for p in per_image if p["depth"] is not None)
        log("lidar: %d/%d registered photos carry depth (%dx%d %s, meta %s)" % (
            with_depth, len(per_image), d0["values"].shape[1], d0["values"].shape[0], d0["mode"], d0["meta"]))
    else:
        log("lidar: no depth maps in the photos (not an iPhone LiDAR capture)")
    return estimate_scale(per_image, log=log if with_depth else None)
