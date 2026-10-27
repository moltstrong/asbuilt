"""Entry point for one build: `python -m asbuilt_cloud.runner --input X.zip --out DIR --status-file S --options JSON`.

--stages real  : pycolmap SfM + OpenMVS mesh (CPU, default) or gsplat training (CUDA, CLOUD_MESHER=splat) + exports
--stages fake  : CPU-only stand-ins for the heavy stages (tests): SfM is replaced by a synthetic COLMAP model of
                 a textured sphere seen by a ring of cameras; OpenMVS by that sphere's mesh (through the real
                 crop); splat training by a splat sampled on it. Everything after (crop, decimate, unwrap,
                 two-band bake, scale/orientation, USDZ/OBJ/thumbnail, result.json, status.json) is the real code.
"""
import argparse
import json
import os
import struct
import sys

import numpy as np

from . import pipeline


class FakeStages(pipeline.Stages):
    """Synthetic scene: unit sphere with a checker texture, 16 cameras, 160x120 px."""

    W, H, F = 160, 120, 150.0

    def _cams(self):
        cams = []
        for k, a in enumerate(np.linspace(0, 2 * np.pi, 16, endpoint=False)):
            C = np.array([3.2 * np.cos(a), -0.8 if k % 2 else 0.6, 3.2 * np.sin(a)])
            z = -C / np.linalg.norm(C)
            x = np.cross([0, -1.0, 0], z); x /= np.linalg.norm(x)
            y = np.cross(z, x)
            R = np.stack([x, y, z]); t = -R @ C
            cams.append(("v%02d.jpg" % k, R, t))
        return cams

    def _render(self, R, t):
        ys, xs = np.mgrid[0:self.H, 0:self.W]
        d = np.stack([(xs + 0.5 - self.W / 2) / self.F, (ys + 0.5 - self.H / 2) / self.F, np.ones_like(xs, float)], -1)
        d /= np.linalg.norm(d, axis=-1, keepdims=True)
        dw = d @ R
        C = -R.T @ t
        b = dw @ C; disc = b * b - (C @ C - 1)
        tt = -b - np.sqrt(np.maximum(disc, 0))
        P = C + dw * tt[..., None]
        u = np.arctan2(P[..., 2], P[..., 0]); v = np.arcsin(np.clip(P[..., 1], -1, 1))
        chk = ((np.floor(u * 4) + np.floor(v * 4)) % 2)[..., None]
        col = np.where(chk > 0, [0.85, 0.55, 0.2], [0.2, 0.35, 0.8])
        img = np.where((disc > 0)[..., None], col, [0.5, 0.5, 0.5])
        return (img * 255).astype(np.uint8)

    def sfm(self, images, work, log, use_gpu=None):
        from PIL import Image
        undist = os.path.join(work, "undist")
        os.makedirs(os.path.join(undist, "images"), exist_ok=True)
        os.makedirs(os.path.join(undist, "sparse"), exist_ok=True)
        cams = self._cams()
        for name, R, t in cams:
            Image.fromarray(self._render(R, t)).save(os.path.join(undist, "images", name), quality=95)
        write_colmap_model(os.path.join(undist, "sparse"), cams, self.W, self.H, self.F)
        log("fake sfm: %d synthetic cameras (ignoring %d uploaded photos)" % (len(cams), len(os.listdir(images))))
        self.sfm_summary = {"mapper": "fake", "registered": len(cams), "images": len(cams),
                            "model": os.path.join(undist, "sparse")}
        return undist

    def train_splat(self, undist, work, log, steps=30000, progress=None):
        rng = np.random.default_rng(0)
        n = 20000  # dense enough that the surface is opaque everywhere (gaps would be carved as free space)
        P = rng.normal(size=(n, 3)); P /= np.linalg.norm(P, axis=1, keepdims=True)
        ply = os.path.join(work, "fake_splat.ply")
        write_splat_ply(ply, P, rgb=np.full((n, 3), 0.6), scale=0.04, opacity=0.99)
        if progress:
            progress(1.0)
        log("fake training: %d gaussians on the unit sphere" % n)
        return ply

    def mvs_mesh(self, undist, work, log, progress=None):
        """Stand-in for OpenMVS: the unit sphere the synthetic photos show (plus a far-away speck that the
        real crop must remove), run through the real crop code."""
        from . import colmap_io, openmvs_mesh
        V, F = icosphere(4)
        speck_v, speck_f = icosphere(1)
        V = np.concatenate([V, speck_v * 0.05 + [40.0, 0, 0]])
        F = np.concatenate([F, speck_f + len(icosphere(4)[0])])
        cams = colmap_io.load_pinhole_model(os.path.join(undist, "sparse"))
        V, F, info = openmvs_mesh.crop(V, F, cams, min_frac=0.1, radius_factor=1.6)
        if progress:
            progress("meshGeneration", 1.0, "Building the mesh")
        log("fake openmvs: sphere %d verts %d tris after crop %s" % (len(V), len(F), info))
        return V, F, {"crop": info, "seconds": {}, "threads": 1}


def icosphere(level):
    """Unit icosphere (outward CCW faces): 20 * 4**level triangles."""
    t = (1 + 5 ** 0.5) / 2
    V = [(-1, t, 0), (1, t, 0), (-1, -t, 0), (1, -t, 0), (0, -1, t), (0, 1, t), (0, -1, -t), (0, 1, -t),
         (t, 0, -1), (t, 0, 1), (-t, 0, -1), (-t, 0, 1)]
    F = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6),
         (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5), (2, 4, 11), (6, 2, 10),
         (8, 6, 7), (9, 8, 1)]
    V = [np.array(v, float) / np.linalg.norm(v) for v in V]
    for _ in range(level):
        cache, F2 = {}, []

        def mid(a, b):
            k = (min(a, b), max(a, b))
            if k not in cache:
                m = V[a] + V[b]
                V.append(m / np.linalg.norm(m))
                cache[k] = len(V) - 1
            return cache[k]

        for a, b, c in F:
            ab, bc, ca = mid(a, b), mid(b, c), mid(c, a)
            F2 += [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
        F = F2
    return np.array(V), np.array(F, np.int64)


def write_colmap_model(d, cams, W, H, f):
    """cameras.bin (PINHOLE), images.bin, points3D.bin (sphere samples) in COLMAP's binary layout."""
    with open(os.path.join(d, "cameras.bin"), "wb") as fh:
        fh.write(struct.pack("<Q", 1))
        fh.write(struct.pack("<iiQQ", 1, 1, W, H))
        fh.write(struct.pack("<4d", f, f, W / 2, H / 2))
    with open(os.path.join(d, "images.bin"), "wb") as fh:
        fh.write(struct.pack("<Q", len(cams)))
        for i, (name, R, t) in enumerate(cams):
            q = rotmat2qvec(R)
            fh.write(struct.pack("<i4d3di", i + 1, *q, *t, 1))
            fh.write(name.encode() + b"\0")
            fh.write(struct.pack("<Q", 0))
    rng = np.random.default_rng(1)
    P = rng.normal(size=(500, 3)); P /= np.linalg.norm(P, axis=1, keepdims=True)
    with open(os.path.join(d, "points3D.bin"), "wb") as fh:
        fh.write(struct.pack("<Q", len(P)))
        for i, p in enumerate(P):
            fh.write(struct.pack("<Q3d3Bd", i + 1, *p, 128, 128, 128, 0.5))
            fh.write(struct.pack("<Q", 0))


def rotmat2qvec(R):
    m = R
    tr = np.trace(m)
    if tr > 0:
        s = np.sqrt(tr + 1.0) * 2
        q = [0.25 * s, (m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s]
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = np.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        q = [(m[2, 1] - m[1, 2]) / s, 0.25 * s, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s]
    elif m[1, 1] > m[2, 2]:
        s = np.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        q = [(m[0, 2] - m[2, 0]) / s, (m[0, 1] + m[1, 0]) / s, 0.25 * s, (m[1, 2] + m[2, 1]) / s]
    else:
        s = np.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
        q = [(m[1, 0] - m[0, 1]) / s, (m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, 0.25 * s]
    q = np.array(q)
    return q / np.linalg.norm(q)


def write_splat_ply(path, xyz, rgb, scale, opacity):
    """INRIA/gsplat 3DGS PLY layout (f_dc SH0, logit opacity, log scales, wxyz quats)."""
    from plyfile import PlyData, PlyElement
    n = len(xyz)
    C0 = 0.28209479177387814
    names = ["x", "y", "z", "nx", "ny", "nz", "f_dc_0", "f_dc_1", "f_dc_2", "opacity",
             "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"]
    a = np.zeros(n, dtype=[(k, "f4") for k in names])
    a["x"], a["y"], a["z"] = xyz.T
    dc = (rgb - 0.5) / C0
    a["f_dc_0"], a["f_dc_1"], a["f_dc_2"] = dc.T
    a["opacity"] = np.log(opacity / (1 - opacity))
    for k in ("scale_0", "scale_1", "scale_2"):
        a[k] = np.log(scale)
    a["rot_0"] = 1.0
    PlyData([PlyElement.describe(a, "vertex")]).write(path)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--status-file", default=None)
    ap.add_argument("--options", default="{}")
    ap.add_argument("--stages", default="real", choices=["real", "fake"])
    a = ap.parse_args(argv)
    o = json.loads(a.options)
    stages = FakeStages() if a.stages == "fake" else pipeline.Stages()
    kw = {}
    if a.stages == "fake":
        kw = dict(max_side=400, steps=10, tris_override=4000, texture_px_override=512)
    r = pipeline.build(a.input, a.out, detail=o.get("detail", "full"), texture=o.get("texture", "8k"),
                       max_polys=o.get("maxPolygons"), obj=bool(o.get("obj", True)), status_file=a.status_file,
                       title=o.get("title"), stages=stages, echo=False, mesher=o.get("mesher"), **kw)
    print(json.dumps({k: r.get(k) for k in ("ok", "polygons", "totalSeconds", "errorMessage")}))
    return 0 if r.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
