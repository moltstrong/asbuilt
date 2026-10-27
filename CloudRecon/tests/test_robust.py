"""Hard real scans (iPhone "Object 1": 23 photos, 13 lined up, 54 points, empty mesh): tests for the robust SfM
passes, the iPhone Object Capture metadata reader, the LiDAR fallback dense stage, phone-pose builds and the plain
failure text. No GPU, no OpenMVS, no account (pytest CloudRecon/tests -q).

The hard *real* set (monstree, darkened) runs only when ASBUILT_HARD_SET points at the 41 full-size monstree photos
(git clone --depth 1 https://github.com/alicevision/dataset_monstree; .../full): it is slow (~1 min).
"""
import io
import json
import os
import struct
import sys
import zipfile

import numpy as np
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

MPU = 0.1  # meters per SfM unit of the synthetic scene (unit sphere -> 20 cm ball)
TIP = "Plain, shiny or dark objects need more photos with overlap - 60+ all around, in even light."


# ---------------------------------------------------------------------------------------------
# Object Capture metadata


def _box(typ, payload, usertype=None):
    body = (usertype or b"") + payload
    return struct.pack(">I4s", 8 + len(body), typ) + body


def test_cmex_parser_reads_position_and_rotation():
    """Apple writes the camera pose as a uuid 'cmex' item property: position in micrometers + quaternion."""
    from asbuilt_cloud import objectcapture as oc
    q = np.array([0.2, -0.1, 0.3])
    flags = 0x01 | 0x02 | 0x04 | 0x08 | 0x10 | 0x20  # pos xyz, orientation, 32-bit quaternion, coordinate id
    payload = bytes([0]) + flags.to_bytes(3, "big") + struct.pack(">iii", -59918, -16182, -69305) + \
        struct.pack(">iii", *[int(round(v * (1 << 30))) for v in q]) + struct.pack(">I", 0)
    ipco = _box(b"ipco", _box(b"ispe", b"\0" * 12) + _box(b"uuid", payload, oc.CMEX_UUID))
    meta = _box(b"meta", b"\0\0\0\0" + _box(b"hdlr", b"\0" * 24) + _box(b"iprp", ipco))
    buf = _box(b"ftyp", b"heic\0\0\0\0mif1heic") + meta
    props = oc._find_properties(buf)
    assert [p[0] for p in props] == [b"ispe", b"uuid"]
    r = oc.parse_cmex(buf[props[1][2]:props[1][3]])
    assert np.allclose(r["position"], [-0.059918, -0.016182, -0.069305])
    w = np.sqrt(1 - (q ** 2).sum())
    assert np.allclose(r["R"], oc.quat_to_matrix(*q, w), atol=1e-8)
    assert np.allclose(r["R"] @ r["R"].T, np.eye(3), atol=1e-8)


def test_depth_from_values_uniform_z():
    from asbuilt_cloud import objectcapture as oc
    v = np.array([[0, 1, 128, 254, 255]], np.uint8)
    d = oc.depth_from_values(v, 255.0, {"z_near": 0.3, "z_far": 1.1, "representation_type": 2})
    assert d[0, 0] == 0 and d[0, 4] == 0  # end codes = no data
    assert abs(d[0, 2] - (0.3 + 128 / 255 * 0.8)) < 1e-6
    assert oc.depth_from_values(v, 255.0, {"z_near": 0.3}) is None  # no range: not metric


# ---------------------------------------------------------------------------------------------
# synthetic scene: FakeStages' unit sphere + phone data (ARKit world = similarity of the SfM world)


def _rot(axis, deg):
    a = np.radians(deg)
    axis = np.asarray(axis, float) / np.linalg.norm(axis)
    K = np.array([[0, -axis[2], axis[1]], [axis[2], 0, -axis[0]], [-axis[1], axis[0], 0]])
    return np.eye(3) + np.sin(a) * K + (1 - np.cos(a)) * K @ K


RA = _rot([0.3, 1.0, 0.2], 40.0)
TA = np.array([0.4, -0.2, 1.3])


def _sphere_depth(cam, room=6.0):
    """Camera-z depth of the unit sphere; rays that miss it hit the 'room' (a sphere of radius `room`), like
    real LiDAR, which also measures the table and walls behind the object."""
    ys, xs = np.mgrid[0:cam.height, 0:cam.width]
    d = np.stack([(xs + 0.5 - cam.cx) / cam.fx, (ys + 0.5 - cam.cy) / cam.fy, np.ones_like(xs, float)], -1)
    dn = d / np.linalg.norm(d, axis=-1, keepdims=True)
    dw = dn @ cam.R
    C = cam.center
    b = dw @ C
    disc = b * b - (C @ C - 1)
    t = -b - np.sqrt(np.maximum(disc, 0))
    t_room = -b + np.sqrt(b * b - (C @ C - room * room))
    return (np.where(disc > 0, t, t_room) * dn[..., 2]).astype(np.float32)


def _fake_cams():
    from asbuilt_cloud import colmap_io, runner
    fs = runner.FakeStages()
    return [colmap_io.Camera(n, R, t, fs.F, fs.F, fs.W / 2, fs.H / 2, fs.W, fs.H) for n, R, t in fs._cams()], fs


def _phone_caps(convention="opencv", with_pose=True):
    """{original name: capture} as objectcapture.read_capture returns it, for the fake scene's 16 photos."""
    from asbuilt_cloud import colmap_io
    cams, fs = _fake_cams()
    flip = np.eye(3) if convention == "opencv" else np.diag([1.0, -1.0, -1.0])
    caps = {}
    for c in cams:
        s = 0.4  # 64x48 depth grid for the 160x120 photo
        dc = colmap_io.Camera(c.name, c.R, c.t, c.fx * s, c.fy * s, c.cx * s, c.cy * s, 64, 48)
        depth = _sphere_depth(dc) * MPU
        pose = {"R": RA @ c.R.T @ flip, "position": MPU * RA @ c.center + TA} if with_pose else None
        caps[c.name] = {"size": (fs.W, fs.H), "K": (c.fx, c.fy, c.cx, c.cy), "pose": pose, "depth": depth,
                        "confidence": np.full(depth.shape, 2, np.uint8)}
    return caps


def _scene_zip(path):
    """The upload: the fake scene's own renders, so prepared photo names match the synthetic cameras."""
    from PIL import Image
    cams, fs = _fake_cams()
    with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as z:
        for c in cams:
            b = io.BytesIO()
            Image.fromarray(fs._render(c.R, c.t)).save(b, "JPEG", quality=95)
            z.writestr("Images/" + c.name, b.getvalue())
    return path


def test_align_phone_poses_recovers_similarity_and_axis_convention():
    from asbuilt_cloud import lidar_fusion
    cams, _ = _fake_cams()
    for conv in ("opencv", "arkit"):
        caps = _phone_caps(conv)
        poses = {os.path.splitext(n)[0]: c["pose"] for n, c in caps.items()}
        a = lidar_fusion.align_phone_poses(cams[:10], poses)
        assert a is not None and a["convention"] == conv
        assert abs(a["metersPerUnit"] - MPU) < 1e-6 and a["rotDeg"] < 0.1 and a["posRel"] < 1e-6
        # an unregistered photo placed from its phone pose lands on its true SfM camera
        cap = caps[cams[12].name]
        c12 = lidar_fusion.phone_camera_in_sfm(a, cap["pose"], cap["K"], cap["size"], "x")
        assert np.allclose(c12.R, cams[12].R, atol=1e-6) and np.allclose(c12.center, cams[12].center, atol=1e-6)
    # poses that disagree with the photos are refused
    caps = _phone_caps()
    poses = {os.path.splitext(n)[0]: dict(c["pose"]) for n, c in caps.items()}
    rng = np.random.default_rng(0)
    for p in poses.values():
        p["R"] = p["R"] @ _rot(rng.normal(size=3), 25.0)
    assert lidar_fusion.align_phone_poses(cams[:10], poses) is None


def test_lidar_mesh_fuses_depth_into_the_sphere():
    from asbuilt_cloud import lidar_fusion
    cams, _ = _fake_cams()
    caps = _phone_caps()
    views = [(c, lidar_fusion.depth_in_units(caps[c.name], MPU)) for c in cams]
    V, F, info = lidar_fusion.lidar_mesh(views, lambda *a: None, units_per_meter=1 / MPU)
    r = np.linalg.norm(V, axis=1)
    assert len(F) > 2000 and abs(np.median(r) - 1.0) < 0.03, (np.median(r), info)
    assert np.percentile(r, 99.5) < 1.06 and r.min() > 0.94  # no fringe: the room's depth carves the air
    assert info["voxelMm"] == pytest.approx(2.5, abs=0.3)


# ---------------------------------------------------------------------------------------------
# pipeline paths (FakeStages for SfM/OpenMVS; everything else is the real code)


def _stages(registered=16, sparse_dense=False, sfm_fails=None):
    from asbuilt_cloud import openmvs_mesh, pipeline, runner

    class Stages(runner.FakeStages):
        def sfm(self, images, work, log, use_gpu=None, sfm_images=None):
            if sfm_fails is not None:
                raise pipeline.MatchFailed(sfm_fails[0], sfm_fails[1])
            undist = super().sfm(images, work, log)
            if registered < 16:  # SfM lined up only some photos
                runner.write_colmap_model(os.path.join(undist, "sparse"), self._cams()[:registered],
                                          self.W, self.H, self.F)
                self.sfm_summary.update(registered=registered)
            return undist

        def mvs_mesh(self, undist, work, log, progress=None):
            if sparse_dense:
                raise openmvs_mesh.SparseDense(0, registered)
            return super().mvs_mesh(undist, work, log, progress)
    return Stages()


def _build(tmp_path, monkeypatch, caps, **kw):
    from asbuilt_cloud import objectcapture, pipeline
    monkeypatch.setattr(objectcapture, "scan_folder", lambda folder, names, want_depth=True:
                        {n: (caps or {}).get(n, {}) for n in names})
    z = _scene_zip(str(tmp_path / "in.zip"))
    out = str(tmp_path / "job" / "out")
    r = pipeline.build(z, out, detail="phone", status_file=str(tmp_path / "job" / "status.json"),
                       stages=_stages(**kw), echo=False, max_side=400, tris_override=4000,
                       texture_px_override=512, mesher="openmvs")
    return r, out


def _extent(out):
    V = np.array([[float(x) for x in l.split()[1:4]] for l in open(os.path.join(out, "obj", "model.obj"))
                  if l.startswith("v ")])
    return V.max(0) - V.min(0)


def test_pipeline_lidar_fallback_when_openmvs_is_empty(tmp_path, monkeypatch):
    """Object 1's failure mode: SfM lines up only some photos and OpenMVS fuses nothing. With the photos' LiDAR
    depth the build fuses it instead (SfM cameras + phone poses for the photos SfM missed) and still ships."""
    r, out = _build(tmp_path, monkeypatch, _phone_caps(), registered=10, sparse_dense=True)
    assert r["ok"], r.get("errorMessage")
    assert r["densePath"] == "lidar" and r["lidarFusion"]["extraPhotos"] == 6
    assert r["lidarFusion"]["phonePoses"]["convention"] == "opencv"
    assert r["scaleSource"] == "phone" and r["scale"]["metersPerUnit"] == pytest.approx(MPU, rel=1e-4)
    assert r["usdcheckerPassed"] is True and r["polygons"] > 1000
    ext = _extent(out)
    assert np.all(np.abs(ext - 0.2) < 0.03), ext  # the 20 cm ball, metric
    log = open(os.path.join(out, "recon-log.txt")).read()
    assert "dense path: lidar" in log and "placed with the phone's poses" in log


def test_pipeline_builds_from_phone_poses_when_sfm_fails(tmp_path, monkeypatch):
    r, out = _build(tmp_path, monkeypatch, _phone_caps("arkit"), sfm_fails=(2, 16))
    assert r["ok"], r.get("errorMessage")
    assert r["densePath"] == "phone-poses+lidar" and r["scaleSource"] == "phone"
    assert r["sfm"]["registered"] == 2
    ext = _extent(out)
    assert np.all(np.abs(ext - 0.2) < 0.03), ext


def test_pipeline_match_failure_text_without_phone_data(tmp_path, monkeypatch):
    r, _ = _build(tmp_path, monkeypatch, None, sfm_fails=(13, 23))
    assert r["ok"] is False
    assert r["errorMessage"] == "Only 13 of 23 photos could be matched. " + TIP


def test_pipeline_empty_dense_without_lidar_fails_plainly(tmp_path, monkeypatch):
    r, _ = _build(tmp_path, monkeypatch, None, registered=13, sparse_dense=True)
    assert r["ok"] is False
    assert "too little surface detail" in r["errorMessage"] and r["errorMessage"].endswith(TIP)


def test_feature_image_stretches_dark_low_contrast_photos():
    from PIL import Image
    from asbuilt_cloud import pipeline
    rng = np.random.default_rng(0)
    tex = rng.random((300, 400))
    dark = Image.fromarray((8 + 12 * tex).astype(np.uint8)).convert("RGB")  # values 8..20 of 255
    g = np.asarray(pipeline.feature_image(dark), float)
    assert g.std() > 40 and g.max() - g.min() > 200


# ---------------------------------------------------------------------------------------------
# the hard real set (slow; opt-in)


HARD = os.environ.get("ASBUILT_HARD_SET")


def make_hard_set(src, dst, n=23, gain=0.06, offset=0.02, noise=0.006):
    """n of the monstree photos (evenly spread), darkened to ~8 % brightness, low contrast, sensor noise."""
    from PIL import Image
    files = sorted(f for f in os.listdir(src) if f.lower().endswith(".jpg"))
    os.makedirs(dst, exist_ok=True)
    rng = np.random.default_rng(0)
    for i in np.round(np.linspace(0, len(files) - 1, n)).astype(int):
        im = np.asarray(Image.open(os.path.join(src, files[i])).convert("RGB"), np.float32) / 255.0
        y = offset + gain * im ** 1.3 + rng.normal(0, noise, im.shape)
        Image.fromarray((np.clip(y, 0, 1) * 255 + 0.5).astype(np.uint8)).save(os.path.join(dst, files[i]), quality=85)
    return dst


@pytest.mark.skipif(not HARD, reason="set ASBUILT_HARD_SET=<dataset_monstree/full> to run the slow hard-set test")
def test_hard_set_fails_with_old_settings_and_lines_up_now(tmp_path):
    pytest.importorskip("pycolmap")
    from asbuilt_cloud import pipeline, sfm_pycolmap
    hard = make_hard_set(HARD, str(tmp_path / "hard"))
    imgs, feats = str(tmp_path / "images"), str(tmp_path / "sfm_images")
    pipeline.prepare_images(hard, imgs, 2000, lambda *a: None, sfm_dir=feats, sfm_max_side=3200)
    # before: 2000 px photos, default SIFT, global mapper (the settings that failed Object 1)
    try:
        old = sfm_pycolmap.run_sfm(imgs, str(tmp_path / "old"), mvs_images=imgs, max_image_size=2000, robust=False,
                                   passes=[{"name": "old", "features": 16384}], log=lambda *a: None)
        old_reg = old["registered"]
    except RuntimeError:
        old_reg = 0
    new = sfm_pycolmap.run_sfm(feats, str(tmp_path / "new"), mvs_images=imgs, log=lambda *a: None)
    print("HARD SET old registered %d/23, new %d/23 with %d points (%s)" % (old_reg, new["registered"],
                                                                            new["points"], new["mapper"]))
    assert old_reg < 0.5 * 23
    assert new["registered"] >= 0.85 * 23 and new["points"] >= 100 * new["registered"]
    # the model comes back in MVS photo pixels
    cams = __import__("asbuilt_cloud.colmap_io", fromlist=["x"]).read_cameras_bin(
        os.path.join(new["model"], "cameras.bin"))
    assert all(c["width"] == 2000 for c in cams.values())
    json.dumps({k: new[k] for k in ("registered", "points", "tried")})
