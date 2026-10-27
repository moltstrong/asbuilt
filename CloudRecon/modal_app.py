"""Modal deployment of the AsBuilt cloud reconstruction server (asbuilt-recon v1 API, CPU OpenMVS builds).

    modal deploy CloudRecon/modal_app.py      # from the repo root; prints https://<workspace>--asbuilt-recon-api.modal.run

Functions:
  api        CPU container, `@modal.web_server` running cloud_server.py (= MacRecon/server/recon_server.py's
             HTTP handler + a CloudWorker). max_containers=1 because the server keeps its queue/locks in-process
             (exactly like the Mac). The CloudWorker runs up to ASBUILT_MAX_CONCURRENT_BUILDS (default 3) builds
             at once, oldest first, each one its own build_cpu call/container. Scales to zero after
             `scaledown_window`; on the next request it restarts and re-attaches to every build still running
             (job.json keeps the FunctionCall id).
  build_cpu  CPU container (16 cores / 32 GiB, no GPU) running one build: HEIC decode (+ LiDAR depth) ->
             pycolmap SfM -> OpenMVS v2.4.0 densify / mesh / refine -> automatic crop -> two-band photo bake
             (250k tris, 8K) -> metric scale from LiDAR, Y-up, object at the origin -> USDZ/OBJ (+GLB by the API).
  build_gpu  OPTIONAL (deploy with ASBUILT_ENABLE_SPLAT=1): the older splat path on an NVIDIA GPU. Off by default.
State: Volume "asbuilt-data" (uploads, jobs, outputs: same layout as the Mac's DATA dir),
       Dict "asbuilt-status" (live progress from the build container), Secret "asbuilt-recon" (ASBUILT_RECON_API_KEY).
"""
import os
import pathlib

import modal

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent
GPU = os.environ.get("ASBUILT_GPU", "L40S")
APP_NAME = os.environ.get("MODAL_APP_NAME", "asbuilt-recon")
ENABLE_SPLAT = os.environ.get("ASBUILT_ENABLE_SPLAT") == "1"
BUILD_CPUS = float(os.environ.get("ASBUILT_BUILD_CPUS", "16"))
BUILD_MEMORY_MB = int(os.environ.get("ASBUILT_BUILD_MEMORY_MB", str(32 * 1024)))
MAX_CONCURRENT_BUILDS = max(1, int(os.environ.get("ASBUILT_MAX_CONCURRENT_BUILDS", "3")))  # build containers at once
OPENMVS_PATCH = HERE / "bakeoff" / "openmvs" / "openmvs-2.4.0-seam-leveling-fix.patch"

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

# CPU build image: OpenMVS v2.4.0 (AGPL-3.0) from source with the TextureMesh seam-leveling fix (upstream #1251,
# commit eeedab7acc backported), CUDA/viewer/python bindings off; pycolmap (BSD-3) CPU wheel for SfM; the CloudRecon
# mesh/bake/export stack. Ubuntu 24.04: Eigen 3.4, Boost 1.83, OpenCV 4.6 from apt; CGAL 6.0.1 + nanoflann 1.7.1 pinned.
OPENMVS_CMAKE = " ".join([
    "-DCMAKE_BUILD_TYPE=Release", "-DVCG_ROOT=/opt/vcglib", "-DCMAKE_INSTALL_PREFIX=/opt/openmvs",
    "-DOpenMVS_USE_CUDA=OFF", "-DOpenMVS_USE_PYTHON=OFF", "-DOpenMVS_BUILD_VIEWER=OFF",
    "-DOpenMVS_USE_BREAKPAD=OFF", "-DOpenMVS_ENABLE_TESTS=OFF", "-DOpenMVS_USE_CERES=OFF",
])
cpu_image = (
    modal.Image.from_registry("ubuntu:24.04", add_python="3.12")
    .env({"DEBIAN_FRONTEND": "noninteractive"})
    .apt_install("build-essential", "cmake", "git", "ca-certificates", "pkg-config",
                 "libpng-dev", "libjpeg-dev", "libtiff-dev", "zlib1g-dev", "libgmp-dev", "libmpfr-dev",
                 "libboost-iostreams-dev", "libboost-program-options-dev", "libboost-system-dev",
                 "libboost-serialization-dev", "libopencv-dev", "libeigen3-dev", "xz-utils", "curl",
                 "libjxl-dev", "libgomp1", "libgl1", "libegl1", "libglib2.0-0", "libx11-6")
    .add_local_file(OPENMVS_PATCH, "/opt/src/openmvs-seam-fix.patch", copy=True)
    .run_commands(
        # nanoflann (header-only KD-tree, BSD) is not in Ubuntu's OpenMVS-compatible form: install a pinned release
        "git clone --depth 1 --branch v1.7.1 https://github.com/jlblancoc/nanoflann.git /opt/src/nanoflann"
        " && cmake -S /opt/src/nanoflann -B /opt/src/nf-build -DNANOFLANN_BUILD_EXAMPLES=OFF"
        " -DNANOFLANN_BUILD_TESTS=OFF && cmake --install /opt/src/nf-build && rm -rf /opt/src/nf-build",
        # OpenMVS' IO lib requires libjxl via pkg-config and prefers static .a files: use the shared ones
        "rm -f /usr/lib/x86_64-linux-gnu/libjxl*.a /usr/lib/x86_64-linux-gnu/libhwy*.a",
        # CGAL >= 6.0 (OpenMVS 2.4 includes CGAL/AABB_traits_3.h; Ubuntu 24.04 ships 5.6): header-only release
        "curl -fsSL https://github.com/CGAL/cgal/releases/download/v6.0.1/CGAL-6.0.1-library.tar.xz | tar -xJ -C /opt/src"
        " && cmake -S /opt/src/CGAL-6.0.1 -B /opt/src/cgal-build -DCMAKE_BUILD_TYPE=Release"
        " && cmake --install /opt/src/cgal-build && rm -rf /opt/src/cgal-build /opt/src/CGAL-6.0.1",
        "git clone https://github.com/cdcseacave/VCG.git /opt/vcglib",
        "git clone --depth 1 --branch v2.4.0 --recurse-submodules https://github.com/cdcseacave/openMVS.git /opt/src/openMVS",
        "cd /opt/src/openMVS && git apply /opt/src/openmvs-seam-fix.patch && git diff --stat",
        # Ubuntu's OpenCV 4.6 predates cv::IMWRITE_JPEGXL_QUALITY (640, OpenCV >= 4.11); only used to write .jxl
        "sed -i 's/cv::IMWRITE_JPEGXL_QUALITY/640/' /opt/src/openMVS/libs/Common/Types.inl",
        "cmake -S /opt/src/openMVS -B /opt/src/build " + OPENMVS_CMAKE,
        "J=$(nproc); [ $J -gt 12 ] && J=12; cmake --build /opt/src/build -j$J -- -k && cmake --install /opt/src/build",
        "rm -rf /opt/src/build && ls -la /opt/openmvs/bin/OpenMVS && /opt/openmvs/bin/OpenMVS/DensifyPointCloud --help | head -3",
    )
    .pip_install("numpy<2.4", "scipy", "numba", "xatlas==0.0.11", "usd-core", "pillow", "pillow-heif", "plyfile",
                 "open3d==0.20.0", "scikit-image", "pycolmap==4.2.1")
    .env({"OMVS_BIN": "/opt/openmvs/bin/OpenMVS", "NUMBA_CACHE_DIR": "/tmp/numba", "PYTHONPATH": "/app",
          "SFM_GPU": "0", "CLOUD_MESHER": "openmvs"})
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
               CLOUD_IGNORE_DISK_CHECK="1", ASBUILT_LOG_DIR="/tmp/asbuilt-logs", ASBUILT_BUILD_FUNCTION="build_cpu",
               ASBUILT_MAX_CONCURRENT_BUILDS=str(MAX_CONCURRENT_BUILDS))
    subprocess.Popen(["python", "/app/cloud_server.py", "--host", "0.0.0.0", "--port", "8000", "--data", "/data",
                      "--backend", "modal", "--verbose"], env=env, cwd="/app")


def _run_build(job_id, options, input_rel, stages="real"):
    import sys
    sys.path.insert(0, "/app")
    from asbuilt_cloud.gpu_entry import run_job
    data.reload()  # see the API container's freshly committed input.zip
    input_zip = os.path.join("/data", input_rel)

    def publish(payload):
        status[job_id] = payload

    # Outputs go to /data/results/<id>/out. Only this container writes there; the API copies them into
    # jobs/<id>/out after a reload, so no file on the volume is ever written by both containers.
    r = run_job(job_id, options, input_zip, "/data/results", publish, stages=stages, work_root="/tmp")
    data.commit()
    return r


@app.function(image=cpu_image, volumes={"/data": data}, timeout=3 * 3600, cpu=BUILD_CPUS, memory=BUILD_MEMORY_MB,
              retries=0)
def build_cpu(job_id: str, options: dict, input_rel: str) -> dict:
    return _run_build(job_id, options, input_rel)


if ENABLE_SPLAT:
    # GPU image: built from CloudRecon/Dockerfile (CUDA 12.4 + torch 2.4 + gsplat 1.5.3 + pycolmap-cuda12 4.2.1 ...).
    gpu_image = (
        modal.Image.from_dockerfile(HERE / "Dockerfile", context_dir=HERE)
        .env({"CLOUD_MESHER": "splat"})
        .add_local_dir(HERE / "asbuilt_cloud", "/app/asbuilt_cloud")
    )

    @app.function(image=gpu_image, gpu=GPU, volumes={"/data": data}, timeout=3 * 3600, cpu=8.0, memory=32768,
                  ephemeral_disk=100 * 1024, retries=0)
    def build_gpu(job_id: str, options: dict, input_rel: str) -> dict:
        return _run_build(job_id, options, input_rel)


@app.function(image=cpu_image, cpu=1.0, memory=1024, timeout=300)
def toolcheck() -> dict:
    """Cheap image sanity check: OpenMVS binaries + python stack import."""
    import glob
    import subprocess
    import sys
    sys.path.insert(0, "/app")
    out = {"bins": sorted(os.path.basename(p) for p in glob.glob("/opt/openmvs/bin/OpenMVS/*"))}
    out["densifyHelp"] = subprocess.run(["/opt/openmvs/bin/OpenMVS/DensifyPointCloud", "--help"], capture_output=True,
                                        text=True).stdout[:300]
    import numba, open3d, pillow_heif, pycolmap, xatlas  # noqa: F401,E401
    from pxr import Usd  # noqa: F401
    out["pycolmap"] = pycolmap.__version__
    out["open3d"] = open3d.__version__
    out["nproc"] = os.cpu_count()
    return out


@app.local_entrypoint()
def smoke(zip_path: str = "", detail: str = "phone", check: bool = False):
    """`modal run CloudRecon/modal_app.py --zip-path photos.zip` runs one CPU build without the HTTP API;
    `modal run CloudRecon/modal_app.py --check` only checks the build image."""
    import json
    import uuid
    if check:
        print(json.dumps(toolcheck.remote(), indent=1))
        return
    if not zip_path:
        print("pass --zip-path <photos.zip> or --check")
        return
    jid = "job_smoke_" + uuid.uuid4().hex[:8]
    with data.batch_upload() as b:
        b.put_file(zip_path, "/jobs/%s/input.zip" % jid)
    r = build_cpu.remote(jid, {"detail": detail, "texture": "8k", "obj": True, "title": "smoke"},
                         "jobs/%s/input.zip" % jid)
    print(json.dumps(r, indent=1))
    print("outputs: modal volume ls asbuilt-data /results/%s/out" % jid)
