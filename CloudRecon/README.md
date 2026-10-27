# CloudRecon: AsBuilt cloud reconstruction (asbuilt-recon v1 API on Modal)

The server the AsBuilt apps upload object scans to. It replaced the owner's Mac (`MacRecon/`, now switched off) and
speaks the **same HTTP API** (`MacRecon/API.md` v1: uploads/chunks/complete/jobs/files, Bearer auth, Range
downloads, sha256), so the iOS and Android apps only see a different **base URL** (published in the discovery gist)
and keep using the same key. Builds run on a **CPU-only** Modal container with an open-source stack:

```
photos.zip ─▶ HEIC/JPEG decode, upright, ≤ 2000 px          (pillow-heif; LiDAR depth stays in the HEICs)
           ─▶ pycolmap 4.2.1 SfM (SIFT, exhaustive matching, global mapper; one camera per image size)
           ─▶ OpenMVS v2.4.0 DensifyPointCloud (full res) → ReconstructMesh (free-space + close holes)
           ─▶ automatic crop (training cameras only) → RefineMesh
           ─▶ CloudRecon bake: QEM 250k → drop unseen faces → xatlas → two-band 8K photo texture
           ─▶ metric scale from the iPhone's LiDAR depth, Y-up (gravity from the camera x axes), object at the origin
           ─▶ model.usdz (usdchecker --arkit clean) + OBJ zip + model.glb (Android) + thumbnail.png + recon-log.txt
```

Why this recipe: the bake-off on the 41-photo stump (`bakeoff/RESULTS.md`, "OpenMVS mesh vs Apple") found it **ties
Apple Object Capture's mesh** on held-out photos (19.80 dB / SSIM 0.648 / LPIPS 0.255 against Apple raw's
19.45 / 0.616 / 0.268) without a GPU. The older splat→TSDF mesh was clearly worse and is now an opt-in GPU path
(`ASBUILT_ENABLE_SPLAT=1`, `CLOUD_MESHER=splat`). OpenMVS is AGPL-3.0 and runs as separate programs; the image builds
it from source with the upstream TextureMesh seam-leveling fix (`bakeoff/openmvs/openmvs-2.4.0-seam-leveling-fix.patch`).

Status (2026-10-27): **deployed and live**; the discovery gist points the apps here. End to end through the public
URL with `scripts/recon-client.py e2e` on the stump (41 × 12 MP JPEG, 168 MB): 24/24 checks passed (auth,
chunk/whole-file sha errors, interrupted + resumed upload, live progress, Range-resumed download, sha256,
`usdchecker --arkit` Success, model.glb): 226k triangles, 8K texture, 20 MB USDZ.

## Time and cost per scan (measured)

41 photos at 2000 px on a Modal CPU container, 16 cores / 32 GiB (no GPU):

| stage | seconds |
|---|---|
| unzip + decode/resize | 10 |
| SfM (pycolmap CPU: extract, match, global mapper, undistort) | 81 |
| DensifyPointCloud (full resolution, 32 threads) | 543 |
| ReconstructMesh | 113 |
| crop | 22 |
| RefineMesh | 293 |
| bake (decimate, unwrap, two 8K passes) | 111 |
| scale, orient, USDZ/OBJ, thumbnail | 4 |
| **build total** | **1182 (19.7 min)** |

Upload of the 168 MB zip took 9 s from a home connection; the 20 MB model downloaded in 4 s. Price: 16 × $0.0000131
+ 32 × $0.00000222 = $0.00028/s for the build container, so **≈ $0.33 per 41-photo scan**, plus ≈ $0.04 for the API
container (1 core, 2 GiB; it scales to zero 20 min after the last request). The Starter plan's $30/month credit
covers about 80 such scans. Densify and refine grow roughly with the photo count: a 100-photo capture is about
40 min and $0.8.

## Files

| file | what |
|---|---|
| `cloud_server.py` | HTTP server = `MacRecon/server/recon_server.py` **imported unchanged** (all routes, errors, auth, resume, downloads, GLB conversion) + a `CloudWorker` that runs builds on a backend instead of the local Apple CLI. |
| `modal_app.py` | Modal deployment: `api` (web server, 1 container, scales to zero), `build_cpu` (16 cores / 32 GiB, the OpenMVS image), `toolcheck`, optional `build_gpu` (splat). |
| `modal_backend.py` | Backend used by the API on Modal: spawns `$ASBUILT_BUILD_FUNCTION` (`build_cpu`), mirrors live progress from a `modal.Dict`, copies outputs from the Volume. |
| `asbuilt_cloud/pipeline.py` | The build (`build_openmvs` default, `build_splat` optional) writing the Mac CLI's `status.json`/`result.json`/`recon-log.txt` contract; `camera_up` / `output_frame`. |
| `asbuilt_cloud/openmvs_mesh.py` | OpenMVS stages with streamed, forward-only progress; crop; face visibility; two-band bake. |
| `asbuilt_cloud/lidar_scale.py` | Metric scale from the depth image inside iPhone Object Capture HEICs (below). |
| `asbuilt_cloud/sfm_pycolmap.py` | SfM (SIFT, exhaustive matching, global mapper with incremental fallback, undistort). |
| `asbuilt_cloud/meshing.py`, `export.py`, `colmap_io.py` | Cleanup/decimation, xatlas unwrap, numba rasterizer + photo bake; USDZ via `usd-core`, OBJ, thumbnail; COLMAP readers. |
| `asbuilt_cloud/runner.py`, `gpu_entry.py` | One-build entry point (`--stages fake` = CPU stand-ins for tests) and the Modal function body (any build container). |
| `asbuilt_cloud/gsplat_train.py`, `splatmesh.py`, `splatrender*.py`, `Dockerfile` | Optional GPU splat path (CUDA image). |
| `tests/test_cloudrecon.py` | 15 tests; no GPU, no OpenMVS, no account needed. |

## Metric scale (LiDAR) and orientation

iPhone Object Capture HEICs carry a small LiDAR depth image (e.g. 192×256, 8-bit, `z-near`/`z-far`, "uniform Z")
that libheif rotates together with the photo. `lidar_scale.py` samples it at every SfM feature track and takes
`median(d_lidar / z_sfm)` as meters per SfM unit. It doesn't trust one decoding: every reading (value→depth
direction, uniform vs inverse Z, grid orientation) is scored by how constant the ratio is, and a scale is used only
when the best one is tight (MAD of log-ratio < 6 %) over ≥ 200 samples in ≥ 3 photos. `result.json` then says
`scaleSource: "lidar"` (plus `scale.mad`, `samples`, `reading`); otherwise `scaleSource: "none"` and the model is sized
as if the photos were taken 1 m away. Tested on synthetic depth maps; **not yet on a real iPhone capture**.

Up = the direction most perpendicular to every camera's x axis (people tilt the phone but don't roll it), which
stays unbiased when the photos look down at the object from one side. On the stump the mean camera "up" was 14° off
and a ground-plane fit about 30° off. The origin is the look-at point dropped onto a ground plane perpendicular to
that up (within 10°), else onto the lowest mesh points.

## Tests (Mac or Linux; no GPU, no account)

```bash
uv venv -p 3.12 /tmp/cr && VIRTUAL_ENV=/tmp/cr uv pip install "numpy<2.4" scipy numba scikit-image "open3d==0.20.0" \
    xatlas usd-core plyfile pillow pillow-heif pycolmap==4.2.1 pytest modal
cd CloudRecon && /tmp/cr/bin/python -m pytest tests -q        # 15 passed in ~20 s on the M4
```
They cover: TSDF sphere; clean → unwrap → bake → USDZ (validators, 64-byte aligned STORE zip) → OBJ; the default
OpenMVS pipeline with fake SfM/OpenMVS stages through the real crop, bake, scale and orientation code (object at the
origin, Y-up, no metric claim for JPEGs); the splat pipeline with fake GPU stages; the crop; LiDAR scale on synthetic
depth (recovers 0.137 and 2.5 m/unit within 2 %, finds flipped and rotated encodings, refuses depth without a range
or inconsistent with the geometry); HEIC without depth; camera-x-axis up on a one-sided capture; forward-only OpenMVS
progress; failure → plain-language `result.json`; the Modal function body; `modal_app.py` builds its App; and the
**v1 HTTP flow end to end** against `cloud_server.py`. `MacRecon/server/test_server.py` still passes (61/61).

Real-data checks: `modal run CloudRecon/modal_app.py --check` (image tools), `--zip-path photos.zip` (one build
without HTTP), and `python3 scripts/recon-client.py e2e photos.zip --base <url> --detail phone --glb` (the phone's flow).

## Deploy / operate

```bash
modal secret create asbuilt-recon --from-json key.json   # {"ASBUILT_RECON_API_KEY": "<the apps' key>"}, never echoed
modal deploy CloudRecon/modal_app.py                       # first OpenMVS image build ~25 min, then seconds
```
The URL is `https://<workspace>--asbuilt-recon-api.<region>.modal.run` and stays the same across deploys. The apps
find it through the discovery gist (`asbuilt-recon.json`: `baseURL`, `apiVersion`, `transport`, `updatedAt`);
TestFlight builds also bake it in from the `RECON_BASE_URL` secret. Deploy-time env: `ASBUILT_BUILD_CPUS` (16),
`ASBUILT_BUILD_MEMORY_MB` (32768), `ASBUILT_ENABLE_SPLAT` (off), `ASBUILT_GPU`, `MODAL_APP_NAME`. In the build
container: `CLOUD_MAX_SIDE` (2000), `OMVS_THREADS` (all cores), `CLOUD_KEEP_WORK=1` (keep intermediates).

Image notes (Ubuntu 24.04): OpenMVS 2.4.0 needs nanoflann (pinned 1.7.1), libjxl through pkg-config, CGAL ≥ 6.0
(`CGAL/AABB_traits_3.h`; Ubuntu ships 5.6, so the 6.0.1 header release is installed) and
`cv::IMWRITE_JPEGXL_QUALITY` (OpenCV ≥ 4.11; replaced by its value 640 for Ubuntu's 4.6).

Design notes:
- **API container** (`max_containers=1`): the Mac server keeps its queue and locks in memory, so it stays a single
  process here too. Builds run in separate containers. The API container may scale to zero while a build runs; on
  restart `CloudWorker.requeue_interrupted` re-attaches to the running call through `gpuCallID` in `job.json`.
- **Uploads**: Modal web endpoints accept bodies up to 4 GiB with a 150 s per-request limit, so 8-32 MiB chunks fit.
- **Volume consistency**: the build container writes only to `results/<job>/` and commits; the API reloads before
  copying into `jobs/<job>/out`. Logs live in `/tmp`, not on the Volume (open files block `Volume.reload()`).
- **"Model ready" notice**: the Mac texted the owner through BlueBubbles; the cloud can't (the BlueBubbles password
  never leaves the Mac). The iOS app posts a local notification instead, when the model lands and, while suspended,
  from background status checks it schedules itself (`AsBuilt/Capture/ReconReadyNotifier.swift`).
- `poses.json` from Android (ARCore) is still ignored; it could give Android captures metric scale later.
- **Licences**: OpenMVS AGPL-3.0 and VCG GPL-3.0 (separate programs, source public), COLMAP/pycolmap BSD-3,
  Open3D MIT, xatlas MIT, usd-core (Pixar TOST), numba BSD. The Inria 3DGS code (non-commercial) is not used.

## Optional: photoreal splat (GPU)

`ASBUILT_ENABLE_SPLAT=1 modal deploy …` adds `build_gpu` (CUDA image from `Dockerfile`: pycolmap-cuda12, gsplat 1.5.3
MCMC, splat depth → TSDF mesh, `splat.ply` download). The splat beats Apple on held-out photos (PSNR 22.6 vs 19.4 dB)
but its mesh doesn't, and phones need a splat renderer to show it. Not deployed.

### Viewing splats on the phones

RealityKit, SceneKit, AR Quick Look and Filament/SceneView **cannot render Gaussian splats**; they are triangle
renderers. Options as of Oct 2026:
- **iOS, native**: [MetalSplatter](https://github.com/scier/MetalSplatter) (MIT, Swift Package, iOS 18+/visionOS 2,
  reads PLY/SPZ/.splat, SH0-SH3; v1.0.1 Feb 2026). Embed its `MTKView` renderer next to the SceneKit model view.
  Caveat: the 1.0.1 PLY reader only accepts SH degree 0 or 3 files; gsplat exports degree 3, so this is fine.
- **Both platforms, web**: [Spark](https://github.com/sparkjsdev/spark) (MIT, three.js/WebGL2, by World Labs; PLY,
  SPZ, SOG, KSPLAT; v2.4.0, Oct 2026) in a `WKWebView` / Android `WebView` loading a small bundled HTML page plus
  the downloaded `splat.ply`. Brush's web viewer (Apache-2.0) is an alternative but needs WebGPU.
- **Android, native**: no maintained native splat renderer comparable to MetalSplatter. Use the WebView/Spark route.
Recommendation: keep the **mesh (USDZ/GLB) as the primary deliverable** (measurable, AR-placeable, opens
everywhere). Add `splat.ply` as an optional "photo-real view": MetalSplatter on iOS, Spark-in-WebView on Android.
Convert PLY to SPZ (~10× smaller; Niantic's spz library, MIT) before download once it's wired up.
