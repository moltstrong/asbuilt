"""Splat -> textured mesh, CPU path (what the cloud worker does after training, minus the GPU):
render median depth of the trained splat from every training camera, TSDF-fuse, crop to the object,
decimate, xatlas-unwrap, bake the real photos into an 8K texture, write OBJ + USDZ (usd-core).

usage: splat2mesh.py <splat.ply> <undistorted colmap dir (images/, sparse/)> <out dir>
       [--depth-scale 0.5] [--voxel-frac 0.004] [--max-tris 250000] [--texture 8192] [--meters-per-unit X]
"""
import argparse
import json
import os
import sys
import time

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, "/Users/moltstrong/projects/asbuilt/CloudRecon")
import splatrender as sr  # noqa: E402
from asbuilt_cloud import colmap_io, export, meshing  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("ply"); ap.add_argument("data"); ap.add_argument("out")
ap.add_argument("--depth-scale", type=float, default=0.5)
ap.add_argument("--voxel-frac", type=float, default=0.002, help="TSDF voxel as fraction of the TSDF box diagonal")
ap.add_argument("--max-tris", type=int, default=250000)
ap.add_argument("--texture", type=int, default=8192)
ap.add_argument("--meters-per-unit", type=float, default=1.0)
ap.add_argument("--exclude", default="", help="comma list of image names not to use (held-out views)")
a = ap.parse_args()
os.makedirs(a.out, exist_ok=True)
T0 = time.time()
log_f = open(os.path.join(a.out, "splat2mesh.log"), "w")


def log(*m):
    s = "%7.1fs " % (time.time() - T0) + " ".join(str(x) for x in m)
    print(s, flush=True); log_f.write(s + "\n"); log_f.flush()


cams = colmap_io.load_pinhole_model(os.path.join(a.data, "sparse"))
excl = set(x.strip() for x in a.exclude.split(",") if x.strip())
cams = [c for c in cams if c.name not in excl]
xyz, _, _, _ = colmap_io.read_points3d_bin(os.path.join(a.data, "sparse", "points3D.bin"))
reg = meshing.object_region(cams, xyz)
log("cameras", len(cams), "region radius %.3f top %.3f bottom %.3f" % (reg["radius"], reg["top"], reg["bottom"]))
g = sr.load_ply(a.ply)
log("splats", len(g["xyz"]))


def depth_iter():
    for k, cam in enumerate(cams):
        c = cam.scaled(a.depth_scale)
        rgb, alpha, dmed, dexp = sr.render(g, c.R, c.t, c.fx, c.fy, c.cx, c.cy, c.width, c.height, want_depth=True)
        d = np.where(alpha > 0.5, dmed, 0).astype(np.float32)
        # drop depth outside the object region (background trees etc.) so TSDF stays small
        log("depth %d/%d %s valid %.1f%%" % (k + 1, len(cams), cam.name, 100 * (d > 0).mean()))
        yield c, d, (rgb * 255).astype(np.uint8)


cache_npz = os.path.join(a.out, "mesh_clean_cache.npz")
bounds = meshing.region_bounds(reg, xyz)
voxel = a.voxel_frac * float(np.linalg.norm(np.subtract(bounds[1], bounds[0])))
if os.path.isfile(cache_npz):
    z = np.load(cache_npz); V, F = z["V"], z["F"]
    log("loaded cleaned mesh from cache", len(V), "verts", len(F), "tris")
else:
    log("tsdf bounds", np.round(bounds[0], 3).tolist(), np.round(bounds[1], 3).tolist())
    V, F, n = meshing.tsdf_mesh(cams, depth_iter(), voxel=voxel, trunc_voxels=4.0, bounds=bounds)
    log("tsdf mesh", len(V), "verts", len(F), "tris (voxel %.4f)" % voxel)
    ground = meshing.fit_ground(V, reg["up"], reg["center"])
    log("ground plane", None if ground is None else np.round(np.r_[ground[0], ground[1]], 4).tolist())
    V, F = meshing.clean_mesh(V, F, region=reg, ground=None, target_tris=a.max_tris)
    log("clean+decimate", len(V), "verts", len(F), "tris")
    np.savez(cache_npz, V=V, F=F)
V2, F2, UV, vmap = meshing.unwrap(V, F, a.texture, log=log)
log("unwrap", len(V2), "verts")
cache = {}


def load_image(cam):
    return np.asarray(Image.open(os.path.join(a.data, "images", cam.name)).convert("RGB"), dtype=np.float32) / 255.0


tex, cov = meshing.bake_texture(V2, F2, UV, F2, cams, load_image, a.texture, log=None)
log("bake %dpx coverage %.1f%%" % (a.texture, 100 * cov))
# Y-up, metric-ish output frame: rotate so reg.up -> +Y, center at the object foot
up = reg["up"]; x = np.cross(up, [0, 0, 1.0]); x /= np.linalg.norm(x); z = np.cross(x, up)
Rw = np.stack([x, up, z])  # rows
origin = reg["center"] + up * reg["bottom"]
Vout = (V2 - origin) @ Rw.T * a.meters_per_unit
export.write_obj(os.path.join(a.out, "obj"), Vout, F2, UV, tex)
export.write_usdz(os.path.join(a.out, "model.usdz"), Vout, F2, UV, tex, os.path.join(a.out, "usd_work"))
ok, msgs = export.check_usdz(os.path.join(a.out, "model.usdz"))
log("usdz", os.path.getsize(os.path.join(a.out, "model.usdz")), "bytes; compliance", ok, msgs[:5])
json.dump({"triangles": int(len(F2)), "vertices": int(len(V2)), "texture": a.texture, "coverage": cov, "voxel": voxel,
           "seconds": time.time() - T0, "region": {k: (v.tolist() if hasattr(v, "tolist") else v) for k, v in reg.items()},
           "toOutput": {"R": Rw.tolist(), "origin": origin.tolist(), "scale": a.meters_per_unit}},
          open(os.path.join(a.out, "splat2mesh.json"), "w"), indent=1)
np.save(os.path.join(a.out, "mesh_colmap_frame_V.npy"), V2); np.save(os.path.join(a.out, "mesh_F.npy"), F2)
np.save(os.path.join(a.out, "mesh_UV.npy"), UV)
log("done")
