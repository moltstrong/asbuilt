"""LiDAR fallback dense stage + phone poses, for scans whose photos alone don't give OpenMVS enough to work with.

iPhone Object Capture HEICs carry a 256x192 LiDAR depth map, intrinsics and the ARKit camera pose of every shot
(objectcapture.py). Two uses here:

  align_phone_poses()  similarity (scale, rotation, translation) from the ARKit world into the SfM frame, fitted on
                       the photos SfM registered and checked against them (camera centers AND rotations; both axis
                       conventions Apple used are tried). It gives SfM-frame cameras for photos SfM could NOT
                       register, and an independent meters-per-unit.
  lidar_mesh()         back-project every usable depth map with its camera (SfM poses, plus the aligned phone poses)
                       and fuse them in the numba TSDF of meshing.py -> marching cubes -> the usual crop.
  phone_cameras()      SfM-free cameras straight from the ARKit poses (meters), for scans SfM can't align at all.

The pipeline uses lidar_mesh only when OpenMVS's dense cloud is empty or very sparse, and records which path ran
(result.json "densePath", recon-log "dense: ...").
"""
import os

import numpy as np

from . import colmap_io, meshing

MIN_CONFIDENCE = 1          # ARKit depth confidence: 0 low, 1 medium, 2 high
MAX_ALIGN_ROT_DEG = 5.0     # phone vs SfM camera rotations after alignment (median)
MAX_ALIGN_POS_REL = 0.05    # phone vs SfM camera centers after alignment, relative to the camera distance (median)


def cams_by_basename(cams):
    return {os.path.splitext(os.path.basename(c.name))[0]: c for c in cams}


def _rot_angle_deg(R):
    return float(np.degrees(np.arccos(np.clip((np.trace(R) - 1) / 2, -1, 1))))


def align_phone_poses(sfm_cams, phone, log=None):
    """sfm_cams: registered colmap_io.Camera list (SfM frame, world->camera R,t). phone: {stem: {"R": c2w 3x3,
    "position": (3,)}} ARKit poses. -> dict(s, R, t, convention, rotDeg, posRel, n) mapping ARKit world points
    X_sfm = s R X_ark + t, or None when there are too few pairs or they disagree."""
    by = cams_by_basename(sfm_cams)
    common = [k for k in sorted(by) if k in phone and phone[k].get("position") is not None]
    if len(common) < 3:
        return None
    C_s = np.array([by[k].center for k in common])
    C_a = np.array([phone[k]["position"] for k in common])
    if np.linalg.norm(C_a - C_a.mean(0), axis=1).max() < 1e-3:
        return None  # the phone didn't move: no baseline to align
    s, R, t = colmap_io.umeyama(C_a, C_s)
    best = None
    for conv, flip in (("opencv", np.eye(3)), ("arkit", np.diag([1.0, -1.0, -1.0]))):
        errs = []
        for k in common:
            Rc2w_sfm = by[k].R.T
            Rc2w_phone = R @ phone[k]["R"] @ flip
            errs.append(_rot_angle_deg(Rc2w_sfm.T @ Rc2w_phone))
        e = float(np.median(errs))
        if best is None or e < best[1]:
            best = (conv, e, flip)
    dist = float(np.median(np.linalg.norm(C_s - C_s.mean(0), axis=1)))
    pos = np.linalg.norm((s * C_a @ R.T + t) - C_s, axis=1)
    pos_rel = float(np.median(pos)) / max(dist, 1e-12)
    info = {"s": float(s), "R": R, "t": t, "convention": best[0], "flip": best[2], "rotDeg": round(best[1], 2),
            "posRel": round(pos_rel, 4), "n": len(common), "metersPerUnit": float(1.0 / s)}
    ok = best[1] <= MAX_ALIGN_ROT_DEG and pos_rel <= MAX_ALIGN_POS_REL
    if log:
        log("phone poses vs SfM: %d photos, %s camera axes, rotation %.1f deg, position %.1f%% of the camera "
            "distance, %.4f m per SfM unit -> %s" % (len(common), best[0], best[1], 100 * pos_rel, 1.0 / s,
                                                    "used" if ok else "NOT used"))
    return info if ok else None


def phone_camera_in_sfm(align, pose, K, size, name):
    """SfM-frame pinhole camera for one photo from its ARKit pose (K = fx, fy, cx, cy at `size` = (w, h))."""
    Rc2w = align["R"] @ pose["R"] @ align["flip"]
    C = align["s"] * align["R"] @ pose["position"] + align["t"]
    R = Rc2w.T
    return colmap_io.Camera(name, R, -R @ C, K[0], K[1], K[2], K[3], size[0], size[1])


def phone_cameras(caps, prepared, flip=None):
    """ARKit-world (meters) pinhole cameras for every prepared photo with pose + intrinsics.
    caps: {original name: objectcapture.read_capture(...)}, prepared: {jpg: (original name, (w, h))}."""
    flip = np.eye(3) if flip is None else flip
    out = []
    for jpg, (orig, wh) in sorted(prepared.items()):
        c = caps.get(orig) or {}
        if not c.get("pose") or c["pose"].get("position") is None or not c.get("K") or not c.get("size"):
            continue
        sx, sy = wh[0] / c["size"][0], wh[1] / c["size"][1]
        fx, fy, cx, cy = c["K"]
        Rc2w = c["pose"]["R"] @ flip
        R = Rc2w.T
        out.append(colmap_io.Camera(jpg, R, -R @ c["pose"]["position"], fx * sx, fy * sy, cx * sx, cy * sy, wh[0], wh[1]))
    return out


def depth_in_units(cap, meters_per_unit, min_conf=MIN_CONFIDENCE):
    """LiDAR depth in SfM units; -1 = unknown (no data or low confidence: never carves free space)."""
    d = cap.get("depth")
    if d is None:
        return None
    out = np.where(d > 0, d / meters_per_unit, -1.0).astype(np.float32)
    conf = cap.get("confidence")
    if conf is not None and conf.shape == d.shape:
        out[conf < min_conf] = -1.0
    return out


def depth_cam(cam, depth):
    """The camera with intrinsics for the depth grid (pixel-edge convention, like COLMAP)."""
    h, w = depth.shape
    sx, sy = w / cam.width, h / cam.height
    return colmap_io.Camera(cam.name, cam.R, cam.t, cam.fx * sx, cam.fy * sy, cam.cx * sx, cam.cy * sy, w, h)


def backproject(cam, depth):
    """World points of a depth map (cam intrinsics are for cam.width x cam.height; depth may be any grid)."""
    h, w = depth.shape
    sx, sy = w / cam.width, h / cam.height
    vs, us = np.nonzero(depth > 0)
    z = depth[vs, us]
    x = ((us + 0.5) / sx - cam.cx) / cam.fx * z
    y = ((vs + 0.5) / sy - cam.cy) / cam.fy * z
    Xc = np.stack([x, y, z], 1)
    return (Xc - cam.t) @ cam.R  # R^T (Xc - t)


def lidar_mesh(views, log, voxel=None, max_voxels=48_000_000, units_per_meter=1.0):
    """views: list of (cam, depth in the cam's units, -1 unknown). Fuses them around the cameras' common look-at
    point (TSDF, marching cubes) and crops like the OpenMVS path. -> (V, F, info)."""
    from . import openmvs_mesh
    from .pipeline import PipelineError
    views = [(c, d) for c, d in views if d is not None and (d > 0).sum() > 100]
    if len(views) < 3:
        raise PipelineError("The mesh came out empty: fewer than 3 photos have usable LiDAR depth.")
    cams = [c for c, _ in views]
    center = openmvs_mesh.look_at_center(cams)
    dist = float(np.median([np.linalg.norm(c.center - center) for c in cams]))
    pts = np.concatenate([backproject(c, d)[::4] for c, d in views])
    near = pts[np.linalg.norm(pts - center, axis=1) <= 1.0 * dist]  # the object, not the room
    if len(near) < 500:
        raise PipelineError("The mesh came out empty: the LiDAR depth doesn't reach the object.")
    lo, hi = np.percentile(near, 1, axis=0), np.percentile(near, 99, axis=0)
    pad = 0.05 * float((hi - lo).max())
    lo, hi = lo - pad, hi + pad
    if voxel is None:
        # ~2.5 mm at object distance (one LiDAR sample), but at most ~360 voxels along the longest side
        voxel = max(0.0025 * units_per_meter, float((hi - lo).max()) / 360.0)
    trunc_vox = max(4.0, 0.012 * units_per_meter / voxel)  # LiDAR noise is ~1 cm
    grid = [(depth_cam(c, d), d, None) for c, d in views]  # the TSDF projects with the depth grid's intrinsics
    V, F, n = meshing.tsdf_mesh(cams, iter(grid), voxel, trunc_voxels=trunc_vox,
                                bounds=(lo, hi), min_weight=2.0, max_voxels=max_voxels)
    info = {"views": n, "voxel": float(voxel), "voxelMm": round(1000 * voxel / units_per_meter, 2),
            "bounds": [lo.tolist(), hi.tolist()], "rawFaces": int(len(F))}
    log("dense: LiDAR TSDF of %d depth maps, voxel %.1f mm, %d raw faces" % (n, info["voxelMm"], len(F)))
    if len(F) == 0:
        raise PipelineError("The mesh came out empty. Try more photos all around the object, with good light.")
    V, F, cinfo = openmvs_mesh.crop(V, F, cams, min_frac=0.1, radius_factor=1.6)
    info["crop"] = cinfo
    log("crop: %s" % cinfo)
    return V, F, info


def write_pinhole_model(d, cams, points=None):
    """COLMAP binary model (one PINHOLE camera per photo) for phone-pose builds, so every later stage
    (bake, frame, thumbnail) reads the same files as after SfM."""
    import struct
    from .runner import rotmat2qvec
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "cameras.bin"), "wb") as fh:
        fh.write(struct.pack("<Q", len(cams)))
        for i, c in enumerate(cams):
            fh.write(struct.pack("<iiQQ", i + 1, 1, c.width, c.height))
            fh.write(struct.pack("<4d", c.fx, c.fy, c.cx, c.cy))
    with open(os.path.join(d, "images.bin"), "wb") as fh:
        fh.write(struct.pack("<Q", len(cams)))
        for i, c in enumerate(cams):
            fh.write(struct.pack("<i4d3di", i + 1, *rotmat2qvec(c.R), *c.t, i + 1))
            fh.write(c.name.encode() + b"\0")
            fh.write(struct.pack("<Q", 0))
    P = np.zeros((0, 3)) if points is None else np.asarray(points, float)
    with open(os.path.join(d, "points3D.bin"), "wb") as fh:
        fh.write(struct.pack("<Q", len(P)))
        for i, p in enumerate(P):
            fh.write(struct.pack("<Q3d3Bd", i + 1, *p, 128, 128, 128, 1.0))
            fh.write(struct.pack("<Q", 0))
