"""COLMAP binary model readers + small camera helpers (numpy only)."""
import os
import struct

import numpy as np

CAM_NPARAMS = {0: 3, 1: 4, 2: 4, 3: 5, 4: 8, 5: 8, 6: 12, 7: 5, 8: 4, 9: 5, 10: 12}


def _read(f, fmt):
    return struct.unpack("<" + fmt, f.read(struct.calcsize("<" + fmt)))


def qvec2rotmat(q):
    w, x, y, z = q
    return np.array([
        [1 - 2 * y * y - 2 * z * z, 2 * x * y - 2 * w * z, 2 * x * z + 2 * w * y],
        [2 * x * y + 2 * w * z, 1 - 2 * x * x - 2 * z * z, 2 * y * z - 2 * w * x],
        [2 * x * z - 2 * w * y, 2 * y * z + 2 * w * x, 1 - 2 * x * x - 2 * y * y]])


def read_cameras_bin(path):
    cams = {}
    with open(path, "rb") as f:
        (n,) = _read(f, "Q")
        for _ in range(n):
            cid, model, w, h = _read(f, "iiQQ")
            params = _read(f, "d" * CAM_NPARAMS[model])
            cams[cid] = dict(model=model, width=int(w), height=int(h), params=np.array(params))
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


def read_images_bin_points(path):
    """name -> dict(R, t, camera_id, xy (n,2) pixel coords, pid (n,) int64 point3D ids, -1 = no 3D point)."""
    imgs = {}
    rec = np.dtype([("x", "<f8"), ("y", "<f8"), ("pid", "<i8")])
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
            a = np.frombuffer(f.read(np2d * 24), dtype=rec, count=np2d)
            imgs[name.decode()] = dict(id=iid, R=qvec2rotmat([qw, qx, qy, qz]), t=np.array([tx, ty, tz]),
                                       camera_id=cid, xy=np.stack([a["x"], a["y"]], 1), pid=a["pid"].astype(np.int64))
    return imgs


def read_points3d_bin_ids(path):
    """(ids (n,) int64, xyz (n,3)) of a points3D.bin."""
    ids, xyz = [], []
    with open(path, "rb") as f:
        (n,) = _read(f, "Q")
        for _ in range(n):
            (pid,) = _read(f, "Q")
            ids.append(pid)
            xyz.append(_read(f, "ddd"))
            f.seek(3 + 8, 1)  # rgb, error
            (tl,) = _read(f, "Q")
            f.seek(8 * tl, 1)
    return np.array(ids, np.int64), np.array(xyz, float).reshape(-1, 3)


def read_points3d_bin(path):
    xyz, rgb, err, track = [], [], [], []
    with open(path, "rb") as f:
        (n,) = _read(f, "Q")
        for _ in range(n):
            _read(f, "Q")
            xyz.append(_read(f, "ddd"))
            rgb.append(_read(f, "BBB"))
            err.append(_read(f, "d")[0])
            (tl,) = _read(f, "Q")
            f.seek(8 * tl, 1)
            track.append(tl)
    return np.array(xyz).reshape(-1, 3), np.array(rgb).reshape(-1, 3), np.array(err), np.array(track)


class Camera:
    """Pinhole camera (undistorted COLMAP model). World->camera: x_c = R x_w + t (OpenCV axes)."""

    def __init__(self, name, R, t, fx, fy, cx, cy, width, height):
        self.name, self.R, self.t = name, np.asarray(R, float), np.asarray(t, float)
        self.fx, self.fy, self.cx, self.cy = float(fx), float(fy), float(cx), float(cy)
        self.width, self.height = int(width), int(height)

    @property
    def center(self):
        return -self.R.T @ self.t

    @property
    def K(self):
        return np.array([[self.fx, 0, self.cx], [0, self.fy, self.cy], [0, 0, 1.0]])

    def scaled(self, s):
        return Camera(self.name, self.R, self.t, self.fx * s, self.fy * s, self.cx * s, self.cy * s,
                      round(self.width * s), round(self.height * s))


def load_pinhole_model(model_dir):
    """Cameras from an undistorted (PINHOLE / SIMPLE_PINHOLE) COLMAP model, sorted by image name."""
    cams = read_cameras_bin(os.path.join(model_dir, "cameras.bin"))
    imgs = read_images_bin(os.path.join(model_dir, "images.bin"))
    out = []
    for name in sorted(imgs):
        im = imgs[name]
        c = cams[im["camera_id"]]
        p = c["params"]
        if c["model"] == 0:  # SIMPLE_PINHOLE f cx cy
            fx = fy = p[0]; cx, cy = p[1], p[2]
        elif c["model"] == 1:  # PINHOLE fx fy cx cy
            fx, fy, cx, cy = p[:4]
        else:
            raise ValueError("model %d is not undistorted; run colmap image_undistorter first" % c["model"])
        out.append(Camera(name, qvec2rotmat(im["q"]), im["t"], fx, fy, cx, cy, c["width"], c["height"]))
    return out


def umeyama(src, dst):
    """Similarity (s, R, t) minimising |dst - (s R src + t)|^2 for Nx3 point sets."""
    mu_s, mu_d = src.mean(0), dst.mean(0)
    xs, xd = src - mu_s, dst - mu_d
    U, D, Vt = np.linalg.svd(xd.T @ xs / len(src))
    S = np.eye(3)
    if np.linalg.det(U) * np.linalg.det(Vt) < 0:
        S[2, 2] = -1
    R = U @ S @ Vt
    s = np.trace(np.diag(D) @ S) / ((xs ** 2).sum() / len(src))
    return s, R, mu_d - s * R @ mu_s
