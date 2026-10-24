"""Side-by-side for agent C: held-out photo | Apple raw | OpenMVS variant(s) [| splat->mesh], full view + 2 crops at
~2.1x, using the ALIGNED renders from eval_c.py (c/eval/aligned/<model>/<view>.png) and per-view metrics from
c/results_heldout_aligned.json. Uncovered pixels are shown magenta so holes are visible.
usage: make_compare_c.py <view> <out.png> <model[,model...]> [crop1 x,y] [crop2 x,y]
"""
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

C = os.path.dirname(os.path.abspath(__file__))
B = os.path.join(C, "..", "b")
view, out = sys.argv[1], sys.argv[2]
models = sys.argv[3].split(",")
crops = [tuple(int(v) for v in a.split(",")) for a in sys.argv[4:6]] or [(900, 600), (300, 300)]
res = json.load(open(os.path.join(C, "results_heldout_aligned.json")))
row = next(r for r in res["perView"] if r["view"] == view)
LABEL = {"apple_raw": "Apple Object Capture raw", "apple_phone_250k": "Apple phone preset (250k)",
         "splat_mesh_250k": "Splat->TSDF mesh (B)", "brush_splat": "Gaussian splat (Brush)"}
cols = [("photo", "Real photo (held out)")] + [(m, LABEL.get(m, m.replace("openmvs", "OpenMVS"))) for m in models]


def img_for(key):
    if key == "photo":
        return Image.open(os.path.join(B, "undist", "images", view + ".jpg")).convert("RGB")
    p = os.path.join(C, "eval", "aligned", key, view + ".png")
    a = np.asarray(Image.open(p).convert("RGB")).copy()
    # coverage: re-derive from the unaligned RGBA render if available (black = uncovered after alignment)
    hole = (a.sum(2) == 0)
    a[hole] = (255, 0, 255)
    return Image.fromarray(a)


ims = [img_for(k) for k, _ in cols]
W, H = ims[0].size
TW = 640
TH = int(H * TW / W)
CS = 300
try:
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 22)
    small = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 18)
except OSError:
    font = small = ImageFont.load_default()
LH = 70
canvas = Image.new("RGB", (TW * len(cols), LH + TH + 2 * (TW + 8) + 40), "white")
d = ImageDraw.Draw(canvas)
for i, ((key, label), im) in enumerate(zip(cols, ims)):
    x0 = i * TW
    d.text((x0 + 10, 6), label, fill="black", font=font)
    if key in row:
        m = row[key]
        d.text((x0 + 10, 38), "PSNR %.1f dB  SSIM %.3f  LPIPS %.3f  cov %.0f%%" % (m["psnr"], m["ssim"], m["lpips"], 100 * m["coverage"]),
               fill=(150, 0, 0), font=small)
    canvas.paste(im.resize((TW, TH), Image.LANCZOS), (x0, LH))
    for j, (cx, cy) in enumerate(crops):
        c = im.crop((cx, cy, cx + CS, cy + CS)).resize((TW, TW), Image.BICUBIC)
        canvas.paste(c, (x0, LH + TH + 8 + j * (TW + 8)))
for j, (cx, cy) in enumerate(crops):
    for i in range(len(cols)):
        sx, sy = cx * TW / W, cy * TH / H
        d.rectangle([i * TW + sx, LH + sy, i * TW + sx + CS * TW / W, LH + sy + CS * TH / H], outline=(255, 220 - 150 * j, 0), width=3)
d.text((10, canvas.height - 32), "Held-out view %s (not used by any model), rendered from its COLMAP camera; metrics inside the object mask "
       "(B's protocol). Magenta = no surface. Crops: %dx%d source px." % (view, CS, CS), fill="black", font=small)
canvas.save(out)
print(out, canvas.size)
