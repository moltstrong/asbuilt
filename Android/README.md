# AsBuilt for Android

Native Kotlin + Jetpack Compose capture app. It takes guided, high-resolution object photos with ARCore poses,
sends them to the owner's asbuilt-recon Mac server (same v1 API as the iPhone app, see `../MacRecon/API.md`),
and shows the full-detail textured model it gets back (`model.glb`) in a Filament/SceneView 3D viewer.

## Modules
- `core/`: pure Kotlin/JVM, unit-tested on CI.
  - `recon/`: v1 protocol models, discovery, `ReconClient` (OkHttp), `RemoteBuildRunner`. The runner mirrors
    iOS `RemoteBuildService`: 8 MB chunks, 3 in flight, per-chunk retry with backoff, Cloudflare HTML/5xx/429
    treated as retryable, resume from `receivedChunks`, waiting-for-Mac state, discovery re-resolve,
    Range + sha256-verified `model.glb` download.
  - `zip/StoreZipWriter`: STORE (uncompressed) zip with ZIP64.
  - `capture/PhotoZip`: `Images/IMG_0001.jpg…` + `poses.json` + `coach-report.txt`, the same layout as the
    iOS photo zip.
  - `coach/`: port of iOS `CaptureCoach`.
    - Sweet-spot distance, speed limits, light, low texture.
    - 12×3 coverage ring with A–F grade.
    - Laplacian-variance blur rejection, plus `ShotPlanner` auto-shutter (new angle/position, 80–200 photos).
  - `cli/E2eMain`: real end-to-end against the server with this exact code path (`./gradlew :core:e2e`).
- `app/`: Compose UI.
  - Job list, capture intro, unsupported screen, live AR capture with coach HUD and haptics, review with grade.
  - Settings: encrypted URL/key override and GLB texture size.
  - 3D viewer: orbit, zoom, pan, neutral IBL plus sun.
  - `BuildService`: dataSync foreground service, so builds survive backgrounding and restarts.

## Capture data
- Camera config: the highest CPU-image resolution the device offers for ARCore.
- Each accepted shot is saved as a full-resolution JPEG (q95, EXIF orientation and 35 mm focal length).
- The shot's ARCore camera-to-world pose (column-major 4×4, metres, Y up) and intrinsics, scaled to the JPEG
  size, go into `poses.json`.
- Depth API (AUTOMATIC) is used when supported, for the distance reading.
- ARCore is `optional` in the manifest. Phones without it can still view models.

## Build
CI (`.github/workflows/android.yml`) runs on every push that touches `Android/**`:
- `:core:test`.
- `:app:assembleRelease`, signed from `ANDROID_KEYSTORE_B64` / `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_ALIAS`.
- Server config is injected as BuildConfig fields from `RECON_API_KEY` / `RECON_BASE_URL` / `RECON_DISCOVERY_URL`.
- An API 34 emulator job opens every screen through `--es demo <name>` and uploads screenshots
  (`scripts/emulator-smoke.sh`).

Demo screens: `empty`, `jobs`, `intro`, `unsupported`, `progress`, `coach`, `coach-fast`, `coach-far`, `review`,
`model`, `settings`.

Local (optional, with a JDK 17 + Android SDK): `./gradlew :core:test :app:assembleDebug`.

The bundled sample `app/src/main/assets/sample/monstree-sample.glb` (20k triangles, 1K textures) is a real Mac
build of the monstree photo set.
