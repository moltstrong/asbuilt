#!/usr/bin/env python3
"""asbuilt-recon HTTP server: resumable chunked photo uploads -> queued full/raw/custom builds.

Python 3.9 stdlib only (macOS /usr/bin/python3). Started by `asbuilt-recon serve` (which execs
this file) or directly. Contract for the iOS client: MacRecon/API.md.

Layout (DATA = ~/Library/Application Support/asbuilt-recon):
  DATA/uploads/<uploadID>/meta.json, chunks/<n>.part
  DATA/jobs/<jobID>/job.json, input.zip, status.json, out/{model.usdz,model-obj.zip,recon-log.txt,...}
  ~/.config/asbuilt-recon/api_key (0600), base_url, config.json (optional)
  ~/Library/Logs/asbuilt-recon/server.log
"""

import argparse
import hashlib
import hmac
import json
import logging
import logging.handlers
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.0.0"
API_VERSION = 1

HOME = os.path.expanduser("~")
CONFIG_DIR = os.path.join(HOME, ".config", "asbuilt-recon")
DATA_DIR = os.environ.get("ASBUILT_RECON_DATA", os.path.join(HOME, "Library", "Application Support", "asbuilt-recon"))
LOG_DIR = os.path.join(HOME, "Library", "Logs", "asbuilt-recon")

MiB = 1024 * 1024
GiB = 1024 * MiB
CHUNK_SIZE = 32 * MiB          # default; clients may ask for 4-64 MiB (Cloudflare caps bodies at 100 MB)
MIN_CHUNK = 4 * MiB
MAX_CHUNK = 64 * MiB
MAX_UPLOAD_BYTES = 8 * GiB
FREE_SPACE_FACTOR = 3
RETENTION_SECONDS = 7 * 24 * 3600
READ_BLOCK = 1 * MiB

AUTH_FAIL_WINDOW = 600      # seconds
AUTH_FAIL_LIMIT = 10        # failures per IP per window
AUTH_LOCKOUT = 900          # seconds an IP is locked out after hitting the limit

DETAILS = ("full", "raw", "custom", "phone")
# "phone": the most detail Apple allows on this Mac, packaged to open on an iPhone: 250k triangles
# (Apple's cap for custom detail here, ~2x what "full" picks) with 8K diffuse + normal maps as JPEG,
# about 30 MB instead of ~300 MB for "full" (5 PNG/EXR maps). Two 8K maps decode to ~0.7 GB in
# SceneKit, which a Pro iPhone handles; five would not.
PHONE_PRESET = ["--detail", "custom", "--texture", "8k", "--max-polys", "250000",
                "--maps", "diffuse,normal", "--texture-format", "jpeg:0.9"]
TEXTURES = ("4k", "8k")
FILE_NAMES = ("model.usdz", "model-obj.zip", "recon-log.txt", "thumbnail.png")
CONTENT_TYPES = {
    "model.usdz": "model/vnd.usdz+zip",
    "model-obj.zip": "application/zip",
    "recon-log.txt": "text/plain; charset=utf-8",
    "thumbnail.png": "image/png",
}
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
HEX64_RE = re.compile(r"^[0-9a-f]{64}$")

log = logging.getLogger("asbuilt-recon")


def now_iso(ts=None):
    return datetime.fromtimestamp(ts if ts is not None else time.time(), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def new_id(prefix):
    return prefix + "_" + uuid.uuid4().hex[:20]


def atomic_write_json(path, obj):
    tmp = path + ".tmp-%d-%d" % (os.getpid(), threading.get_ident())
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=1, sort_keys=True)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def read_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def free_bytes(path):
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(4 * MiB)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


class ApiError(Exception):
    def __init__(self, status, code, message, **extra):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.extra = extra


# ---------------------------------------------------------------------------------------------
# State

class Store:
    """All persistent state. One lock guards metadata; chunk bodies are written outside it."""

    def __init__(self, data_dir):
        self.data = data_dir
        self.uploads_dir = os.path.join(data_dir, "uploads")
        self.jobs_dir = os.path.join(data_dir, "jobs")
        for d in (self.uploads_dir, self.jobs_dir):
            os.makedirs(d, exist_ok=True)
        self.lock = threading.RLock()
        self.wake = threading.Condition(self.lock)
        # uploadID -> lock serialising /complete for that upload
        self.complete_locks = {}

    # uploads -------------------------------------------------------------------------------
    def upload_dir(self, uid):
        if not ID_RE.match(uid or ""):
            raise ApiError(404, "upload_not_found", "No upload with that ID.")
        return os.path.join(self.uploads_dir, uid)

    def load_upload(self, uid):
        meta = read_json(os.path.join(self.upload_dir(uid), "meta.json"))
        if not meta:
            raise ApiError(404, "upload_not_found", "No upload with that ID. It may have expired (uploads are kept 7 days); start a new one.")
        return meta

    def save_upload(self, meta):
        atomic_write_json(os.path.join(self.upload_dir(meta["uploadID"]), "meta.json"), meta)

    def received_chunks(self, uid):
        d = os.path.join(self.upload_dir(uid), "chunks")
        out = []
        try:
            for n in os.listdir(d):
                if n.endswith(".part"):
                    try:
                        out.append(int(n[:-5]))
                    except ValueError:
                        pass
        except OSError:
            pass
        return sorted(out)

    def reserved_upload_bytes(self, exclude=None):
        """Bytes still to arrive for open uploads (so parallel uploads can't overcommit the disk)."""
        total = 0
        for uid in os.listdir(self.uploads_dir):
            if uid == exclude:
                continue
            meta = read_json(os.path.join(self.uploads_dir, uid, "meta.json"))
            if not meta or meta.get("state") != "open":
                continue
            got = len(self.received_chunks(uid))
            total += max(meta["totalBytes"] - got * meta["chunkSize"], 0)
        return total

    # jobs ----------------------------------------------------------------------------------
    def job_dir(self, jid):
        if not ID_RE.match(jid or ""):
            raise ApiError(404, "job_not_found", "No job with that ID.")
        return os.path.join(self.jobs_dir, jid)

    def load_job(self, jid):
        job = read_json(os.path.join(self.job_dir(jid), "job.json"))
        if not job:
            raise ApiError(404, "job_not_found", "No job with that ID. Finished jobs are deleted after 7 days.")
        return job

    def save_job(self, job):
        atomic_write_json(os.path.join(self.job_dir(job["jobID"]), "job.json"), job)

    def all_jobs(self):
        jobs = []
        for jid in os.listdir(self.jobs_dir):
            j = read_json(os.path.join(self.jobs_dir, jid, "job.json"))
            if j:
                jobs.append(j)
        return jobs

    def queued_jobs(self):
        return sorted([j for j in self.all_jobs() if j["state"] == "queued"], key=lambda j: (j["createdAt"], j["jobID"]))


# ---------------------------------------------------------------------------------------------
# Notifications (optional): one iMessage per finished job through the local BlueBubbles server.

def read_dotenv(path):
    env = {}
    try:
        with open(path) as f:
            for line in f:
                m = re.match(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$", line)
                if m:
                    v = m.group(2).strip()
                    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                        v = v[1:-1]
                    env[m.group(1)] = v
    except OSError:
        pass
    return env


class Notifier:
    def __init__(self, cfg):
        n = cfg.get("notify") or {}
        self.enabled = bool(n.get("bluebubbles", False))
        self.chat_guid = n.get("chatGuid", "")
        self.env_file = os.path.expanduser(n.get("envFile", "~/.hermes/.env"))

    def send(self, text):
        if not self.enabled or not self.chat_guid:
            return False, "disabled"
        env = read_dotenv(self.env_file)
        server = env.get("BLUEBUBBLES_SERVER_URL", "")
        pw = env.get("BLUEBUBBLES_PASSWORD", "")
        if not server or not pw:
            return False, "BlueBubbles credentials not found"
        host = urllib.parse.urlparse(server).hostname or ""
        if host not in ("127.0.0.1", "localhost", "::1"):
            # Never send the BlueBubbles password off this machine.
            return False, "BlueBubbles server is not local; skipped"
        url = server.rstrip("/") + "/api/v1/message/text?password=" + urllib.parse.quote(pw, safe="")
        body = json.dumps({"chatGuid": self.chat_guid, "tempGuid": "asbuilt-" + uuid.uuid4().hex, "message": text}).encode()
        req = urllib.request.Request(url, data=body, method="POST", headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                data = json.loads(r.read() or b"{}")
                ok = r.status == 200 and data.get("status") == 200
                return ok, "status %s" % data.get("status")
        except Exception as e:  # network/HTTP errors: report, never raise into the worker
            return False, type(e).__name__ + ": " + re.sub(r"password=[^&\s]+", "password=***", str(e))[:200]


# ---------------------------------------------------------------------------------------------
# Worker

class Worker(threading.Thread):
    def __init__(self, store, cli, notifier):
        super().__init__(name="worker", daemon=True)
        self.store = store
        self.cli = cli
        self.notifier = notifier
        self.current = None  # (jobID, Popen)
        self.cancel_requested = set()
        self.stopping = False

    def requeue_interrupted(self):
        """On start: anything left 'processing' by a crash/restart goes back to the queue head."""
        with self.store.lock:
            for job in self.store.all_jobs():
                if job["state"] != "processing":
                    continue
                pid = job.get("pid")
                if pid:
                    try:
                        cmd = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout
                        # Only kill it if it really is this job's build (its command line names the job folder).
                        if self.store.job_dir(job["jobID"]) in cmd and " build " in cmd:
                            os.kill(pid, signal.SIGTERM)  # CLI cancels + cleans temp; it holds the build lock until then
                            for _ in range(30):
                                time.sleep(0.5)
                                if subprocess.run(["/bin/kill", "-0", str(pid)], capture_output=True).returncode != 0:
                                    break
                            else:
                                os.kill(pid, signal.SIGKILL)
                            log.info("stopped orphan build pid %s for %s", pid, job["jobID"])
                    except Exception:
                        pass
                job["state"] = "queued"
                job["restarts"] = job.get("restarts", 0) + 1
                job["message"] = "Waiting to restart (the server restarted during the build)"
                job["progress"] = 0
                job.pop("pid", None)
                job.pop("startedAt", None)
                self.store.save_job(job)
                log.info("requeued interrupted job %s (restart #%d)", job["jobID"], job["restarts"])

    def cancel(self, jid):
        with self.store.lock:
            self.cancel_requested.add(jid)
            if self.current and self.current[0] == jid:
                try:
                    self.current[1].send_signal(signal.SIGTERM)
                except Exception:
                    pass

    def run(self):
        while not self.stopping:
            with self.store.lock:
                try:
                    queued = self.store.queued_jobs()
                except OSError:
                    log.exception("worker: can't read the job queue")
                    self.store.wake.wait(timeout=5)
                    continue
                if not queued:
                    self.store.wake.wait(timeout=30)
                    continue
                job = queued[0]
                job["state"] = "processing"
                job["startedAt"] = now_iso()
                job["message"] = "Starting the build"
                self.store.save_job(job)
            try:
                self.build(job)
            except Exception:
                log.exception("worker crashed on %s", job["jobID"])
                with self.store.lock:
                    try:
                        j = self.store.load_job(job["jobID"])
                        j.update(state="failed", finishedAt=now_iso(), message="The Mac hit an internal error while building. Try again.",
                                 error={"code": "internal_error", "message": "internal server error"})
                        self.store.save_job(j)
                    except ApiError:
                        pass

    def build(self, job):
        jid = job["jobID"]
        jdir = self.store.job_dir(jid)
        out = os.path.join(jdir, "out")
        if os.path.isdir(out):
            shutil.rmtree(out, ignore_errors=True)
        os.makedirs(out, exist_ok=True)
        status_path = os.path.join(jdir, "status.json")
        try:
            os.remove(status_path)
        except OSError:
            pass
        detail_args = PHONE_PRESET if job["detail"] == "phone" else ["--detail", job["detail"]]
        args = [self.cli, "build", os.path.join(jdir, "input.zip")] + detail_args + ["--out", out,
                "--status-file", status_path, "--title", job.get("title") or job["captureID"],
                # Lets a build that was interrupted by a server restart resume instead of starting over.
                "--checkpoint", os.path.join(jdir, "checkpoint")]
        if job.get("obj"):
            args.append("--obj")
        if job["detail"] == "custom":
            args += ["--texture", job.get("texture") or "8k", "--max-polys", str(job.get("maxPolygons") or 1000000)]
        log.info("job %s: start %s", jid, " ".join(args[1:]))
        t0 = time.time()
        with open(os.path.join(jdir, "console.log"), "ab") as console:
            p = subprocess.Popen(args, stdout=console, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, cwd=jdir)
            # Keep the Mac awake (idle sleep) for exactly as long as the build runs.
            subprocess.Popen(["/usr/bin/caffeinate", "-i", "-w", str(p.pid)], stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            with self.store.lock:
                self.current = (jid, p)
                j = self.store.load_job(jid)
                j["pid"] = p.pid
                self.store.save_job(j)
                if jid in self.cancel_requested:
                    p.send_signal(signal.SIGTERM)
            rc = p.wait()
        with self.store.lock:
            self.current = None
            cancelled = jid in self.cancel_requested
            self.cancel_requested.discard(jid)
        secs = time.time() - t0
        if cancelled:
            log.info("job %s: cancelled after %.0fs", jid, secs)
            return  # DELETE handler removes the directory
        if self.stopping:
            return  # server shutting down: leave 'processing' so the next start requeues it
        result = read_json(os.path.join(out, "result.json"), {}) or {}
        files = []
        for name in FILE_NAMES:
            path = os.path.join(out, name)
            if os.path.isfile(path):
                files.append({"name": name, "bytes": os.path.getsize(path), "sha256": sha256_file(path),
                              "url": "/v1/jobs/%s/files/%s" % (jid, name)})
        with self.store.lock:
            try:
                j = self.store.load_job(jid)
            except ApiError:
                return  # deleted meanwhile
            j.pop("pid", None)
            j["finishedAt"] = now_iso()
            j["buildSeconds"] = round(secs, 1)
            j["files"] = files
            j["polygons"] = result.get("polygons")
            j["textures"] = [{"name": t["name"], "width": t["width"], "height": t["height"]} for t in result.get("textures", [])]
            j["usdcheckerPassed"] = result.get("usdcheckerPassed")
            if rc == 0 and result.get("ok") and any(f["name"] == "model.usdz" for f in files):
                j["state"] = "done"
                j["progress"] = 1.0
                j["stage"] = None
                j["etaSeconds"] = None
                j["message"] = "Model ready: %s polygons." % ("{:,}".format(j["polygons"]) if j.get("polygons") else "?")
            else:
                j["state"] = "failed"
                msg = result.get("errorMessage") or "The build failed. The log has the details."
                j["message"] = msg
                j["error"] = {"code": "build_failed", "message": msg, "exitCode": rc, "technical": (result.get("errorTechnical") or "")[:2000]}
            # Input zip is no longer needed once the job finished.
            try:
                os.remove(os.path.join(jdir, "input.zip"))
            except OSError:
                pass
            self.store.save_job(j)
        log.info("job %s: %s in %.0fs (rc=%s, polygons=%s)", jid, j["state"], secs, rc, j.get("polygons"))
        if j.get("notify", True):
            title = j.get("title") or j["captureID"]
            word = "full-detail" if j["detail"] == "phone" else "%s-detail" % j["detail"]
            text = ("AsBuilt: '%s' %s model is ready \u2014 open the app." % (title, word)) if j["state"] == "done" else \
                   ("AsBuilt: '%s' %s build failed \u2014 open the app for details." % (title, word))
            ok, info = self.notifier.send(text)
            log.info("job %s: notify %s (%s)", jid, "sent" if ok else "not sent", info)
            with self.store.lock:
                try:
                    j2 = self.store.load_job(jid)
                    j2["notified"] = ok
                    self.store.save_job(j2)
                except ApiError:
                    pass


def assemble_upload(store, uid):
    """Assemble an upload's chunks, verify the whole-file sha256 and enqueue a job (idempotent)."""
    with store.lock:
        lock = store.complete_locks.setdefault(uid, threading.Lock())
    with lock:  # one assembly per upload at a time; a retry waits and then gets the same jobID
        with store.lock:
            meta = store.load_upload(uid)
            if meta["state"] == "completed":
                return {"jobID": meta["jobID"], "uploadID": uid, "alreadyCompleted": True}
            got = set(store.received_chunks(uid))
            missing = [i for i in range(meta["chunkCount"]) if i not in got]
            if missing:
                raise ApiError(409, "missing_chunks", "%d of %d chunks haven't arrived yet." % (len(missing), meta["chunkCount"]),
                               missingChunks=missing[:1000], missingCount=len(missing))
        udir = store.upload_dir(uid)
        jid = new_id("job")
        jdir = store.job_dir(jid)
        os.makedirs(jdir)
        dest = os.path.join(jdir, "input.zip")
        h = hashlib.sha256()
        t0 = time.time()
        with open(dest, "wb") as out:
            for i in range(meta["chunkCount"]):
                with open(os.path.join(udir, "chunks", "%d.part" % i), "rb") as f:
                    while True:
                        b = f.read(4 * MiB)
                        if not b:
                            break
                        h.update(b)
                        out.write(b)
            out.flush()
            os.fsync(out.fileno())
        digest = h.hexdigest()
        size = os.path.getsize(dest)
        if digest != meta["sha256"] or size != meta["totalBytes"]:
            shutil.rmtree(jdir, ignore_errors=True)
            with store.lock:
                shutil.rmtree(os.path.join(udir, "chunks"), ignore_errors=True)
                os.makedirs(os.path.join(udir, "chunks"))
                meta["updatedAtEpoch"] = time.time()
                store.save_upload(meta)
            log.warning("upload %s: whole-file sha256 mismatch (got %s..., want %s...)", uid, digest[:12], meta["sha256"][:12])
            raise ApiError(422, "sha256_mismatch",
                           "The uploaded file doesn't match its checksum. All chunks were discarded; upload them again.",
                           expected=meta["sha256"], actual=digest)
        t = time.time()
        job = {"jobID": jid, "uploadID": uid, "captureID": meta["captureID"], "title": meta.get("title"),
               "detail": meta["detail"], "texture": meta.get("texture"), "obj": meta.get("obj", False),
               "maxPolygons": meta.get("maxPolygons"), "notify": meta.get("notify", True),
               "inputBytes": size, "inputSha256": digest, "state": "queued", "progress": 0.0,
               "message": "Waiting for the Mac", "createdAt": now_iso(t), "files": [], "restarts": 0}
        with store.lock:
            store.save_job(job)
            meta["state"] = "completed"
            meta["jobID"] = jid
            meta["updatedAtEpoch"] = t
            store.save_upload(meta)
            shutil.rmtree(os.path.join(udir, "chunks"), ignore_errors=True)
            store.wake.notify_all()
        log.info("upload %s complete -> job %s (%d bytes assembled+verified in %.1fs)", uid, jid, size, time.time() - t0)
        return {"jobID": jid, "uploadID": uid, "alreadyCompleted": False}


def auto_complete_upload(store, uid):
    """Background /complete for uploads created with autoComplete (the phone may be asleep)."""
    try:
        r = assemble_upload(store, uid)
        log.info("upload %s auto-completed -> %s", uid, r["jobID"])
    except ApiError as e:
        log.warning("upload %s auto-complete: %s %s", uid, e.status, e.code)
    except Exception:
        log.exception("upload %s auto-complete crashed", uid)


# ---------------------------------------------------------------------------------------------
# Cleanup

class Janitor(threading.Thread):
    def __init__(self, store, retention=RETENTION_SECONDS):
        super().__init__(name="janitor", daemon=True)
        self.store = store
        self.retention = retention

    def sweep(self):
        cutoff = time.time() - self.retention
        with self.store.lock:
            for uid in os.listdir(self.store.uploads_dir):
                d = os.path.join(self.store.uploads_dir, uid)
                meta = read_json(os.path.join(d, "meta.json"))
                last = (meta or {}).get("updatedAtEpoch") or os.path.getmtime(d)
                if last < cutoff:
                    shutil.rmtree(d, ignore_errors=True)
                    log.info("cleanup: removed upload %s", uid)
            for jid in os.listdir(self.store.jobs_dir):
                d = os.path.join(self.store.jobs_dir, jid)
                job = read_json(os.path.join(d, "job.json"))
                if job and job["state"] in ("queued", "processing"):
                    continue
                last = (job or {}).get("finishedAtEpoch") or os.path.getmtime(d)
                if job and job.get("finishedAt"):
                    last = datetime.strptime(job["finishedAt"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
                if last < cutoff:
                    shutil.rmtree(d, ignore_errors=True)
                    log.info("cleanup: removed job %s", jid)

    def run(self):
        while True:
            try:
                self.sweep()
            except Exception:
                log.exception("cleanup failed")
            time.sleep(3600)


# ---------------------------------------------------------------------------------------------
# Auth rate limiting

class AuthLimiter:
    def __init__(self):
        self.lock = threading.Lock()
        self.failures = {}   # ip -> [timestamps]
        self.locked = {}     # ip -> until

    def check(self, ip):
        with self.lock:
            until = self.locked.get(ip, 0)
            if until > time.time():
                return int(until - time.time()) + 1
            return 0

    def fail(self, ip):
        with self.lock:
            t = time.time()
            lst = [x for x in self.failures.get(ip, []) if x > t - AUTH_FAIL_WINDOW]
            lst.append(t)
            self.failures[ip] = lst
            if len(lst) >= AUTH_FAIL_LIMIT:
                self.locked[ip] = t + AUTH_LOCKOUT
                self.failures[ip] = []
                log.warning("auth: %s locked out for %ds after %d failures", ip, AUTH_LOCKOUT, AUTH_FAIL_LIMIT)

    def success(self, ip):
        with self.lock:
            self.failures.pop(ip, None)


# ---------------------------------------------------------------------------------------------
# HTTP

class Handler(BaseHTTPRequestHandler):
    server_version = "asbuilt-recon/" + VERSION
    sys_version = ""
    protocol_version = "HTTP/1.1"
    app = None  # set in main()

    # -- plumbing ---------------------------------------------------------------------------
    def log_message(self, fmt, *args):
        pass  # access log written in send_json/_finish

    def client_ip(self):
        # Bound to loopback: requests arrive through the tunnel, which sets these headers.
        if self.client_address[0] in ("127.0.0.1", "::1"):
            for h in ("CF-Connecting-IP", "Tailscale-Forwarded-For", "X-Forwarded-For"):
                v = self.headers.get(h)
                if v:
                    return v.split(",")[0].strip()
        return self.client_address[0]

    def send_json(self, status, obj, headers=None):
        body = (json.dumps(obj, sort_keys=True) + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        self._status = status

    def send_error_json(self, e):
        body = {"error": dict({"code": e.code, "message": e.message}, **e.extra)}
        headers = {}
        if e.status == 401:
            headers["WWW-Authenticate"] = 'Bearer realm="asbuilt-recon"'
        if e.status == 429 and "retryAfterSeconds" in e.extra:
            headers["Retry-After"] = str(e.extra["retryAfterSeconds"])
        if e.status == 405 and "allow" in e.extra:
            headers["Allow"] = e.extra["allow"]
        # Don't leave an unread request body on a kept-alive connection. For authenticated
        # requests with a body up to one chunk, read and discard it first so the client always
        # receives this error response (closing mid-upload shows up as a broken pipe instead).
        if self._body_pending():
            cl = self.headers.get("Content-Length") or ""
            if getattr(self, "_authed", False) and cl.isdigit() and int(cl) <= MAX_CHUNK + MiB:
                try:
                    left = int(cl)
                    while left:
                        b = self.rfile.read(min(READ_BLOCK, left))
                        if not b:
                            break
                        left -= len(b)
                    self._body_consumed = True
                except (OSError, socket.timeout):
                    pass
            if self._body_pending():
                self.close_connection = True
                headers["Connection"] = "close"
        self.send_json(e.status, body, headers)

    def _body_pending(self):
        if getattr(self, "_body_consumed", False):
            return False
        te = (self.headers.get("Transfer-Encoding") or "").lower()
        cl = self.headers.get("Content-Length")
        return "chunked" in te or (cl not in (None, "", "0"))

    def read_json_body(self, limit=64 * 1024):
        cl = self.headers.get("Content-Length")
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            data = b"".join(self.iter_body(limit))
        else:
            try:
                n = int(cl or "0")
            except ValueError:
                raise ApiError(400, "bad_request", "Invalid Content-Length.")
            if n > limit:
                raise ApiError(413, "body_too_large", "JSON body too large.")
            data = self.rfile.read(n) if n else b""
        self._body_consumed = True
        try:
            obj = json.loads(data or b"{}")
        except ValueError:
            raise ApiError(400, "invalid_json", "Body must be JSON.")
        if not isinstance(obj, dict):
            raise ApiError(400, "invalid_json", "Body must be a JSON object.")
        return obj

    def iter_body(self, limit):
        """Yield the request body (Content-Length or chunked) in blocks, enforcing `limit` bytes."""
        te = (self.headers.get("Transfer-Encoding") or "").lower()
        total = 0
        if "chunked" in te:
            while True:
                line = self.rfile.readline(1024)
                if not line:
                    raise ConnectionError("client disconnected")
                size = int(line.split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    while True:  # trailers
                        t = self.rfile.readline(8192)
                        if t in (b"\r\n", b"\n", b""):
                            break
                    break
                total += size
                if total > limit:
                    raise ApiError(413, "chunk_too_large", "Body is larger than allowed.")
                left = size
                while left:
                    b = self.rfile.read(min(READ_BLOCK, left))
                    if not b:
                        raise ConnectionError("client disconnected")
                    left -= len(b)
                    yield b
                self.rfile.readline(8)
        else:
            n = int(self.headers.get("Content-Length") or "0")
            if n > limit:
                raise ApiError(413, "chunk_too_large", "Body is larger than allowed.")
            left = n
            while left:
                b = self.rfile.read(min(READ_BLOCK, left))
                if not b:
                    raise ConnectionError("client disconnected")
                left -= len(b)
                yield b
        self._body_consumed = True

    def authorize(self):
        ip = self.client_ip()
        wait = self.app.limiter.check(ip)
        if wait:
            raise ApiError(429, "rate_limited", "Too many failed sign-in attempts from this address. Try again later.", retryAfterSeconds=wait)
        h = self.headers.get("Authorization") or ""
        token = h[7:].strip() if h[:7].lower() == "bearer " else ""
        # Constant-time compare of equal-length digests (length of the token isn't leaked either).
        good = hmac.compare_digest(hashlib.sha256(token.encode()).digest(), hashlib.sha256(self.app.api_key.encode()).digest())
        if not token or not good:
            self.app.limiter.fail(ip)
            log.warning("auth: rejected %s %s from %s", self.command, self.path.split("?")[0], ip)
            raise ApiError(401, "unauthorized", "Missing or wrong API key.")
        self.app.limiter.success(ip)
        self._authed = True

    # -- dispatch ---------------------------------------------------------------------------
    ROUTES = [
        ("GET", re.compile(r"^/v1/health$"), "health", False),
        ("POST", re.compile(r"^/v1/uploads$"), "create_upload", True),
        ("GET", re.compile(r"^/v1/uploads/([^/]+)$"), "get_upload", True),
        ("DELETE", re.compile(r"^/v1/uploads/([^/]+)$"), "delete_upload", True),
        ("PUT", re.compile(r"^/v1/uploads/([^/]+)/chunks/([0-9]+)$"), "put_chunk", True),
        ("POST", re.compile(r"^/v1/uploads/([^/]+)/complete$"), "complete_upload", True),
        ("GET", re.compile(r"^/v1/jobs$"), "list_jobs", True),
        ("GET", re.compile(r"^/v1/jobs/([^/]+)$"), "get_job", True),
        ("DELETE", re.compile(r"^/v1/jobs/([^/]+)$"), "delete_job", True),
        ("GET", re.compile(r"^/v1/jobs/([^/]+)/files/([^/]+)$"), "get_file", True),
        ("POST", re.compile(r"^/v1/diagnostics$"), "diagnostics", True),
    ]

    def dispatch(self):
        self._status = 0
        self._body_consumed = False
        self._authed = False
        t0 = time.time()
        parsed = urllib.parse.urlsplit(self.path)
        self.query = urllib.parse.parse_qs(parsed.query)
        method = "GET" if self.command == "HEAD" else self.command
        try:
            allowed = []
            for m, rx, name, auth in self.ROUTES:
                mt = rx.match(parsed.path)
                if not mt:
                    continue
                allowed.append(m)
                if m != method:
                    continue
                if auth:
                    self.authorize()
                getattr(self, name)(*[urllib.parse.unquote(g) for g in mt.groups()])
                break
            else:
                if allowed:
                    raise ApiError(405, "method_not_allowed", "Method not allowed.", allow=", ".join(sorted(set(allowed))))
                raise ApiError(404, "not_found", "Unknown route.")
        except ApiError as e:
            try:
                self.send_error_json(e)
            except (BrokenPipeError, ConnectionResetError):
                pass
        except (BrokenPipeError, ConnectionResetError, ConnectionError, socket.timeout) as e:
            self.close_connection = True
            log.info("%s %s: connection lost (%s)", self.command, parsed.path, type(e).__name__)
        except Exception:
            log.exception("%s %s failed", self.command, parsed.path)
            self.close_connection = True
            try:
                self.send_json(500, {"error": {"code": "internal_error", "message": "Internal server error."}}, {"Connection": "close"})
            except Exception:
                pass
        log.info("%s %s %s %.0fms ip=%s", self.command, parsed.path, self._status, (time.time() - t0) * 1000, self.client_ip())

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = lambda self: self.dispatch()

    # -- routes -----------------------------------------------------------------------------
    def health(self):
        store = self.app.store
        with store.lock:
            jobs = store.all_jobs()
        self.send_json(200, {"ok": True, "version": VERSION, "apiVersion": API_VERSION, "serverTime": now_iso(),
                             "startedAt": self.app.started_at,
                             "queueLength": sum(1 for j in jobs if j["state"] == "queued"),
                             "processing": any(j["state"] == "processing" for j in jobs)})

    def upload_view(self, meta):
        got = self.app.store.received_chunks(meta["uploadID"])
        return {
            "uploadID": meta["uploadID"], "captureID": meta["captureID"], "filename": meta["filename"],
            "totalBytes": meta["totalBytes"], "sha256": meta["sha256"], "chunkSize": meta["chunkSize"],
            "chunkCount": meta["chunkCount"], "receivedChunks": got,
            "receivedBytes": sum(self.expected_chunk_size(meta, n) for n in got),
            "state": meta["state"], "jobID": meta.get("jobID"), "detail": meta["detail"],
            "autoComplete": bool(meta.get("autoComplete")),
            "createdAt": meta["createdAt"], "expiresAt": now_iso(meta["updatedAtEpoch"] + RETENTION_SECONDS),
        }

    @staticmethod
    def expected_chunk_size(meta, n):
        if n < meta["chunkCount"] - 1:
            return meta["chunkSize"]
        return meta["totalBytes"] - meta["chunkSize"] * (meta["chunkCount"] - 1)

    def create_upload(self):
        b = self.read_json_body()

        def field(name, typ, required=True):
            v = b.get(name)
            if v is None:
                if required:
                    raise ApiError(400, "invalid_field", "Missing field '%s'." % name, field=name)
                return None
            if typ is int and isinstance(v, bool) or not isinstance(v, typ):
                raise ApiError(400, "invalid_field", "Field '%s' has the wrong type." % name, field=name)
            return v

        capture = field("captureID", str)
        if not ID_RE.match(capture):
            raise ApiError(400, "invalid_field", "captureID must be 1-128 characters of A-Z a-z 0-9 . _ -", field="captureID")
        filename = os.path.basename(field("filename", str))
        if not filename or not filename.lower().endswith(".zip") or len(filename) > 200:
            raise ApiError(400, "invalid_field", "filename must end in .zip", field="filename")
        total = field("totalBytes", int)
        if total <= 0:
            raise ApiError(400, "invalid_field", "totalBytes must be positive.", field="totalBytes")
        if total > MAX_UPLOAD_BYTES:
            raise ApiError(413, "upload_too_large", "That capture is %.1f GB; the limit is 8 GB. Remove some photos and try again." % (total / 1e9),
                           maxBytes=MAX_UPLOAD_BYTES, totalBytes=total)
        sha = field("sha256", str).lower()
        if not HEX64_RE.match(sha):
            raise ApiError(400, "invalid_field", "sha256 must be 64 lowercase hex characters.", field="sha256")
        detail = field("detail", str, required=False) or "full"
        if detail not in DETAILS:
            raise ApiError(400, "invalid_field", "detail must be one of full, raw, custom, phone.", field="detail")
        texture = field("texture", str, required=False) or "8k"
        if texture not in TEXTURES:
            raise ApiError(400, "invalid_field", "texture must be 4k or 8k.", field="texture")
        obj = field("obj", bool, required=False)
        obj = bool(obj) if obj is not None else False
        max_polys = field("maxPolygons", int, required=False)
        if max_polys is not None and not (10000 <= max_polys <= 20000000):
            raise ApiError(400, "invalid_field", "maxPolygons must be between 10,000 and 20,000,000.", field="maxPolygons")
        chunk = field("chunkSize", int, required=False)
        if chunk is None:
            chunk = CHUNK_SIZE
        elif chunk % MiB or not (MIN_CHUNK <= chunk <= MAX_CHUNK):
            raise ApiError(400, "invalid_field", "chunkSize must be a whole number of MiB between 4 MiB and 64 MiB.", field="chunkSize")
        title = field("title", str, required=False)
        title = (title or "").strip()[:120] or None
        notify = field("notify", bool, required=False)
        auto_complete = bool(field("autoComplete", bool, required=False))

        store = self.app.store
        with store.lock:
            free = free_bytes(store.data)
            reserved = store.reserved_upload_bytes()
            need = FREE_SPACE_FACTOR * total
            if free - reserved < need:
                raise ApiError(507, "insufficient_storage",
                               "The Mac doesn't have enough free disk space for this capture right now. Try again later.",
                               freeBytes=free - reserved, requiredBytes=need)
            uid = new_id("up")
            os.makedirs(os.path.join(store.uploads_dir, uid, "chunks"))
            t = time.time()
            meta = {"uploadID": uid, "captureID": capture, "filename": filename, "totalBytes": total, "sha256": sha,
                    "chunkSize": chunk, "chunkCount": (total + chunk - 1) // chunk, "detail": detail,
                    "texture": texture, "obj": obj, "maxPolygons": max_polys, "title": title,
                    "notify": True if notify is None else notify, "state": "open", "autoComplete": auto_complete,
                    "createdAt": now_iso(t), "updatedAtEpoch": t}
            store.save_upload(meta)
        log.info("upload %s created: capture=%s %d bytes, %d chunks, detail=%s", uid, capture, total, meta["chunkCount"], detail)
        self.send_json(201, self.upload_view(meta))

    def get_upload(self, uid):
        store = self.app.store
        with store.lock:
            meta = store.load_upload(uid)
        self.send_json(200, self.upload_view(meta))

    def delete_upload(self, uid):
        store = self.app.store
        with store.lock:
            store.load_upload(uid)
            shutil.rmtree(store.upload_dir(uid), ignore_errors=True)
        self.send_json(200, {"deleted": True, "uploadID": uid})

    def put_chunk(self, uid, n):
        n = int(n)
        store = self.app.store
        with store.lock:
            meta = store.load_upload(uid)
        if meta["state"] != "open":
            raise ApiError(409, "upload_completed", "This upload is already complete.", jobID=meta.get("jobID"))
        if n >= meta["chunkCount"]:
            raise ApiError(400, "invalid_chunk_index", "Chunk index out of range (0-%d)." % (meta["chunkCount"] - 1), chunkCount=meta["chunkCount"])
        expected = self.expected_chunk_size(meta, n)
        te = (self.headers.get("Transfer-Encoding") or "").lower()
        cl = self.headers.get("Content-Length")
        if "chunked" not in te:
            if cl is None:
                raise ApiError(411, "length_required", "Content-Length is required.")
            if int(cl) != expected:
                raise ApiError(400, "chunk_size_mismatch", "Chunk %d must be exactly %d bytes; got Content-Length %s." % (n, expected, cl),
                               expectedBytes=expected, receivedBytes=int(cl))
        want_sha = (self.headers.get("X-Chunk-SHA256") or "").strip().lower() or None
        if want_sha and not HEX64_RE.match(want_sha):
            raise ApiError(400, "invalid_header", "X-Chunk-SHA256 must be 64 hex characters.")
        cdir = os.path.join(store.upload_dir(uid), "chunks")
        tmp = os.path.join(cdir, "%d.part.tmp-%s" % (n, uuid.uuid4().hex[:8]))
        h = hashlib.sha256()
        got = 0
        ok = False
        try:
            with open(tmp, "wb") as f:
                for block in self.iter_body(expected):
                    f.write(block)
                    h.update(block)
                    got += len(block)
                f.flush()
                os.fsync(f.fileno())
            if got != expected:
                raise ApiError(400, "chunk_size_mismatch", "Chunk %d must be exactly %d bytes; received %d." % (n, expected, got),
                               expectedBytes=expected, receivedBytes=got)
            digest = h.hexdigest()
            if want_sha and not hmac.compare_digest(digest, want_sha):
                raise ApiError(400, "chunk_sha256_mismatch", "Chunk %d was corrupted in transit; upload it again." % n, expected=want_sha, actual=digest)
            with store.lock:
                meta = store.load_upload(uid)
                if meta["state"] != "open":
                    raise ApiError(409, "upload_completed", "This upload is already complete.", jobID=meta.get("jobID"))
                os.replace(tmp, os.path.join(cdir, "%d.part" % n))
                ok = True
                meta["updatedAtEpoch"] = time.time()
                store.save_upload(meta)
                received = store.received_chunks(uid)
        finally:
            if not ok:
                try:
                    os.remove(tmp)
                except OSError:
                    pass
        auto = bool(meta.get("autoComplete")) and len(received) == meta["chunkCount"]
        if auto:
            # Phones upload chunks from a background URLSession while the app is suspended, so they
            # can't call /complete themselves: assemble + enqueue as soon as the last chunk lands.
            threading.Thread(target=auto_complete_upload, args=(store, uid), daemon=True).start()
        self.send_json(200, {"uploadID": uid, "index": n, "bytes": got, "sha256": digest,
                             "receivedChunks": received, "chunkCount": meta["chunkCount"], "autoCompleting": auto})

    def complete_upload(self, uid):
        result = assemble_upload(self.app.store, uid)
        self.send_json(200 if result["alreadyCompleted"] else 201, result)

    def job_view(self, job, queue=None):
        store = self.app.store
        v = {k: job.get(k) for k in ("jobID", "captureID", "title", "state", "detail", "message", "polygons", "createdAt",
                                     "startedAt", "finishedAt", "textures", "error", "restarts", "buildSeconds", "obj")}
        v["files"] = job.get("files") or []
        v["progress"] = job.get("progress", 0.0)
        v["stage"] = job.get("stage")
        v["etaSeconds"] = None
        v["queuePosition"] = None
        if job["state"] == "queued":
            q = queue if queue is not None else store.queued_jobs()
            ids = [j["jobID"] for j in q]
            v["queuePosition"] = ids.index(job["jobID"]) + 1 if job["jobID"] in ids else None
            v["message"] = "Waiting for the Mac (%d in line)" % v["queuePosition"] if v["queuePosition"] and v["queuePosition"] > 1 else (job.get("message") or "Waiting for the Mac")
        elif job["state"] == "processing":
            v["queuePosition"] = 0
            st = read_json(os.path.join(store.job_dir(job["jobID"]), "status.json"), {}) or {}
            frac = float(st.get("fraction") or 0)
            phase = st.get("state")
            # Map the CLI's phases into one 0-1 bar: unzip 0-2%, photogrammetry 2-97%, checks 97-100%.
            if phase in ("starting", "extracting", "waiting", None):
                v["progress"] = 0.01
            elif phase == "processing":
                v["progress"] = round(0.02 + 0.95 * frac, 4)
            elif phase == "inspecting":
                v["progress"] = 0.97
            v["stage"] = st.get("stage") or phase
            if st.get("etaSeconds") is not None:
                v["etaSeconds"] = int(st["etaSeconds"])
            v["message"] = st.get("message") or job.get("message")
            if phase == "waiting":
                v["message"] = "Waiting for another build on the Mac to finish"
            if st.get("attempt", 1) and st.get("attempt", 1) > 1:
                v["message"] += " (retrying with different settings)"
        if job["state"] != "done":
            v["files"] = [f for f in v["files"] if f["name"] == "recon-log.txt"]
        return v

    DIAG_FIELDS = {"captureID": str, "uploadID": str, "event": str, "phase": str, "message": str, "errorDomain": str,
                   "errorCode": int, "chunk": int, "chunkSize": int, "received": int, "chunkCount": int,
                   "appBuild": str, "device": str, "appState": str}

    def diagnostics(self):
        """Phone-side events (upload errors, phase changes) so the Mac's log shows both ends."""
        b = self.read_json_body(limit=16 * 1024)
        rec = {"at": now_iso(), "ip": self.client_ip()}
        for k, typ in self.DIAG_FIELDS.items():
            v = b.get(k)
            if isinstance(v, typ) and not isinstance(v, bool):
                rec[k] = v[:500] if isinstance(v, str) else v
        if not rec.get("event"):
            raise ApiError(400, "invalid_field", "event is required.", field="event")
        log.info("phone: %s", json.dumps(rec, sort_keys=True))
        try:
            with open(os.path.join(self.app.log_dir, "phone-diagnostics.jsonl"), "a") as f:
                f.write(json.dumps(rec, sort_keys=True) + "\n")
        except OSError:
            pass
        self.send_json(200, {"ok": True})

    def list_jobs(self):
        cap = (self.query.get("captureID") or [None])[0]
        store = self.app.store
        with store.lock:
            jobs = store.all_jobs()
            queue = sorted([j for j in jobs if j["state"] == "queued"], key=lambda j: (j["createdAt"], j["jobID"]))
            if cap:
                jobs = [j for j in jobs if j["captureID"] == cap]
            jobs.sort(key=lambda j: (j["createdAt"], j["jobID"]), reverse=True)
            views = [self.job_view(j, queue) for j in jobs[:100]]
        self.send_json(200, {"jobs": views})

    def get_job(self, jid):
        store = self.app.store
        with store.lock:
            job = store.load_job(jid)
            v = self.job_view(job)
        self.send_json(200, v)

    def delete_job(self, jid):
        store = self.app.store
        with store.lock:
            job = store.load_job(jid)
            was = job["state"]
        if was == "processing":
            self.app.worker.cancel(jid)
            for _ in range(100):  # up to 10 s for the build to stop
                with store.lock:
                    if not (self.app.worker.current and self.app.worker.current[0] == jid):
                        break
                time.sleep(0.1)
        with store.lock:
            shutil.rmtree(store.job_dir(jid), ignore_errors=True)
            store.wake.notify_all()
        log.info("job %s deleted (was %s)", jid, was)
        self.send_json(200, {"deleted": True, "jobID": jid, "previousState": was})

    def get_file(self, jid, name):
        store = self.app.store
        if name not in FILE_NAMES:
            raise ApiError(404, "file_not_found", "Unknown file name.", available=list(FILE_NAMES))
        with store.lock:
            job = store.load_job(jid)
        info = next((f for f in job.get("files") or [] if f["name"] == name), None)
        path = os.path.join(store.job_dir(jid), "out", name)
        if name == "recon-log.txt" and job["state"] in ("queued", "processing") and os.path.isfile(path):
            info = {"name": name, "bytes": os.path.getsize(path), "sha256": None}  # live log
        if not info or not os.path.isfile(path):
            raise ApiError(404, "file_not_found", "That file isn't available for this job (yet).")
        size = os.path.getsize(path)
        etag = '"%s"' % info["sha256"] if info.get("sha256") else None
        start, end = 0, size - 1
        partial = False
        rng = self.headers.get("Range")
        if_range = self.headers.get("If-Range")
        if rng and (not if_range or (etag and if_range.strip() == etag)):
            m = re.match(r"^bytes=(\d*)-(\d*)$", rng.strip())
            if not m or (m.group(1) == "" and m.group(2) == ""):
                raise ApiError(416, "range_not_satisfiable", "Bad Range header.", size=size)
            if m.group(1) == "":
                suffix = int(m.group(2))
                start = max(size - suffix, 0)
            else:
                start = int(m.group(1))
                if m.group(2):
                    end = min(int(m.group(2)), size - 1)
            if start >= size or start > end:
                self.send_response(416)
                self.send_header("Content-Range", "bytes */%d" % size)
                self.send_header("Content-Length", "0")
                self.end_headers()
                self._status = 416
                return
            partial = True
        length = end - start + 1
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", CONTENT_TYPES.get(name, "application/octet-stream"))
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % name)
        self.send_header("Cache-Control", "private, no-transform")
        if etag:
            self.send_header("ETag", etag)
        if info.get("sha256"):
            self.send_header("X-Content-SHA256", info["sha256"])
        if partial:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()
        self._status = 206 if partial else 200
        if self.command == "HEAD":
            return
        with open(path, "rb") as f:
            f.seek(start)
            left = length
            while left:
                b = f.read(min(READ_BLOCK, left))
                if not b:
                    break
                self.wfile.write(b)
                left -= len(b)


class App:
    pass


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64


def load_api_key(path):
    try:
        st = os.stat(path)
    except OSError:
        sys.exit("error: API key file %s not found. Create it with: umask 077; openssl rand -hex 32 > %s" % (path, path))
    if st.st_mode & 0o077:
        os.chmod(path, 0o600)
    with open(path) as f:
        key = f.read().strip()
    if len(key) < 32:
        sys.exit("error: API key in %s is too short (need >= 32 characters)" % path)
    return key


def find_cli():
    env = os.environ.get("ASBUILT_RECON_BIN")
    cands = [env] if env else []
    here = os.path.dirname(os.path.abspath(__file__))
    cands += [os.path.join(here, "asbuilt-recon"), os.path.join(here, "..", ".build", "release", "asbuilt-recon")]
    for c in cands:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return os.path.abspath(c)
    sys.exit("error: asbuilt-recon binary not found (set ASBUILT_RECON_BIN)")


def setup_logging(log_dir, verbose):
    os.makedirs(log_dir, exist_ok=True)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(threadName)s %(message)s")
    fh = logging.handlers.RotatingFileHandler(os.path.join(log_dir, "server.log"), maxBytes=10 * MiB, backupCount=5)
    fh.setFormatter(fmt)
    log.addHandler(fh)
    if verbose:
        sh = logging.StreamHandler(sys.stdout)
        sh.setFormatter(fmt)
        log.addHandler(sh)
    log.setLevel(logging.INFO)


def main():
    ap = argparse.ArgumentParser(prog="asbuilt-recon serve")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--data", default=DATA_DIR)
    ap.add_argument("--key-file", default=os.path.join(CONFIG_DIR, "api_key"))
    ap.add_argument("--config", default=os.path.join(CONFIG_DIR, "config.json"))
    ap.add_argument("--log-dir", default=LOG_DIR)
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()

    setup_logging(a.log_dir, a.verbose)
    app = App()
    app.started_at = now_iso()
    app.log_dir = a.log_dir
    app.api_key = load_api_key(a.key_file)
    cfg = read_json(a.config, {}) or {}
    app.store = Store(a.data)
    app.limiter = AuthLimiter()
    cli = find_cli()
    app.worker = Worker(app.store, cli, Notifier(cfg))
    app.worker.requeue_interrupted()
    Handler.app = app
    httpd = Server((a.host, a.port), Handler)
    httpd.timeout = 30

    def stop(signum, frame):
        log.info("signal %d: shutting down", signum)
        app.worker.stopping = True
        cur = app.worker.current

        def finish():
            # SIGTERM lets the CLI cancel PhotogrammetrySession and delete its multi-GB temp folder;
            # launchd's ExitTimeOut is 20 s, so give it 15 s before SIGKILL. The job stays
            # 'processing' on disk and is requeued at the head of the queue on the next start.
            if cur:
                try:
                    cur[1].send_signal(signal.SIGTERM)
                    cur[1].wait(15)
                except subprocess.TimeoutExpired:
                    cur[1].kill()
                except Exception:
                    pass
            httpd.shutdown()

        threading.Thread(target=finish, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    app.worker.start()
    Janitor(app.store).start()
    log.info("asbuilt-recon server %s listening on http://%s:%d (data %s, cli %s, notify=%s)", VERSION, a.host, a.port, a.data, cli,
             app.worker.notifier.enabled)
    httpd.serve_forever(poll_interval=0.5)
    log.info("stopped")


if __name__ == "__main__":
    main()
