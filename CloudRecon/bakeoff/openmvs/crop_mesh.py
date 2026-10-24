"""Automatic object crop for an object-centric capture (no masks, no manual input).

Region = intersection of
  (a) camera-frustum support: the vertex projects inside >= `min_frac` of the training photos (in front of the camera),
  (b) a sphere around the 'look-at' point (least-squares point nearest all optical axes) whose radius is
      `radius_factor` x the median camera-to-look-at distance (things farther out than the photographer are background),
then only connected components with >= `min_component` of the largest component's faces are kept.

usage: crop_mesh.py <in.ply> <colmap sparse dir> <out.ply> [--min-frac 0.3] [--radius-factor 0.8] [--exclude a.jpg,b.jpg]
"""
import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.environ.get("CLOUDRECON_DIR", os.path.expanduser("~/projects/asbuilt/CloudRecon")))
from asbuilt_cloud import colmap_io  # noqa: E402


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


def _face_adj(F, nv):
    from scipy.sparse import coo_matrix
    # vertex graph via triangle edges; label faces by their first vertex afterwards
    e = np.concatenate([F[:, [0, 1]], F[:, [1, 2]], F[:, [2, 0]]])
    return coo_matrix((np.ones(len(e)), (e[:, 0], e[:, 1])), shape=(nv, nv))


def crop(V, F, cams, min_frac=0.3, radius_factor=0.8, min_component=0.05):
    c = look_at_center(cams)
    dist_cam = np.median([np.linalg.norm(cm.center - c) for cm in cams])
    frac = frustum_fraction(V, cams)
    keep_v = (frac >= min_frac) & (np.linalg.norm(V - c, axis=1) <= radius_factor * dist_cam)
    keep_f = keep_v[F].all(1)
    F1 = F[keep_f]
    used = np.unique(F1)
    remap = -np.ones(len(V), np.int64); remap[used] = np.arange(len(used))
    V1, F1 = V[used], remap[F1]
    from scipy.sparse.csgraph import connected_components
    n, lab = connected_components(_face_adj(F1, len(V1)), directed=False)
    flab = lab[F1[:, 0]]
    sizes = np.bincount(flab, minlength=n)
    good = sizes >= min_component * sizes.max()
    F2 = F1[good[flab]]
    used = np.unique(F2)
    remap = -np.ones(len(V1), np.int64); remap[used] = np.arange(len(used))
    info = {"center": c.tolist(), "medianCameraDistance": float(dist_cam), "radius": float(radius_factor * dist_cam),
            "minFrac": min_frac, "facesIn": int(len(F)), "facesOut": int(len(F2)), "components": int(n), "componentsKept": int(good.sum())}
    return V1[used], remap[F2], info


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inp"); ap.add_argument("sparse"); ap.add_argument("out")
    ap.add_argument("--min-frac", type=float, default=0.3)
    ap.add_argument("--radius-factor", type=float, default=0.8)
    ap.add_argument("--min-component", type=float, default=0.05)
    ap.add_argument("--exclude", default="")
    a = ap.parse_args()
    cams = colmap_io.load_pinhole_model(a.sparse)
    ex = set(x for x in a.exclude.split(",") if x)
    cams = [c for c in cams if c.name not in ex]
    V, F = read_ply_mesh(a.inp)
    V2, F2, info = crop(V, F, cams, a.min_frac, a.radius_factor, a.min_component)
    info["cameras"] = len(cams)
    write_ply_mesh(a.out, V2, F2)
    json.dump(info, open(os.path.splitext(a.out)[0] + "_crop.json", "w"), indent=1)
    print(json.dumps(info))


if __name__ == "__main__":
    main()
