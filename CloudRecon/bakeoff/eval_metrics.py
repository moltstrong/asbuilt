"""Held-out metrics: Apple phone (250k) / Apple raw / Brush splat / splat->mesh vs the real held-out photos.

All renders come from the exact COLMAP camera of each held-out photo (undistorted PINHOLE 2000x1500):
  * Apple meshes: SceneKit unlit texture render (eval/apple_*_constant), camera mapped into Apple's frame
    via align.json (0.08 % / 0.02 deg residual), RGBA (alpha = mesh coverage)
  * splat: Brush's own eval render at the same camera (splat/eval_15000), full frame
  * splat->mesh (if present): SceneKit unlit render of mesh_final/model.usdz (cams via cams_out_frame.py)
Object mask = Apple phone mesh coverage (the scanned object), eroded 4 px so 1-px silhouette jitter doesn't dominate.
Within the mask: PSNR, SSIM (mean of the SSIM map over the mask), LPIPS-alex on the mask bbox with
outside-mask pixels composited from the photo (so only the object differs). Pixels a model doesn't cover inside
the mask are black (penalized) and reported as coverage.
Two variants: "raw" (renders as-is) and "aligned": one global sub-pixel 2D shift per (model, view), found by
phase correlation over the object, is applied before scoring (test-time camera alignment, as in NeRF-W/BARF
evaluations). Needed because COLMAP fixes the principal point at the image center while Apple refines it, so Apple's
mesh rendered through COLMAP's held-out cameras lands a constant ~7 px off in every view (measured: -7.0..-7.4 px x,
-0.5..-1.9 px y, no scale/rotation term) - a camera-convention offset, not a reconstruction error.
"""
import json
import os
import sys

import numpy as np
from PIL import Image
from scipy.ndimage import binary_erosion
from skimage.metrics import structural_similarity

HERE = os.path.dirname(os.path.abspath(__file__))
held = [l.strip().replace(".JPG", ".jpg") for l in open(os.path.join(HERE, "heldout.txt")) if l.strip()]
SPLAT_EVAL = sys.argv[1] if len(sys.argv) > 1 else "splat/eval_15000"
ALIGN = "--align" in sys.argv
SAVE_ALIGNED = ALIGN

MODELS = {
    "apple_phone_250k": ("eval/apple_phone_constant", "rgba"),
    "apple_raw": ("eval/apple_raw_constant", "rgba"),
    "brush_splat": (SPLAT_EVAL, "rgb"),
    "splat_mesh_250k": ("mesh_final/render", "rgba"),
}


def load(path, kind):
    im = Image.open(path)
    if kind == "rgba":
        a = np.asarray(im.convert("RGBA"), dtype=np.float32) / 255.0
        return a[..., :3] * (a[..., 3:] > 0.5), a[..., 3] > 0.5
    a = np.asarray(im.convert("RGB"), dtype=np.float32) / 255.0
    return a, np.ones(a.shape[:2], bool)


def best_shift(gt, img, mask):
    from skimage.registration import phase_cross_correlation
    ys, xs = np.nonzero(mask)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    w = mask[y0:y1, x0:x1].astype(np.float32)
    g = gt[y0:y1, x0:x1].mean(2) * w
    r = img[y0:y1, x0:x1].mean(2) * w
    sh, _, _ = phase_cross_correlation(g, r, upsample_factor=10, normalization=None)
    return sh  # (dy, dx) to apply to img


def apply_shift(img, cov, sh):
    from scipy.ndimage import shift as ndshift
    out = np.stack([ndshift(img[..., c], sh, order=1, mode="constant", cval=0.0) for c in range(3)], -1)
    c2 = ndshift(cov.astype(np.float32), sh, order=0, mode="constant", cval=0.0) > 0.5
    return out, c2


def main():
    import torch
    import lpips
    net = lpips.LPIPS(net="alex", verbose=False)
    rows = []
    for n in held:
        stem = os.path.splitext(n)[0]
        gt = np.asarray(Image.open(os.path.join(HERE, "undist", "images", n)).convert("RGB"), dtype=np.float32) / 255.0
        _, m_apple = load(os.path.join(HERE, MODELS["apple_phone_250k"][0], stem + ".png"), "rgba")
        mask = binary_erosion(m_apple, iterations=4)
        ys, xs = np.nonzero(mask)
        y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
        row = {"view": stem, "maskFraction": round(float(mask.mean()), 4)}
        for name, (d, kind) in MODELS.items():
            p = os.path.join(HERE, d, stem + ".png")
            if not os.path.isfile(p):
                continue
            img, cov = load(p, kind)
            if img.shape != gt.shape:
                img = np.asarray(Image.fromarray((img * 255).astype(np.uint8)).resize(gt.shape[1::-1], Image.BICUBIC), dtype=np.float32) / 255.0
            sh = None
            if ALIGN:
                sh = best_shift(gt, img, mask)
                img, cov = apply_shift(img, cov, sh)
                if SAVE_ALIGNED:
                    od = os.path.join(HERE, "eval", "aligned", name); os.makedirs(od, exist_ok=True)
                    Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8)).save(os.path.join(od, stem + ".png"))
            mse = float(((img - gt) ** 2)[mask].mean())
            _, smap = structural_similarity(gt, img, channel_axis=2, data_range=1.0, full=True)
            comp = np.where(mask[..., None], img, gt)[y0:y1, x0:x1]
            g = gt[y0:y1, x0:x1]
            t = lambda a: torch.from_numpy(a).permute(2, 0, 1)[None] * 2 - 1
            with torch.no_grad():
                lp = float(net(t(comp), t(g)).item())
            row[name] = {"psnr": round(10 * np.log10(1.0 / mse), 3), "ssim": round(float(smap.mean(axis=2)[mask].mean()), 4),
                         "lpips": round(lp, 4), "coverage": round(float(cov[mask].mean()), 4)}
            if sh is not None:
                row[name]["shiftPx"] = [round(float(sh[1]), 2), round(float(sh[0]), 2)]
        rows.append(row)
        print(json.dumps(row))
    summary = {}
    for name in MODELS:
        vals = [r[name] for r in rows if name in r]
        if vals:
            summary[name] = {k: round(float(np.mean([v[k] for v in vals])), 4) for k in ("psnr", "ssim", "lpips", "coverage")}
            summary[name]["views"] = len(vals)
    out = {"protocol": __doc__.strip(), "variant": "aligned" if ALIGN else "raw", "heldout": held, "perView": rows, "mean": summary}
    json.dump(out, open(os.path.join(HERE, "results_heldout_%s.json" % ("aligned" if ALIGN else "raw")), "w"), indent=1)
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
