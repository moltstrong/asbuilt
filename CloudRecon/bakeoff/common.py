"""Shared helpers for the bake-off: COLMAP binary reader, Apple<->COLMAP similarity alignment, metrics."""
import json
import os
import struct

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))


def _read(f, fmt):
    return struct.unpack("<" + fmt, f.read(struct.calcsize("<" + fmt)))


def read_cameras_bin(path):
    nparams = {0: 3, 1: 4, 2: 4, 3: 5, 4: 8, 5: 8, 6: 12, 7: 5, 8: 4, 9: 5, 10: 12}
    cams = {}
    with open(path, "rb") as f:
        (n,) = _read(f, "Q")
        for _ in range(n):
            cid, model, w, h = _read(f, "iiQQ")
            params = _read(f, "d" * nparams[model])
            cams[cid] = dict(model=model, width=w, height=h, params=params)
    return cams


def read_images_bin(path):
    imgs = {}
    with open(path, "rb") as f:
        (n,) = _read(f, "Q")
        for _ in range(n):
            iid, qw, qx, qy, qz, tx, ty, tz, cid = _read(f, "idddddddi")
            name = b""
            while True:
                c = f.read(1)
                if c == b"\0":
                    break
                name += c
            (np2d,) = _read(f, "Q")
            f.seek(np2d * 24, 1)
            imgs[name.decode()] = dict(id=iid, q=np.array([qw, qx, qy, qz]), t=np.array([tx, ty, tz]), camera_id=cid)
    return imgs


def qvec2rotmat(q):
    w, x, y, z = q
    return np.array([
        [1 - 2 * y * y - 2 * z * z, 2 * x * y - 2 * w * z, 2 * x * z + 2 * w * y],
        [2 * x * y + 2 * w * z, 1 - 2 * x * x - 2 * z * z, 2 * y * z - 2 * w * x],
        [2 * x * z - 2 * w * y, 2 * y * z + 2 * w * x, 1 - 2 * x * x - 2 * y * y]])


def colmap_c2w(img):
    """COLMAP stores world->camera (x right, y down, z forward). Return 4x4 camera->world (same axes)."""
    R = qvec2rotmat(img["q"])
    M = np.eye(4)
    M[:3, :3] = R.T
    M[:3, 3] = -R.T @ img["t"]
    return M


def umeyama(src, dst):
    """Similarity (s, R, t) minimising |dst - (s R src + t)|^2. src, dst: Nx3."""
    mu_s, mu_d = src.mean(0), dst.mean(0)
    xs, xd = src - mu_s, dst - mu_d
    cov = xd.T @ xs / len(src)
    U, D, Vt = np.linalg.svd(cov)
    S = np.eye(3)
    if np.linalg.det(U) * np.linalg.det(Vt) < 0:
        S[2, 2] = -1
    R = U @ S @ Vt
    var_s = (xs ** 2).sum() / len(src)
    s = np.trace(np.diag(D) @ S) / var_s
    t = mu_d - s * R @ mu_s
    return s, R, t


def load_apple_poses(path):
    d = json.load(open(path))["poses"]
    out = {}
    for p in d:
        M = np.array(p["transformColumnMajor"]).reshape(4, 4).T  # column-major -> row-major math matrix
        out[os.path.splitext(p["url"])[0].lower()] = M
    return out


def psnr(a, b, mask=None):
    a = a.astype(np.float64) / 255.0
    b = b.astype(np.float64) / 255.0
    d = (a - b) ** 2
    if mask is not None:
        d = d[mask]
    mse = d.mean()
    return 10 * np.log10(1.0 / max(mse, 1e-12))


def ssim(a, b, mask=None):
    """Gaussian-window SSIM (11x11, sigma 1.5) on luminance-free RGB mean; mask averages the SSIM map."""
    from scipy.ndimage import gaussian_filter
    a = a.astype(np.float64) / 255.0
    b = b.astype(np.float64) / 255.0
    C1, C2 = 0.01 ** 2, 0.03 ** 2
    maps = []
    for c in range(3):
        x, y = a[..., c], b[..., c]
        f = lambda z: gaussian_filter(z, 1.5, truncate=3.5)
        mx, my = f(x), f(y)
        sxx = f(x * x) - mx * mx
        syy = f(y * y) - my * my
        sxy = f(x * y) - mx * my
        maps.append(((2 * mx * my + C1) * (2 * sxy + C2)) / ((mx * mx + my * my + C1) * (sxx + syy + C2)))
    m = np.mean(maps, axis=0)
    return float(m[mask].mean() if mask is not None else m.mean())
