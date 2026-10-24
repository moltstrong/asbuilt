#!/bin/bash
# B's SfM: COLMAP 4.2.1 (CPU, Homebrew) on the 41 half-res photos (2016x1512), then undistort to PINHOLE.
# Runs both the global mapper (GLOMAP, merged into COLMAP 4) and the incremental mapper; logs timings.
set -uo pipefail
cd "$(dirname "$0")"
L=../logs
rm -rf db.db* sparse_glo sparse_inc undist
mkdir -p sparse_glo sparse_inc
t() { local name=$1; shift; local s=$(date +%s.%N 2>/dev/null || date +%s); /usr/bin/time -l "$@" > $L/b_$name.log 2>&1; local rc=$?; local e=$(date +%s.%N 2>/dev/null || date +%s); printf "%s rc=%s %.1fs\n" "$name" "$rc" "$(echo "$e - $s" | bc)" | tee -a $L/b_sfm_times.txt; }
: > $L/b_sfm_times.txt
t extract colmap feature_extractor --database_path db.db --image_path images \
   --ImageReader.single_camera 1 --ImageReader.camera_model OPENCV \
   --FeatureExtraction.use_gpu 0 --FeatureExtraction.num_threads 6 --SiftExtraction.max_num_features 16384
t match colmap exhaustive_matcher --database_path db.db --FeatureMatching.use_gpu 0
cp db.db db_inc.db
t global_mapper colmap global_mapper --database_path db.db --image_path images --output_path sparse_glo
t mapper colmap mapper --database_path db_inc.db --image_path images --output_path sparse_inc
for m in sparse_glo sparse_inc; do
  for d in $m/*/; do echo "== $d"; colmap model_analyzer --path $d 2>&1 | grep -E "Cameras|Images|Registered|Points|Observations|Mean track|Mean obs|Mean reproj" | sed 's/.*\] //'; done
done | tee $L/b_sfm_models.txt
