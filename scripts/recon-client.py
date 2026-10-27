#!/usr/bin/env python3
"""Acts like the AsBuilt iPhone app against an asbuilt-recon server (contract: MacRecon/API.md).

  recon-client.py health | job <jobID> | jobs --capture ID
  recon-client.py e2e <photos.zip> --small <small.zip> [--restart-cmd CMD] [--out DIR]

Base URL: --base or ~/.config/asbuilt-recon/base_url. Key: ~/.config/asbuilt-recon/api_key (never printed).
`e2e` runs the full scripted phone test and writes <out>/e2e-report.json:
  health; 401 (no key, wrong key); per-chunk sha mismatch (400); whole-file sha mismatch (422);
  chunked upload interrupted mid-chunk and resumed from GET /v1/uploads/{id}; complete -> job;
  second job queued behind it; server restart while the first job is processing (--restart-cmd) ->
  job requeued and finished; 5 s polling; Range-resumed download + sha256 check; usdchecker;
  list by captureID; DELETE job -> 404.
"""
import argparse
import hashlib
import http.client
import json
import os
import socket
import subprocess
import sys
import time
import urllib.parse

CONF = os.path.expanduser("~/.config/asbuilt-recon")


def key():
    with open(os.path.join(CONF, "api_key")) as f:
        return f.read().strip()


_ip_cache = {}


def resolve(host):
    """System resolver first; fall back to 1.1.1.1 (a home router may cache NXDOMAIN for a new
    trycloudflare hostname). TLS still verifies the certificate against the hostname."""
    if host in _ip_cache:
        return _ip_cache[host]
    try:
        ip = socket.getaddrinfo(host, 443, socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
    except OSError:
        out = subprocess.run(["/usr/bin/dig", "+short", host, "@1.1.1.1"], capture_output=True, text=True, timeout=15).stdout.split()
        ip = next((x for x in out if x.count(".") == 3 and x.replace(".", "").isdigit()), None)
        if not ip:
            raise
    _ip_cache[host] = ip
    return ip


class PinnedHTTPSConnection(http.client.HTTPSConnection):
    def connect(self):
        sock = socket.create_connection((resolve(self.host), self.port or 443), self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


class Client:
    def __init__(self, base, api_key, timeout=300):
        u = urllib.parse.urlsplit(base)
        self.scheme, self.host, self.port = u.scheme, u.hostname, u.port
        self.prefix = u.path.rstrip("/")
        self.key = api_key
        self.timeout = timeout
        self.conn = None

    def _conn(self):
        if self.conn is None:
            if self.scheme == "https":
                self.conn = PinnedHTTPSConnection(self.host, self.port, timeout=self.timeout)
            else:
                self.conn = http.client.HTTPConnection(self.host, self.port, timeout=self.timeout)
        return self.conn

    def reset(self):
        if self.conn:
            self.conn.close()
        self.conn = None

    def request(self, method, path, body=None, headers=None, auth=True, raw=False, stream_to=None, retries=3):
        h = {"User-Agent": "AsBuilt-test/1.0"}
        if auth:
            h["Authorization"] = "Bearer " + (self.key if auth is True else auth)
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
            h["Content-Type"] = "application/json"
        h.update(headers or {})
        for attempt in range(retries):
            try:
                c = self._conn()
                c.request(method, self.prefix + path, body=body, headers=h)
                r = c.getresponse()
                if stream_to is not None:
                    n = 0
                    while True:
                        b = r.read(1 << 20)
                        if not b:
                            break
                        stream_to(b)
                        n += len(b)
                    return r.status, dict(r.getheaders()), n
                data = r.read()
                if (r.getheader("Connection") or "").lower() == "close":
                    self.reset()
                if raw:
                    return r.status, dict(r.getheaders()), data
                try:
                    return r.status, dict(r.getheaders()), json.loads(data or b"null")
                except ValueError:
                    return r.status, dict(r.getheaders()), {"_raw": data[:500].decode("utf-8", "replace")}
            except (http.client.RemoteDisconnected, ConnectionError, http.client.CannotSendRequest,
                    http.client.BadStatusLine, OSError):
                self.reset()
                if attempt == retries - 1:
                    raise
                time.sleep(2)

    def put_partial(self, path, data, cut):
        """Start a chunk PUT with the full Content-Length, send only `cut` bytes, then drop the
        connection, like a phone losing signal mid-chunk."""
        self.reset()
        c = self._conn()
        c.putrequest("PUT", self.prefix + path)
        c.putheader("Authorization", "Bearer " + self.key)
        c.putheader("Content-Type", "application/octet-stream")
        c.putheader("Content-Length", str(len(data)))
        c.putheader("X-Chunk-SHA256", hashlib.sha256(data).hexdigest())
        c.endheaders()
        c.send(data[:cut])
        self.reset()


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(4 << 20), b""):
            h.update(b)
    return h.hexdigest()


def hdr(h, name):
    for k, v in h.items():
        if k.lower() == name.lower():
            return v
    return None


class Report:
    def __init__(self):
        self.checks = []
        self.data = {}
        self.t0 = time.time()

    def check(self, name, ok, detail=""):
        self.checks.append({"name": name, "ok": bool(ok), "detail": detail})
        print("%s %-55s %s" % ("PASS" if ok else "FAIL", name, detail), flush=True)
        return ok

    def note(self, msg):
        print("   [%6.1fs] %s" % (time.time() - self.t0, msg), flush=True)


def upload_chunks(c, path, up, rep, interrupt_chunk=None):
    """PUT every missing chunk; optionally kill the connection halfway through one chunk.
    Returns (bytes_sent_ok, seconds, interrupted)."""
    have = set(up["receivedChunks"])
    cs, total = up["chunkSize"], up["totalBytes"]
    sent, t0 = 0, time.time()
    with open(path, "rb") as f:
        for n in range(up["chunkCount"]):
            if n in have:
                continue
            f.seek(n * cs)
            data = f.read(min(cs, total - n * cs))
            if interrupt_chunk is not None and n == interrupt_chunk:
                c.put_partial("/v1/uploads/%s/chunks/%d" % (up["uploadID"], n), data, len(data) // 2)
                rep.note("chunk %d: connection dropped after %d of %d bytes" % (n, len(data) // 2, len(data)))
                return sent, time.time() - t0, True
            t1 = time.time()
            st, _, js = c.request("PUT", "/v1/uploads/%s/chunks/%d" % (up["uploadID"], n), body=data,
                                  headers={"Content-Type": "application/octet-stream",
                                           "X-Chunk-SHA256": hashlib.sha256(data).hexdigest()})
            if st != 200:
                raise RuntimeError("chunk %d -> HTTP %s %s" % (n, st, js))
            sent += len(data)
            rep.note("chunk %d/%d ok: %.1f MB in %.1fs (%.1f MB/s)" % (n + 1, up["chunkCount"], len(data) / 1e6,
                                                                    time.time() - t1, len(data) / 1e6 / max(time.time() - t1, 1e-3)))
    return sent, time.time() - t0, False


def download(c, jid, name, dest, interrupt_at=None):
    """Range-resumable download into dest. Returns (status, bytes_this_call, seconds, headers)."""
    have = os.path.getsize(dest) if os.path.exists(dest) else 0
    hdrs = {"Range": "bytes=%d-" % have} if have else {}
    got = [0]
    t0 = time.time()

    class Stop(Exception):
        pass

    with open(dest, "ab") as f:
        def sink(b):
            if interrupt_at is not None and have + got[0] + len(b) >= interrupt_at:
                cut = interrupt_at - have - got[0]
                f.write(b[:cut])
                got[0] += cut
                raise Stop()
            f.write(b)
            got[0] += len(b)
        try:
            st, h, _ = c.request("GET", "/v1/jobs/%s/files/%s" % (jid, name), headers=hdrs, stream_to=sink, retries=1)
        except Stop:
            c.reset()
            return "interrupted", got[0], time.time() - t0, {}
    return st, got[0], time.time() - t0, h


def wait_job(c, jid, rep, until=("done", "failed"), timeout=7200, on_poll=None, interval=5):
    last = None
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            st, _, j = c.request("GET", "/v1/jobs/" + jid)
        except Exception as e:
            rep.note("poll error (%s); retrying" % type(e).__name__)
            time.sleep(interval)
            continue
        if st == 200:
            line = "%s %s %.0f%% %s eta=%s q=%s" % (j["state"], j.get("stage"), 100 * (j.get("progress") or 0),
                                                    j.get("message"), j.get("etaSeconds"), j.get("queuePosition"))
            if line != last:
                rep.note("%s: %s" % (jid[-8:], line))
                last = line
            if on_poll and on_poll(j):
                return j
            if j["state"] in until:
                return j
        else:
            rep.note("poll HTTP %s %s" % (st, j))
        time.sleep(interval)
    raise TimeoutError(jid)


def e2e(a, c, base):
    rep = Report()
    out = a.out
    os.makedirs(out, exist_ok=True)
    zip_path, small = a.args[0], a.small
    rep.data["baseURL"] = base
    rep.data["zip"] = {"path": zip_path, "bytes": os.path.getsize(zip_path)}

    # Health (no auth)
    t = time.time()
    st, _, js = c.request("GET", "/v1/health", auth=False)
    rep.check("health 200 without auth", st == 200 and js.get("ok"), "%.0f ms" % ((time.time() - t) * 1000))

    # Bad auth
    st, _, js = c.request("GET", "/v1/jobs?captureID=x", auth=False)
    rep.check("401 without Authorization", st == 401 and js["error"]["code"] == "unauthorized", str(js))
    st, _, js = c.request("GET", "/v1/jobs?captureID=x", auth="0" * 64)
    rep.check("401 with wrong key", st == 401, str(js)[:120])

    # Bad per-chunk sha and bad whole-file sha (small throwaway upload)
    blob = os.urandom(5 * 1024 * 1024)
    wrong_total_sha = hashlib.sha256(b"not the same bytes").hexdigest()
    st, _, up = c.request("POST", "/v1/uploads", {"captureID": "e2e-badsha", "filename": "bad.zip", "totalBytes": len(blob),
                                                  "sha256": wrong_total_sha, "detail": "full", "notify": False})
    rep.check("create throwaway upload 201", st == 201, "chunkSize=%s" % up.get("chunkSize"))
    st, _, js = c.request("PUT", "/v1/uploads/%s/chunks/0" % up["uploadID"], body=blob,
                          headers={"Content-Type": "application/octet-stream", "X-Chunk-SHA256": "f" * 64})
    rep.check("400 chunk_sha256_mismatch (bad X-Chunk-SHA256)", st == 400 and js["error"]["code"] == "chunk_sha256_mismatch", js["error"]["code"])
    st, _, js = c.request("PUT", "/v1/uploads/%s/chunks/0" % up["uploadID"], body=blob,
                          headers={"Content-Type": "application/octet-stream", "X-Chunk-SHA256": hashlib.sha256(blob).hexdigest()})
    rep.check("chunk with correct sha accepted", st == 200, str(js.get("receivedChunks")))
    st, _, js = c.request("POST", "/v1/uploads/%s/complete" % up["uploadID"])
    rep.check("422 sha256_mismatch on complete (bad whole-file sha)", st == 422 and js["error"]["code"] == "sha256_mismatch", js["error"]["message"])
    st, _, js = c.request("DELETE", "/v1/uploads/%s" % up["uploadID"])
    rep.check("DELETE upload 200", st == 200)

    # Main upload: interrupted mid-chunk, then resumed
    capture = a.capture
    sha = sha256_file(zip_path)
    size = os.path.getsize(zip_path)
    st, _, up = c.request("POST", "/v1/uploads", {"captureID": capture, "filename": os.path.basename(zip_path), "totalBytes": size,
                                                  "sha256": sha, "detail": a.detail, "texture": "8k", "obj": True,
                                                  "glb": bool(a.glb), "title": a.title, "notify": True})
    rep.check("create upload 201", st == 201, "%s chunks x %d MiB" % (up.get("chunkCount"), (up.get("chunkSize") or 0) >> 20))
    uid = up["uploadID"]
    cut_at = max(1, up["chunkCount"] // 2)
    t_up = time.time()
    sent1, secs1, interrupted = upload_chunks(c, zip_path, up, rep, interrupt_chunk=cut_at)
    rep.check("upload interrupted mid-chunk %d" % cut_at, interrupted)
    time.sleep(2)
    st, _, up2 = c.request("GET", "/v1/uploads/" + uid)
    rep.check("resume info: partial chunk not counted", st == 200 and up2["receivedChunks"] == list(range(cut_at)),
              "receivedChunks=%s" % up2["receivedChunks"])
    sent2, secs2, _ = upload_chunks(c, zip_path, up2, rep)
    up_secs = time.time() - t_up
    st, _, up3 = c.request("GET", "/v1/uploads/" + uid)
    rep.check("all chunks received after resume", up3["receivedChunks"] == list(range(up3["chunkCount"])))
    t = time.time()
    st, _, js = c.request("POST", "/v1/uploads/%s/complete" % uid)
    complete_secs = time.time() - t
    rep.check("complete 201 -> jobID", st == 201 and js.get("jobID"), "%s (assembly+sha %.1fs)" % (js.get("jobID"), complete_secs))
    jid = js["jobID"]
    st, _, js2 = c.request("POST", "/v1/uploads/%s/complete" % uid)
    rep.check("complete is idempotent (same jobID)", st == 200 and js2.get("jobID") == jid)
    rep.data["upload"] = {"bytes": size, "chunks": up["chunkCount"], "chunkSize": up["chunkSize"],
                          "wallSeconds": round(up_secs, 1), "transferSeconds": round(secs1 + secs2, 1),
                          "throughputMBps": round((sent1 + sent2) / 1e6 / max(secs1 + secs2, 1e-3), 2),
                          "completeSeconds": round(complete_secs, 1)}

    # Second, smaller job queued behind it
    jid2 = None
    if small:
        ssha, ssize = sha256_file(small), os.path.getsize(small)
        st, _, sup = c.request("POST", "/v1/uploads", {"captureID": capture + "-small", "filename": os.path.basename(small),
                                                       "totalBytes": ssize, "sha256": ssha, "detail": "full", "notify": False})
        upload_chunks(c, small, sup, rep)
        st, _, js = c.request("POST", "/v1/uploads/%s/complete" % sup["uploadID"])
        jid2 = js.get("jobID")
        st, _, j2 = c.request("GET", "/v1/jobs/" + jid2)
        rep.check("second job queued behind the first", j2["state"] == "queued" and (j2.get("queuePosition") or 0) >= 1,
                  "state=%s queuePosition=%s" % (j2["state"], j2.get("queuePosition")))

    # Restart the server while job 1 is processing
    t_job = time.time()
    if a.restart_cmd:
        wait_job(c, jid, rep, on_poll=lambda j: j["state"] == "processing" and (j.get("progress") or 0) >= 0.10)
        rep.note("restarting the server: %s" % a.restart_cmd)
        before = c.request("GET", "/v1/health", auth=False)[2].get("startedAt")
        t = time.time()
        r = subprocess.run(a.restart_cmd, shell=True, capture_output=True, text=True, timeout=180)
        rep.note("restart cmd exit %s %s" % (r.returncode, (r.stdout + r.stderr).strip()[-300:]))
        back = None
        for _ in range(120):
            try:
                c.reset()
                st, _, h = c.request("GET", "/v1/health", auth=False, retries=1)
                if st == 200 and h.get("startedAt") != before:  # a NEW server process
                    back = time.time() - t
                    break
            except Exception:
                pass
            time.sleep(1)
        rep.check("server back after restart", back is not None, "%.1fs" % (back or -1))
        st, _, j = c.request("GET", "/v1/jobs/" + jid)
        rep.check("interrupted job requeued (restarts>=1)", j.get("restarts", 0) >= 1 and j["state"] in ("queued", "processing"),
                  "state=%s restarts=%s message=%s" % (j["state"], j.get("restarts"), j.get("message")))
        rep.data["restart"] = {"backSeconds": round(back or -1, 1)}

    j = wait_job(c, jid, rep)
    rep.data["job"] = {k: j.get(k) for k in ("state", "detail", "polygons", "textures", "buildSeconds", "restarts", "message", "files")}
    rep.data["job"]["wallSecondsFromComplete"] = round(time.time() - t_job, 1)
    rep.check("job 1 done", j["state"] == "done", "%s polygons, build %ss" % (j.get("polygons"), j.get("buildSeconds")))
    files = {f["name"]: f for f in j.get("files", [])}
    rep.check("files listed (usdz, obj zip, log)", {"model.usdz", "model-obj.zip", "recon-log.txt"} <= set(files), ",".join(sorted(files)))

    # Range-resumed download of model.usdz
    dest = os.path.join(out, "model.usdz")
    if os.path.exists(dest):
        os.remove(dest)
    total = files["model.usdz"]["bytes"]
    st1, b1, s1, _ = download(c, jid, "model.usdz", dest, interrupt_at=int(total * 0.4))
    st2, b2, s2, h2 = download(c, jid, "model.usdz", dest)
    got_sha = sha256_file(dest)
    rep.check("download interrupted at 40%% then resumed with 206", st1 == "interrupted" and st2 == 206,
              "first=%s (%d B) resume=%s (%d B) Content-Range=%s" % (st1, b1, st2, b2, hdr(h2, "Content-Range")))
    rep.check("model.usdz sha256 matches job file list", got_sha == files["model.usdz"]["sha256"] and os.path.getsize(dest) == total,
              got_sha[:16])
    rep.data["download"] = {"bytes": total, "seconds": round(s1 + s2, 1), "throughputMBps": round(total / 1e6 / max(s1 + s2, 1e-3), 2)}
    for name in ("recon-log.txt", "model-obj.zip") + (("model.glb", "thumbnail.png") if a.glb else ()):
        p = os.path.join(out, name)
        if os.path.exists(p):
            os.remove(p)
        st, n, s, _ = download(c, jid, name, p)
        rep.check("download %s sha256" % name, st == 200 and sha256_file(p) == files[name]["sha256"], "%d B in %.1fs" % (n, s))
    try:
        r = subprocess.run(["/usr/bin/usdchecker", "--arkit", dest], capture_output=True, text=True, timeout=600)
        rep.check("usdchecker --arkit on downloaded model", r.returncode == 0, (r.stdout.strip().splitlines() or ["?"])[-1])
    except subprocess.TimeoutExpired:
        rep.check("usdchecker --arkit on downloaded model", False, "timed out")

    # Re-find by captureID; finish/delete the second job
    st, _, js = c.request("GET", "/v1/jobs?captureID=" + urllib.parse.quote(capture))
    rep.check("GET /v1/jobs?captureID finds the job", st == 200 and any(x["jobID"] == jid for x in js.get("jobs", [])),
              "%d job(s)" % len(js.get("jobs", [])))
    if jid2:
        j2 = wait_job(c, jid2, rep)
        rep.check("job 2 (queued during restart) done", j2["state"] == "done", "%s polygons" % j2.get("polygons"))
        st, _, _ = c.request("DELETE", "/v1/jobs/" + jid2)
        st2, _, _ = c.request("GET", "/v1/jobs/" + jid2)
        rep.check("DELETE job 200 then GET 404", st == 200 and st2 == 404)

    rep.data["checks"] = rep.checks
    rep.data["passed"] = sum(x["ok"] for x in rep.checks)
    rep.data["failed"] = sum(not x["ok"] for x in rep.checks)
    rep.data["jobID"] = jid
    with open(os.path.join(out, "e2e-report.json"), "w") as f:
        json.dump(rep.data, f, indent=1)
    print("\n%d passed, %d failed; report %s" % (rep.data["passed"], rep.data["failed"], os.path.join(out, "e2e-report.json")))
    return rep.data["failed"] == 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd")
    ap.add_argument("args", nargs="*")
    ap.add_argument("--base")
    ap.add_argument("--capture", default="e2e-monstree")
    ap.add_argument("--title", default="Monstree test")
    ap.add_argument("--detail", default="full")
    ap.add_argument("--small")
    ap.add_argument("--glb", action="store_true", help="also ask for model.glb (what the Android app requests)")
    ap.add_argument("--restart-cmd")
    ap.add_argument("--out", default=os.path.join(os.getcwd(), "e2e-out"))
    a = ap.parse_args()
    base = (a.base or open(os.path.join(CONF, "base_url")).read()).strip().rstrip("/")
    c = Client(base, key())
    if a.cmd == "health":
        print(c.request("GET", "/v1/health", auth=False)[2])
    elif a.cmd == "job":
        print(json.dumps(c.request("GET", "/v1/jobs/" + a.args[0])[2], indent=1))
    elif a.cmd == "jobs":
        print(json.dumps(c.request("GET", "/v1/jobs?captureID=" + urllib.parse.quote(a.capture))[2], indent=1))
    elif a.cmd == "e2e":
        sys.exit(0 if e2e(a, c, base) else 1)
    else:
        sys.exit("unknown command")


if __name__ == "__main__":
    main()
