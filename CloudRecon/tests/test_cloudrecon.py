"""CloudRecon tests: run on a Mac/Linux box without a GPU (pytest CloudRecon/tests -q).

* stage tests: TSDF on a synthetic sphere, USDZ export validated by usd-core's validators,
* pipeline test: fake GPU stages (synthetic SfM + splat) through the *real* mesh/texture/export code,
* HTTP test: cloud_server (recon_server.py's handler + CloudWorker + LocalBackend 'fake') driven through the
  asbuilt-recon v1 flow with stdlib http.client: health, auth 401, create upload, chunk PUT with sha,
  resume (GET upload), complete, job polling with stage/progress, Range download + sha256, model.glb
  conversion (recon_server.obj_to_glb), splat.ply download, job list, delete,
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


def test_pipeline_with_fake_gpu_stages(tmp_path):
    from asbuilt_cloud import pipeline, runner
    z = make_zip(str(tmp_path / "in.zip"))
    out = str(tmp_path / "job" / "out")
    st = str(tmp_path / "job" / "status.json")
    r = pipeline.build(z, out, detail="phone", status_file=st, stages=runner.FakeStages(), echo=False,
                       max_side=400, steps=10, tris_override=4000, texture_px_override=512)
    assert r["ok"], r
    assert 2000 < r["polygons"] <= 4000
    for name in ("model.usdz", "splat.ply", "thumbnail.png", "recon-log.txt", "result.json"):
        assert os.path.isfile(os.path.join(out, name)), name
    s = json.load(open(st))
    assert s["state"] == "done" and s["fraction"] == 1.0
    assert r["usdcheckerPassed"] is True
    assert r["splat"]["gaussians"] == 20000


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
    m = importlib.import_module("modal_app")
    assert m.app.name == "asbuilt-recon"
    assert hasattr(m, "api") and hasattr(m, "build_gpu")
    assert m.GPU == "L40S"


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
    assert stored["splatInfo"]["gaussians"] == 20000 and "gpuCallID" not in stored
    names = {f["name"]: f for f in job["files"]}
    assert {"model.usdz", "recon-log.txt", "thumbnail.png", "model.glb", "splat.ply"} <= set(names)
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
    st, ply, _ = c.req("GET", names["splat.ply"]["url"], raw=True)
    assert st == 200 and ply.startswith(b"ply")

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
