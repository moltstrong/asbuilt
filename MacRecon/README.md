# asbuilt-recon: full-detail 3D models from AsBuilt photos, on a Mac

iPhones can only build Object Capture models at `.reduced` detail. AsBuilt keeps the capture's
`Images/` folder (HEICs with LiDAR depth and Object Capture metadata), so the office Mac can rebuild
the same capture at the highest detail Apple's `PhotogrammetrySession` allows:

| detail | what you get |
| --- | --- |
| `reduced` | what the phone makes: ~50k triangles, 2K diffuse + normal + AO |
| `full` | ~100-250k triangles, **8K** diffuse, normal, roughness, AO + displacement (EXR) |
| `raw` | everything Apple reconstructed: ~0.5-2M+ triangles, 8K diffuse only. For CAD/measurement, not AR |
| `custom` | you choose: `--max-polys`, `--texture 1k…8k` (16k on macOS 15+), which maps, PNG/JPEG. **Apple clamps `--max-polys` to a per-device limit: 250,000 on this M4/16 GB** (and on an M1 Max/32 GB per Apple's forums); the log says so. For more polygons use `raw` |

Output: `model.usdz` (AR Quick Look / Reality Composer / Blender), and with `--obj` an `obj/` folder
plus `model-obj.zip` (OBJ + MTL + texture PNGs/EXR) for CAD, Rhino, Blender or MeshLab.

## Install

Needs macOS 14+ on Apple silicon (or an Intel Mac with a 4 GB+ AMD GPU). Command Line Tools are
enough; full Xcode is not needed.

```bash
xcode-select --install                     # once, if `swift --version` fails
cd MacRecon
swift build -c release                     # ~1 min
swift test                                 # option parsing, error table, OBJ parser
mkdir -p ~/bin && cp .build/release/asbuilt-recon ~/bin/
asbuilt-recon info <photos-folder-or-zip>  # also says whether this Mac is supported
```

## Usage

```bash
# Highest-quality textured model (what most people want)
asbuilt-recon build ~/Downloads/Pump-3-photos.zip --detail full --obj

# Every polygon Apple can make (surface accuracy), plus OBJ for CAD
asbuilt-recon build ~/Downloads/Pump-3-photos.zip --detail raw --obj --out ~/Desktop/pump-raw

# Exact budget: 250k polygons (Apple's cap on this Mac), 8K textures, chosen maps
asbuilt-recon build Images/ --detail custom --max-polys 250k --texture 8k --maps diffuse,normal,ao --obj

# What's in the capture? Photo count, resolution, LiDAR depth, Object Capture metadata
asbuilt-recon info ~/Downloads/Pump-3-photos.zip

# Drop zips into a folder and walk away (iCloud Drive / AirDrop inbox)
asbuilt-recon watch ~/Library/Mobile\ Documents/com~apple~CloudDocs/AsBuilt-Inbox --detail full --obj
```

Input can be a photo folder or a `.zip`. Deflate zips (Finder, `ditto`) and STORE zips (`zip -0`,
AsBuilt's export) both work. The folder holding the most photos is used, so `Images/`, a capture
folder, or loose photos at the zip root are all fine.

Each build writes to `--out` (default `<input>-recon-<detail>/` next to the input):

- `model.usdz`
- `obj/` and `model-obj.zip` (with `--obj`)
- `recon-log.txt`: config, photo stats, live progress, stage timings, polygon count, textures, file
  sizes, `usdchecker --arkit` result, and the full `String(reflecting:)` of any error
- `result.json`: the same facts, machine-readable
- `thumbnail.png`: 4-view render, for a quick check that it's the right object

Progress prints every few seconds: percent, stage (aligning, point cloud, mesh, textures,
optimizing) and Apple's ETA. Skipped or invalid photos and automatic downsampling are reported.

**Retries.** If the first attempt fails, and you didn't set `--ordering`, `--sensitivity` or
`--no-masking`, the build is retried once with sequential ordering, high feature sensitivity and
masking off. That fixes many "photos couldn't be aligned" failures (`CoreOC…Error 6`, processError).
`--no-retry` turns this off.

**One build at a time.** Builds take a machine-wide lock. A second `build`, the watcher, or the
server waits for the first instead of running two sessions in 16 GB. The 2-4 GB of temp files Apple
leaves per run in `$TMPDIR/com.apple.coreoc.Photogrammetry` are deleted afterwards (`--keep-temp`
keeps them, along with the unzipped photos).

**Exit codes:** 0 ok · 1 build failed · 2 bad arguments · 3 Mac not supported · 130 cancelled (Ctrl-C).

### Watch folder

`watch <dir>` polls every 10 s (`--interval`). A new `.zip` or photo folder must stop changing for
one full interval, so half-copied AirDrops and iCloud downloads are skipped. Zips are also
`unzip -t` tested first. Results go to `<dir>/done/<name>/`. Inputs move to `<dir>/processed/`, or to
`failed/` with the log in `done/<name>/recon-log.txt`. `--once` handles what's there and exits.

## Getting photos from the phone

1. In AsBuilt, open the object capture › **Share photos (.zip)**. It contains `Images/` and
   `reconstruction-log.txt`.
2. Either:
   - **AirDrop** it to the Mac (it lands in `~/Downloads`), then run
     `asbuilt-recon build ~/Downloads/<name>.zip --detail full --obj`; or
   - **Save to Files › iCloud Drive › AsBuilt-Inbox** and leave
     `asbuilt-recon watch ~/Library/Mobile\ Documents/com~apple~CloudDocs/AsBuilt-Inbox` running on the
     Mac. In Finder, set the folder to "Keep Downloaded" so iCloud doesn't leave placeholders.
3. Send `model.usdz` back to the phone (AirDrop, or the same iCloud folder) and open it in AsBuilt or
   AR Quick Look.

For a hands-off "Build full detail" button in the app, see **Server** below and [API.md](API.md).

## Measured on this Mac (Mac mini M4, 16 GB, macOS 26.5.1)

Dataset: [alicevision/dataset_monstree](https://github.com/alicevision/dataset_monstree) `full/`.
41 JPEGs, 4032×3024, iPhone 7, no depth. A tree stump with a carved face, about 1.6 × 2.2 × 1.5 model
units (no depth, so the scale is arbitrary).

| detail | wall time (recon / total) | triangles | textures in USDZ | model.usdz | model-obj.zip | peak RSS | usdchecker --arkit |
| --- | --- | --- | --- | --- | --- | --- | --- |
| reduced | 3m37s / 3m38s | 50,000 | 3 × 2048² (diffuse, normal, AO) | 14.9 MB | 17 MB | 4.5 GB | pass |
| full | 4m28s / 8m12s¹ | 118,105 | 4 × 8192² PNG (diffuse, normal, roughness, AO) + 8192² EXR displacement | 300 MB | 304 MB | 5.9 GB | pass |
| raw | 3m33s / 3m41s | 593,420 | 1 × 8192² diffuse | 93 MB | 118 MB | 6.9 GB | pass |
| custom 2M req. / 8K / all 5 maps | 4m49s / 4m57s | 249,999 (clamped) | 5 × 8192² | 185 MB | 195 MB | 5.9 GB | pass |
| custom 2M req. / 8K / diffuse+normal+AO | 4m36s / 6m21s¹ | 250,000 (clamped) | 3 × 8192² | 142 MB | 152 MB | 6.1 GB | pass |

¹ The total includes 2-4 min spent waiting on the build lock for another build. Without the wait it's about recon + 10-30 s.
Inputs: the folder for raw and custom, a `zip -0` STORE zip for full, and the folder plus a `ditto` zip for reduced
(both gave 50,000 triangles). A full build from a 14-photo subset took 57 s for 36k triangles. Twelve unrelated wallpaper images
failed in 1.3 s with `CoreOC.PhotogrammetrySession.Error.processError` (code 6) on both attempts, with the
plain-language "couldn't line up the photos" message.

Rough guide for a 40-80 photo capture on an M4: reduced, full, raw and custom all take 3-6 min, because alignment,
point cloud and meshing dominate. Expect about 2× per doubling of photo count. Peak memory is 5-7 GB, so 16 GB is
enough for one build at a time.
Full and custom make 8K maps, so allow about 1 GB of disk per build plus a few GB of temp space.

## Server (phone → Mac → phone, no Mac interaction)

`asbuilt-recon serve` runs `server/recon_server.py`, a Python 3 stdlib HTTP server on `127.0.0.1:8765`. The phone
does a resumable chunked upload of the photo zip, the Mac builds one job at a time at full/raw/custom detail,
and the phone downloads `model.usdz` (Range-resumable). [API.md](API.md) is the exact contract.

- **Auth:** `Authorization: Bearer <key>`. The key is in `~/.config/asbuilt-recon/api_key` (0600) and in the GitHub
  secret `RECON_API_KEY`. Compared in constant time. 10 bad keys in 10 min locks out that IP for 15 min.
- **State:** `~/Library/Application Support/asbuilt-recon/{uploads,jobs}`. It survives restarts, and a build
  interrupted by a restart is requeued at the head of the queue. Data is removed after 7 days. Uploads are refused
  if free disk < 3 × size; the cap is 8 GiB.
- **Logs:** `~/Library/Logs/asbuilt-recon/` (`server.log`, `tunnel.log`, `cloudflared.log`, per-job `console.log`
  in the job folder).
- **Public HTTPS:** `server/recon_tunnel.py` runs a Cloudflare *quick tunnel* (`cloudflared tunnel --url`).
  On every new hostname it writes `~/.config/asbuilt-recon/base_url`, updates the GitHub secret `RECON_BASE_URL`,
  and rewrites a secret discovery gist (`RECON_DISCOVERY_URL`) that the app reads when the saved URL stops answering.
  Tradeoffs: the hostname changes on every cloudflared restart; there's no SLA (Cloudflare calls quick tunnels
  testing-only); and the request body limit is 100 MB, hence the 32 MiB chunks. A named tunnel or Tailscale Funnel
  would give a stable hostname. Both need a one-time human step (see below), after which only
  `recon_tunnel.py` changes; the API doesn't.
- **iMessage:** on done or failed, one message through the local BlueBubbles server
  (`~/.config/asbuilt-recon/config.json`, creds from `~/.hermes/.env`, never logged; it refuses non-localhost servers).
- **Keep awake:** each build runs under `caffeinate -i -w <pid>`, and this Mac's `pmset sleep` is 0.

Install / update:
```bash
scripts/install-recon-server.sh      # builds, copies to ~/Library/Application Support/asbuilt-recon/bin, writes the LaunchAgents
# then in Terminal.app (first time `load`, after updates `restart`):
"$HOME/Library/Application Support/asbuilt-recon/bin/recon-launchd.sh" load
scripts/recon-client.py e2e photos.zip --small small.zip   # phone-like end-to-end test against base_url
```
LaunchAgents: `com.moltstrong.asbuilt-recon` (server) and `com.moltstrong.asbuilt-recon-tunnel` (tunnel), both
RunAtLoad + KeepAlive.

To get a stable URL instead of the quick tunnel, do one of these once:
- **Tailscale Funnel:** a tailnet admin (family@armstrong.nyc) opens
  https://login.tailscale.com/f/funnel?node=nZ7CaSMzxW11CNTRL and clicks Enable (this turns on HTTPS certs + Funnel),
  then run `tailscale funnel --bg 8765`. The URL is `https://molts-mac-mini-2.tail3efcc6.ts.net`.
- **Cloudflare named tunnel:** `cloudflared tunnel login` (browser), then
  `cloudflared tunnel create asbuilt-recon && cloudflared tunnel route dns asbuilt-recon recon.agentonair.com`.

## Accuracy notes

- `raw` keeps Apple's full-resolution surface (`custom` is clamped to 250k triangles on this Mac). On small,
  well-textured objects shot close up (good overlap, 3 orbits, 60-120 photos) surface detail can
  reach roughly the millimetre level. `full` decimates the geometry and puts the fine detail in
  normal/displacement maps, which looks the same but measures coarser.
- Accuracy depends on the photos far more than on the detail level: coverage from all sides and
  heights, sharp exposures, diffuse even light, and matte, textured surfaces. Shiny, transparent,
  black or uniform surfaces reconstruct poorly at any detail.
- **Scale.** Object Capture HEICs from AsBuilt carry LiDAR depth, so the model comes out in real
  metres; `info` shows `depth map: N/N`. Plain photos with no depth, like the test set above, give a
  model with arbitrary scale. Check one known dimension before trusting measurements.
- `usdchecker --arkit` passing means the USDZ is valid for AR Quick Look/RealityKit. It doesn't say
  anything about geometric accuracy.

## Errors in plain language

`recon-log.txt` keeps the technical identity and `build` prints the plain-language version. The
decoded tables are copied from AsBuiltCore so this package has no dependency on it:

| error | meaning |
| --- | --- |
| `CoreOC.PhotogrammetrySession.Error` 0 reconstructionError, 5 sampleError, **6 processError** | photos couldn't be aligned (no SfM map): more photos/overlap/light |
| … 1 snapshotURLError, 2 imageURLError | photos couldn't be read |
| … 3 initError, 4 requestError | engine refused to start / request unsupported on this Mac |
| … 7 storageFull · public `PhotogrammetrySession.Error` 2 insufficientStorage | disk full |
| public 0 invalidImages · 1 invalidOutput | bad input folder · output path not writable |

## Not yet verified

- Real AsBuilt iPhone Object Capture HEICs (LiDAR depth, ObjectCapture auxiliary data) haven't
  been run through this tool yet. `info` reads their auxiliary-data types through ImageIO, but has
  only been run on plain JPEGs. The real-scale claim is Apple's documented behaviour, not measured
  here.
