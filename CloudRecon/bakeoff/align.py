"""Fit the similarity Apple-frame -> COLMAP-frame from the 35 shared training cameras and report residuals.

Writes b/align.json: {s, R, t, camRot (3x3 fixed camera-axis change apple->colmap), residuals}.
"""
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import HERE, colmap_c2w, load_apple_poses, read_images_bin, umeyama  # noqa: E402

model = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "undist", "sparse")
apple = load_apple_poses(os.path.join(HERE, "apple35", "poses.json"))
cimgs = read_images_bin(os.path.join(model, "images.bin"))
col = {os.path.splitext(k)[0].lower(): colmap_c2w(v) for k, v in cimgs.items()}
names = sorted(set(apple) & set(col))
A = np.array([apple[n][:3, 3] for n in names])
C = np.array([col[n][:3, 3] for n in names])
s, R, t = umeyama(A, C)
res = np.linalg.norm((s * (R @ A.T)).T + t - C, axis=1)
span = np.linalg.norm(C - C.mean(0), axis=1).mean()
# Fixed rotation between Apple's camera axes and COLMAP's: Rc = R @ Ra @ K  =>  K = Ra^T R^T Rc
Ks = [apple[n][:3, :3].T @ R.T @ col[n][:3, :3] for n in names]
Kmean = np.mean(Ks, axis=0)
U, _, Vt = np.linalg.svd(Kmean)
K = U @ Vt
angs = [np.degrees(np.arccos(np.clip((np.trace(K.T @ k) - 1) / 2, -1, 1))) for k in Ks]
print("cameras", len(names), "scale", s)
print("center residual RMS %.4f (mean cam distance from centroid %.3f => %.2f%%)" % (np.sqrt((res ** 2).mean()), span, 100 * np.sqrt((res ** 2).mean()) / span))
print("camera-axis change K (apple cam -> colmap cam):\n", np.round(K, 3))
print("rotation residual deg: mean %.3f max %.3f" % (np.mean(angs), np.max(angs)))
json.dump({"s": s, "R": R.tolist(), "t": t.tolist(), "K": K.tolist(), "names": names,
           "centerResidualRMS": float(np.sqrt((res ** 2).mean())), "centerResidualPct": float(100 * np.sqrt((res ** 2).mean()) / span),
           "rotResidualMeanDeg": float(np.mean(angs)), "rotResidualMaxDeg": float(np.max(angs))},
          open(os.path.join(HERE, "align.json"), "w"), indent=1)
