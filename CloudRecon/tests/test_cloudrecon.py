"""CloudRecon tests: run on a Mac/Linux box without a GPU (pytest CloudRecon/tests -q).

* stage tests: TSDF on a synthetic sphere, USDZ export validated by usd-core's validators, the OpenMVS-mesh crop,
  LiDAR metric scale (decoding search + robust ratio) on synthetic depth maps, HEIC without depth -> no scale,
* pipeline tests: fake heavy stages (synthetic SfM + OpenMVS mesh / splat) through the *real* crop, bake,
  scale/orientation and export code (default OpenMVS path and the optional splat path),
* HTTP test: cloud_server (recon_server.py's handler + CloudWorker + LocalBackend 'fake') driven through the
  asbuilt-recon v1 flow with stdlib http.client: health, auth 401, create upload, chunk PUT with sha,
  resume (GET upload), complete, job polling with stage/progress, Range download + sha256, model.glb
  conversion (recon_server.obj_to_glb), no splat.ply on the default OpenMVS path, job list, delete,
* concurrency tests: a gated fake backend proves 3 builds overlap, the 4th/5th wait in line with cloud wording
  (never "Mac"), a deleted running build frees its slot, all finish with correct state; and a restart re-attaches
  every running build before newer queued work,
* gpu_entry test: the Modal function body with a dict as the status channel,
* modal_app import test: the deployment file builds its App/functions locally (no login, no network).
"""
import hashlib
import http.client
import io
import json
import os
import socket
import sys
import threading
import time
import zipfile

import numpy as np
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)

KEY = "k" * 40


# ---------------------------------------------------------------------------------------------
# helpers


def make_zip(path, n=6):
    from PIL import Image
    buf = io.BytesIO()
    with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as z:
        for i in range(n):
            b = io.BytesIO()
            Image.fromarray((np.random.default_rng(i).random((48, 64, 3)) * 255).astype("uint8")).save(b, "JPEG")
            z.writestr("Images/IMG_%04d.jpg" % i, b.getvalue())
        z.writestr("poses.json", "{}")
    return path


def sphere_cams(n=12, W=160, H=120, f=150.0, dist=3.5):
    from asbuilt_cloud import colmap_io
    cams = []
    for k, a in enumerate(np.linspace(0, 2 * np.pi, n, endpoint=False)):
        C = np.array([dist * np.cos(a), 0.5 if k % 2 else -0.5, dist * np.sin(a)])
        z = -C / np.linalg.norm(C)
        x = np.cross([0, -1.0, 0], z); x /= np.linalg.norm(x)
        y = np.cross(z, x)
        R = np.stack([x, y, z])
        cams.append(colmap_io.Camera("c%d" % k, R, -R @ C, f, f, W / 2, H / 2, W, H))
    return cams


def sphere_depth(cam):
    ys, xs = np.mgrid[0:cam.height, 0:cam.width]
    d = np.stack([(xs + 0.5 - cam.cx) / cam.fx, (ys + 0.5 - cam.cy) / cam.fy, np.ones_like(xs, float)], -1)
    dn = d / np.linalg.norm(d, axis=-1, keepdims=True)
    dw = dn @ cam.R
    C = cam.center
    b = dw @ C
    disc = b * b - (C @ C - 1)
    t = -b - np.sqrt(np.maximum(disc, 0))
    return np.where(disc > 0, t * dn[..., 2], 0).astype(np.float32)


# ---------------------------------------------------------------------------------------------
# stage tests


def test_tsdf_sphere_radius_and_winding():
    from asbuilt_cloud import meshing
    cams = sphere_cams()
    V, F, n = meshing.tsdf_mesh(cams, ((c, sphere_depth(c), None) for c in cams), voxel=0.03,
                                bounds=([-1.3] * 3, [1.3] * 3))
    assert n == len(cams) and len(F) > 1000
    r = np.linalg.norm(V, axis=1)
    assert abs(r.mean() - 1.0) < 0.02 and r.std() < 0.03
    fn = np.cross(V[F[:, 1]] - V[F[:, 0]], V[F[:, 2]] - V[F[:, 0]])
    assert ((fn * V[F].mean(1)).sum(1) > 0).mean() > 0.98  # counter-clockwise from outside


def test_clean_unwrap_bake_export_usdz(tmp_path):
    from asbuilt_cloud import export, meshing
    cams = sphere_cams()
    V, F, _ = meshing.tsdf_mesh(cams, ((c, sphere_depth(c), None) for c in cams), voxel=0.05,
                                bounds=([-1.3] * 3, [1.3] * 3))
    V, F = meshing.clean_mesh(V, F, target_tris=3000)
    assert 2000 <= len(F) <= 3000
    V2, F2, UV, _ = meshing.unwrap(V, F, 256)
    assert UV.min() >= 0 and UV.max() <= 1

    def img(cam):
        a = np.zeros((cam.height, cam.width, 3), np.float32)
        a[..., 0] = 0.8
        return a

    tex, cov = meshing.bake_texture(V2, F2, UV, F2, cams, img, 256)
    assert cov > 0.5 and tex.shape == (256, 256, 3)
    painted = tex.reshape(-1, 3)
    assert np.median(painted[:, 0]) > 150  # red photos -> red texture
    usdz = str(tmp_path / "m.usdz")
    export.write_usdz(usdz, V2, F2, UV, tex, str(tmp_path / "w"))
    ok, msgs = export.check_usdz(usdz)
    assert ok, msgs
    with zipfile.ZipFile(usdz) as z:
        names = z.namelist()
        assert names[0].endswith(".usdc") and any(n.endswith(".jpg") for n in names)
        for info in z.infolist():  # USDZ: stored, 64-byte aligned data
            assert info.compress_type == zipfile.ZIP_STORED
            assert (info.header_offset + 30 + len(info.filename) + len(info.extra)) % 64 == 0
    objp = export.write_obj(str(tmp_path / "obj"), V2, F2, UV, tex)
    assert open(objp).read().count("\nf ") == len(F2)


def test_pipeline_openmvs_path_with_fake_stages(tmp_path):
    from asbuilt_cloud import pipeline, runner
    z = make_zip(str(tmp_path / "in.zip"))
    out = str(tmp_path / "job" / "out")
    st = str(tmp_path / "job" / "status.json")
    r = pipeline.build(z, out, detail="phone", status_file=st, stages=runner.FakeStages(), echo=False,
                       max_side=400, tris_override=4000, texture_px_override=512, mesher="openmvs")
    assert r["ok"], r
    assert r["mesher"] == "openmvs" and 2000 < r["polygons"] <= 4000
    for name in ("model.usdz", "thumbnail.png", "recon-log.txt", "result.json", "obj/model.obj"):
        assert os.path.isfile(os.path.join(out, name)), name
    assert not os.path.exists(os.path.join(out, "splat.ply"))
    s = json.load(open(st))
    assert s["state"] == "done" and s["fraction"] == 1.0
    assert r["usdcheckerPassed"] is True
    # JPEGs carry no LiDAR depth: no metric claim, sized as if shot from ~1 m, Y-up with the object at the origin
    assert r["scaleSource"] == "none" and r["metersPerUnit"] == 1.0
    assert r["openmvs"]["crop"]["componentsKept"] == 1  # the far-away speck was cropped
    V = np.array([[float(x) for x in l.split()[1:4]] for l in open(os.path.join(out, "obj", "model.obj"))
                  if l.startswith("v ")])
    ext = V.max(0) - V.min(0)
    assert abs(V[:, 1].min()) < 0.02 * ext.max()       # resting on y = 0
    assert np.all(np.abs(V[:, [0, 2]].mean(0)) < 0.1 * ext.max())  # centred over the origin
    # unit sphere seen from ~3.3 units -> scaled so the cameras are ~1 m away: diameter ~0.6 m
    assert 0.4 < ext.max() < 0.9, ext
    assert np.allclose(r["dimensionsMeters"], ext, atol=1e-3)
    log = open(os.path.join(out, "recon-log.txt")).read()
    assert "scale: none" in log and "stage seconds" in log


def test_pipeline_splat_path_with_fake_gpu_stages(tmp_path):
    from asbuilt_cloud import pipeline, runner
    z = make_zip(str(tmp_path / "in.zip"))
    out = str(tmp_path / "job" / "out")
    st = str(tmp_path / "job" / "status.json")
    r = pipeline.build(z, out, detail="phone", status_file=st, stages=runner.FakeStages(), echo=False,
                       max_side=400, steps=10, tris_override=4000, texture_px_override=512, mesher="splat")
    assert r["ok"], r
    assert 2000 < r["polygons"] <= 4000
    for name in ("model.usdz", "splat.ply", "thumbnail.png", "recon-log.txt", "result.json"):
        assert os.path.isfile(os.path.join(out, name)), name
    s = json.load(open(st))
    assert s["state"] == "done" and s["fraction"] == 1.0
    assert r["usdcheckerPassed"] is True
    assert r["splat"]["gaussians"] == 20000


def test_openmvs_crop_keeps_object_drops_background():
    from asbuilt_cloud import openmvs_mesh, runner
    cams = sphere_cams()
    V, F = runner.icosphere(3)
    fv, ff = runner.icosphere(0)  # 20 faces: < 5 % of the object's 1280
    V = np.concatenate([V, fv * 0.1 + [30.0, 0, 0], fv * 0.02 + [0, 0, 1.5]])  # far debris + a nearby fleck
    F = np.concatenate([F, ff + len(runner.icosphere(3)[0]), ff + len(runner.icosphere(3)[0]) + len(fv)])
    V2, F2, info = openmvs_mesh.crop(V, F, cams, min_frac=0.1, radius_factor=1.6)
    assert info["componentsKept"] == 1 and len(F2) == len(runner.icosphere(3)[1])
    assert np.allclose(np.linalg.norm(V2, axis=1), 1.0)


def test_camera_up_ignores_pitch_on_a_one_sided_capture():
    from asbuilt_cloud import colmap_io, pipeline
    true_up = np.array([0.2, 1.0, -0.1]); true_up /= np.linalg.norm(true_up)
    a = np.cross(true_up, [0, 0, 1.0]); a /= np.linalg.norm(a); b = np.cross(true_up, a)
    cams = []
    for az in np.linspace(-1.4, 1.4, 15):  # half ring in front of the object, all looking down ~35 deg
        horiz = np.cos(az) * a + np.sin(az) * b
        C = 2.0 * horiz + 1.4 * true_up
        z = -C / np.linalg.norm(C)
        x = np.cross(-true_up, z); x /= np.linalg.norm(x)   # level camera: x horizontal
        y = np.cross(z, x)
        R = np.stack([x, y, z])
        cams.append(colmap_io.Camera("c", R, -R @ C, 100, 100, 50, 50, 100, 100))
    up, source = pipeline.camera_up(cams)
    mean_up = np.mean([c.R.T @ np.array([0, -1.0, 0]) for c in cams], 0); mean_up /= np.linalg.norm(mean_up)
    err = np.degrees(np.arccos(np.clip(up @ true_up, -1, 1)))
    bias = np.degrees(np.arccos(np.clip(mean_up @ true_up, -1, 1)))
    assert source == "camera x axes" and err < 0.5 and bias > 10, (err, bias)


def test_openmvs_progress_is_monotonic_across_phases():
    from asbuilt_cloud.openmvs_mesh import PhaseProgress
    now = [0.0]
    seen = []
    pp = PhaseProgress(seen.append, expected_seconds=100, main=r"depth-?maps?", clock=lambda: now[0])
    script = [(1, "05:15:21 [App     ] Selected images (100%, 1s)"),             # quick phase: no jump to 100 %
              (2, "05:15:22 [App     ] Selecting images for dense reconstruction..."),
              (10, "05:15:30 [App     ] Estimated depth-maps 10 (25%, 10s, ETA 30s)..."),
              (40, "05:16:00 [App     ] Estimated depth-maps 41 (60%, 40s)"),
              (41, "05:16:01 [App     ] Filtered depth-maps 3 (7.3%, 1s, ETA 9s)..."),  # restarts at 7 %: ignored
              (70, "05:16:30 [App     ] Fused depth-maps 20 (48.8%, 3s)..."),
              (300, "05:20:00 [App     ] Fused depth-maps 41 (100%, 9s)")]
    out = []
    for t, line in script:
        now[0] = t
        out.append(pp.line(line))
    assert out[1] is None and out[0] == 100.0
    assert seen == sorted(seen) and seen[0] < 0.05          # the 1-second phase did not fill the bar
    assert pp.last == pytest.approx(0.95)                   # capped until the program exits
    assert any(abs(x - 0.6) < 1e-6 for x in seen)           # main-phase percentage drives it when ahead of time
    assert pp.labels[:3] == ["Selected images", "Estimated depth-maps", "Filtered depth-maps"]


def _synthetic_lidar(cams, true_mpu, rep="uniformZ", noise=0.01, rot=0, seed=0):
    """Per-image LiDAR maps of the unit sphere scene in meters (scene units * true_mpu), 8-bit uniform Z with
    z_near/z_far like Object Capture, and SfM observations at random sphere points."""
    rng = np.random.default_rng(seed)
    per = []
    for c in cams:
        d = sphere_depth(c) * true_mpu  # metric camera z
        valid = d > 0
        zn, zf = float(d[valid].min()) * 0.9, float(d[valid].max()) * 1.1
        q = np.clip(np.round((d - zn) / (zf - zn) * 255), 1, 254)
        q = np.where(valid, q, 0).astype(np.uint8)
        if rep == "uniformZ-flipped":
            q = np.where(valid, 255 - q, 0).astype(np.uint8)
        dep = {"values": np.rot90(q, rot).astype(np.float32), "max": 255.0,
               "meta": {"z_near": zn, "z_far": zf, "representation_type": 2}, "mode": "L",
               "primary_size": (c.width, c.height)}
        P = rng.normal(size=(400, 3)); P /= np.linalg.norm(P, axis=1, keepdims=True)
        Xc = P @ c.R.T + c.t
        u = c.fx * Xc[:, 0] / Xc[:, 2] + c.cx
        v = c.fy * Xc[:, 1] / Xc[:, 2] + c.cy
        vis = (P @ (c.center / np.linalg.norm(c.center)) > 0.3) & (u > 2) & (v > 2) & (u < c.width - 2) & (v < c.height - 2)
        z = Xc[vis, 2] * (1 + noise * rng.normal(size=vis.sum()))
        per.append({"depth": dep, "xy": np.stack([u[vis], v[vis]], 1), "z": z, "img_wh": (c.width, c.height)})
    return per


def test_lidar_scale_recovers_metric_scale():
    from asbuilt_cloud import lidar_scale
    cams = sphere_cams(W=192, H=256, f=200.0)  # portrait, like a decoded Object Capture HEIC
    for true in (0.137, 2.5):
        r = lidar_scale.estimate_scale(_synthetic_lidar(cams, true))
        assert r["ok"], r
        assert abs(r["metersPerUnit"] / true - 1) < 0.02, r
        assert r["reading"] == "uniformZ" and r["rot90"] == 0 and r["mad"] < 0.03
    # an encoder that stores near = 255 instead of near = 0 is found by the consistency search
    r = lidar_scale.estimate_scale(_synthetic_lidar(cams, 0.5, rep="uniformZ-flipped"))
    assert r["ok"] and r["reading"] == "uniformZ-flipped" and abs(r["metersPerUnit"] / 0.5 - 1) < 0.02, r
    # depth grid stored 180 degrees rotated: found (sphere off-centre so the orientations are distinguishable)
    for c in cams:
        c.cx, c.cy = 0.62 * c.width, 0.6 * c.height
    r = lidar_scale.estimate_scale(_synthetic_lidar(cams, 0.5))
    assert r["ok"] and r["rot90"] == 0 and r["flip"] is False, r
    r = lidar_scale.estimate_scale(_synthetic_lidar(cams, 0.5, rot=2))
    assert r["ok"] and r["rot90"] == 2 and abs(r["metersPerUnit"] / 0.5 - 1) < 0.02, r


def test_lidar_scale_refuses_without_range_or_with_inconsistent_depth():
    from asbuilt_cloud import lidar_scale
    cams = sphere_cams(W=192, H=256, f=200.0)
    per = _synthetic_lidar(cams, 0.5)
    for p in per:  # integer depth without z_near/z_far: relative only
        p["depth"]["meta"] = {}
    r = lidar_scale.estimate_scale(per)
    assert not r["ok"]
    per = _synthetic_lidar(cams, 0.5)
    for k, p in enumerate(per):  # smooth depth that has nothing to do with the geometry (a tilted ramp)
        h, w = p["depth"]["values"].shape
        ramp = np.add.outer(np.linspace(1, 120, h), np.linspace(1, 130, w) * (1 if k % 2 else -1) + (130 if k % 2 == 0 else 0))
        p["depth"]["values"] = np.clip(ramp, 1, 254).astype(np.float32)
    r = lidar_scale.estimate_scale(per)
    assert not r["ok"] and "spread" in r.get("reason", ""), r
    r = lidar_scale.estimate_scale([{"depth": None, "xy": np.zeros((5, 2)), "z": np.ones(5), "img_wh": (10, 10)}] * 5)
    assert not r["ok"] and "carry LiDAR depth" in r["reason"]


def test_heic_without_depth_has_no_depth(tmp_path):
    pillow_heif = pytest.importorskip("pillow_heif")
    from PIL import Image
    from asbuilt_cloud import lidar_scale, pipeline
    pillow_heif.register_heif_opener()
    src = tmp_path / "src"
    src.mkdir()
    p = str(src / "IMG_0001.HEIC")
    Image.fromarray((np.random.default_rng(0).random((60, 80, 3)) * 255).astype("uint8")).save(p, format="HEIF")
    assert lidar_scale.read_heic_depth(p) is None
    names, sizes, mapping = pipeline.prepare_images(str(src), str(tmp_path / "out"), 2000, lambda *a: None)
    assert names == ["IMG_0001.HEIC"] and mapping == {"IMG_0001.jpg": ("IMG_0001.HEIC", (80, 60))}


def test_pipeline_failure_writes_result(tmp_path):
    from asbuilt_cloud import pipeline
    z = str(tmp_path / "empty.zip")
    with zipfile.ZipFile(z, "w") as f:
        f.writestr("Images/readme.txt", "no photos")
    r = pipeline.build(z, str(tmp_path / "o"), status_file=str(tmp_path / "s.json"), echo=False)
    assert r["ok"] is False and "photos" in r["errorMessage"]
    assert json.load(open(tmp_path / "s.json"))["state"] == "failed"
    assert json.load(open(tmp_path / "o" / "result.json"))["ok"] is False


def test_gpu_entry_with_dict_channel(tmp_path):
    from asbuilt_cloud import gpu_entry
    z = make_zip(str(tmp_path / "in.zip"))
    seen = []
    r = gpu_entry.run_job("job_x", {"detail": "phone", "obj": True}, z, str(tmp_path / "results"),
                          seen.append, stages="fake", work_root=str(tmp_path), poll=0.5)
    assert r["ok"], r
    assert os.path.isfile(tmp_path / "results" / "job_x" / "out" / "model.usdz")
    assert seen and seen[-1]["finished"]["ok"] and seen[-1]["status"]["state"] == "done"
    assert "asbuilt-cloud build" in seen[-1]["logTail"]
    assert any((p.get("status") or {}).get("state") == "processing" for p in seen)


def test_modal_app_definition_imports():
    pytest.importorskip("modal")
    import importlib
    os.environ.pop("ASBUILT_GPU", None)
    os.environ.pop("ASBUILT_ENABLE_SPLAT", None)
    m = importlib.import_module("modal_app")
    assert m.app.name == "asbuilt-recon"
    assert hasattr(m, "api") and hasattr(m, "build_cpu")
    assert not hasattr(m, "build_gpu")  # the splat GPU path is opt-in (ASBUILT_ENABLE_SPLAT=1)
    assert m.BUILD_CPUS == 16 and m.BUILD_MEMORY_MB == 32768
    assert m.OPENMVS_PATCH.is_file()


# ---------------------------------------------------------------------------------------------
# HTTP contract test


def _free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Client:
    def __init__(self, port, key=KEY):
        self.port, self.key = port, key

    def req(self, method, path, body=None, headers=None, raw=False):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=60)
        h = {"Authorization": "Bearer " + self.key} if self.key else {}
        h.update(headers or {})
        data = None
        if isinstance(body, (dict, list)):
            data = json.dumps(body).encode()
            h["Content-Type"] = "application/json"
        elif isinstance(body, bytes):
            data = body
            h.setdefault("Content-Type", "application/octet-stream")
        c.request(method, path, body=data, headers=h)
        r = c.getresponse()
        b = r.read()
        c.close()
        if raw:
            return r.status, b, dict(r.getheaders())
        return r.status, (json.loads(b) if b else None)


@pytest.fixture(scope="module")
def server(tmp_path_factory):
    import cloud_server
    data = str(tmp_path_factory.mktemp("data"))
    os.environ["ASBUILT_LOG_DIR"] = os.path.join(data, "logs")
    app = cloud_server.make_app(data, KEY, cloud_server.LocalBackend("fake"))
    app.worker.POLL_SECONDS = 0.5
    port = _free_port()
    httpd = cloud_server.serve(app, "127.0.0.1", port)
    t = threading.Thread(target=httpd.serve_forever, kwargs={"poll_interval": 0.2}, daemon=True)
    t.start()
    yield port, app
    app.worker.stopping = True
    httpd.shutdown()


def test_http_v1_flow(server, tmp_path):
    port, app = server
    c = Client(port)
    st, h = Client(port, key=None).req("GET", "/v1/health")
    assert st == 200 and h["ok"] is True and h["apiVersion"] == 1
    st, e = Client(port, key="wrong" * 10).req("GET", "/v1/jobs")
    assert st == 401 and e["error"]["code"] == "unauthorized"

    z = make_zip(str(tmp_path / "Images.zip"), n=8)
    blob = open(z, "rb").read()
    sha = hashlib.sha256(blob).hexdigest()
    chunk = 4 * 1024 * 1024
    st, up = c.req("POST", "/v1/uploads", {"captureID": "cap-1", "filename": "Images.zip", "totalBytes": len(blob),
                                           "sha256": sha, "detail": "phone", "glb": True, "obj": False,
                                           "chunkSize": chunk, "title": "cloud test"})
    assert st == 201, up
    assert up["chunkCount"] == 1 and up["receivedChunks"] == []
    uid = up["uploadID"]
    st, e = c.req("PUT", "/v1/uploads/%s/chunks/0" % uid, blob[:-1] + b"x",
                  {"X-Chunk-SHA256": hashlib.sha256(blob).hexdigest()})
    assert st == 400 and e["error"]["code"] == "chunk_sha256_mismatch"
    st, ch = c.req("PUT", "/v1/uploads/%s/chunks/0" % uid, blob, {"X-Chunk-SHA256": sha})
    assert st == 200 and ch["receivedChunks"] == [0]
    st, again = c.req("GET", "/v1/uploads/%s" % uid)
    assert st == 200 and again["receivedChunks"] == [0]
    st, done = c.req("POST", "/v1/uploads/%s/complete" % uid)
    assert st == 201, done
    jid = done["jobID"]
    st, done2 = c.req("POST", "/v1/uploads/%s/complete" % uid)
    assert st == 200 and done2["alreadyCompleted"] and done2["jobID"] == jid

    stages, t0 = set(), time.time()
    while True:
        st, job = c.req("GET", "/v1/jobs/%s" % jid)
        assert st == 200
        if job["stage"]:
            stages.add(job["stage"])
        if job["state"] in ("done", "failed"):
            break
        assert time.time() - t0 < 240, job
        time.sleep(0.5)
    assert job["state"] == "done", job
    assert job["polygons"] and job["polygons"] <= 4000
    stored = app.store.load_job(jid)  # internal fields the v1 job view doesn't expose (same as the Mac)
    assert stored["usdcheckerPassed"] is True and stored["engine"] == "asbuilt-cloud"
    assert "splatInfo" not in stored and "gpuCallID" not in stored
    assert not os.path.exists(os.path.join(app.store.job_dir(jid), "input.zip"))  # done: photos no longer needed
    names = {f["name"]: f for f in job["files"]}
    assert {"model.usdz", "recon-log.txt", "thumbnail.png", "model.glb"} <= set(names)
    assert "splat.ply" not in names  # OpenMVS (default) builds have no splat
    assert "model-obj.zip" not in names  # obj=false: dropped even though the build made one for the GLB
    assert job["glbInfo"]["triangles"] == job["polygons"]
    assert stages, "no live stage was ever reported"

    # Range download + sha
    f = names["model.usdz"]
    st, part, hd = c.req("GET", f["url"], headers={"Range": "bytes=0-99"}, raw=True)
    assert st == 206 and len(part) == 100 and hd["Content-Range"].endswith("/%d" % f["bytes"])
    st, rest, hd = c.req("GET", f["url"], headers={"Range": "bytes=100-", "If-Range": '"%s"' % f["sha256"]}, raw=True)
    assert st == 206 and hashlib.sha256(part + rest).hexdigest() == f["sha256"]
    st, glb, hd = c.req("GET", names["model.glb"]["url"], raw=True)
    assert st == 200 and glb[:4] == b"glTF" and hd["Content-Type"] == "model/gltf-binary"

    st, lst = c.req("GET", "/v1/jobs?captureID=cap-1")
    assert st == 200 and [j["jobID"] for j in lst["jobs"]] == [jid]
    st, d = c.req("DELETE", "/v1/jobs/%s" % jid)
    assert st == 200 and d["deleted"]
    st, e = c.req("GET", "/v1/jobs/%s" % jid)
    assert st == 404 and e["error"]["code"] == "job_not_found"


def test_http_failed_build_reports_plain_error(server, tmp_path):
    port, _ = server
    c = Client(port)
    z = str(tmp_path / "bad.zip")
    with zipfile.ZipFile(z, "w") as f:
        f.writestr("Images/notes.txt", "no images here")
    blob = open(z, "rb").read()
    st, up = c.req("POST", "/v1/uploads", {"captureID": "cap-2", "filename": "bad.zip", "totalBytes": len(blob),
                                           "sha256": hashlib.sha256(blob).hexdigest(), "autoComplete": True,
                                           "chunkSize": 4 * 1024 * 1024})
    assert st == 201
    st, _ = c.req("PUT", "/v1/uploads/%s/chunks/0" % up["uploadID"], blob)
    assert st == 200
    t0 = time.time()
    while True:
        st, u = c.req("GET", "/v1/uploads/%s" % up["uploadID"])
        if u.get("jobID"):
            st, job = c.req("GET", "/v1/jobs/%s" % u["jobID"])
            if job["state"] in ("done", "failed"):
                break
        assert time.time() - t0 < 60
        time.sleep(0.3)
    assert job["state"] == "failed"
    assert job["error"]["code"] == "build_failed" and "photos" in job["error"]["message"]
    # a failed build keeps its upload + log for the retention window, so the failure can be reproduced
    jdir = server[1].store.job_dir(u["jobID"])
    assert os.path.isfile(os.path.join(jdir, "input.zip")) and server[1].store.load_job(u["jobID"])["inputKept"]
    assert os.path.isfile(os.path.join(jdir, "out", "recon-log.txt"))
    assert any(f["name"] == "recon-log.txt" for f in job["files"])


# ---------------------------------------------------------------------------------------------
# Concurrency: several cloud builds at once


class GateBackend:
    """Fake cloud backend: every spawned build 'runs' until the test releases it; records the overlap."""

    def __init__(self):
        self.lock = threading.Lock()
        self.calls = {}      # call id -> {"jid", "release": Event, "reattach": bool}
        self.spawned = []    # jobIDs, in spawn order
        self.cancelled = []  # call ids
        self.active = set()
        self.max_active = 0

    def add_call(self, cid, jid):
        with self.lock:
            self.calls[cid] = {"jid": jid, "release": threading.Event()}

    def spawn(self, job, input_zip, out_dir, status_path):
        assert os.path.isfile(input_zip)
        with self.lock:
            cid = "fc-%d" % (len(self.calls) + 1)
            self.calls[cid] = {"jid": job["jobID"], "release": threading.Event()}
            self.spawned.append(job["jobID"])
        return cid

    def poll(self, call_id, job, status_path):
        c = self.calls[call_id]
        assert c["jid"] == job["jobID"]  # each slot polls its own call
        with self.lock:
            if c["release"].is_set():
                self.active.discard(call_id)
                return True, None
            self.active.add(call_id)
            self.max_active = max(self.max_active, len(self.active))
        return False, {"state": "processing", "fraction": 0.5, "stage": "densify", "message": "Building the mesh"}

    def cancel(self, call_id):
        with self.lock:
            self.cancelled.append(call_id)
            self.active.discard(call_id)
        self.calls[call_id]["release"].set()

    def fetch_outputs(self, job, out_dir):
        os.makedirs(out_dir, exist_ok=True)
        with open(os.path.join(out_dir, "model.usdz"), "wb") as f:
            f.write(b"usdz " + job["jobID"].encode())
        with open(os.path.join(out_dir, "result.json"), "w") as f:
            json.dump({"ok": True, "polygons": 1234, "textures": [], "usdcheckerPassed": True, "totalSeconds": 1.0}, f)

    def release(self, jid):
        for c in self.calls.values():
            if c["jid"] == jid:
                c["release"].set()


def _wait_for(pred, what, timeout=20):
    t0 = time.time()
    while not pred():
        assert time.time() - t0 < timeout, "timed out waiting for " + what
        time.sleep(0.05)


@pytest.fixture()
def gated_server(tmp_path):
    """A second cloud server with a GateBackend, on its own handler class (rs.Handler.app stays untouched)."""
    import cloud_server
    rs = cloud_server.rs
    prev = rs.Handler.app
    backend = GateBackend()
    app = cloud_server.make_app(str(tmp_path / "data"), KEY, backend, concurrency=3)
    rs.Handler.app = prev
    app.worker.POLL_SECONDS = 0.05
    handler = type("GatedHandler", (rs.Handler,), {"app": app})
    port = _free_port()
    httpd = rs.Server(("127.0.0.1", port), handler)
    threading.Thread(target=httpd.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True).start()
    app.worker.start()
    yield port, app, backend
    app.worker.stopping = True
    for c in backend.calls.values():
        c["release"].set()
    httpd.shutdown()


def _submit(c, blob, cap):
    sha = hashlib.sha256(blob).hexdigest()
    st, up = c.req("POST", "/v1/uploads", {"captureID": cap, "filename": "Images.zip", "totalBytes": len(blob),
                                           "sha256": sha, "detail": "phone", "chunkSize": 4 * 1024 * 1024})
    assert st == 201, up
    st, _ = c.req("PUT", "/v1/uploads/%s/chunks/0" % up["uploadID"], blob, {"X-Chunk-SHA256": sha})
    assert st == 200
    st, done = c.req("POST", "/v1/uploads/%s/complete" % up["uploadID"])
    assert st == 201, done
    return done["jobID"]


def test_cloud_runs_three_builds_at_once_and_queues_the_rest(gated_server, tmp_path):
    port, app, backend = gated_server
    c = Client(port)
    assert app.worker.concurrency == 3
    import cloud_server
    assert set(cloud_server.CLOUD_MESSAGES) == set(cloud_server.rs.MESSAGES)  # every Mac message has a cloud one
    assert not [v for v in cloud_server.rs.MESSAGES.values() if "Mac" in v]
    blob = open(make_zip(str(tmp_path / "Images.zip"), n=3), "rb").read()

    def job(jid):
        st, v = c.req("GET", "/v1/jobs/%s" % jid)
        assert st == 200
        assert "Mac" not in json.dumps(v), v  # cloud wording only
        return v

    def health():
        st, h = c.req("GET", "/v1/health")
        assert st == 200
        return h

    running = []
    for i in range(3):  # each one starts right away in its own slot
        running.append(_submit(c, blob, "cap-%d" % i))
        _wait_for(lambda: job(running[-1])["state"] == "processing", "build %d to start" % i)
    _wait_for(lambda: backend.max_active == 3, "3 overlapping builds")
    for jid in running:
        v = job(jid)
        assert v["state"] == "processing" and v["queuePosition"] == 0 and v["stage"] == "densify"
    h = health()
    assert h["processing"] is True and h["queueLength"] == 0

    # 4th and 5th wait in line (no slot), with cloud wording
    fourth = _submit(c, blob, "cap-3")
    time.sleep(1.05)  # createdAt has 1 s resolution (same-second ties go by jobID): make the line order certain
    fifth = _submit(c, blob, "cap-4")
    time.sleep(0.5)
    v4, v5 = job(fourth), job(fifth)
    assert v4["state"] == "queued" and v4["queuePosition"] == 1 and v4["message"] == "Queued in the cloud", v4
    assert v5["state"] == "queued" and v5["queuePosition"] == 2 and v5["message"] == "Queued in the cloud (2 in line)", v5
    assert backend.spawned == running and len(app.worker.running) == 3
    assert health()["queueLength"] == 2
    st, lst = c.req("GET", "/v1/jobs")
    assert sorted(j["queuePosition"] for j in lst["jobs"]) == [0, 0, 0, 1, 2] and "Mac" not in json.dumps(lst)

    # deleting a running build cancels only its call and frees its slot for the oldest queued job
    st, d = c.req("DELETE", "/v1/jobs/%s" % running[0])
    assert st == 200 and d["previousState"] == "processing"
    assert [backend.calls[x]["jid"] for x in backend.cancelled] == [running[0]]
    _wait_for(lambda: job(fourth)["state"] == "processing", "the 4th build to take the freed slot")
    assert job(fifth)["queuePosition"] == 1 and job(fifth)["message"] == "Queued in the cloud"

    # one finishes -> the 5th starts; the others keep running
    backend.release(running[1])
    _wait_for(lambda: job(running[1])["state"] == "done", "build 2 to finish")
    _wait_for(lambda: job(fifth)["state"] == "processing", "the 5th build to start")
    assert job(running[2])["state"] == "processing" and job(fourth)["state"] == "processing"

    for jid in (running[2], fourth, fifth):
        backend.release(jid)
    for jid in (running[1], running[2], fourth, fifth):
        _wait_for(lambda: job(jid)["state"] == "done", "build %s to finish" % jid)
        v = job(jid)
        assert v["progress"] == 1.0 and v["polygons"] == 1234 and v["queuePosition"] is None
        assert [f["name"] for f in v["files"] if f["name"] == "model.usdz"] == ["model.usdz"]
        stored = app.store.load_job(jid)
        assert "gpuCallID" not in stored and stored["state"] == "done"
        st, body, _ = c.req("GET", "/v1/jobs/%s/files/model.usdz" % jid, raw=True)
        assert st == 200 and body == b"usdz " + jid.encode()  # every job got its own outputs
    assert backend.max_active == 3  # never more than the limit
    assert backend.spawned == running + [fourth, fifth]
    _wait_for(lambda: not app.worker.running, "all slots to free up")
    h = health()
    assert h["processing"] is False and h["queueLength"] == 0
    assert not app.worker.cancel_requested


def test_cloud_restart_reattaches_every_running_build_first(tmp_path):
    import cloud_server
    rs = cloud_server.rs
    prev = rs.Handler.app
    backend = GateBackend()
    data = str(tmp_path / "data")
    store = rs.Store(data)

    def put(jid, state, created, call=None):
        os.makedirs(store.job_dir(jid))
        with open(os.path.join(store.job_dir(jid), "input.zip"), "wb") as f:
            f.write(b"zip")
        j = {"jobID": jid, "captureID": jid, "detail": "phone", "state": state, "progress": 0.3,
             "createdAt": created, "files": [], "restarts": 0, "message": "Building"}
        if call:
            j["gpuCallID"] = call
            backend.add_call(call, jid)
        store.save_job(j)

    # an old queued job (e.g. the limit was lowered) and three builds still running in the cloud
    put("job_old_queued", "queued", "2026-01-01T00:00:00Z")
    for i in range(3):
        put("job_running_%d" % i, "processing", "2026-01-02T00:00:0%dZ" % i, call="call-%d" % i)
    put("job_fresh_none", "processing", "2026-01-02T00:00:09Z")  # spawned nothing before the restart

    app = cloud_server.make_app(data, KEY, backend, concurrency=3)
    rs.Handler.app = prev
    app.worker.POLL_SECONDS = 0.05
    for jid in ("job_running_0", "job_running_1", "job_running_2"):
        j = app.store.load_job(jid)
        assert j["state"] == "queued" and j["gpuCallID"] and j["message"] == "Reconnecting to the cloud build"
    assert app.store.load_job("job_fresh_none")["restarts"] == 1
    app.worker.start()
    try:
        _wait_for(lambda: len(app.worker.running) == 3, "3 re-attached builds")
        assert sorted(app.worker.running) == ["job_running_0", "job_running_1", "job_running_2"]
        assert backend.spawned == []  # re-attached, nothing started over
        assert app.store.load_job("job_old_queued")["state"] == "queued"
        for i in range(3):
            backend.release("job_running_%d" % i)
        _wait_for(lambda: all(app.store.load_job("job_running_%d" % i)["state"] == "done" for i in range(3)),
                  "re-attached builds to finish")
        _wait_for(lambda: sorted(backend.spawned) == ["job_fresh_none", "job_old_queued"], "the other two to start")
        for jid in ("job_old_queued", "job_fresh_none"):
            backend.release(jid)
        _wait_for(lambda: all(j["state"] == "done" for j in app.store.all_jobs()), "everything to finish")
        assert backend.max_active <= 3
    finally:
        app.worker.stopping = True
        for c in backend.calls.values():
            c["release"].set()


def test_modal_backend_copies_outputs_without_reloading_the_volume(tmp_path):
    """fetch_outputs reads results/<id>/out through the volume service (no Volume.reload(): it remounts /data
    under the other build slots), keeps the folder layout, then removes results/<id>."""
    import enum
    import types
    from modal_backend import ModalBackend

    Kind = enum.Enum("Kind", "FILE DIRECTORY")
    blobs = {"results/job_x/out/model.usdz": b"usdz", "results/job_x/out/obj/tex/d.jpg": b"jpg",
             "results/job_x/out/result.json": b"{}"}

    class FakeVolume:
        removed = []

        def reload(self):
            raise AssertionError("the API container must not reload the volume")

        def listdir(self, path, recursive=False):
            assert path == "results/job_x/out" and recursive
            yield types.SimpleNamespace(path="results/job_x/out/obj", type=Kind.DIRECTORY)
            for k in blobs:
                yield types.SimpleNamespace(path=k, type=Kind.FILE)

        def read_file_into_fileobj(self, path, f):
            f.write(blobs[path])

        def remove_file(self, path, recursive=False):
            self.removed.append((path, recursive))

    be = object.__new__(ModalBackend)
    be.volume, be.status, be.volume_lock = FakeVolume(), {"job_x": {"status": {}}}, threading.Lock()
    out = tmp_path / "jobs" / "job_x" / "out"
    assert be.fetch_outputs({"jobID": "job_x"}, str(out)) == 4
    assert (out / "model.usdz").read_bytes() == b"usdz" and (out / "obj" / "tex" / "d.jpg").read_bytes() == b"jpg"
    assert not list(out.rglob("*.part"))
    assert FakeVolume.removed == [("results/job_x", True)] and "job_x" not in be.status
