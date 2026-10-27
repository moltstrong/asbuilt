"""Backend that runs builds as Modal function calls (used by cloud_server.CloudWorker inside the API container).
The build function is $ASBUILT_BUILD_FUNCTION: "build_cpu" (OpenMVS, default) or "build_gpu" (optional splat path).

Data flow (no big payloads through function arguments):
  API container                         build container (modal_app.build_cpu)
  /data volume: jobs/<id>/input.zip ---> reads it from the same "asbuilt-data" volume (after .reload())
  modal.Dict "asbuilt-status"[<id>] <--- {status, logTail} every ~2 s
  /data volume: jobs/<id>/out/*  <------ writes outputs there, then .commit()
The API keeps live status.json / recon-log.txt in sync from the Dict so the v1 job route works unchanged.
"""
import os


class ModalBackend:
    APP_NAME = os.environ.get("MODAL_APP_NAME", "asbuilt-recon")

    def __init__(self, data_root="/data"):
        import modal
        self.modal = modal
        self.data_root = data_root
        self.volume = modal.Volume.from_name(os.environ.get("ASBUILT_VOLUME", "asbuilt-data"))
        self.status = modal.Dict.from_name(os.environ.get("ASBUILT_STATUS_DICT", "asbuilt-status"), create_if_missing=True)
        self.fn = modal.Function.from_name(self.APP_NAME, os.environ.get("ASBUILT_BUILD_FUNCTION", "build_cpu"))

    def _rel(self, path):
        return os.path.relpath(path, self.data_root)

    def spawn(self, job, input_zip, out_dir, status_path):
        from cloud_server import build_options
        self.volume.commit()  # make input.zip visible to the build container
        call = self.fn.spawn(job["jobID"], build_options(job), self._rel(input_zip))
        return call.object_id

    def poll(self, call_id, job, status_path):
        call = self.modal.FunctionCall.from_id(call_id)
        finished = False
        try:
            call.get(timeout=0)
            finished = True
        except TimeoutError:
            pass
        except Exception:  # the call raised / was cancelled / expired: finished (result.json decides)
            finished = True
        payload = self.status.get(job["jobID"], None) or {}
        log_tail = payload.get("logTail")
        if log_tail:
            out = os.path.join(os.path.dirname(status_path), "out")
            os.makedirs(out, exist_ok=True)
            with open(os.path.join(out, "recon-log.txt"), "w") as f:
                f.write(log_tail)
        return finished, payload.get("status")

    def cancel(self, call_id):
        self.modal.FunctionCall.from_id(call_id).cancel(terminate_containers=True)

    def fetch_outputs(self, job, out_dir):
        """Copy results/<id>/out (written + committed by the build container) into jobs/<id>/out."""
        import shutil
        import time
        jid = job["jobID"]
        src_rel = "results/%s/out" % jid
        src = os.path.join(self.data_root, src_rel)
        reloaded = False
        for attempt in range(5):
            try:
                self.volume.reload()
                reloaded = True
                break
            except Exception:  # "volume busy" while an upload chunk is being written: retry
                time.sleep(2 + 2 * attempt)
        os.makedirs(out_dir, exist_ok=True)
        if reloaded and os.path.isdir(src):
            for name in os.listdir(src):
                s, d = os.path.join(src, name), os.path.join(out_dir, name)
                if os.path.isdir(s):
                    shutil.rmtree(d, ignore_errors=True)
                    shutil.copytree(s, d)
                else:
                    shutil.copy2(s, d)
            shutil.rmtree(os.path.join(self.data_root, "results", jid), ignore_errors=True)
        else:  # read straight from the volume service (no reload needed)
            for e in self.volume.listdir(src_rel, recursive=True):
                rel = os.path.relpath(e.path, src_rel)
                dest = os.path.join(out_dir, rel)
                if e.type.name == "DIRECTORY":
                    os.makedirs(dest, exist_ok=True)
                    continue
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with open(dest, "wb") as f:
                    self.volume.read_file_into_fileobj(e.path, f)
        try:
            self.status.pop(jid)
        except KeyError:
            pass
