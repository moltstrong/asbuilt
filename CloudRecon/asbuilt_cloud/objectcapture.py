"""What an iPhone Object Capture HEIC carries besides the photo, read without Apple frameworks.

Verified on a real ObjectCaptureSession HEIC (iPhone 13 Pro, iOS 18.4+; libheif 1.19/1.23, pillow-heif 1.x):

  primary image   3024x4032 after the `irot` 270 the decoders apply (stored 4032x3024)
  depth           192x256 8-bit auxiliary image (rotated with the photo), z-near/z-far set, "uniform Z":
                  z = z_near + v/255 * (z_far - z_near) meters; 0 = no data.  pillow-heif: info["depth_images"]
  confidence      "tag:apple.com,2023:ObjectCapture#DepthConfidenceMap" aux image, same grid, values 0..2/3
  intrinsics      `cmin` property, in pixels of the *displayed* (rotated) photo: fx = fy ~ 3022, cx ~ 1518,
                  cy ~ 2006 for 3024x4032. pillow-heif: info["heif"]["camera_intrinsic_matrix"]
  camera pose     `cmex` property (a uuid box 4363e914-5b7d-4aab-97ae-bea69803b434 in Apple's files):
                  camera position in micrometers + rotation quaternion in the ARKit world frame (meters, +Y up =
                  against gravity). The rotation maps OpenCV camera axes (x right, y down, z forward, of the
                  displayed photo) to the world on iOS >= 18.4; older iOS wrote ARKit camera axes (y up, -z
                  forward). pillow-heif exposes only the rotation (info["heif"]["camera_extrinsic_matrix_rot"]),
                  so read_cmex() parses the box itself.
  metadata items  uri "tag:apple.com,2023:ObjectCapture#..." items: CameraCalibrationData (NSKeyedArchiver
                  plist: IntrinsicMatrix for 4032x3024, LensDistortionCoefficients, ...), ObjectBoundingBox
                  (3x4 float32, columns = box axes scaled to half-extents + center, world meters),
                  ObjectTransform, RawFeaturePoints, PointCloudData, WideToDepthCameraTransform, ...

Everything here is best effort: any field may be missing (plain JPEGs, other apps, other iOS versions), and the
pipeline checks the poses against the photo geometry before trusting them (see lidar_fusion.align_phone_poses).
"""
import os
import struct

import numpy as np

CMEX_UUID = bytes.fromhex("4363e9145b7d4aab97aebea69803b434")
CMIN_UUID = bytes.fromhex("22cc04c7d6d94e0799d90eb6ecbaf3a3")
CONFIDENCE_AUX = "tag:apple.com,2023:ObjectCapture#DepthConfidenceMap"


def _boxes(buf, start, end):
    """Yield (type, usertype or None, payload_start, box_end) for the ISOBMFF boxes in buf[start:end]."""
    p = start
    while p + 8 <= end:
        size, typ = struct.unpack(">I4s", buf[p:p + 8])
        hdr = 8
        if size == 1:
            size = struct.unpack(">Q", buf[p + 8:p + 16])[0]
            hdr = 16
        elif size == 0:
            size = end - p
        if size < hdr or p + size > end:
            return
        usertype = None
        if typ == b"uuid":
            usertype = buf[p + hdr:p + hdr + 16]
            hdr += 16
        yield typ, usertype, p + hdr, p + size
        p += size


def _find_properties(buf):
    """All (type, usertype, payload_start, end) item properties: the children of meta/iprp/ipco."""
    start, end = 0, len(buf)
    for want in (b"meta", b"iprp", b"ipco"):
        for typ, _, ps, pe in _boxes(buf, start, end):
            if typ == want:
                start, end = ps + (4 if typ == b"meta" else 0), pe  # meta is a FullBox
                break
        else:
            return []
    return list(_boxes(buf, start, end))


def quat_to_matrix(x, y, z, w):
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def parse_cmex(payload):
    """ISO/IEC 23001-17 camera extrinsics (FullBox version 0). Returns dict(position_m or None, R or None)."""
    if len(payload) < 4:
        return None
    version = payload[0]
    flags = int.from_bytes(payload[1:4], "big")
    if version != 0:
        return None
    p = 4
    pos = []
    for bit in (0x01, 0x02, 0x04):  # pos_x/y/z present
        if flags & bit:
            pos.append(struct.unpack(">i", payload[p:p + 4])[0])
            p += 4
        else:
            pos.append(None)
    R = None
    if flags & 0x08:  # orientation present (quaternion x, y, z; w derived)
        big = bool(flags & 0x10)
        fmt, n = (">i", 4) if big else (">h", 2)
        q = []
        for _ in range(3):
            q.append(struct.unpack(fmt, payload[p:p + n])[0] / float(1 << (30 if big else 14)))
            p += n
        s = q[0] ** 2 + q[1] ** 2 + q[2] ** 2
        if s <= 1.0 + 1e-6:
            R = quat_to_matrix(q[0], q[1], q[2], float(np.sqrt(max(0.0, 1.0 - s))))
    position = None if any(v is None for v in pos) else np.array(pos, float) * 1e-6
    return {"position": position, "R": R}


def read_cmex(path):
    """Camera pose stored in the HEIC (position meters, rotation 3x3) or None."""
    try:
        with open(path, "rb") as f:
            buf = f.read(4 << 20)  # properties live in the meta box near the start
    except OSError:
        return None
    for typ, ut, ps, pe in _find_properties(buf):
        if typ == b"cmex" or (typ == b"uuid" and ut == CMEX_UUID):
            r = parse_cmex(buf[ps:pe])
            if r and r["R"] is not None:
                return r
    return None


def depth_from_values(v, vmax, meta):
    """8/16-bit uniform-Z depth image -> meters (0 = no data); None if it has no usable range."""
    def get(*names):
        for n in names:
            if meta.get(n) is not None:
                try:
                    return float(meta[n])
                except (TypeError, ValueError):
                    pass
        return None
    zn, zf = get("z_near", "zNear", "z-near"), get("z_far", "zFar", "z-far")
    rep = meta.get("representation_type")
    if zn is None or zf is None or not (0 < zn < zf < 100) or rep not in (None, 2):
        return None
    v = v.astype(np.float32)
    d = zn + (v / vmax) * (zf - zn)
    d[(v <= 0) | (v >= vmax)] = 0.0
    return d


def read_capture(path, want_depth=True):
    """-> dict(size (w, h) displayed, K (fx, fy, cx, cy) or None, pose dict or None, depth meters HxW or None,
    confidence HxW or None, source) for one photo; {} when it isn't a HEIC or can't be read."""
    if not path.lower().endswith((".heic", ".heif")):
        return {}
    try:
        import pillow_heif
        hf = pillow_heif.open_heif(path, convert_hdr_to_8bit=False)
        im = hf[getattr(hf, "primary_index", 0)]
    except Exception:  # noqa: BLE001
        return {}
    out = {"size": tuple(im.size), "K": None, "pose": None, "depth": None, "confidence": None}
    cam = (im.info.get("heif") or {}).get("camera_intrinsic_matrix")
    if cam and cam.get("focal_length_x"):
        fy = cam.get("focal_length_y") or cam["focal_length_x"]
        out["K"] = (float(cam["focal_length_x"]), float(fy), float(cam["principal_point_x"]),
                    float(cam["principal_point_y"]))
    out["pose"] = read_cmex(path)
    if want_depth:
        try:
            depths = [d for d in (im.info.get("depth_images") or []) if d is not None]
            if depths:
                d = depths[0]
                arr = np.asarray(d.to_pillow())
                if arr.ndim == 3:
                    arr = arr[..., 0]
                vmax = 255.0 if arr.dtype == np.uint8 else float(2 ** 16 - 1)
                if arr.dtype.kind != "f":
                    out["depth"] = depth_from_values(arr, vmax, dict(d.info.get("metadata") or {}))
            ids = (im.info.get("aux") or {}).get(CONFIDENCE_AUX) or []
            if ids and out["depth"] is not None:
                c = np.asarray(im.get_aux_image(ids[0]).to_pillow())
                if c.shape[:2] == out["depth"].shape:
                    out["confidence"] = c[..., 0] if c.ndim == 3 else c
        except Exception:  # noqa: BLE001  depth is optional
            out["depth"] = out["depth"] if isinstance(out.get("depth"), np.ndarray) else None
    return out


def summarize(caps):
    """One log line about what the phone put in the photos."""
    n = len(caps)
    k = sum(1 for c in caps if c.get("K"))
    p = sum(1 for c in caps if c.get("pose") and c["pose"].get("position") is not None)
    d = sum(1 for c in caps if c.get("depth") is not None)
    return {"photos": n, "withIntrinsics": k, "withPose": p, "withDepth": d}


def scan_folder(folder, names, want_depth=True):
    """{name: read_capture(...)} for the given original file names."""
    return {n: read_capture(os.path.join(folder, n), want_depth=want_depth) for n in names}
