"""asbuilt-recon v1 HTTP server for the cloud: the Mac's recon_server.py with its build worker swapped for one
that runs each build in its own cloud container, several at once.

  * every route, error code, auth rule, upload/resume and download behaviour comes from
    MacRecon/server/recon_server.py itself (imported, not forked), so the apps only change the base URL;
    only its user-facing wording (recon_server.MESSAGES) is swapped for cloud wording;
  * `CloudWorker` runs up to $ASBUILT_MAX_CONCURRENT_BUILDS (default 3) builds at once, oldest first; each
    `build()` hands its job to a Backend (Modal CPU function = one container per build, or a local process
    for tests), mirrors live progress into the job's status.json and then does the exact same
    post-processing as the Mac (model.glb via recon_server.obj_to_glb, files + sha256, state, messages).

Run locally (tests, or on any Linux GPU box):
    python cloud_server.py --data /tmp/asb --key-file key.txt --backend local
On Modal this module is started by modal_app.py (`api` web server).
"""
import argparse
import json
import logging
import os
import shutil
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def import_recon_server():
    """recon_server.py lives in MacRecon/server in the repo and at /app/recon_server.py in the image."""
    for p in (os.environ.get("RECON_SERVER_DIR"), "/app", os.path.join(HERE, "..", "MacRecon", "server")):
        if p and os.path.isfile(os.path.join(p, "recon_server.py")):
            if p not in sys.path:
                sys.path.insert(0, p)
            break
    import recon_server
    return recon_server


rs = import_recon_server()
log = logging.getLogger("asbuilt-recon")

DEFAULT_MAX_CONCURRENT_BUILDS = 3

# What the phone shows while a cloud job waits or fails (recon_server's defaults name the Mac).
CLOUD_MESSAGES = {
    "queued": "Queued in the cloud",
    "queued_in_line": "Queued in the cloud (%d in line)",
    "starting": "Starting in the cloud",
    "waiting_other_build": "Waiting for a free cloud builder",
    "internal_error": "The cloud server hit an internal error while building. Try again.",
    "insufficient_storage": "The cloud doesn't have enough free space for this capture right now. Try again later.",
}


def max_concurrent_builds():
    try:
        return max(1, int(os.environ.get("ASBUILT_MAX_CONCURRENT_BUILDS") or DEFAULT_MAX_CONCURRENT_BUILDS))
    except ValueError:
        return DEFAULT_MAX_CONCURRENT_BUILDS


# ---------------------------------------------------------------------------------------------
# Backends


class LocalBackend:
    """Runs asbuilt_cloud.pipeline.build in a child process on this machine.
    `stages` = "real" (needs CUDA, COLMAP etc.) or "fake" (tests: CPU-only stand-ins for the GPU stages)."""

    def __init__(self, stages="real"):
        self.stages = stages
        self.procs = {}

    def spawn(self, job, input_zip, out_dir, status_path):
        args = [sys.executable, "-m", "asbuilt_cloud.runner", "--input", input_zip, "--out", out_dir,
                "--status-file", status_path, "--options", json.dumps(build_options(job)), "--stages", self.stages]
        env = dict(os.environ, PYTHONPATH=HERE + os.pathsep + os.environ.get("PYTHONPATH", ""))
        with open(os.path.join(os.path.dirname(out_dir), "console.log"), "ab") as console:
            p = subprocess.Popen(args, stdout=console, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env)
        self.procs[str(p.pid)] = p
        return str(p.pid)

    def poll(self, call_id, job, status_path):
        """-> (finished, status dict or None). Status is written by the child straight into status_path."""
        p = self.procs.get(call_id)
        if p is None:
            return True, None  # lost (server restarted): treat as finished; result.json decides
        return p.poll() is not None, None

    def cancel(self, call_id):
        p = self.procs.get(call_id)
        if p and p.poll() is None:
            p.terminate()

    def fetch_outputs(self, job, out_dir):
        return  # already written in place


def build_options(job):
    return {"detail": job.get("detail") or "full", "texture": job.get("texture") or "8k",
            "maxPolygons": job.get("maxPolygons"), "obj": True, "title": job.get("title") or job.get("captureID"),
            "jobID": job.get("jobID")}


# ---------------------------------------------------------------------------------------------


class CloudWorker(rs.Worker):
    """Up to `concurrency` builds at once (one slot thread each, see rs.Worker.slot_loop); every build is its own
    backend call (= its own Modal container). Per-job state lives in job.json, so slots share nothing else."""
    POLL_SECONDS = 3.0

    def __init__(self, store, backend, notifier, concurrency=None):
        super().__init__(store, "cloud", notifier,
                         concurrency=max_concurrent_builds() if concurrency is None else concurrency)
        self.backend = backend
        # Copying outputs + GLB conversion run on the small 1-CPU API container: one job at a time (the builds
        # themselves still overlap).
        self.finish_lock = threading.Lock()

    def requeue_interrupted(self):
        """API container restarted (scale-from-zero) while cloud builds ran: put each job back in the queue
        *keeping* its gpuCallID, so build() re-attaches to the running call instead of starting over."""
        with self.store.lock:
            for job in self.store.all_jobs():
                if job["state"] != "processing":
                    continue
                job["state"] = "queued"
                if not job.get("gpuCallID"):
                    job["restarts"] = job.get("restarts", 0) + 1
                job["message"] = "Reconnecting to the cloud build" if job.get("gpuCallID") else "Waiting to restart"
                self.store.save_job(job)
                log.info("requeued %s (gpuCallID=%s)", job["jobID"], job.get("gpuCallID"))

    def next_job(self, queued):
        """Builds that are still running in the cloud (re-attach after a restart) first, then oldest first."""
        return next((j for j in queued if j.get("gpuCallID")), queued[0])

    def cancel(self, jid):
        with self.store.lock:
            self.cancel_requested.add(jid)
            call_id = self.running.get(jid)
        if call_id:
            try:
                self.backend.cancel(call_id)
            except Exception:
                log.exception("cancel %s", jid)

    def build(self, job):
        jid = job["jobID"]
        jdir = self.store.job_dir(jid)
        out = os.path.join(jdir, "out")
        status_path = os.path.join(jdir, "status.json")
        t0 = time.time()
        call_id = job.get("gpuCallID")
        if not call_id:
            shutil.rmtree(out, ignore_errors=True)
            os.makedirs(out, exist_ok=True)
            try:
                os.remove(status_path)
            except OSError:
                pass
            call_id = self.backend.spawn(job, os.path.join(jdir, "input.zip"), out, status_path)
            log.info("job %s: spawned cloud build %s", jid, call_id)
            with self.store.lock:
                try:
                    j = self.store.load_job(jid)
                except rs.ApiError:
                    j = None  # deleted while the call was being spawned
                if j is not None:
                    j["gpuCallID"] = call_id
                    j["gpuSpawnedAt"] = rs.now_iso()
                    self.store.save_job(j)
            if j is None:
                log.info("job %s: deleted during spawn; cancelling %s", jid, call_id)
                self._cancel_call(call_id)
                with self.store.lock:
                    self.cancel_requested.discard(jid)
                return
        else:
            log.info("job %s: re-attached to cloud build %s", jid, call_id)
        with self.store.lock:
            self.running[jid] = call_id
            cancel_now = jid in self.cancel_requested
        if cancel_now:
            self._cancel_call(call_id)
        finished = False
        while not finished:
            try:
                finished, st = self.backend.poll(call_id, job, status_path)
            except Exception:
                log.exception("job %s: poll failed", jid)
                finished, st = False, None
            if st:
                try:
                    rs.atomic_write_json(status_path, st)
                except OSError:
                    pass
            with self.store.lock:
                cancelled = jid in self.cancel_requested
            if cancelled or self.stopping:
                break
            if not finished:
                time.sleep(self.POLL_SECONDS)
        with self.store.lock:
            cancelled = jid in self.cancel_requested
            if cancelled or self.stopping:
                self.running.pop(jid, None)
                self.cancel_requested.discard(jid)
        if cancelled:
            log.info("job %s: cancelled", jid)
            return
        if self.stopping:
            return  # stays 'processing' with its gpuCallID; the next start re-attaches
        try:
            with self.finish_lock:
                try:
                    self.backend.fetch_outputs(job, out)
                except Exception:
                    log.exception("job %s: fetching outputs failed", jid)
                self.finish(job, out, status_path, time.time() - t0)
        finally:
            with self.store.lock:
                self.running.pop(jid, None)
                self.cancel_requested.discard(jid)

    def _cancel_call(self, call_id):
        try:
            self.backend.cancel(call_id)
        except Exception:
            log.exception("cancel call %s", call_id)

    def finish(self, job, out, status_path, secs):
        """Same bookkeeping as recon_server.Worker.build after the CLI exits (kept in sync by tests)."""
        jid = job["jobID"]
        result = rs.read_json(os.path.join(out, "result.json"), {}) or {}
        ok = bool(result.get("ok"))
        glb_info, glb_error = None, None
        if job.get("glb") and ok:
            glb_info, glb_error = self.make_glb(job, out, status_path)
        if not job.get("obj"):
            try:
                os.remove(os.path.join(out, "model-obj.zip"))
            except OSError:
                pass
        files = []
        for name in rs.FILE_NAMES + EXTRA_FILES:
            path = os.path.join(out, name)
            if os.path.isfile(path):
                files.append({"name": name, "bytes": os.path.getsize(path), "sha256": rs.sha256_file(path),
                              "url": "/v1/jobs/%s/files/%s" % (jid, name)})
        with self.store.lock:
            try:
                j = self.store.load_job(jid)
            except rs.ApiError:
                return
            j.pop("gpuCallID", None)
            j["finishedAt"] = rs.now_iso()
            j["buildSeconds"] = round(result.get("totalSeconds") or secs, 1)
            j["files"] = files
            j["polygons"] = result.get("polygons")
            j["textures"] = [{"name": t["name"], "width": t["width"], "height": t["height"]} for t in result.get("textures", [])]
            j["usdcheckerPassed"] = result.get("usdcheckerPassed")
            j["engine"] = result.get("engine", "asbuilt-cloud")
            if result.get("splat"):
                j["splatInfo"] = result["splat"]
            if glb_info:
                j["glbInfo"] = glb_info
            if glb_error:
                j["glbError"] = glb_error
            if ok and any(f["name"] == "model.usdz" for f in files):
                j.update(state="done", progress=1.0, stage=None, etaSeconds=None,
                         message="Model ready: %s polygons." % ("{:,}".format(j["polygons"]) if j.get("polygons") else "?"))
            else:
                msg = result.get("errorMessage") or "The cloud build failed. The log has the details."
                j["state"] = "failed"
                j["message"] = msg
                j["error"] = {"code": "build_failed", "message": msg, "exitCode": 0 if ok else 1,
                              "technical": (result.get("errorTechnical") or "")[:2000]}
            # Successful builds don't need their photos any more. Failed ones keep input.zip (and out/recon-log.txt)
            # for the normal retention window, so the failure can be reproduced and diagnosed.
            if j["state"] == "done":
                try:
                    os.remove(os.path.join(self.store.job_dir(jid), "input.zip"))
                except OSError:
                    pass
            else:
                j["inputKept"] = os.path.isfile(os.path.join(self.store.job_dir(jid), "input.zip"))
            self.store.save_job(j)
        log.info("job %s: %s in %.0fs (polygons=%s)", jid, j["state"], secs, j.get("polygons"))


# Cloud-only downloads, served by the same files route (Range, sha256, HEAD) once registered below.
EXTRA_FILES = ("splat.ply",)


def register_extra_files():
    if "splat.ply" not in rs.FILE_NAMES:
        rs.FILE_NAMES = tuple(rs.FILE_NAMES) + EXTRA_FILES
        rs.CONTENT_TYPES["splat.ply"] = "application/octet-stream"


def use_cloud_wording():
    rs.MESSAGES.update(CLOUD_MESSAGES)


def make_app(data, api_key, backend, config=None, concurrency=None):
    """Builds the recon_server App wired to a CloudWorker (no sockets; tests and main() share it)."""
    register_extra_files()
    use_cloud_wording()
    if os.environ.get("CLOUD_IGNORE_DISK_CHECK") == "1":
        # Network volumes report meaningless statvfs numbers; the provider enforces quota instead.
        rs.free_bytes = lambda path: 1 << 50
    app = rs.App()
    app.started_at = rs.now_iso()
    app.log_dir = os.environ.get("ASBUILT_LOG_DIR") or os.path.join(data, "logs")
    os.makedirs(app.log_dir, exist_ok=True)
    app.api_key = api_key
    app.store = rs.Store(data)
    app.limiter = rs.AuthLimiter()
    app.worker = CloudWorker(app.store, backend, rs.Notifier(config or {}), concurrency=concurrency)
    app.worker.requeue_interrupted()
    rs.Handler.app = app
    return app


def serve(app, host, port):
    httpd = rs.Server((host, port), rs.Handler)
    httpd.timeout = 30
    app.worker.start()
    rs.Janitor(app.store).start()
    log.info("asbuilt-recon cloud server listening on http://%s:%d (data %s, %d builds at once)", host, port,
             app.store.data, app.worker.concurrency)
    return httpd


def main(argv=None):
    ap = argparse.ArgumentParser(prog="cloud_server")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--data", required=True)
    ap.add_argument("--key-file", default=None, help="else $ASBUILT_RECON_API_KEY")
    ap.add_argument("--backend", default="local", choices=["local", "local-fake", "modal"])
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args(argv)
    os.makedirs(a.data, exist_ok=True)
    log_dir = os.environ.get("ASBUILT_LOG_DIR") or os.path.join(a.data, "logs")
    rs.setup_logging(log_dir, a.verbose)
    key = rs.load_api_key(a.key_file) if a.key_file else os.environ.get("ASBUILT_RECON_API_KEY", "")
    if len(key) < 32:
        sys.exit("error: API key must be >= 32 characters (ASBUILT_RECON_API_KEY or --key-file)")
    if a.backend == "modal":
        from modal_backend import ModalBackend
        backend = ModalBackend()
    else:
        backend = LocalBackend("fake" if a.backend == "local-fake" else "real")
    app = make_app(a.data, key, backend)
    httpd = serve(app, a.host, a.port)
    try:
        httpd.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
