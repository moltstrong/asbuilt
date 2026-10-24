"""Body of the GPU function (Modal) - runs one build and publishes progress + outputs.

    run_job(job_id, options, input_zip, results_dir, publish)

* runs pipeline.build in a child process (so a crash/OOM can't take the publisher down),
* every ~2 s calls publish({"status": <status.json>, "logTail": <last 64 KiB of recon-log.txt>}),
* when finished, copies out/ (result.json, model.usdz, obj/, model-obj.zip, splat.ply, thumbnail.png,
  recon-log.txt) to results_dir/<job_id>/out and returns the result summary.
`publish` is a modal.Dict setter in production and a plain dict setter in tests.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

LOG_TAIL = 64 * 1024


def _read_json(p):
    try:
        with open(p) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _tail(p, n=LOG_TAIL):
    try:
        with open(p, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - n))
            return f.read().decode("utf-8", "replace")
    except OSError:
        return ""


def run_job(job_id, options, input_zip, results_dir, publish, stages="real", work_root=None, poll=2.0):
    work = tempfile.mkdtemp(prefix="asb-%s-" % job_id, dir=work_root)
    out = os.path.join(work, "job", "out")
    os.makedirs(out)
    status = os.path.join(work, "job", "status.json")
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    env = dict(os.environ, PYTHONPATH=here + os.pathsep + os.environ.get("PYTHONPATH", ""))
    cmd = [sys.executable, "-m", "asbuilt_cloud.runner", "--input", input_zip, "--out", out, "--status-file", status,
           "--options", json.dumps(options), "--stages", stages]
    t0 = time.time()
    with open(os.path.join(work, "console.log"), "ab") as console:
        p = subprocess.Popen(cmd, stdout=console, stderr=subprocess.STDOUT, env=env)
        last = None
        while True:
            rc = p.poll()
            st = _read_json(status)
            payload = {"status": st, "logTail": _tail(os.path.join(out, "recon-log.txt")), "updatedAt": time.time()}
            if st != last or rc is not None:
                try:
                    publish(payload)
                except Exception:  # noqa: BLE001  never let the status channel kill a build
                    pass
                last = st
            if rc is not None:
                break
            time.sleep(poll)
    result = _read_json(os.path.join(out, "result.json"))
    if result is None:  # child died hard (OOM-kill etc.) before writing result.json
        result = {"ok": False, "errorMessage": "The cloud build stopped unexpectedly.",
                  "errorTechnical": _tail(os.path.join(work, "console.log"), 4000), "engine": "asbuilt-cloud"}
        with open(os.path.join(out, "result.json"), "w") as f:
            json.dump(result, f)
    final_status = _read_json(status)
    dest = os.path.join(results_dir, job_id, "out")
    shutil.rmtree(dest, ignore_errors=True)
    shutil.copytree(out, dest)
    shutil.rmtree(work, ignore_errors=True)
    summary = {"ok": bool(result.get("ok")), "polygons": result.get("polygons"), "exitCode": rc,
               "seconds": round(time.time() - t0, 1), "errorMessage": result.get("errorMessage")}
    try:
        publish({"status": final_status or {"state": "done" if summary["ok"] else "failed", "fraction": 1.0},
                 "logTail": _tail(os.path.join(dest, "recon-log.txt")), "finished": summary, "updatedAt": time.time()})
    except Exception:  # noqa: BLE001
        pass
    return summary
