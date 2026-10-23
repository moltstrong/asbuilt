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
out=""; status=""
while [ $# -gt 0 ]; do case "$1" in --out) out="$2"; shift;; --status-file) status="$2"; shift;; esac; shift; done
mkdir -p "$out"
for i in 1 2 3 4 5 6 7 8 9 10; do
  echo "{\"state\":\"processing\",\"fraction\":0.$i,\"stage\":\"meshGeneration\",\"etaSeconds\":$((10-i)),\"message\":\"Building\"}" > "$status"
  sleep ${FAKE_SECONDS:-0.2}
done
head -c 3000000 /dev/urandom > "$out/model.usdz"
echo "fake log" > "$out/recon-log.txt"
echo '{"ok":true,"polygons":12345,"textures":[{"name":"t.png","width":8192,"height":8192,"bytes":1}],"usdcheckerPassed":true}' > "$out/result.json"
exit 0
'''

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
