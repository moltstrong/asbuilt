# OpenMVS mesh candidate (agents C + D, 2026-10-24)

Scripts behind the "OpenMVS vs Apple Object Capture" section of `../RESULTS.md`. They were run from scratch dirs
`c/` and `d/` that sit next to B's bake-off dir `b/` (`~/.hermes/cache/scratch/cloudrecon/`). The relative `../b`
paths below assume that layout. Models, renders and images were not committed (see RESULTS.md for their paths).

| file | what |
|---|---|
| `make_train35.py` | COLMAP workspace with the 6 held-out photos removed: images, poses **and every track observation** (points left with < 2 views are dropped). Uses B's poses (b/undist). |
| `run_best.sh` | Best recipe end to end: InterfaceCOLMAP, DensifyPointCloud (full res), ReconstructMesh (free-space support + close holes), automatic crop, RefineMesh, CloudRecon photo bake. Logs time + peak RSS per stage. |
| `crop_mesh.py` | Automatic object crop from the **training cameras only** (no masks, no Apple data): keep vertices seen by ≥ `min-frac` of the cameras and within `radius-factor` × the median camera distance of the cameras' common look-at point. Then keep the large connected components. |
| `bake_cloudrecon.py` | Textures an OpenMVS mesh with `asbuilt_cloud.meshing` instead of TextureMesh: QEM decimation to 250k, drops faces no training photo sees (z-buffer), xatlas, then multi-view weighted bake. Optional two-band blend (`--multiband σ`): low frequencies come from the smooth average, high frequencies from a near-best-view bake. |
| `obj2usdz.py` | OBJ (COLMAP frame) to USDZ (repo exporter). Writes SceneKit cameras for the 6 held-out views and B's 2 hero views, then renders them with B's `meshrender`. |
| `eval_d.py` | B's metric protocol unchanged (mask = Apple phone silhouette eroded 4 px, PSNR/SSIM/LPIPS-alex, phase-correlation aligned). Recomputes the Apple/splat rows too, so all rows come from one script. |
| `geomcov.py` | Geometry-only coverage of B's object mask at the held-out cameras (fast crop/mesh-option sweeps). |
| `make_compare_c.py`, `hero_compare_c.py` | Side-by-sides: held-out photo, Apple raw and OpenMVS, full view plus 1:1 crops, and the off-path hero views. |
| `stage.sh` | Per-stage timing wrapper (`/usr/bin/time -l`). |
| `openmvs-2.4.0-seam-leveling-fix.patch` | Upstream fix for OpenMVS issue #1251 (commit `eeedab7acc` on `develop`), applied to v2.4.0. Without it, TextureMesh's global/local seam leveling produces black or saturated garbage texture. Reproduced on macOS arm64 with Eigen 3.4 and 5.0. |

Build used on the Mac: OpenMVS v2.4.0 from source (Homebrew boost/cgal/opencv/eigen, CUDA off) plus VCG. The
`develop` branch was also built via vcpkg (pinned `37bb045f…`). Its defaults gave **less** complete meshes on this
data (coverage 94–95 %), so the release build is the one used. OpenMVS is **AGPL-3.0**. That is fine for this public
repo and for a network service whose source is public, but any closed fork would have to publish its changes.
