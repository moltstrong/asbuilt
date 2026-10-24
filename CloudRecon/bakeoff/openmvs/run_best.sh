#!/bin/bash
# Best OpenMVS mesh recipe from the bake-off (variant "omvs_fsc_mb2"), end to end, CPU only.
#   usage: run_best.sh <colmap dense workspace (images/ + sparse/ with the held-out photos removed)> <out dir>
#   env:   OMVS_BIN   dir with InterfaceCOLMAP/DensifyPointCloud/ReconstructMesh/RefineMesh (OpenMVS v2.4.0, AGPL-3.0)
#          PY         python with numpy/scipy/plyfile/open3d/xatlas/numba/pillow/usd-core (default: python3)
#          THREADS    OpenMVS --max-threads (default 8)
# Every stage logs wall time + peak RSS to <out>/times.txt. The crop uses ONLY the training cameras (no masks).
set -euo pipefail
WS=$(cd "$1" && pwd); OUT=$2; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
OMVS=${OMVS_BIN:?set OMVS_BIN}; PY=${PY:-python3}; T=${THREADS:-8}
cd "$OUT"; : > times.txt
step() { local name=$1; shift; local t0=$(date +%s)
  /usr/bin/time -l "$@" > "$name.log" 2>&1 || { echo "$name FAILED (see $OUT/$name.log)" | tee -a times.txt; exit 1; }
  echo "$name $(( $(date +%s) - t0 ))s peakRSS=$(awk '/maximum resident/{printf "%.2fGB", $1/1073741824}' "$name.log")" | tee -a times.txt; }
step import    "$OMVS/InterfaceCOLMAP" -i "$WS" -o scene.mvs --image-folder "$WS/images/"
# full-resolution PatchMatch depth maps; OpenMVS' own ROI/tower heuristics off (they cut the stump's base)
step densify   "$OMVS/DensifyPointCloud" -i scene.mvs -o dense.mvs --max-threads "$T" --resolution-level 0 \
               --tower-mode 0 --crop-to-roi 0
# Delaunay + graph-cut with free-space support, close holes (fills the deep dark cavities Apple also closes)
step mesh      "$OMVS/ReconstructMesh" -i dense.mvs -p dense.ply -o mesh.mvs --max-threads "$T" --crop-to-roi 0 \
               -f 1 --close-holes 300 --remove-spurious 0
# automatic object crop: vertices seen by >= 10 % of the training cameras and within 1.6 x the median
# camera distance of the cameras' common look-at point; keep the largest connected component(s)
step crop      "$PY" "$HERE/crop_mesh.py" mesh.ply "$WS/sparse" crop.ply --min-frac 0.1 --radius-factor 1.6
step refine    "$OMVS/RefineMesh" -i dense.mvs -m crop.ply -o refined.mvs --max-threads "$T" --resolution-level 0 \
               --decimate 0.25
# texture with the CloudRecon baker (not TextureMesh): QEM decimate to 250k -> drop faces no photo sees ->
# xatlas -> two-band multi-view photo bake (8K)
step bake      "$PY" "$HERE/bake_cloudrecon.py" refined.ply bake --tris 250000 --tex 8192 --min-views 1 --multiband 2 \
               --sparse "$WS/sparse" --images "$WS/images"
echo "done: $OUT/bake/model.obj (+ model_diffuse.jpg)" | tee -a times.txt
