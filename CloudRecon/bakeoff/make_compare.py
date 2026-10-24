"""compare.png: held-out view, 4 columns (Apple 250k phone | Apple raw | Brush splat [| splat->mesh] | real photo)
+ two fine-detail crop rows (bark texture, silhouette edge) at 1:1 pixels, with per-view metrics in the labels.
Inputs are the *aligned* renders written by eval_metrics.py --align (global 2D shift removed, see its docstring).
usage: make_compare.py <view> <out.png> [crop1 x,y] [crop2 x,y]
"""
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
view = sys.argv[1] if len(sys.argv) > 1 else "IMG_1031"
out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "..", "compare.png")
crops = [tuple(int(v) for v in a.split(",")) for a in sys.argv[3:5]] or [(900, 600), (300, 300)]
res = json.load(open(os.path.join(HERE, "results_heldout_aligned.json")))
row = next(r for r in res["perView"] if r["view"] == view)

cols = [("apple_phone_250k", "Apple Object Capture\nphone preset (250k tris, 8K)"),
        ("apple_raw", "Apple Object Capture\nraw (all geometry)"),
        ("brush_splat", "Gaussian splat (Brush, 15k it,\n0.47M splats, COLMAP/GLOMAP)")]
if os.path.isdir(os.path.join(HERE, "eval", "aligned", "splat_mesh_250k")):
    cols.append(("splat_mesh_250k", "Splat->TSDF mesh\n(250k tris, photo-baked 8K)"))
cols.append(("photo", "Real photo (held out:\nnot used by any model)"))

def img_for(key):
    if key == "photo":
        return Image.open(os.path.join(HERE, "undist", "images", view + ".jpg")).convert("RGB")
    return Image.open(os.path.join(HERE, "eval", "aligned", key, view + ".png")).convert("RGB")

ims = [img_for(k) for k, _ in cols]
W, H = ims[0].size
TW = 640
TH = int(H * TW / W)
CS = 300  # crop size in source px, shown at 640 px (~2.1x)
try:
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 22)
    small = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 18)
except OSError:
    font = small = ImageFont.load_default()
LH = 92
canvas = Image.new("RGB", (TW * len(cols), LH + TH + 2 * (TW + 8) + 40), "white")
d = ImageDraw.Draw(canvas)
for i, ((key, label), im) in enumerate(zip(cols, ims)):
    x0 = i * TW
    d.multiline_text((x0 + 10, 6), label, fill="black", font=font, spacing=2)
    if key in row:
        m = row[key]
        d.text((x0 + 10, 62), "PSNR %.1f dB  SSIM %.3f  LPIPS %.3f" % (m["psnr"], m["ssim"], m["lpips"]), fill=(150, 0, 0), font=small)
    canvas.paste(im.resize((TW, TH), Image.LANCZOS), (x0, LH))
    for j, (cx, cy) in enumerate(crops):
        c = im.crop((cx, cy, cx + CS, cy + CS)).resize((TW, TW), Image.NEAREST if False else Image.BICUBIC)
        canvas.paste(c, (x0, LH + TH + 8 + j * (TW + 8)))
for j, (cx, cy) in enumerate(crops):
    for i in range(len(cols)):
        sx, sy = cx * TW / W, cy * TH / H
        d.rectangle([i * TW + sx, LH + sy, i * TW + sx + CS * TW / W, LH + sy + CS * TH / H], outline=(255, 220 - 150 * j, 0), width=3)
d.text((10, canvas.height - 32), "Held-out view %s, all renders from the photo's own COLMAP camera (2000x1500); metrics inside the object mask. "
       "Crops: %dx%d source px." % (view, CS, CS), fill="black", font=small)
canvas.save(out)
print(out, canvas.size)
