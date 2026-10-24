"""Held-out metrics for OpenMVS variants in B's exact protocol (copied from b/eval_metrics.py, read-only use of B's data):
object mask = Apple phone-mesh coverage eroded 4 px; PSNR / SSIM over the mask; LPIPS-alex on the mask bbox with
outside-mask pixels composited from the photo; uncovered pixels inside the mask are black (penalised);
"aligned" = one global sub-pixel 2D shift per (model, view) by phase correlation.
Apple/splat/splat-mesh rows are recomputed from B's renders too, so every number comes from this one script.

usage: eval_d.py <name>=<render dir with <view>.png RGBA> [...]  -> d/results_d_{aligned,raw}.json
"""
import json
import os
import sys

import numpy as np
from PIL import Image
from scipy.ndimage import binary_erosion, shift as ndshift
from skimage.metrics import structural_similarity
from skimage.registration import phase_cross_correlation

HERE = os.path.dirname(os.path.abspath(__file__))
B = os.path.join(HERE, "..", "b")
held = [l.strip().replace(".JPG", ".jpg") for l in open(os.path.join(B, "heldout.txt")) if l.strip()]
MODELS = {"apple_phone_250k": (os.path.join(B, "eval/apple_phone_constant"), "rgba"),
          "apple_raw": (os.path.join(B, "eval/apple_raw_constant"), "rgba"),
          "brush_splat": (os.path.join(B, "splat/eval_15000"), "rgb"),
          "splat_mesh_250k": (os.path.join(B, "mesh_final/render"), "rgba")}
for a in sys.argv[1:]:
    k, v = a.split("=", 1)
    MODELS[k] = (os.path.abspath(v), "rgba")


def load(path, kind):
    im = Image.open(path)
    if kind == "rgba":
        a = np.asarray(im.convert("RGBA"), dtype=np.float32) / 255.0
        return a[..., :3] * (a[..., 3:] > 0.5), a[..., 3] > 0.5
    a = np.asarray(im.convert("RGB"), dtype=np.float32) / 255.0
    return a, np.ones(a.shape[:2], bool)


def best_shift(gt, img, mask):
    ys, xs = np.nonzero(mask)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    w = mask[y0:y1, x0:x1].astype(np.float32)
    sh, _, _ = phase_cross_correlation(gt[y0:y1, x0:x1].mean(2) * w, img[y0:y1, x0:x1].mean(2) * w,
                                       upsample_factor=10, normalization=None)
    return sh


def apply_shift(img, cov, sh):
    out = np.stack([ndshift(img[..., c], sh, order=1, mode="constant", cval=0.0) for c in range(3)], -1)
    return out, ndshift(cov.astype(np.float32), sh, order=0, mode="constant", cval=0.0) > 0.5


def main():
    import torch
    import lpips
    net = lpips.LPIPS(net="alex", verbose=False)
    res = {"raw": [], "aligned": []}
    for n in held:
        stem = os.path.splitext(n)[0]
        gt = np.asarray(Image.open(os.path.join(B, "undist", "images", n)).convert("RGB"), dtype=np.float32) / 255.0
        _, m_apple = load(os.path.join(MODELS["apple_phone_250k"][0], stem + ".png"), "rgba")
        mask = binary_erosion(m_apple, iterations=4)
        ys, xs = np.nonzero(mask)
        y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
        rows = {v: {"view": stem, "maskFraction": round(float(mask.mean()), 4)} for v in res}
        for name, (d, kind) in MODELS.items():
            p = os.path.join(d, stem + ".png")
            if not os.path.isfile(p):
                continue
            img0, cov0 = load(p, kind)
            for variant in res:
                img, cov, sh = img0, cov0, None
                if variant == "aligned":
                    sh = best_shift(gt, img0, mask)
                    img, cov = apply_shift(img0, cov0, sh)
                    od = os.path.join(HERE, "eval_aligned", name); os.makedirs(od, exist_ok=True)
                    Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8)).save(os.path.join(od, stem + ".png"))
                mse = float(((img - gt) ** 2)[mask].mean())
                _, smap = structural_similarity(gt, img, channel_axis=2, data_range=1.0, full=True)
                comp = np.where(mask[..., None], img, gt)[y0:y1, x0:x1]
                t = lambda a: torch.from_numpy(np.ascontiguousarray(a)).permute(2, 0, 1)[None] * 2 - 1
                with torch.no_grad():
                    lp = float(net(t(comp), t(gt[y0:y1, x0:x1])).item())
                r = {"psnr": round(10 * np.log10(1.0 / mse), 3), "ssim": round(float(smap.mean(axis=2)[mask].mean()), 4),
                     "lpips": round(lp, 4), "coverage": round(float(cov[mask].mean()), 4)}
                if sh is not None:
                    r["shiftPx"] = [round(float(sh[1]), 2), round(float(sh[0]), 2)]
                rows[variant][name] = r
        for v in res:
            res[v].append(rows[v])
        print(stem, {k: (rows["aligned"][k]["psnr"], rows["aligned"][k]["lpips"]) for k in MODELS if k in rows["aligned"]}, flush=True)
    for variant, rows in res.items():
        summary = {}
        for name in MODELS:
            vals = [r[name] for r in rows if name in r]
            if vals:
                summary[name] = {k: round(float(np.mean([v[k] for v in vals])), 4) for k in ("psnr", "ssim", "lpips", "coverage")}
                summary[name]["views"] = len(vals)
        json.dump({"protocol": __doc__.strip(), "variant": variant, "heldout": held, "perView": rows, "mean": summary},
                  open(os.path.join(HERE, "results_d_%s.json" % variant), "w"), indent=1)
        print(variant, json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
