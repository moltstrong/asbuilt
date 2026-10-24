"""Texture an OpenMVS mesh (COLMAP frame) with the CloudRecon photo baker instead of TextureMesh:
decimate to the triangle budget (Open3D QEM) -> [drop faces no training photo sees] -> xatlas unwrap
-> multi-view weighted bake from the 35 training photos.
usage: bake_cloudrecon.py <mesh.ply> <out.obj dir> [--tris 250000] [--tex 8192] [--min-views 1] [--multiband 2]
       [--sparse <COLMAP sparse dir> --images <undistorted image dir>]   (default: the bake-off's b/undist minus heldout.txt)
"""
import argparse
import os
import sys
import time

import numpy as np
from PIL import Image

sys.path.insert(0, os.environ.get("CLOUDRECON_DIR", os.path.expanduser("~/projects/asbuilt/CloudRecon")))
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from asbuilt_cloud import colmap_io, export, meshing  # noqa: E402
from crop_mesh import read_ply_mesh as read_ply  # noqa: E402


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mesh"); ap.add_argument("out")
    ap.add_argument("--tris", type=int, default=250000)
    ap.add_argument("--tex", type=int, default=8192)
    ap.add_argument("--power", type=float, default=2.0)
    ap.add_argument("--multiband", type=float, default=0.0, help="sigma (texels) of the two-band split; 0 = off")
    ap.add_argument("--sharp-power", type=float, default=16.0)
    ap.add_argument("--min-views", type=int, default=0, help="drop faces seen by fewer training photos (0 = keep all)")
    B = os.environ.get("BAKEOFF_B", os.path.join(HERE, "..", "b"))
    ap.add_argument("--sparse", default=os.path.join(B, "undist", "sparse"))
    ap.add_argument("--images", default=os.path.join(B, "undist", "images"))
    ap.add_argument("--exclude", default=os.path.join(B, "heldout.txt"), help="file with image names to ignore")
    a = ap.parse_args()
    t0 = time.time()
    held = set()
    if a.exclude and os.path.exists(a.exclude):
        held = {l.strip().replace(".JPG", ".jpg") for l in open(a.exclude) if l.strip()}
    cams = [c for c in colmap_io.load_pinhole_model(a.sparse) if c.name not in held]
    print("cameras", len(cams), flush=True)
    V, F = read_ply(a.mesh)
    V, F = meshing.clean_mesh(V, F, target_tris=a.tris)
    print("decimated", len(F), "%.1fs" % (time.time() - t0), flush=True)
    if a.min_views > 0:
        cnt = face_view_counts(V, F, cams)
        keep = cnt >= a.min_views
        F = F[keep]
        used = np.unique(F); remap = -np.ones(len(V), np.int64); remap[used] = np.arange(len(used))
        V, F = V[used], remap[F]
        print("visibility: dropped %d unseen faces (< %d views), %d left  %.1fs" % ((~keep).sum(), a.min_views, len(F), time.time() - t0), flush=True)
    V2, F2, UV, _ = meshing.unwrap(V, F, a.tex)
    print("unwrapped %.1fs" % (time.time() - t0), flush=True)

    def load_image(cam):
        return np.asarray(Image.open(os.path.join(a.images, cam.name)).convert("RGB"), dtype=np.float32) / 255.0

    tex, cov = meshing.bake_texture(V2, F2, UV, F2, cams, load_image, a.tex, power=a.power)
    print("bake coverage %.3f  %.1fs" % (cov, time.time() - t0), flush=True)
    if a.multiband > 0:
        # two-band blend: low frequencies from the smooth multi-view average (colour/exposure consistent),
        # high frequencies from a near-best-view bake (sharp detail, no ghosting from slight misregistration)
        from scipy.ndimage import gaussian_filter
        sharp, _ = meshing.bake_texture(V2, F2, UV, F2, cams, load_image, a.tex, power=a.sharp_power)
        lo = lambda x: np.stack([gaussian_filter(x[..., c], a.multiband) for c in range(3)], -1)
        b, s = tex.astype(np.float32), sharp.astype(np.float32)
        tex = np.clip(lo(b) + (s - lo(s)), 0, 255).astype(np.uint8)
        print("multiband sigma %.1f sharp power %.0f  %.1fs" % (a.multiband, a.sharp_power, time.time() - t0), flush=True)
    export.write_obj(a.out, V2, F2, UV, tex)
    print("ok", a.out)


if __name__ == "__main__":
    main()
