"""OpenMVS textured OBJ (COLMAP world frame) -> USDZ via the repo's export.write_usdz, plus SceneKit cameras
(6 held-out COLMAP cameras + B's 2 hero cameras mapped from Apple's frame) in the same frame, then renders them
with B's meshrender (SceneKit, unlit = texture only).

usage: obj2usdz.py <textured.obj> <outdir>        -> outdir/model.usdz, cams.json, render/<view>.png
"""
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image

C = os.path.dirname(os.path.abspath(__file__))
B = os.path.join(C, "..", "b")
sys.path.insert(0, os.environ.get("CLOUDRECON_DIR", os.path.expanduser("~/projects/asbuilt/CloudRecon")))
from asbuilt_cloud import colmap_io, export  # noqa: E402

Image.MAX_IMAGE_PIXELS = None


def load_obj(path):
    """OBJ with v/vt faces and one or more materials -> per-corner-split V, F, UV, texture (atlases stacked
    vertically if there are several)."""
    vs, vts, faces, mats = [], [], [], []
    cur = 0
    mtl_map, mtl_order = {}, []
    d = os.path.dirname(path)
    with open(path) as f:
        for line in f:
            if line.startswith("v "):
                vs.append(line.split()[1:4])
            elif line.startswith("vt "):
                vts.append(line.split()[1:3])
            elif line.startswith("f "):
                p = line.split()[1:]
                faces.append([tuple(int(x) for x in q.split("/")[:2]) for q in p[:3]])
                mats.append(cur)
            elif line.startswith("usemtl "):
                name = line.split()[1]
                if name not in mtl_order:
                    mtl_order.append(name)
                cur = mtl_order.index(name)
            elif line.startswith("mtllib "):
                mp = os.path.join(d, line.split(None, 1)[1].strip())
                name = None
                for l2 in open(mp):
                    if l2.startswith("newmtl "):
                        name = l2.split()[1]
                    elif l2.startswith("map_Kd "):
                        mtl_map[name] = os.path.join(d, l2.split(None, 1)[1].strip())
    V = np.asarray(vs, np.float64)
    VT = np.asarray(vts, np.float64)
    Fc = np.asarray(faces, np.int64) - 1  # (m,3,2)
    mats = np.asarray(mats)
    if not mtl_order:
        mtl_order = list(mtl_map)[:1]
    texs = [np.asarray(Image.open(mtl_map[n]).convert("RGB")) for n in mtl_order]
    k = len(texs)
    if k > 1:  # stack atlases vertically, remap v
        h = texs[0].shape[0]
        assert all(t.shape == texs[0].shape for t in texs)
        tex = np.concatenate(texs[::-1], 0)  # material 0 at the bottom (v origin bottom-left)
    else:
        tex = texs[0]
    key = Fc[:, :, 0] * (len(VT) + 1) + Fc[:, :, 1]
    uniq, inv = np.unique(key.ravel(), return_inverse=True)
    vi = uniq // (len(VT) + 1)
    ti = uniq % (len(VT) + 1)
    V2 = V[vi]
    UV = VT[ti].copy()
    F2 = inv.reshape(-1, 3)
    if k > 1:
        corner_mat = np.repeat(mats, 3)
        # each split vertex belongs to one material (same vt index never shared across atlases in OpenMVS)
        vm = np.zeros(len(uniq), int); vm[inv] = corner_mat
        UV[:, 1] = (UV[:, 1] + vm) / k
    return V2, F2, UV, tex


def cams_colmap_frame():
    """6 held-out cams (COLMAP undistorted) + B's 2 hero cams, as meshrender c2w in the COLMAP world frame."""
    cams = {c.name: c for c in colmap_io.load_pinhole_model(os.path.join(B, "undist", "sparse"))}
    held = [l.strip().replace(".JPG", ".jpg") for l in open(os.path.join(B, "heldout.txt")) if l.strip()]
    flip = np.diag([1.0, -1.0, -1.0])  # OpenCV cam axes -> SceneKit cam axes
    out = []
    for n in held:
        c = cams[n]
        T = np.eye(4); T[:3, :3] = c.R.T @ flip; T[:3, 3] = c.center
        out.append({"name": n[:-4], "c2w": T.flatten().tolist(), "fovY": float(np.degrees(2 * np.arctan(c.height / 2 / c.fy))),
                    "width": c.width, "height": c.height})
    al = json.load(open(os.path.join(B, "align.json")))
    s, Ra, ta, K = al["s"], np.array(al["R"]), np.array(al["t"]), np.array(al["K"])
    for h in json.load(open(os.path.join(B, "eval", "cams_hero.json")))["heroes"]:
        T0 = np.array(h["c2w"]).reshape(4, 4)
        Mrot = Ra @ T0[:3, :3] @ K           # COLMAP c2w rotation (OpenCV axes), same as hero_compare.py
        Cc = s * Ra @ T0[:3, 3] + ta
        T = np.eye(4); T[:3, :3] = Mrot @ flip; T[:3, 3] = Cc
        out.append({"name": h["name"], "c2w": T.flatten().tolist(), "fovY": h["fovY"], "width": h["width"], "height": h["height"]})
    return out


def main():
    obj, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    V, F, UV, tex = load_obj(obj)
    print("obj: %d verts %d tris tex %s" % (len(V), len(F), tex.shape))
    usdz = os.path.join(outdir, "model.usdz")
    export.write_usdz(usdz, V, F, UV, tex, os.path.join(outdir, "usd"), title="OpenMVS")
    ok, msgs = export.check_usdz(usdz)
    print("usd validators:", "PASSED" if ok else "FAILED", msgs[:3])
    cams = cams_colmap_frame()
    json.dump(cams, open(os.path.join(outdir, "cams.json"), "w"))
    subprocess.check_call([os.path.join(B, "meshrender", "meshrender"), usdz, os.path.join(outdir, "cams.json"),
                           os.path.join(outdir, "render"), "constant"])
    json.dump({"triangles": int(len(F)), "vertices": int(len(V)), "texture": list(tex.shape[:2]), "usdValidators": ok,
               "usdzBytes": os.path.getsize(usdz)}, open(os.path.join(outdir, "info.json"), "w"))


if __name__ == "__main__":
    main()
