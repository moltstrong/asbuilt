"""Backend that runs builds as Modal function calls (used by cloud_server.CloudWorker inside the API container).
The build function is $ASBUILT_BUILD_FUNCTION: "build_cpu" (OpenMVS, default) or "build_gpu" (optional splat path).

Data flow (no big payloads through function arguments):
  API container                         build container (modal_app.build_cpu)
  /data volume: jobs/<id>/input.zip ---> reads it from the same "asbuilt-data" volume (after .reload())
  modal.Dict "asbuilt-status"[<id>] <--- {status, logTail} every ~2 s
  /data volume: results/<id>/out/* <---- writes outputs there, then .commit(); the API copies them into
                                         jobs/<id>/out through the volume service (no reload in the API container)
The API keeps live status.json / recon-log.txt in sync from the Dict so the v1 job route works unchanged.
Several builds run at once (one CloudWorker slot thread each): every call is its own container and its own
Dict key; volume commits and output copies in this container are serialised by `volume_lock`.
"""
import os
import threading


class ModalBackend:
    APP_NAME = os.environ.get("MODAL_APP_NAME", "asbuilt-recon")

    def __init__(self, data_root="/data"):
        import modal
        self.modal = modal
        self.data_root = data_root
        self.volume = modal.Volume.from_name(os.environ.get("ASBUILT_VOLUME", "asbuilt-data"))
        self.status = modal.Dict.from_name(os.environ.get("ASBUILT_STATUS_DICT", "asbuilt-status"), create_if_missing=True)
        self.fn = modal.Function.from_name(self.APP_NAME, os.environ.get("ASBUILT_BUILD_FUNCTION", "build_cpu"))
        self.volume_lock = threading.Lock()  # one commit / output copy of the shared volume at a time

    def _rel(self, path):
        return os.path.relpath(path, self.data_root)

    def spawn(self, job, input_zip, out_dir, status_path):
        from cloud_server import build_options
        with self.volume_lock:
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
        """Copy results/<id>/out (written + committed by the build container) into jobs/<id>/out.

        Reads through the volume service, never `Volume.reload()`: a reload remounts /data in this container, and
        with several builds at once the other slots' polls, job.json writes and the phone's chunk PUTs would hit
        EPERM / "not found" for that moment (seen live: "PermissionError: '/data/jobs'")."""
        with self.volume_lock:
            return self._fetch_outputs(job, out_dir)

    def _fetch_outputs(self, job, out_dir):
        jid = job["jobID"]
        src_rel = "results/%s/out" % jid
        os.makedirs(out_dir, exist_ok=True)
        try:
            entries = list(self.volume.listdir(src_rel, recursive=True))
        except Exception:  # the build wrote nothing (crashed before its first output): finish() reports it
            entries = []
        for e in entries:
            rel = os.path.relpath(e.path.lstrip("/"), src_rel)
            if rel.startswith(".."):
                continue
            dest = os.path.join(out_dir, rel)
            if e.type.name == "DIRECTORY":
                os.makedirs(dest, exist_ok=True)
                continue
            if e.type.name != "FILE":
                continue
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            tmp = dest + ".part"
            with open(tmp, "wb") as f:
                self.volume.read_file_into_fileobj(e.path, f)
            os.replace(tmp, dest)
        try:
            self.volume.remove_file("results/%s" % jid, recursive=True)
        except Exception:
            pass  # leftovers are harmless (a later deploy can sweep results/)
        try:
            self.status.pop(jid)
        except KeyError:
            pass
        return len(entries)
