"""Minimal CPU 3D Gaussian Splat renderer (numba) for Brush/Inria-format PLYs, used to render a trained
splat from arbitrary cameras (the exact held-out photo cameras and the same 3/4 'hero' view as the
Apple mesh renders) and to produce per-view depth for TSDF mesh extraction.
Front-to-back alpha compositing, EWA projection with a 0.3 px low-pass, SH deg<=3.
Validated against Brush's own GPU render of the same view: 30.8 dB PSNR agreement.

Camera convention = COLMAP/OpenCV: w2c rotation R, translation t; x right, y down, z forward.
"""
import math

import numpy as np
from numba import njit
from plyfile import PlyData

SH_C0 = 0.28209479177387814
SH_C1 = 0.4886025119029199
SH_C2 = [1.0925484305920792, -1.0925484305920792, 0.31539156525252005, -1.0925484305920792, 0.5462742152960396]
SH_C3 = [-0.5900435899266435, 2.890611442640554, -0.4570457994644658, 0.3731763325901154, -0.4570457994644658,
         1.445305721320277, -0.5900435899266435]


def load_ply(path):
    v = PlyData.read(path)["vertex"].data
    names = v.dtype.names
    xyz = np.stack([v["x"], v["y"], v["z"]], 1).astype(np.float64)
    scales = np.exp(np.stack([v["scale_0"], v["scale_1"], v["scale_2"]], 1).astype(np.float64))
    q = np.stack([v["rot_0"], v["rot_1"], v["rot_2"], v["rot_3"]], 1).astype(np.float64)
    q /= np.linalg.norm(q, axis=1, keepdims=True)
    opac = 1 / (1 + np.exp(-v["opacity"].astype(np.float64)))
    dc = np.stack([v["f_dc_0"], v["f_dc_1"], v["f_dc_2"]], 1).astype(np.float64)
    rest_names = sorted([n for n in names if n.startswith("f_rest_")], key=lambda s: int(s[7:]))
    if rest_names:
        rest = np.stack([v[n] for n in rest_names], 1).astype(np.float64)
        k = len(rest_names) // 3
        rest = rest.reshape(-1, 3, k).transpose(0, 2, 1)  # [N, coeffs, rgb]
    else:
        rest = np.zeros((len(xyz), 0, 3))
    return dict(xyz=xyz, scales=scales, quat=q, opacity=opac, dc=dc, rest=rest)


def subset(g, mask):
    return {k: v[mask] for k, v in g.items()}


def sh_color(g, campos):
    d = g["xyz"] - campos
    d /= np.linalg.norm(d, axis=1, keepdims=True)
    x, y, z = d[:, 0:1], d[:, 1:2], d[:, 2:3]
    c = SH_C0 * g["dc"]
    r = g["rest"]
    k = r.shape[1]
    if k >= 3:
        c = c - SH_C1 * y * r[:, 0] + SH_C1 * z * r[:, 1] - SH_C1 * x * r[:, 2]
    if k >= 8:
        xx, yy, zz, xy, yz, xz = x * x, y * y, z * z, x * y, y * z, x * z
        c = (c + SH_C2[0] * xy * r[:, 3] + SH_C2[1] * yz * r[:, 4] + SH_C2[2] * (2 * zz - xx - yy) * r[:, 5]
             + SH_C2[3] * xz * r[:, 6] + SH_C2[4] * (xx - yy) * r[:, 7])
        if k >= 15:
            c = (c + SH_C3[0] * y * (3 * xx - yy) * r[:, 8] + SH_C3[1] * xy * z * r[:, 9]
                 + SH_C3[2] * y * (4 * zz - xx - yy) * r[:, 10] + SH_C3[3] * z * (2 * zz - 3 * xx - 3 * yy) * r[:, 11]
                 + SH_C3[4] * x * (4 * zz - xx - yy) * r[:, 12] + SH_C3[5] * z * (xx - yy) * r[:, 13]
                 + SH_C3[6] * x * (xx - 3 * yy) * r[:, 14])
    return np.clip(c + 0.5, 0, None)


def quat_to_rot(q):
    w, x, y, z = q[:, 0], q[:, 1], q[:, 2], q[:, 3]
    R = np.empty((len(q), 3, 3))
    R[:, 0, 0] = 1 - 2 * (y * y + z * z); R[:, 0, 1] = 2 * (x * y - w * z); R[:, 0, 2] = 2 * (x * z + w * y)
    R[:, 1, 0] = 2 * (x * y + w * z); R[:, 1, 1] = 1 - 2 * (x * x + z * z); R[:, 1, 2] = 2 * (y * z - w * x)
    R[:, 2, 0] = 2 * (x * z - w * y); R[:, 2, 1] = 2 * (y * z + w * x); R[:, 2, 2] = 1 - 2 * (x * x + y * y)
    return R


@njit(cache=True)
def _raster(order, mx, my, ca, cb, cc, rad, op, col, zz, W, H, out, T, dexp, dmed):
    for gi in range(order.shape[0]):
        i = order[gi]
        r = rad[i]
        x0 = max(0, int(mx[i] - r)); x1 = min(W - 1, int(mx[i] + r) + 1)
        y0 = max(0, int(my[i] - r)); y1 = min(H - 1, int(my[i] + r) + 1)
        for py in range(y0, y1 + 1):
            dy = py + 0.5 - my[i]
            for px in range(x0, x1 + 1):
                t = T[py, px]
                if t < 1e-4:
                    continue
                dx = px + 0.5 - mx[i]
                power = -0.5 * (ca[i] * dx * dx + cc[i] * dy * dy) - cb[i] * dx * dy
                if power > 0:
                    continue
                a = op[i] * math.exp(power)
                if a > 0.99:
                    a = 0.99
                if a < 1.0 / 255.0:
                    continue
                w = a * t
                out[py, px, 0] += w * col[i, 0]
                out[py, px, 1] += w * col[i, 1]
                out[py, px, 2] += w * col[i, 2]
                dexp[py, px] += w * zz[i]
                nt = t * (1 - a)
                if t > 0.5 and nt <= 0.5:
                    dmed[py, px] = zz[i]  # median depth: where transmittance crosses 0.5 (as in 2DGS/GOF)
                T[py, px] = nt


def render(g, R, t, fx, fy, cx, cy, W, H, bg=(0, 0, 0), want_depth=False):
    """Returns (rgb HxWx3 in [0,1], alpha HxW) or, with want_depth, (rgb, alpha, median_depth, expected_depth).
    Depths are camera-z; median depth is 0 where alpha never reached 0.5."""
    R = np.asarray(R, float); t = np.asarray(t, float)
    campos = -R.T @ t
    pc = g["xyz"] @ R.T + t
    z = pc[:, 2]
    keep = z > 0.02
    pc = pc[keep]; z = z[keep]
    Rg = quat_to_rot(g["quat"][keep])
    S = g["scales"][keep]
    M = Rg * S[:, None, :]
    cov = M @ M.transpose(0, 2, 1)
    covc = R[None] @ cov @ R.T[None]
    J = np.zeros((len(z), 2, 3))
    J[:, 0, 0] = fx / z; J[:, 0, 2] = -fx * pc[:, 0] / z ** 2
    J[:, 1, 1] = fy / z; J[:, 1, 2] = -fy * pc[:, 1] / z ** 2
    c2 = J @ covc @ J.transpose(0, 2, 1)
    a = c2[:, 0, 0] + 0.3; b = c2[:, 0, 1]; c = c2[:, 1, 1] + 0.3
    det = a * c - b * b
    ok = det > 1e-12
    mx = fx * pc[:, 0] / z + cx
    my = fy * pc[:, 1] / z + cy
    mid = 0.5 * (a + c)
    lam = mid + np.sqrt(np.maximum(0.1, mid * mid - det))
    rad = np.ceil(3 * np.sqrt(lam))
    ok &= (mx + rad > 0) & (mx - rad < W) & (my + rad > 0) & (my - rad < H) & (rad < 4 * max(W, H))
    col = sh_color({"xyz": g["xyz"][keep], "dc": g["dc"][keep], "rest": g["rest"][keep]}, campos)
    op = g["opacity"][keep]
    idx = np.nonzero(ok)[0]
    order = idx[np.argsort(z[idx], kind="stable")].astype(np.int64)
    out = np.zeros((H, W, 3)); T = np.ones((H, W)); dexp = np.zeros((H, W)); dmed = np.zeros((H, W))
    _raster(order, mx, my, c / det, -b / det, a / det, rad, op, col, z, W, H, out, T, dexp, dmed)
    alpha = 1 - T
    out += T[..., None] * np.asarray(bg, float)[None, None]
    rgb = np.clip(out, 0, 1)
    if want_depth:
        return rgb, alpha, dmed, np.where(alpha > 1e-3, dexp / np.maximum(alpha, 1e-6), 0)
    return rgb, alpha
