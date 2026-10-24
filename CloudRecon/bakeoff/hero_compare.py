"""Hero (3/4 orbit) views of all four models from the SAME camera: Apple phone, Apple raw (SceneKit unlit),
Brush splat (numba CPU renderer, validated vs Brush at 30.8 dB), splat->TSDF mesh (SceneKit unlit).
Hero cameras are defined in Apple's frame (eval/cams_hero.json, written by render_mesh_views.py) and mapped into
COLMAP (splat) and the splat-mesh output frame with align.json / mesh_final/splat2mesh.json."""
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import splatrender as sr  # noqa: E402

al = json.load(open(os.path.join(HERE, "align.json")))
s, Ra, ta, K = al["s"], np.array(al["R"]), np.array(al["t"]), np.array(al["K"])
heroes = json.load(open(os.path.join(HERE, "eval", "cams_hero.json")))["heroes"]
tf = json.load(open(os.path.join(HERE, "mesh_final", "splat2mesh.json")))["toOutput"]
Rw, origin, so = np.array(tf["R"]), np.array(tf["origin"]), tf["scale"]
flip = np.diag([1.0, -1.0, -1.0])
g = sr.load_ply(os.path.join(HERE, "splat", "splat_15000.ply"))
out_dir = os.path.join(HERE, "eval", "hero")
os.makedirs(out_dir, exist_ok=True)
mesh_cams = []
for h in heroes:
    T = np.array(h["c2w"]).reshape(4, 4)
    Rscn, Ca = T[:3, :3], T[:3, 3]
    Mrot = Ra @ Rscn @ K          # COLMAP c2w rotation (OpenCV axes)
    C = s * Ra @ Ca + ta          # COLMAP camera center
    R = Mrot.T
    t = -R @ C
    W = H = h["width"]
    f = (H / 2) / np.tan(np.radians(h["fovY"]) / 2)
    rgb, a = sr.render(g, R, t, f, f, W / 2, H / 2, W, H, bg=(1, 1, 1))[:2]
    Image.fromarray((np.clip(rgb, 0, 1) * 255).astype(np.uint8)).save(os.path.join(out_dir, "splat_%s.png" % h["name"]))
    Cout = (C - origin) @ Rw.T * so
    Rout = Rw @ Mrot @ flip
    Tm = np.eye(4); Tm[:3, :3] = Rout; Tm[:3, 3] = Cout
    mesh_cams.append({"name": h["name"], "c2w": Tm.flatten().tolist(), "fovY": h["fovY"], "width": W, "height": H})
json.dump(mesh_cams, open(os.path.join(out_dir, "cams_mesh.json"), "w"))
subprocess.check_call([os.path.join(HERE, "meshrender", "meshrender"), os.path.join(HERE, "mesh_final", "model.usdz"),
                       os.path.join(out_dir, "cams_mesh.json"), os.path.join(out_dir, "splatmesh"), "constant"])

try:
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 26)
except OSError:
    font = ImageFont.load_default()
labels = ["Apple phone preset (250k)", "Apple raw (all geometry)", "Gaussian splat (Brush)", "Splat->TSDF mesh (250k)"]
TS = 700
canvas = Image.new("RGB", (TS * 4, (TS + 40) * len(heroes)), "white")
d = ImageDraw.Draw(canvas)
for r, h in enumerate(heroes):
    n = h["name"]
    paths = [os.path.join(HERE, "eval", "apple_phone_constant", n + ".png"),
             os.path.join(HERE, "eval", "apple_raw_constant", n + ".png"),
             os.path.join(out_dir, "splat_%s.png" % n),
             os.path.join(out_dir, "splatmesh", n + ".png")]
    for c, p in enumerate(paths):
        im = Image.open(p).convert("RGBA")
        bg = Image.new("RGBA", im.size, (255, 255, 255, 255)); bg.alpha_composite(im)
        canvas.paste(bg.convert("RGB").resize((TS, TS), Image.LANCZOS), (c * TS, r * (TS + 40) + 40))
        d.text((c * TS + 10, r * (TS + 40) + 6), "%s - %s" % (labels[c], n), fill="black", font=font)
dest = os.path.join(HERE, "..", "compare_hero.png")
canvas.save(dest)
print(os.path.abspath(dest), canvas.size)
