"""Render the Apple meshes (SceneKit, unlit = texture only) from the 6 held-out photo cameras.
Cameras: COLMAP undistorted PINHOLE (2000x1500, centered principal point) mapped into Apple's frame via align.json.
Also writes two 3/4 'hero' cameras (same in both frames) to eval/cams_hero.json for the splat renderer.
usage: render_mesh_views.py [scale]
"""
import json
import os
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import HERE, colmap_c2w, read_cameras_bin, read_images_bin  # noqa: E402

scale = float(sys.argv[1]) if len(sys.argv) > 1 else 1.0
OUT = os.path.join(HERE, "eval")
os.makedirs(OUT, exist_ok=True)
al = json.load(open(os.path.join(HERE, "align.json")))
s, Ra, ta, K = al["s"], np.array(al["R"]), np.array(al["t"]), np.array(al["K"])
cam = list(read_cameras_bin(os.path.join(HERE, "undist", "sparse", "cameras.bin")).values())[0]
fx, fy, cx, cy = cam["params"]
W, H = int(round(cam["width"] * scale)), int(round(cam["height"] * scale))
assert abs(cx - cam["width"] / 2) < 1 and abs(cy - cam["height"] / 2) < 1, "principal point must be centered"
imgs = read_images_bin(os.path.join(HERE, "undist", "sparse", "images.bin"))
held = [l.strip().replace(".JPG", ".jpg") for l in open(os.path.join(HERE, "heldout.txt")) if l.strip()]
MR = os.path.join(HERE, "meshrender", "meshrender")

cams = []
for n in held:
    M = colmap_c2w(imgs[n])
    Ca = Ra.T @ (M[:3, 3] - ta) / s
    Rcam = Ra.T @ M[:3, :3] @ K.T  # Apple/SceneKit camera axes in Apple frame
    T = np.eye(4); T[:3, :3] = Rcam; T[:3, 3] = Ca
    cams.append({"name": os.path.splitext(n)[0], "c2w": T.flatten().tolist(),
                 "fovY": float(np.degrees(2 * np.arctan(cam["height"] / 2 / fy))), "width": W, "height": H})

# hero views (same recipe as the scnphone harness: bbox center + d*(0.55,0.35,0.75), fov 45) + an opposite one
bb = json.loads(subprocess.check_output([MR, os.path.join(HERE, "apple35", "phone.usdz"), "--bbox"]).decode().strip().splitlines()[-1])
mn, mx = np.array(bb["min"]), np.array(bb["max"])
center = (mn + mx) / 2
d = (mx - mn).max() * 1.6


def look(dirv):
    pos = center + d * np.asarray(dirv) / np.linalg.norm(dirv)
    z = (pos - center) / np.linalg.norm(pos - center)
    x = np.cross([0, 1, 0], z); x /= np.linalg.norm(x)
    y = np.cross(z, x)
    T = np.eye(4); T[:3, 0], T[:3, 1], T[:3, 2], T[:3, 3] = x, y, z, pos
    return T


HERO = 1200
heroes = [{"name": "hero1", "c2w": look([0.55, 0.35, 0.75]).flatten().tolist(), "fovY": 45.0, "width": HERO, "height": HERO},
          {"name": "hero2", "c2w": look([-0.7, 0.3, -0.6]).flatten().tolist(), "fovY": 45.0, "width": HERO, "height": HERO}]
json.dump(cams + heroes, open(os.path.join(OUT, "cams_apple.json"), "w"), indent=1)
json.dump({"bbox_min": mn.tolist(), "bbox_max": mx.tolist(), "heroes": heroes}, open(os.path.join(OUT, "cams_hero.json"), "w"), indent=1)
for model in ("phone", "raw"):
    for mode in ("constant", "app"):
        out = os.path.join(OUT, "apple_%s_%s" % (model, mode))
        subprocess.check_call([MR, os.path.join(HERE, "apple35", model + ".usdz"), os.path.join(OUT, "cams_apple.json"), out, mode])
print("ok", W, H)
