# AsBuilt cloud GPU build image (Modal builds it from this file; any Docker host with an NVIDIA GPU works too).
#   SfM:      pycolmap-cuda12 4.2.1 (COLMAP 4.2.1 incl. the GLOMAP global mapper; BSD-3) in its own venv
#   Splat:    gsplat 1.5.3 (Apache-2.0) + its examples/simple_trainer.py, torch 2.4.1 / CUDA 12.4
#   Mesh/out: numba TSDF + scikit-image marching cubes + Open3D cleanup/decimation (MIT) + xatlas (MIT)
#             + usd-core (Pixar TOST/Apache-2.0 style) for USDZ.  No Inria (non-commercial) code anywhere.
# Build check without a GPU:  docker build -f CloudRecon/Dockerfile CloudRecon   (gsplat wheel is prebuilt)
FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive PIP_NO_CACHE_DIR=1 PYTHONUNBUFFERED=1 \
    TORCH_CUDA_ARCH_LIST="8.0;8.6;8.9;9.0" NUMBA_CACHE_DIR=/tmp/numba
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3.10 python3.10-venv python3-pip git curl ca-certificates \
        libgl1 libglib2.0-0 libgomp1 libheif1 \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3.10 /usr/local/bin/python && ln -sf /usr/bin/python3.10 /usr/local/bin/python3

# --- training + meshing env (system python 3.10: gsplat ships prebuilt cp310 wheels) ---
RUN python -m pip install --upgrade pip \
    && python -m pip install torch==2.4.1 torchvision==0.19.1 --index-url https://download.pytorch.org/whl/cu124 \
    && python -m pip install "gsplat==1.5.3" --index-url https://docs.gsplat.studio/whl/pt24cu124 \
       --extra-index-url https://pypi.org/simple
# gsplat's example trainer at the same tag (+ its pinned deps, minus the GUI viewer which we disable)
RUN git clone --depth 1 --branch v1.5.3 https://github.com/nerfstudio-project/gsplat.git /opt/gsplat \
    && python -m pip install "numpy<2.0.0" imageio[ffmpeg] scikit-learn tqdm "torchmetrics[image]" \
       opencv-python-headless "tyro>=0.8.8" Pillow tensorboard tensorly pyyaml matplotlib splines viser \
       "git+https://github.com/rmbrualla/pycolmap@cc7ea4b7301720ac29287dbe450952511b32125e" \
       "git+https://github.com/nerfstudio-project/nerfview@4538024fe0d15fd1a0e4d760f3695fc44ca72787" \
       "git+https://github.com/rahul-goel/fused-ssim@328dc9836f513d00c4b5bc38fe30478b4435cbb5" \
    && python -m pip install "numba>=0.59" "scikit-image>=0.22" "open3d==0.20.0" "xatlas==0.0.11" \
       "usd-core==26.8" plyfile scipy pillow-heif
ENV GSPLAT_EXAMPLES=/opt/gsplat/examples

# --- SfM env (separate venv: the official COLMAP 4.2.1 bindings with CUDA SIFT/matching) ---
RUN python -m venv /opt/sfm && /opt/sfm/bin/pip install --upgrade pip \
    && /opt/sfm/bin/pip install "pycolmap-cuda12==4.2.1" numpy
ENV SFM_PYTHON=/opt/sfm/bin/python SFM_GPU=1

WORKDIR /app
ENV PYTHONPATH=/app
# The application code (asbuilt_cloud/) is layered on top by modal_app.py (add_local_dir) or:
# COPY asbuilt_cloud /app/asbuilt_cloud
