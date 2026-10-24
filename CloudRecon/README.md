# CloudRecon: AsBuilt cloud GPU reconstruction (asbuilt-recon v1 API)

A drop-in alternative to the Mac's `asbuilt-recon` server. It speaks the **same HTTP API**
(`MacRecon/API.md` v1: uploads/chunks/complete/jobs/files, Bearer auth, Range downloads, sha256), so the iOS and
Android apps only need a different **base URL + key**. Builds run on a cloud NVIDIA GPU (Modal) using an
open-source, commercially licensed stack:

```
photos.zip ─▶ pycolmap 4.2.1 (COLMAP + GLOMAP global mapper, CUDA SIFT)       ── poses
           ─▶ gsplat 1.5.3 MCMC 3D Gaussian Splatting (30k it, ≤1.5M splats)   ── splat.ply  (photoreal viewer asset)
           ─▶ splat depth → TSDF → marching cubes → clean/decimate → xatlas UV ── mesh
           ─▶ texture baked from the *real photos* (not splat colours) → USDZ (usd-core) + OBJ + GLB
```

Bake-off on the 41-photo stump (`bakeoff/RESULTS.md`): the **splat** beats Apple Object Capture on unseen photos
(PSNR 22.6 vs 19.4 dB, SSIM 0.72 vs 0.61, LPIPS tie). The **splat-derived mesh does not beat Apple's mesh**
(19.2 dB, worse geometry), so use this as an add-on photoreal splat, not a mesh replacement.

Status: **written and tested locally (CPU, GPU stages mocked); not deployed.** No Modal account was created and
nothing was spent. See "Go live" below for what's needed.

## Files

| file | what |
|---|---|
| `cloud_server.py` | HTTP server = `MacRecon/server/recon_server.py` **imported unchanged** (all routes, errors, auth, resume, downloads, GLB conversion) + a `CloudWorker` that runs builds on a backend instead of the local Apple CLI. Adds one extra download, `splat.ply`. |
| `modal_app.py` | Modal deployment: `api` (CPU web server, 1 container, scales to zero) + `build_gpu` (L40S by default). |
| `modal_backend.py` | Backend used by the API on Modal: spawns `build_gpu`, mirrors live progress from a `modal.Dict`, copies outputs from the Volume. |
| `Dockerfile` | GPU image: CUDA 12.4, torch 2.4.1, gsplat 1.5.3 (prebuilt wheel) + its example trainer, pycolmap-cuda12 4.2.1 (own venv), open3d, xatlas, usd-core, numba. |
| `asbuilt_cloud/pipeline.py` | The build: unzip → HEIC/JPEG prep → SfM → splat → mesh → exports, writing the Mac CLI's `status.json`/`result.json`/`recon-log.txt` contract. |
| `asbuilt_cloud/sfm_pycolmap.py` | SfM (SIFT, exhaustive matching, global mapper with incremental fallback, undistort). |
| `asbuilt_cloud/gsplat_train.py` | gsplat `simple_trainer` configured in code (MCMC, antialiased, no world normalization). |
| `asbuilt_cloud/splatmesh.py`, `meshing.py` | splat → mesh: depth renders, numba TSDF, marching cubes, cleanup, decimation, chunked xatlas unwrap, multi-view photo texture bake. |
| `asbuilt_cloud/export.py` | OBJ/MTL/JPEG, USDZ via `usd-core` (validated with USD's validators; the bake-off USDZ also passes Apple `usdchecker --arkit`), thumbnail. |
| `asbuilt_cloud/splatrender.py` / `splatrender_gpu.py` | splat renderers (numba CPU; gsplat CUDA on the cloud GPU). |
| `asbuilt_cloud/runner.py`, `gpu_entry.py` | one-build entry point (`--stages fake` = CPU stand-ins for tests) and the Modal function body. |
| `tests/test_cloudrecon.py` | 8 tests, no GPU needed (see below). |

## Tests (run on the Mac, no GPU, no account)

```bash
python3 -m venv /tmp/cr && /tmp/cr/bin/pip install numpy scipy numba scikit-image open3d xatlas usd-core plyfile pillow pytest modal
cd CloudRecon && /tmp/cr/bin/python -m pytest tests -q        # 8 passed in ~57 s on the M4
```
They cover: TSDF on a synthetic sphere (radius error < 2 %, outward winding); clean → unwrap → bake → USDZ
(USD validators pass, USDZ zip stored/64-byte aligned) → OBJ; the full pipeline with fake GPU stages (synthetic
SfM + splat) through the real mesh/texture/export code; failure → plain-language `result.json`; the Modal function
body with a dict status channel; `modal_app.py` builds its App locally; and the **v1 HTTP flow end to end**
against `cloud_server.py` (health, 401, create upload, chunk sha mismatch → 400, resume via GET, complete
(idempotent), live stage/progress polling, `done` with `model.usdz`/`model.glb`/`splat.ply`/`thumbnail.png`,
Range + `If-Range` download with sha256 check, job list, delete → 404, a failing build reported as `build_failed`).
The original Mac server tests still pass unchanged (`MacRecon/server/test_server.py`: 61/61).

Not exercised locally (needs CUDA): `pycolmap-cuda12`, gsplat training, the gsplat depth renderer, the Docker
build. `asbuilt_cloud/sfm_pycolmap.py` itself was run on the real 41 photos with CPU `pycolmap` 4.2.1:
41/41 registered (global mapper), 0.72 px, 100 s. The splat→mesh code was run on a
real Brush splat of the stump (bake-off below).

## Go live (what Eamonn has to do; ~15 min)

1. **Modal account** at modal.com (GitHub login). The Starter plan is $0/month and includes **$30/month of free
   compute credit** ([modal.com/pricing](https://modal.com/pricing)), which covers roughly 60-150 scans/month at the
   cost below. Add a payment card only if you need more than that.
2. On the Mac (from the repo root):
   ```bash
   pip install modal && modal setup                      # browser login, stores a token in ~/.modal.toml
   modal secret create asbuilt-recon ASBUILT_RECON_API_KEY=$(openssl rand -hex 32)   # the app's Bearer key
   modal volume create asbuilt-data
   modal deploy CloudRecon/modal_app.py                   # first deploy builds the GPU image (~10-15 min)
   ```
   Deploy prints `https://<workspace>--asbuilt-recon-api.modal.run`. That is the base URL.
3. Smoke test: `curl https://…modal.run/v1/health` → `{"ok": true, "apiVersion": 1, …}`; then
   `python3 scripts/recon-client.py --base https://…modal.run --key <key> <photos.zip>` (or
   `modal run CloudRecon/modal_app.py --zip-path photos.zip` for a GPU-only run without HTTP).
4. Point an app at it: same settings screen as the Mac (base URL + key). Discovery via the gist is optional
   (the URL is stable, so no tunnel or gist rewrite is needed).

Env/secret names: secret `asbuilt-recon` with `ASBUILT_RECON_API_KEY` (≥ 32 chars). Optional env at deploy time:
`ASBUILT_GPU` (default `L40S`; `A100-40GB`, `H100`, `L4` also work), `MODAL_APP_NAME`. Inside the GPU image:
`SPLAT_STEPS` (30000), `SPLAT_CAP_MAX` (1500000), `CLOUD_MAX_SIDE` (3000 px), `SFM_GPU` (1).

Design notes:
- **API container** (`max_containers=1`): the Mac server keeps its queue and locks in memory, so it stays a single
  process here too. Builds run on separate GPU containers. The API container may scale to zero while a build runs
  (20 min idle window). On restart, `CloudWorker.requeue_interrupted` re-attaches to the running GPU call through
  the `gpuCallID` stored in `job.json`.
- **Uploads**: Modal web endpoints accept bodies up to 4 GiB with a 150 s per-request limit
  ([webhooks](https://modal.com/docs/guide/webhooks), [timeouts](https://modal.com/docs/guide/webhook-timeouts)),
  so the 8-32 MiB chunks and the 120 s `complete` call fit.
- **Volume consistency**: the GPU container writes only to `results/<job>/` and commits. The API reloads before
  copying into `jobs/<job>/out`. Server logs go to `/tmp`, not the Volume, because open files block
  `Volume.reload()`.
- **Licences**: COLMAP/pycolmap BSD-3, gsplat Apache-2.0, Open3D MIT, xatlas MIT, scikit-image BSD, usd-core
  (Pixar TOST), numba BSD. The Inria 3DGS reference code (non-commercial) is **not** used. Brush (Apache-2.0) was
  used only for the local bake-off. On Linux it needs Vulkan, so gsplat (CUDA) is used in the cloud.
- `poses.json` from Android (ARCore) is ignored for now, as on the Mac. It could seed SfM intrinsics and metric
  scale later. Cloud models are in SfM units with a Y-up, foot-at-origin frame. No metric scale is claimed
  (`scaleSource` in `result.json`).

## Cost and time per scan (41 photos, 12 MP)

Measured locally on the M4 (no CUDA): COLMAP 4.2.1 CPU SfM **1.9 min** (extract 41 s + match 51 s + global
mapper 23 s); Brush 15k steps on the M4 GPU via Metal **58 min** (peak 3.8 GB, 0.47 M splats); splat→mesh CPU
**4.5 min** (numba depth renders + TSDF 3.5 min, then clean 17 s, unwrap 17 s, bake 21 s; the depth renders run
in seconds on CUDA). Apple Object Capture
(`PhotogrammetrySession`, phone + raw in one session) **3.6 min**, peak 11 GB.

Cloud estimate (L40S at **$0.000542/s = $1.95/h** GPU, plus 8 CPU cores × $0.0000131/core/s ≈ $0.38/h and 32 GiB ×
$0.00000222/GiB/s ≈ $0.26/h, Modal list prices [modal.com/pricing](https://modal.com/pricing), checked
2026-10-23). Total ≈ **$2.6/h** for the build container:

| stage | basis | L40S time |
|---|---|---|
| cold start + image pull | Modal containers start in seconds; a 6-8 GB CUDA image pulls in ~30-90 s (cached after) | ~1 min |
| SfM (CUDA SIFT + matching + global mapper) | CPU run took 1.9 min; GPU SIFT/matching is several-fold faster | ~0.7 min |
| gsplat 30k MCMC, ≤1.5 M splats, ~3 MP images | gsplat's own benchmark: mcmc 1 M on A100 = **15.4 min**, 2 M = 21.8 min, at ~1.6 MP Mip-NeRF 360 images ([docs.gsplat.studio eval](https://docs.gsplat.studio/main/tests/eval.html)); L40S ≈ A100 for 3DGS raster; ~2× pixels | ~15-25 min |
| splat→mesh + bake + exports | ~1.5 min CPU (TSDF/clean/unwrap/bake) once depth renders move to CUDA | ~2 min |
| **total** | | **~20-30 min ≈ $0.85-1.30 per scan** |

Cheaper/faster knobs: `SPLAT_STEPS=7000` (gsplat 7k ≈ 5 min on the same benchmark, about -1 dB PSNR) gives
≈ 8-10 min, **≈ $0.35-0.45/scan**. On `A100-40GB` ($2.10/h GPU) the cost is about the same. `H100` ($3.95/h) is
~1.5-2× faster at a similar price per scan. Storage: about 150 MB per job on the Volume ($0.09/GiB-month,
deleted after 7 days by the existing janitor). Egress for results ≈ 0.1-0.2 GB/scan ($0.04/GiB beyond 1 TiB free).
An idle API container costs nothing (scale to zero). While polling it runs at about 1 CPU, 2 GiB, ≈ $0.06/h.

These figures are estimates from published benchmarks and local runs. **No cloud run was performed.** The first
real deploy should log stage timings (they are in `recon-log.txt`) so this table can be updated.

## Viewing splats on the phones

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
