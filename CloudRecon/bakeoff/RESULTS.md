# Bake-off: Apple Object Capture vs. COLMAP/GLOMAP + Gaussian splat (+ splat→mesh)

Dataset: `dataset_monstree`, 41 iPhone photos (12 MP) of a tree stump. Run entirely on the M4 Mac (16 GB),
2026-10-23. Scripts are in this folder. Images and models were left in the scratch dir (paths below), not committed.

## Protocol (held-out views, so no model has seen the test photos)

- Held out every 7th photo (sorted): IMG_1024, 1031, 1038, 1046, 1053, 1060 (`heldout.txt`). Every model was
  trained on the **other 35**.
- **Apple**: `PhotogrammetrySession` on the 35 photos, phone preset (250k tris, 8K) and raw (`applepose.swift`, one
  session that also exports Apple's camera poses). 3.6 min, peak 11 GB.
- **Poses for the splat**: COLMAP 4.2.1 CPU, OPENCV single camera, exhaustive matching, `global_mapper` (GLOMAP).
  All 41 registered at 0.72 px; undistorted to PINHOLE 2000×1500 (`sfm_b.sh`, 1.9 min).
- **Splat**: Brush v0.3.0 (Apache-2.0, Metal) for 15k steps with `--eval-split-every 7`, so it trained on the same
  35 photos. 58 min, peak 3.8 GB, 0.47 M splats. A 30k run was not affordable in the time box. Brush's own eval
  PSNR peaked at 7.5k (20.6 dB full frame) and was 20.2 dB at 15k, so the run had converged.
- **Splat→mesh**: the CloudRecon code path (`splat2mesh.py` → `asbuilt_cloud.meshing`). Median depth of the
  splat rendered at the 35 training views → TSDF → marching cubes → 250k tris → xatlas → 8K texture baked from the
  **real photos** → USDZ (passes Apple `usdchecker --arkit`). 4.5 min CPU.
- **Same cameras for everyone**: Apple meshes were rendered (SceneKit, unlit texture) through each held-out photo's
  COLMAP camera, mapped into Apple's frame by a similarity transform fit on the 35 shared cameras (residual
  0.08 % of the camera-centre spread, 0.02°, `align.py`). The splat render is Brush's own render at that camera.
- **Metrics** inside the object mask (Apple phone-mesh silhouette, eroded 4 px): PSNR, SSIM, LPIPS-alex.
  "Aligned" removes one global 2D shift per (model, view) found by phase correlation. Apple's renders sit a
  constant ≈ −7.5 px / −1.4 px off in **every** view, and the other models sit at ≈ 0. This is a principal-point
  convention difference (COLMAP's undistorted camera is centred; Apple refines its own), not geometry error.
  Both variants are in `results_heldout_{aligned,raw}.json`.

## Results (mean of 6 held-out views)

| model | PSNR ↑ (aligned) | SSIM ↑ | LPIPS ↓ | PSNR raw |
|---|---|---|---|---|
| Apple phone preset (250k, 8K) | 19.42 | 0.610 | 0.275 | 16.06 |
| Apple raw (all geometry) | 19.45 | 0.616 | **0.268** | 16.04 |
| **Gaussian splat (Brush 15k)** | **22.56** | **0.716** | **0.265** | **22.53** |
| Splat→TSDF mesh (250k, 8K photo bake) | 19.25 | 0.528 | 0.354 | 19.21 |

Per view, the splat has the best PSNR and SSIM in **6/6** views (+0.8 to +9.9 dB over Apple raw). The IMG_1038
outlier is an exposure/colour mismatch in Apple's texture. On LPIPS (perceptual) the splat is **not** better: it
wins 2 views, Apple raw wins 4, and the means are a tie (0.265 vs 0.268).

What the images show (`compare.png`, `compare_IMG_1038.png`, `compare_IMG_1046.png`, `compare_hero.png`):
- **Splat**: closest to the photo in tone and lighting, because view-dependent colour reproduces exposure and
  sheen. Bark texture is slightly soft at 1:1 and fine strands look painterly. **Novel views far from the photos
  break down**: the back/low "hero2" view is fog and streaks, and the whole background (grass, trees) is part of the
  model. It has no surfaces, so it can't be measured or placed in AR as a solid.
- **Apple meshes**: crisp, clean, watertight object with the background removed automatically. Holds up from any
  angle where photos exist. Bark detail at 1:1 is as good as or better than the splat (texture baked from photos),
  but the colours are flatter (no view dependence). Raw and phone look almost identical, so the extra 340k
  triangles barely show in renders.
- **Splat→mesh (our cloud mesh path)**: on the object it is roughly as good as Apple (PSNR within 0.2 dB), but it is
  worse overall. It has lumpier geometry, streaky "fins" at silhouettes and background debris inside the crop
  volume (visible in `compare_hero.png`), and a lower texture fill (31 % of the atlas). A first attempt to drop
  mixed depth pixels made it worse (PSNR 15.8) and is disabled. **The current open-source splat→mesh path does
  not beat Apple's mesh.** CUDA-only methods built for this (2DGS / PGSR / MILo / GOF) are reported to give much
  cleaner surfaces but were not testable here. Several are research-licence only (see README).

## Verdict

"Higher quality" depends on what you need:
1. **Photoreal appearance near the capture path**: yes. A Gaussian splat beats Object Capture clearly on this
   data (+3.1 dB PSNR, +0.10 SSIM on unseen photos). The cloud pipeline produces this (`splat.ply`).
2. **A clean, complete, measurable 3D object** (USDZ/GLB, AR, measurements, CAD): **no**. Apple's mesh is
   still the best result here. Our splat-derived mesh matches it only in photo-space PSNR and is visibly worse in
   geometry and novel views. The splat has no surfaces or scale and includes the background.
3. **Geometric accuracy**: not measured (no ground-truth scan). Reprojection consistency is similar (COLMAP 0.72 px,
   and Apple's cameras agree with COLMAP to 0.02°). Object Capture can use per-photo depth (LiDAR/stereo HEICs from the app's capture flow) for
   scale. This dataset is plain JPEGs, so neither model has verified metric scale here.

So a cloud GPU pipeline is worth it **as an add-on photoreal splat next to Apple's mesh**, not as a replacement
mesh, unless a better surface method (2DGS/PGSR-class, CUDA) is validated first.

## OpenMVS mesh vs Apple (agents C + D, 2026-10-24)

The question: is a CPU-only, cloud-runnable open-source photogrammetry **mesh** clearly better than Object Capture?
The candidate was OpenMVS v2.4.0 (AGPL-3.0): DensifyPointCloud, ReconstructMesh, RefineMesh, then a texture step.
Protocol, masks, cameras, renderer and metrics are unchanged from above. It used the same 35 training photos and B's
COLMAP poses, with the held-out images **and all their track observations** removed (`openmvs/make_train35.py`).
The object crop is automatic and uses only the training cameras (`openmvs/crop_mesh.py`). It uses no masks and no
Apple data. Scripts, the patch and the full per-view JSON are in `openmvs/` (see `openmvs/README.md`).

| model (aligned, mean of 6 held-out views) | PSNR ↑ | SSIM ↑ | LPIPS ↓ | mask coverage | wins vs Apple raw (PSNR/SSIM/LPIPS) |
|---|---|---|---|---|---|
| Apple phone preset (250k, 8K) | 19.42 | 0.610 | 0.275 | 99.7 % | 2/0/0 of 6 |
| Apple raw | 19.45 | 0.616 | 0.268 | 99.7 % | — |
| Gaussian splat (Brush 15k), not a mesh | 22.56 | 0.716 | 0.265 | 100 % | 6/6/2 |
| Splat→TSDF mesh (current CloudRecon mesh) | 19.25 | 0.528 | 0.354 | 99.8 % | 2/0/0 |
| OpenMVS full-res, tight crop, TextureMesh, seam leveling off | 17.72 | 0.597 | 0.269 | 96.4 % | 1/2/4 |
| same mesh, TextureMesh with the seam-leveling fix | 17.78 | 0.599 | 0.267 | 96.4 % | 1/2/4 |
| OpenMVS wide crop, fixed TextureMesh (C v9) | 18.93 | 0.637 | 0.258 | 98.1 % | 3/5/4 |
| OpenMVS free-space + close-holes, fixed TextureMesh | 18.78 | 0.602 | 0.269 | 99.7 % | 0/2/3 |
| same mesh, CloudRecon bake (multi-view average) | **20.01** | **0.667** | 0.279 | 99.7 % | 5/6/2 |
| **same mesh, CloudRecon two-band bake (best, `run_best.sh`)** | 19.80 | 0.648 | **0.255** | 99.7 % | **5/6/5** |

Best recipe (`openmvs/run_best.sh`):
1. DensifyPointCloud at full resolution, with OpenMVS' ROI and tower heuristics off (they cut off the stump's base).
2. ReconstructMesh `-f 1 --close-holes 300 --remove-spurious 0`. Free-space support plus hole closing fills the deep
   dark cavities, as Apple does. Without it, coverage stays at 96–98 % and every uncovered pixel scores black.
3. Crop: keep vertices seen by ≥ 10 % of the cameras and within 1.6 × the median camera distance.
4. RefineMesh at full resolution, decimate 0.25.
5. CloudRecon's own baker instead of TextureMesh: QEM decimation to 250k, faces no photo sees are dropped, xatlas,
   then an 8K bake. The bake uses low frequencies from the multi-view average and high frequencies from a
   near-best-view bake (σ = 2 texels).

On the same mesh this baker beat TextureMesh by about 1 dB PSNR and 0.05 SSIM. TextureMesh leaves the unseen back
of the hole-closed mesh orange.

**Stage times and peak RAM** (measured on the M4 Mac, 8 threads, 35 photos at 2000×1500):

| stage | time | peak RSS |
|---|---|---|
| InterfaceCOLMAP | 1 s | 0.1 GB |
| DensifyPointCloud | 5.8 min | 3.6 GB |
| ReconstructMesh | 1.3 min | 5.9 GB |
| crop (numpy) | 10 s | <2 GB |
| RefineMesh | 7.3 min | 5.4 GB |
| bake | 62 s | 10.8 GB |
| **total** | **≈ 15.7 min** | **10.8 GB** |

COLMAP SfM adds about 2 min. Apple Object Capture took 3.6 min (peak 11 GB) for the whole job.

**What the images show** (`d/compare_openmvs.png`, `d/crops_mb2.png`, `d/hero_mb2.png`, `d/full_1046.png`):
- At normal viewing size the two are **about the same**: same silhouette, same cavities, similar colour.
- OpenMVS is a little more faithful in tone on IMG_1038. That is Apple's colour/exposure outlier, and the biggest
  per-view gain (+1.2 dB).
- At 1:1 the two-band bake is about as sharp as Apple. The plain average bake is softer (high-frequency energy is
  0.66 of the photo's, against Apple's 0.73 and the two-band bake's 0.80).
- OpenMVS has small defects Apple doesn't:
  - a smeared flap at the rim of IMG_1038's big cavity;
  - dark membrane-like cavity interiors where Apple shows leaves (IMG_1053);
  - a small fern and some speckle on the ground skirt;
  - a dark flap on the low back hero view.
- Apple has its own defect: a black hole inside IMG_1038's cavity.
- Neither shows background debris inside the crop. The splat→TSDF mesh does.

**Verdict: not clearly better. It is about equal to Apple, with a small but consistent metric edge.** The best
OpenMVS variant beats Apple raw by +0.35 dB PSNR, +0.033 SSIM and −0.012 LPIPS, winning 5/6, 6/6 and 5/6 views.
Three things stop this from being a "clearly better" result:
1. The margins are smaller than the spread between our own variants.
2. About 15 variants were tuned on these same 6 views, so the best one benefits from selection on the test set.
   It is also one object.
3. A viewer doesn't see a difference, apart from IMG_1038's colour.

What it *does* show: the cloud can produce an Apple-class mesh **without the Mac and without a GPU**. That is a
large step up from the current splat→TSDF mesh (+0.55 dB, +0.12 SSIM, −0.10 LPIPS, no fins or debris). If the owner
wants "off the Mac at the same quality", this is the path. If he wants "clearly higher quality", this data doesn't
support paying for it. The CUDA-only surface methods (2DGS, PGSR, GOF, MILo) remain untested here; they need an
NVIDIA GPU.

**Cloud estimate** (not measured: no account was created). Use a CPU-only Modal container with 16 physical cores and
32 GiB, because the bake peaks at 10.8 GB:
- price: 16 × $0.0000131 + 32 × $0.00000222 = **$0.00028/s ≈ $1.01/h**;
- run time: assuming a cloud x86 core is 1.5–2× slower than an M4 core and 16 cores replace 8 threads, the measured
  15.7 min becomes about **15–25 min**, plus 2–4 min of CPU SfM;
- cost: **≈ $0.30–0.50 per scan**, so the $30/month free credit covers about 60–100 scans.

An L40S is not needed for this path. The v2.4.0 build used here is CPU-only. OpenMVS `develop` has CUDA PatchMatch,
but on this data its defaults gave less complete meshes (coverage 94–95 %).

Other findings:
- OpenMVS v2.4.0 TextureMesh's global/local **seam leveling is broken**: it produces black or saturated garbage.
  This is upstream issue #1251, fixed on `develop` in commit `eeedab7acc`. It was reproduced on macOS arm64 with
  Eigen 3.4 and 5.0. The fix backported to v2.4.0 is `openmvs/openmvs-2.4.0-seam-leveling-fix.patch`, and any
  Dockerfile must apply it or build `develop`.
- **Licence**: OpenMVS is AGPL-3.0. That is fine for this public repo and for a network service whose source is
  published. A closed fork would have to release its changes. VCG is GPL-3.0. CloudRecon would only run OpenMVS as
  separate programs, so its own code should keep its licences (aggregation, not a derivative). Not legal advice.

Scratch paths: `c/r{3..9}/`, `d/runs/q0/` (`refined_r16.ply`, `bake_repo/model.obj`), `d/eval_q0_*`,
`d/eval_aligned/`, `c/eval/aligned/`, `d/src/build-2.4/bin`, `c/bin_dev/`.

## Paths (scratch, not committed)

- `~/.hermes/cache/scratch/cloudrecon/compare.png` (IMG_1031), `compare_IMG_1038.png`, `compare_IMG_1046.png`,
  `compare_hero.png`
- `b/results_heldout_{aligned,raw}.json`, `b/eval/aligned/<model>/<view>.png`, `b/splat/eval_15000/`
- `b/apple35/{phone,raw}.usdz`, `b/splat/splat_15000.ply` (111 MB), `b/mesh_final/model.usdz` (32 MB)
- logs: `logs/b_brush.log`, `logs/b_sfm_times.txt`, `logs/b_apple35.log`, `logs/b_mesh_final.log`, `logs/b_pytest.log`
