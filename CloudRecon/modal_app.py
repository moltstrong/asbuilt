"""Modal deployment of the AsBuilt cloud reconstruction server (asbuilt-recon v1 API on a GPU backend).

    modal deploy CloudRecon/modal_app.py      # from the repo root; prints https://<workspace>--asbuilt-recon-api.modal.run

Two functions:
  api        CPU container, `@modal.web_server` running cloud_server.py (= MacRecon/server/recon_server.py's
             HTTP handler + a CloudWorker). max_containers=1 because the server keeps its queue/locks in-process
             (exactly like the Mac). Scales to zero after `scaledown_window`; on the next request it restarts and
             re-attaches to any GPU build still running (job.json keeps the FunctionCall id).
  build_gpu  GPU container (L40S by default, `ASBUILT_GPU` to change) running one build: pycolmap SfM (CUDA) ->
             gsplat MCMC 3DGS -> splat->mesh (TSDF) -> photo-baked texture -> USDZ/OBJ/GLB + splat.ply.
State: Volume "asbuilt-data" (uploads, jobs, outputs: same layout as the Mac's DATA dir),
       Dict "asbuilt-status" (live progress from the GPU container), Secret "asbuilt-recon" (ASBUILT_RECON_API_KEY).
"""
import os
import pathlib

import modal

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent
GPU = os.environ.get("ASBUILT_GPU", "L40S")
APP_NAME = os.environ.get("MODAL_APP_NAME", "asbuilt-recon")

app = modal.App(APP_NAME)
data = modal.Volume.from_name("asbuilt-data", create_if_missing=True)
status = modal.Dict.from_name("asbuilt-status", create_if_missing=True)
secret = modal.Secret.from_name("asbuilt-recon", required_keys=["ASBUILT_RECON_API_KEY"])

# Small CPU image for the HTTP API: stdlib server + modal client.
api_image = (
    modal.Image.debian_slim(python_version="3.11")
    .pip_install("modal>=1.0")
    .add_local_file(REPO / "MacRecon" / "server" / "recon_server.py", "/app/recon_server.py")
    .add_local_file(HERE / "cloud_server.py", "/app/cloud_server.py")
    .add_local_file(HERE / "modal_backend.py", "/app/modal_backend.py")
)

# GPU image: built from CloudRecon/Dockerfile (CUDA 12.4 + torch 2.4 + gsplat 1.5.3 + pycolmap-cuda12 4.2.1 ...).
gpu_image = (
    modal.Image.from_dockerfile(HERE / "Dockerfile", context_dir=HERE)
    .add_local_dir(HERE / "asbuilt_cloud", "/app/asbuilt_cloud")
)


@app.function(image=api_image, volumes={"/data": data}, secrets=[secret], max_containers=1,
              scaledown_window=20 * 60, timeout=24 * 3600, cpu=1.0, memory=2048)
@modal.concurrent(max_inputs=64)
@modal.web_server(8000, startup_timeout=60)
def api():
    import subprocess
    # Logs live off the volume: an always-open log file on /data would make every Volume.reload() fail ("volume busy").
    env = dict(os.environ, PYTHONPATH="/app", RECON_SERVER_DIR="/app", MODAL_APP_NAME=APP_NAME,
               CLOUD_IGNORE_DISK_CHECK="1", ASBUILT_LOG_DIR="/tmp/asbuilt-logs")
    subprocess.Popen(["python", "/app/cloud_server.py", "--host", "0.0.0.0", "--port", "8000", "--data", "/data",
                      "--backend", "modal", "--verbose"], env=env, cwd="/app")


@app.function(image=gpu_image, gpu=GPU, volumes={"/data": data}, timeout=3 * 3600, cpu=8.0, memory=32768,
              ephemeral_disk=100 * 1024, retries=0)
def build_gpu(job_id: str, options: dict, input_rel: str) -> dict:
    import sys
    sys.path.insert(0, "/app")
    from asbuilt_cloud.gpu_entry import run_job
    data.reload()  # see the API container's freshly committed input.zip
    input_zip = os.path.join("/data", input_rel)

    def publish(payload):
        status[job_id] = payload

    # Outputs go to /data/results/<id>/out. Only this container writes there; the API copies them into
    # jobs/<id>/out after a reload, so no file on the volume is ever written by both containers.
    r = run_job(job_id, options, input_zip, "/data/results", publish, stages="real", work_root="/tmp")
    data.commit()
    return r


@app.local_entrypoint()
def smoke(zip_path: str = "", detail: str = "phone"):
    """`modal run CloudRecon/modal_app.py --zip-path photos.zip` runs one GPU build without the HTTP API."""
    import json
    import uuid
    if not zip_path:
        print("pass --zip-path <photos.zip>")
        return
    jid = "job_smoke_" + uuid.uuid4().hex[:8]
    with data.batch_upload() as b:
        b.put_file(zip_path, "/jobs/%s/input.zip" % jid)
    r = build_gpu.remote(jid, {"detail": detail, "texture": "8k", "obj": True, "title": "smoke"},
                         "jobs/%s/input.zip" % jid)
    print(json.dumps(r, indent=1))
    print("outputs: modal volume ls asbuilt-data /results/%s/out" % jid)
