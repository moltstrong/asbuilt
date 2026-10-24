#!/usr/bin/env python3
"""Local protocol tests for recon_server.py (no photogrammetry: uses a fake CLI).

Starts the server on a random port with a temp data dir + temp key, then checks auth, rate
limiting, chunk validation, resume, whole-file sha, job listing, Range downloads, restart
requeue, delete, and the disk-space/size guards.
"""
import hashlib
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "scripts"))
import importlib.util  # noqa: E402

spec = importlib.util.spec_from_file_location("rc", os.path.join(HERE, "..", "..", "scripts", "recon-client.py"))
rc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rc)

FAKE_CLI = r'''#!/bin/bash
# fake asbuilt-recon: build <zip> --detail D --out OUT --status-file S ... ; sleeps $FAKE_SECONDS
out=""; status=""; obj=0; title=""
echo "$@" > "$(dirname "$0")/last-args.txt"
while [ $# -gt 0 ]; do case "$1" in --out) out="$2"; shift;; --status-file) status="$2"; shift;; --title) title="$2"; shift;; --obj) obj=1;; esac; shift; done
mkdir -p "$out"
if [ "$obj" = 1 ]; then
  cp -R "$(dirname "$0")/obj-fixture" "$out/obj"
  case "$title" in *broken-obj*) printf '# no faces\nv 0 0 0\n' > "$out/obj/baked_mesh_test.obj";; esac
  (cd "$out" && zip -qr model-obj.zip obj)
fi
for i in 1 2 3 4 5 6 7 8 9 10; do
  echo "{\"state\":\"processing\",\"fraction\":0.$i,\"stage\":\"meshGeneration\",\"etaSeconds\":$((10-i)),\"message\":\"Building\"}" > "$status"
  sleep ${FAKE_SECONDS:-0.2}
done
head -c 3000000 /dev/urandom > "$out/model.usdz"
echo "fake log" > "$out/recon-log.txt"
echo '{"ok":true,"polygons":12345,"textures":[{"name":"t.png","width":8192,"height":8192,"bytes":1}],"usdcheckerPassed":true}' > "$out/result.json"
exit 0
'''

_rc_download = rc.download


# Adapters to the current recon-client.py API (its helpers were reshaped for the e2e report).
class _QuietReport:
    def note(self, msg):
        pass


def create_upload(c, path, capture, detail, sha=None, title=None, **extra):
    body = {"captureID": capture, "filename": os.path.basename(path), "totalBytes": os.path.getsize(path),
            "sha256": sha or rc.sha256_file(path), "detail": detail}
    if title:
        body["title"] = title
    body.update(extra)
    return c.request("POST", "/v1/uploads", body)


def put_chunks(c, path, up, only=None, log=None):
    up = dict(up)
    if only is not None:
        up["receivedChunks"] = [n for n in range(up["chunkCount"]) if n not in only]
    rc.upload_chunks(c, path, up, _QuietReport())


def download(c, jid, name, dest, interrupt_at=None, log=None):
    """-> (bytes_this_call, None, X-Content-SHA256, status) like the old helper."""
    st, n, _, h = _rc_download(c, jid, name, dest, interrupt_at=interrupt_at)
    return n, None, rc.hdr(h, "X-Content-SHA256") if h else None, st


rc.create_upload, rc.put_chunks, rc.download = create_upload, put_chunks, download

PASS, FAIL = [], []


def check(name, cond, info=""):
    (PASS if cond else FAIL).append(name)
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  " + str(info)[:300]))


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def start(tmp, port, extra_env=None):
    env = dict(os.environ, ASBUILT_RECON_BIN=os.path.join(tmp, "fake-cli"), FAKE_SECONDS="0.2")
    env.update(extra_env or {})
    p = subprocess.Popen([sys.executable, "-u", os.path.join(HERE, "recon_server.py"), "--port", str(port), "--data",
                          os.path.join(tmp, "data"), "--key-file", os.path.join(tmp, "key"), "--log-dir", os.path.join(tmp, "logs"),
                          "--config", os.path.join(tmp, "none.json")], env=env)
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
            return p
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("server didn't start")


def tiny_png(w=4, h=4):
    import struct
    import zlib
    raw = b"".join(b"\x00" + bytes([200, 100, 50]) * w for _ in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + \
        chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


# Apple-style OBJ set: v/vt/vn, one quad (fan-split into 2 triangles), one triangle with relative
# (negative) indices, a material with diffuse + normal + AO maps.
FIXTURE_OBJ = """mtllib baked_mesh_test.mtl
v 0 0 0
v 1 0 0
v 1 1 0
v 0 1 0
v 0 0 1
vt 0 0
vt 1 0
vt 1 1
vt 0 1
vt 0.5 0.5
vn 0 0 1
vn 0 1 0
usemtl g0
f 1/1/1 2/2/1 3/3/1 4/4/1
f -5/-5/-1 -4/-4/-1 -1/-1/-2
"""
FIXTURE_MTL = """newmtl g0
map_Kd baked_mesh_test_tex0.png
norm baked_mesh_test_norm0.png
map_ao baked_mesh_test_ao0.png
"""


def write_obj_fixture(d):
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "baked_mesh_test.obj"), "w") as f:
        f.write(FIXTURE_OBJ)
    with open(os.path.join(d, "baked_mesh_test.mtl"), "w") as f:
        f.write(FIXTURE_MTL)
    for m in ("tex0", "norm0", "ao0"):
        with open(os.path.join(d, "baked_mesh_test_%s.png" % m), "wb") as f:
            f.write(tiny_png())


def parse_glb(data):
    """-> (gltf JSON, BIN chunk) of a binary glTF, or raises."""
    import struct
    magic, version, total = struct.unpack_from("<4sII", data, 0)
    assert magic == b"glTF" and version == 2 and total == len(data), (magic, version, total, len(data))
    jlen, jtype = struct.unpack_from("<I4s", data, 12)
    assert jtype == b"JSON" and jlen % 4 == 0
    gltf = json.loads(data[20:20 + jlen])
    blen, btype = struct.unpack_from("<I4s", data, 20 + jlen)
    assert btype == b"BIN\0" and blen % 4 == 0
    return gltf, data[28 + jlen:28 + jlen + blen]


def check_glb_structure(name, data, want_tris):
    import struct
    try:
        g, b = parse_glb(data)
        prim = g["meshes"][0]["primitives"][0]
        acc = g["accessors"]
        tris = sum(acc[p["indices"]]["count"] for p in g["meshes"][0]["primitives"]) // 3
        nv = acc[prim["attributes"]["POSITION"]]["count"]
        ind_acc = acc[prim["indices"]]
        bv = g["bufferViews"][ind_acc["bufferView"]]
        idx = struct.unpack_from("<%dI" % ind_acc["count"], b, bv["byteOffset"])
        mat = g["materials"][prim["material"]]
        imgs = [g["images"][g["textures"][i]["source"]]["mimeType"] for i in (
            mat["pbrMetallicRoughness"]["baseColorTexture"]["index"], mat["normalTexture"]["index"], mat["occlusionTexture"]["index"])]
        ok = (tris == want_tris and max(idx) < nv and set(prim["attributes"]) == {"POSITION", "NORMAL", "TEXCOORD_0"}
              and imgs == ["image/png"] * 3 and all(v["byteOffset"] + v["byteLength"] <= len(b) for v in g["bufferViews"])
              and acc[0]["min"] == [0, 0, 0] and acc[0]["max"] == [1, 1, 1])
        check(name, ok, (tris, nv, max(idx), prim["attributes"], imgs, acc[0].get("min"), acc[0].get("max")))
        return g
    except Exception as e:  # noqa: BLE001 - report any structural problem as a failed check
        check(name, False, repr(e))
        return None


def wait_state(c, jid, states, timeout=60):
    t0 = time.time()
    while time.time() - t0 < timeout:
        st, _, j = c.request("GET", "/v1/jobs/" + jid)
        if j.get("state") in states:
            return j
        time.sleep(0.2)
    return j


def main():
    tmp = tempfile.mkdtemp(prefix="recon-srv-test-")
    srv = None
    try:
        with open(os.path.join(tmp, "fake-cli"), "w") as f:
            f.write(FAKE_CLI)
        os.chmod(os.path.join(tmp, "fake-cli"), 0o755)
        write_obj_fixture(os.path.join(tmp, "obj-fixture"))

        # obj_to_glb directly (stdlib converter): quad fan-split + negative indices + 3 maps.
        spec2 = importlib.util.spec_from_file_location("recon_server", os.path.join(HERE, "recon_server.py"))
        rs = importlib.util.module_from_spec(spec2)
        spec2.loader.exec_module(rs)
        gdest = os.path.join(tmp, "direct.glb")
        info = rs.obj_to_glb(os.path.join(tmp, "obj-fixture"), gdest)
        check("obj_to_glb stats", info["triangles"] == 3 and info["materials"] == 1 and len(info["textures"]) == 3, info)
        with open(gdest, "rb") as fg:
            check_glb_structure("obj_to_glb writes a valid GLB", fg.read(), 3)
        key = hashlib.sha256(os.urandom(32)).hexdigest()
        with open(os.path.join(tmp, "key"), "w") as f:
            f.write(key)
        os.chmod(os.path.join(tmp, "key"), 0o600)
        # 70 MiB test zip -> 3 chunks (32 + 32 + 6)
        z = os.path.join(tmp, "photos.zip")
        with open(z, "wb") as f:
            f.write(b"PK\x03\x04" + os.urandom(70 * 1024 * 1024 - 4))
        sha = rc.sha256_file(z)
        port = free_port()
        srv = start(tmp, port)
        base = "http://127.0.0.1:%d" % port
        c = rc.Client(base, key)
        quiet = lambda *a: None

        st, _, h = c.request("GET", "/v1/health", auth=False)
        check("health no auth", st == 200 and h["ok"] is True)
        st, _, d = c.request("POST", "/v1/diagnostics", {"captureID": "CAP-1", "event": "chunk_failed", "errorCode": -1005,
                                                          "errorDomain": "NSURLErrorDomain", "chunk": 3, "message": "x" * 900})
        check("diagnostics accepted", st == 200 and d.get("ok") is True, (st, d))
        st, _, d = c.request("POST", "/v1/diagnostics", {"captureID": "CAP-1"})
        check("diagnostics needs event", st == 400 and d["error"]["code"] == "invalid_field", (st, d))
        st, _, d = c.request("POST", "/v1/diagnostics", {"event": "x"}, auth=False)
        check("diagnostics needs auth", st == 401, st)
        diag = os.path.join(tmp, "logs", "phone-diagnostics.jsonl")
        line = open(diag).read().strip().splitlines()[-1] if os.path.exists(diag) else "{}"
        rec = json.loads(line)
        check("diagnostics written + message capped", rec.get("errorCode") == -1005 and len(rec.get("message", "")) == 500, line[:120])
        st, hd, e = c.request("GET", "/v1/jobs", auth=False)
        check("401 without key", st == 401 and e["error"]["code"] == "unauthorized" and "WWW-Authenticate" in hd)
        st, _, e = c.request("GET", "/v1/jobs", auth="0" * 64)
        check("401 wrong key", st == 401)
        st, _, e = c.request("POST", "/v1/uploads", {"captureID": "x"}, auth="nope")
        check("401 before body validation", st == 401)

        st, _, e = c.request("POST", "/v1/uploads", {"captureID": "cap1", "filename": "p.zip", "totalBytes": 9 * 1024 ** 3, "sha256": sha})
        check("413 over 8 GB", st == 413 and e["error"]["code"] == "upload_too_large")
        st, _, e = c.request("POST", "/v1/uploads", {"captureID": "cap1", "filename": "p.zip", "totalBytes": 10, "sha256": "zz"})
        check("400 bad sha field", st == 400 and e["error"]["field"] == "sha256")
        st, _, e = c.request("POST", "/v1/uploads", {"captureID": "cap1", "filename": "p.zip", "totalBytes": 10, "sha256": sha, "detail": "ultra"})
        check("400 bad detail", st == 400 and e["error"]["field"] == "detail")
        free = shutil.disk_usage(tmp).free
        st, _, e = c.request("POST", "/v1/uploads", {"captureID": "cap1", "filename": "p.zip", "totalBytes": min(free // 2, 8 * 1024 ** 3 - 1) if free // 2 < 8 * 1024 ** 3 else 8 * 1024 ** 3, "sha256": sha})
        check("507 when < 3x free (or 201 if disk is huge)", (st == 507 and e["error"]["code"] == "insufficient_storage") or (st == 201 and free > 24 * 1024 ** 3), (st, e))
        if st == 201:
            c.request("DELETE", "/v1/uploads/" + e["uploadID"])

        st, _, up = rc.create_upload(c, z, "cap1", "full", sha=sha, title="Pump room valve")
        check("201 create upload", st == 201 and up["chunkSize"] == 32 * 1024 * 1024 and up["chunkCount"] == 3 and up["receivedChunks"] == [], up)
        uid = up["uploadID"]

        # wrong size chunk
        st, _, e = c.request("PUT", "/v1/uploads/%s/chunks/0" % uid, body=b"x" * 100)
        check("400 chunk size mismatch", st == 400 and e["error"]["code"] == "chunk_size_mismatch")
        # bad per-chunk sha
        with open(z, "rb") as f:
            data0 = f.read(up["chunkSize"])
        st, _, e = c.request("PUT", "/v1/uploads/%s/chunks/0" % uid, body=data0, headers={"X-Chunk-SHA256": "0" * 64})
        check("400 chunk sha mismatch", st == 400 and e["error"]["code"] == "chunk_sha256_mismatch")
        st, _, e = c.request("PUT", "/v1/uploads/%s/chunks/7" % uid, body=b"x")
        check("400 chunk index out of range", st == 400 and e["error"]["code"] == "invalid_chunk_index")

        # upload chunk 0 only ("interrupted"), then resume via GET
        rc.put_chunks(c, z, up, only={0}, log=quiet)
        st, _, g = c.request("GET", "/v1/uploads/" + uid)
        check("GET upload shows chunk 0", st == 200 and g["receivedChunks"] == [0] and g["receivedBytes"] == up["chunkSize"])
        st, _, e = c.request("POST", "/v1/uploads/%s/complete" % uid)
        check("409 complete with missing chunks", st == 409 and e["error"]["missingChunks"] == [1, 2])
        # idempotent re-PUT of chunk 0
        st, _, e = c.request("PUT", "/v1/uploads/%s/chunks/0" % uid, body=data0, headers={"X-Chunk-SHA256": hashlib.sha256(data0).hexdigest()})
        check("re-PUT chunk idempotent", st == 200 and e["receivedChunks"] == [0])
        rc.put_chunks(c, z, g, log=quiet)
        st, _, done = c.request("POST", "/v1/uploads/%s/complete" % uid)
        check("201 complete", st == 201 and done["jobID"].startswith("job_"), done)
        jid = done["jobID"]
        st, _, again = c.request("POST", "/v1/uploads/%s/complete" % uid)
        check("complete is idempotent", st == 200 and again["jobID"] == jid and again["alreadyCompleted"])
        st, _, e = c.request("PUT", "/v1/uploads/%s/chunks/0" % uid, body=data0)
        check("409 chunk after complete", st == 409)

        # bad whole-file sha
        st, _, bad = rc.create_upload(c, z, "cap-bad", "full", sha="a" * 64)
        rc.put_chunks(c, z, bad, log=quiet)
        st, _, e = c.request("POST", "/v1/uploads/%s/complete" % bad["uploadID"])
        check("422 whole-file sha mismatch", st == 422 and e["error"]["code"] == "sha256_mismatch")
        st, _, g = c.request("GET", "/v1/uploads/" + bad["uploadID"])
        check("chunks discarded after sha mismatch", g["receivedChunks"] == [] and g["state"] == "open")

        j = wait_state(c, jid, ("processing", "done"))
        check("job starts processing", j["state"] in ("processing", "done"), j)
        if j["state"] == "processing":
            check("processing has progress/stage/eta", 0 <= j["progress"] <= 1 and j["queuePosition"] == 0, j)
        j = wait_state(c, jid, ("done", "failed"))
        check("job done", j["state"] == "done" and j["polygons"] == 12345 and j["title"] == "Pump room valve", j)
        f = {x["name"]: x for x in j["files"]}
        check("files listed with sha", "model.usdz" in f and len(f["model.usdz"]["sha256"]) == 64 and f["model.usdz"]["url"].endswith("/files/model.usdz"))

        # Range download with interruption + resume
        dest = os.path.join(tmp, "dl.usdz")
        n1, _, _, s1 = rc.download(c, jid, "model.usdz", dest, interrupt_at=1_000_000, log=quiet)
        n2, _, shah, s2 = rc.download(c, jid, "model.usdz", dest, log=quiet)
        check("range resume 206", s1 == "interrupted" and s2 == 206 and n1 + n2 == f["model.usdz"]["bytes"], (n1, n2, s1, s2))
        check("downloaded sha matches", rc.sha256_file(dest) == f["model.usdz"]["sha256"] == shah)
        st, hd, body = c.request("GET", "/v1/jobs/%s/files/model.usdz" % jid, headers={"Range": "bytes=-10"}, raw=True)
        check("suffix range", st == 206 and len(body) == 10 and hd.get("Content-Range", "").endswith("/%d" % f["model.usdz"]["bytes"]))
        st, hd, body = c.request("GET", "/v1/jobs/%s/files/model.usdz" % jid, headers={"Range": "bytes=999999999-"}, raw=True)
        check("416 past end", st == 416)
        st, _, e = c.request("GET", "/v1/jobs/%s/files/../../key" % jid)
        check("no path traversal", st in (404, 400))
        st, _, e = c.request("GET", "/v1/jobs/%s/files/model-obj.zip" % jid)
        check("404 missing file", st == 404 and e["error"]["code"] == "file_not_found")

        st, _, lst = c.request("GET", "/v1/jobs?captureID=cap1")
        check("list by captureID", st == 200 and [x["jobID"] for x in lst["jobs"]] == [jid])

        # Phone preset + autoComplete: the phone's background URLSession can't call /complete, so the
        # server assembles and enqueues as soon as the last chunk lands.
        st, _, pu = c.request("POST", "/v1/uploads", {"captureID": "cap-phone", "filename": "Images.zip",
                                                       "totalBytes": os.path.getsize(z), "sha256": sha,
                                                       "detail": "phone", "autoComplete": True, "title": "Valve"})
        check("201 phone + autoComplete", st == 201 and pu["detail"] == "phone" and pu["autoComplete"] is True, pu)
        rc.put_chunks(c, z, pu, log=quiet)
        pj = None
        for _ in range(100):
            st, _, g = c.request("GET", "/v1/uploads/" + pu["uploadID"])
            if g.get("jobID"):
                pj = g["jobID"]
                break
            time.sleep(0.1)
        check("upload auto-completed into a job", pj is not None and g["state"] == "completed", g)
        if pj:
            st, _, again = c.request("POST", "/v1/uploads/%s/complete" % pu["uploadID"])
            check("explicit complete after auto-complete is idempotent", st == 200 and again["jobID"] == pj, again)
            j = wait_state(c, pj, ("done", "failed"))
            check("phone job done", j["state"] == "done" and j["detail"] == "phone", j)
            with open(os.path.join(tmp, "last-args.txt")) as fa:
                last = fa.read()
            check("phone preset = custom 250k + 8K diffuse/normal jpeg",
                  "--detail custom --texture 8k --max-polys 250000 --maps diffuse,normal --texture-format jpeg:0.9" in last, last)

        # Backward compatibility: a job created without glb never gets --obj or model.glb.
        with open(os.path.join(tmp, "last-args.txt")) as fa:
            check("no glb/obj -> no --obj flag", "--obj" not in fa.read())
        st, _, e = c.request("POST", "/v1/uploads", {"captureID": "cap-g", "filename": "Images.zip", "totalBytes": 10,
                                                      "sha256": sha, "glb": "yes"})
        check("400 glb wrong type", st == 400 and e["error"]["field"] == "glb", (st, e))
        st, _, e = c.request("POST", "/v1/uploads", {"captureID": "cap-g", "filename": "Images.zip", "totalBytes": 10,
                                                      "sha256": sha, "glb": True, "glbTextureSize": 3000})
        check("400 bad glbTextureSize", st == 400 and e["error"]["field"] == "glbTextureSize", (st, e))

        # Android: detail=phone + glb -> server builds with --obj, converts to model.glb, lists it with sha.
        st, _, gu = c.request("POST", "/v1/uploads", {"captureID": "cap-android", "filename": "Images.zip",
                                                       "totalBytes": os.path.getsize(z), "sha256": sha, "detail": "phone",
                                                       "autoComplete": True, "glb": True, "chunkSize": 8 * 1024 * 1024})
        check("201 glb upload", st == 201 and gu.get("glb") is True and gu["chunkCount"] == 9, gu)
        rc.put_chunks(c, z, gu, log=quiet)
        gj = None
        for _ in range(100):
            st, _, g = c.request("GET", "/v1/uploads/" + gu["uploadID"])
            if g.get("jobID"):
                gj = g["jobID"]
                break
            time.sleep(0.1)
        j = wait_state(c, gj, ("done", "failed")) if gj else {}
        names = [x["name"] for x in j.get("files", [])]
        check("glb job done, model.glb listed, OBJ intermediate not listed",
              j.get("state") == "done" and "model.glb" in names and "model.usdz" in names and "model-obj.zip" not in names
              and j.get("glb") is True and (j.get("glbInfo") or {}).get("triangles") == 3, j)
        with open(os.path.join(tmp, "last-args.txt")) as fa:
            check("glb job built with --obj", "--obj" in fa.read())
        gf = {x["name"]: x for x in j.get("files", [])}
        if "model.glb" in gf:
            st, hd, body = c.request("GET", gf["model.glb"]["url"], raw=True)
            check("model.glb download: content type + sha", st == 200 and hd.get("Content-Type") == "model/gltf-binary"
                  and hashlib.sha256(body).hexdigest() == gf["model.glb"]["sha256"] == hd.get("X-Content-SHA256"), (st, hd))
            check_glb_structure("downloaded model.glb is a valid textured GLB", body, 3)
            st, hd, body = c.request("GET", gf["model.glb"]["url"], headers={"Range": "bytes=12-"}, raw=True)
            check("model.glb range resume", st == 206 and len(body) == gf["model.glb"]["bytes"] - 12, st)
            jd = os.path.join(tmp, "data", "jobs", gj, "out")
            check("OBJ intermediate removed from disk", not os.path.exists(os.path.join(jd, "obj")) and not os.path.exists(os.path.join(jd, "model-obj.zip")))

        # glb + obj together keeps both; a broken OBJ never fails the build (USDZ still delivered).
        st, _, bu = rc.create_upload(c, z, "cap-glb-broken", "phone", sha=sha, title="broken-obj", glb=True, obj=True, autoComplete=True)
        rc.put_chunks(c, z, bu, log=quiet)
        bj = None
        for _ in range(100):
            st, _, g = c.request("GET", "/v1/uploads/" + bu["uploadID"])
            if g.get("jobID"):
                bj = g["jobID"]
                break
            time.sleep(0.1)
        j = wait_state(c, bj, ("done", "failed")) if bj else {}
        names = [x["name"] for x in j.get("files", [])]
        check("broken OBJ: job still done with usdz + obj zip, no glb, glbError set",
              j.get("state") == "done" and "model.usdz" in names and "model-obj.zip" in names and "model.glb" not in names
              and (j.get("glbError") or {}).get("code") == "glb_failed", j)

        # Restart mid-queue: two jobs, slow fake; kill server while job A processes; B queued.
        srv.send_signal(signal.SIGTERM)
        srv.wait(10)
        srv = start(tmp, port, {"FAKE_SECONDS": "1"})
        c.reset()
        jobs = []
        for cap in ("capA", "capB"):
            st, _, u = rc.create_upload(c, z, cap, "full", sha=sha)
            rc.put_chunks(c, z, u, log=quiet)
            jobs.append(c.request("POST", "/v1/uploads/%s/complete" % u["uploadID"])[2]["jobID"])
        a = wait_state(c, jobs[0], ("processing",))
        b = c.request("GET", "/v1/jobs/" + jobs[1])[2]
        check("second job queued at position 1", b["state"] == "queued" and b["queuePosition"] == 1, b)
        srv.kill()  # hard crash
        srv.wait(10)
        srv = start(tmp, port, {"FAKE_SECONDS": "0.2"})
        c.reset()
        a = c.request("GET", "/v1/jobs/" + jobs[0])[2]
        check("crashed job requeued", a["state"] in ("queued", "processing") and a["restarts"] == 1, a)
        a = wait_state(c, jobs[0], ("done", "failed"))
        b = wait_state(c, jobs[1], ("done", "failed"))
        check("both jobs finish after restart", a["state"] == "done" and b["state"] == "done", (a["state"], b["state"]))

        st, _, d = c.request("DELETE", "/v1/jobs/" + jobs[1])
        check("delete job", st == 200 and d["deleted"])
        st, _, _ = c.request("GET", "/v1/jobs/" + jobs[1])
        check("deleted job 404", st == 404)

        # Rate limit: 10 bad keys -> 429
        statuses = [c.request("GET", "/v1/jobs", auth="bad%02d" % i)[0] for i in range(11)]
        check("rate limit after 10 failures", statuses[:10] == [401] * 10 and statuses[10] == 429, statuses)
        st, hd, e = c.request("GET", "/v1/jobs")
        check("locked out even with good key", st == 429 and "Retry-After" in hd)

        srv.send_signal(signal.SIGTERM)
        srv.wait(10)
        logtxt = open(os.path.join(tmp, "logs", "server.log")).read()
        check("key never logged", key not in logtxt)
    finally:
        if srv and srv.poll() is None:
            srv.kill()
            srv.wait(10)
        shutil.rmtree(tmp, ignore_errors=True)
    print("\n%d passed, %d failed" % (len(PASS), len(FAIL)))
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
