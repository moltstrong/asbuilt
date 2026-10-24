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

## Paths (scratch, not committed)

- `~/.hermes/cache/scratch/cloudrecon/compare.png` (IMG_1031), `compare_IMG_1038.png`, `compare_IMG_1046.png`,
  `compare_hero.png`
- `b/results_heldout_{aligned,raw}.json`, `b/eval/aligned/<model>/<view>.png`, `b/splat/eval_15000/`
- `b/apple35/{phone,raw}.usdz`, `b/splat/splat_15000.ply` (111 MB), `b/mesh_final/model.usdz` (32 MB)
- logs: `logs/b_brush.log`, `logs/b_sfm_times.txt`, `logs/b_apple35.log`, `logs/b_mesh_final.log`, `logs/b_pytest.log`
