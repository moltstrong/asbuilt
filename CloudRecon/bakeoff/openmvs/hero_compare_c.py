"""Hero (off-path 3/4) views: Apple raw | splat->TSDF mesh (B) | OpenMVS variants, from B's hero cameras
(defined in Apple's frame in b/eval/cams_hero.json; mapped to COLMAP for OpenMVS by obj2usdz.cams_colmap_frame).
Lit ('app' mode: SceneKit default light + ambient) and unlit rows so both texture and shape are visible.
usage: hero_compare_c.py <out.png> label=renderdir_unlit[:renderdir_lit] ...
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

C = os.path.dirname(os.path.abspath(__file__))
B = os.path.join(C, "..", "b")
out = sys.argv[1]
cols = [("Apple raw (Object Capture)", os.path.join(B, "eval", "apple_raw_constant")),
        ("Splat->TSDF mesh (B)", os.path.join(B, "eval", "hero", "splatmesh"))]
for a in sys.argv[2:]:
    k, d = a.split("=", 1)
    cols.append((k, d))
TS = 700
try:
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 26)
except OSError:
    font = ImageFont.load_default()
heroes = ["hero1", "hero2"]
canvas = Image.new("RGB", (TS * len(cols), (TS + 40) * len(heroes)), "white")
d = ImageDraw.Draw(canvas)
for r, h in enumerate(heroes):
    for c, (label, dd) in enumerate(cols):
        p = os.path.join(dd, h + ".png")
        if not os.path.isfile(p):
            continue
        im = Image.open(p).convert("RGBA")
        bg = Image.new("RGBA", im.size, (255, 255, 255, 255)); bg.alpha_composite(im)
        canvas.paste(bg.convert("RGB").resize((TS, TS), Image.LANCZOS), (c * TS, r * (TS + 40) + 40))
        d.text((c * TS + 10, r * (TS + 40) + 6), "%s - %s" % (label, h), fill="black", font=font)
canvas.save(out)
print(out, canvas.size)
