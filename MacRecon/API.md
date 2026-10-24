# asbuilt-recon server API, v1

This is the contract the AsBuilt iOS app uses to send a capture's photos to the Mac mini. The Mac
builds a full, raw or custom-detail model and the app downloads it back into the job.
Server: `MacRecon/server/recon_server.py`, run as `asbuilt-recon serve` under launchd. Test client
that does exactly what the app should do: `scripts/recon-client.py e2e`.

## 1. Base URL, discovery, key

| | |
|---|---|
| Base URL | `https://<random>.trycloudflare.com` (Cloudflare quick tunnel → `127.0.0.1:8765`). **It changes whenever the tunnel restarts** (Mac reboot, network change, cloudflared crash). |
| Discovery | `GET https://api.github.com/gists/41f628ce6ff0601ad6e3ac2e78cc83cb` (secret gist; no auth needed). Read `files["asbuilt-recon.json"].content` and parse it as JSON: `{"baseURL": "...", "apiVersion": 1, "transport": "cloudflare-quick-tunnel", "updatedAt": "..."}`. The Mac rewrites it on every new URL. |
| Build-time injection | `RECON_API_KEY` (64 hex chars), `RECON_BASE_URL`, `RECON_DISCOVERY_URL` (= the gist API URL above) are GitHub Actions secrets. CI writes them into Info.plist keys `ReconAPIKey`, `ReconBaseURL`, `ReconDiscoveryURL` at build time. **Never commit them.** Store the key in the Keychain on first launch. |

Base URL resolution in the app:
1. Use the last known-good URL (UserDefaults), falling back to `ReconBaseURL`.
2. If `GET {base}/v1/health` fails (DNS error, connect error, timeout, any non-200, or the body lacks `"ok": true`),
   fetch the discovery URL. If its `baseURL` differs, retry health on the new URL and save it.
3. If both fail, show "The Mac build server is offline" and retry later. Uploads and jobs resume
   against the new URL with the same IDs, because IDs are server-side and survive restarts.

Rate limit: GitHub allows 60 unauthenticated gist reads per hour per IP, so only read discovery when health fails.

## 2. Auth and common rules

- Every route except `GET /v1/health` needs `Authorization: Bearer <RECON_API_KEY>`. The comparison is constant-time.
- Wrong or missing key returns **401** `unauthorized` with header `WWW-Authenticate: Bearer realm="asbuilt-recon"`.
- 10 failed auths from one IP within 10 minutes lock that IP out for 15 minutes. During lockout every authed
  route returns **429** `rate_limited` with `Retry-After` and `retryAfterSeconds`, even with the right key.
  Behind the tunnel the IP is the phone's public IP (`CF-Connecting-IP`).
- JSON in and out: `Content-Type: application/json; charset=utf-8`, UTF-8, keys are camelCase, timestamps are
  ISO-8601 UTC (`2026-10-23T19:14:06Z`). JSON request bodies are limited to 64 KiB.
- IDs are opaque strings: `up_<24 hex>`, `job_<24 hex>`. `captureID` is yours: 1-128 chars of `A-Z a-z 0-9 . _ -`,
  and must start with a letter or digit. Use the AsBuilt capture UUID.
- **Error body** for every 4xx/5xx except 416 on downloads, which has an empty body:
  ```json
  {"error": {"code": "missing_chunks", "message": "2 of 6 chunks haven't arrived yet.", "missingChunks": [3, 5], "missingCount": 2}}
  ```
  `message` is plain language and safe to show users. Branch on `code`; extra fields depend on the code (see §7).
- Responses carry `Cache-Control: no-store` (downloads: `private, no-transform`).

## 3. Limits

| | |
|---|---|
| Max upload (`totalBytes`) | 8 GiB (8,589,934,592). Larger returns 413 `upload_too_large` |
| Chunk size | default **32 MiB** (33,554,432). You may request 4-64 MiB in whole MiB with `chunkSize`. Use 8 MiB on cellular and 32 MiB on Wi-Fi. Cloudflare rejects request bodies over 100 MB |
| Free disk | the server needs 3 × `totalBytes` free (less what open uploads have reserved), else 507 `insufficient_storage` |
| Retention | uploads, jobs and their files are deleted 7 days after their last activity (`expiresAt`) |
| Builds | one at a time, FIFO. Full detail for a 41-photo, 168 MB set on the M4 takes about 4-8 min |

## 4. Routes

### `GET /v1/health` (no auth)
200:
```json
{"ok": true, "version": "1.0.0", "apiVersion": 1, "serverTime": "2026-10-23T19:14:06Z",
 "startedAt": "2026-10-23T19:12:27Z", "queueLength": 1, "processing": true}
```

### `POST /v1/uploads` → 201
Request:
```json
{"captureID": "6F1C…-UUID", "filename": "Images.zip", "totalBytes": 168396531,
 "sha256": "<64 lowercase hex of the whole zip>",
 "detail": "full", "texture": "8k", "obj": true,
 "title": "Kitchen north wall", "notify": true,
 "chunkSize": 33554432, "maxPolygons": 250000}
```
| field | type | req | notes |
|---|---|---|---|
| `captureID` | string | yes | see §2 |
| `filename` | string | yes | must end in `.zip`; basename only |
| `totalBytes` | int | yes | 1 … 8 GiB |
| `sha256` | string | yes | 64 lowercase hex |
| `detail` | `full` \| `raw` \| `custom` \| `phone` | no (default `full`) | `full`: about 100-250k triangles plus 8K diffuse/normal/roughness/AO/displacement maps, ARKit-valid. `raw`: all reconstructed geometry (≈0.5-2M triangles) with one 8K diffuse map, for measurement and CAD. `custom`: `maxPolygons` + `texture`. `phone` (what AsBuilt sends): 250,000 triangles (Apple's cap here) with 8K diffuse + normal maps as JPEG, about 30 MB, opens in SceneKit/AR Quick Look on an iPhone |
| `autoComplete` | bool | no (default false) | the server calls `complete` itself once the last chunk arrives, so the phone can sleep right after uploading |
| `texture` | `4k` \| `8k` | no (default `8k`) | used for `custom` |
| `maxPolygons` | int | no | `custom` only, 10,000-20,000,000, default 1,000,000. **Apple clamps it to 250,000 on this Mac**; use `raw` for more geometry |
| `obj` | bool | no (default false) | also produce `model-obj.zip` (OBJ+MTL+textures) |
| `glb` | bool | no (default false) | also produce `model.glb` (binary glTF 2.0, for Android/Filament/SceneView and the web): the same mesh as `model.usdz` with its diffuse (`baseColorTexture`), normal (`normalTexture`) and, if built, AO (`occlusionTexture`) maps embedded. Converted from the OBJ output, so the build runs with OBJ export; `model-obj.zip` is only kept and listed when `obj` is also true. A conversion failure never fails the job: the job is still `done` with `model.usdz`, no `model.glb` in `files`, and `glbError` set |
| `glbTextureSize` | int | no | `glb` only: cap the embedded textures' longest side at 1024, 2048, 4096 or 8192 px (re-encoded as JPEG q0.9). Default: keep the build's size (8K for `phone`) |
| `title` | string | no | ≤120 chars, shown in the iMessage notification |
| `notify` | bool | no (default true) | iMessage the owner when the job is done or failed |
| `chunkSize` | int | no | 4-64 MiB, multiple of 1 MiB |

The zip is AsBuilt's photo export: the `Images/` folder of Object Capture HEICs (STORE zip is fine,
since HEIC/JPEG are already compressed). The server finds the image folder anywhere inside the zip
(the folder holding the most HEIC/JPEG/PNG/TIFF files; other files such as `poses.json` are ignored).
The Android app sends `Images/IMG_0001.jpg …` (full-resolution JPEGs with EXIF focal length) plus
`poses.json` (ARCore camera pose + intrinsics per photo, see `Android/README.md`) in a STORE zip, with
`detail: "phone"`, `autoComplete: true`, `glb: true`, `chunkSize: 8388608`.

201 (also the shape of `GET /v1/uploads/{id}`):
```json
{"uploadID": "up_8c1…", "captureID": "6F1C…", "filename": "Images.zip", "totalBytes": 168396531,
 "sha256": "…", "chunkSize": 33554432, "chunkCount": 6, "receivedChunks": [], "receivedBytes": 0,
 "state": "open", "jobID": null, "detail": "full", "autoComplete": false, "obj": true, "glb": false,
 "createdAt": "2026-10-23T19:14:20Z", "expiresAt": "2026-10-30T19:14:20Z"}
```
Errors: 400 `invalid_field` (+`field`), 400 `invalid_json`, 413 `upload_too_large` (+`maxBytes`, `totalBytes`),
413 `body_too_large`, 507 `insufficient_storage` (+`freeBytes`, `requiredBytes`).

### `PUT /v1/uploads/{uploadID}/chunks/{n}` → 200
- `n` is 0-based, `0 … chunkCount-1`. Chunk `n` is bytes `[n*chunkSize, min((n+1)*chunkSize, totalBytes))`.
  Every chunk is exactly `chunkSize` bytes except the last.
- Headers: `Content-Type: application/octet-stream`, `Content-Length: <exact chunk length>` (required),
  `X-Chunk-SHA256: <hex>` (optional, **recommended**).
- Body: raw bytes. The server streams them to a temp file and only marks the chunk as received after the full length
  arrived and the sha matched, so a dropped connection never leaves a half chunk counted.
- Idempotent: re-sending a received chunk overwrites it and returns 200.
- 200:
  ```json
  {"uploadID": "up_…", "index": 3, "bytes": 33554432, "sha256": "…", "receivedChunks": [0,1,2,3], "chunkCount": 6}
  ```
- Errors: 400 `chunk_size_mismatch` (+`expectedBytes`, `receivedBytes`); 400 `chunk_sha256_mismatch`
  (+`expected`, `actual`), so re-send that chunk; 400 `invalid_chunk_index` (+`chunkCount`); 400 `invalid_header`;
  411 `length_required`; 404 `upload_not_found`; 409 `upload_completed` (+`jobID`), meaning it's already done, so go to the job.

### `GET /v1/uploads/{uploadID}` → 200
The same shape as the create response. **This is the resume primitive.** `receivedChunks` is the sorted set the
server has, and anything not in it must be (re)sent. Once `state` is `"completed"`, `jobID` is set.

### `DELETE /v1/uploads/{uploadID}` → 200 `{"deleted": true, "uploadID": "…"}`
Abandons an upload and frees its disk space.

### `POST /v1/uploads/{uploadID}/complete` → 201 (or 200 if already completed)
No body. The server assembles the chunks, checks the whole-file sha256 and size, then enqueues a job.
For multi-GB files this takes a few seconds (≈0.2 s for 168 MB), so use a 120 s request timeout.
- 201: `{"jobID": "job_…", "uploadID": "up_…", "alreadyCompleted": false}`
- 200: `{"jobID": "job_…", "uploadID": "up_…", "alreadyCompleted": true}`. This is idempotent, so retry freely.
- 409 `missing_chunks` (+`missingChunks` (first 1000), `missingCount`): upload those chunks, then call complete again.
- 422 `sha256_mismatch` (+`expected`, `actual`): **all chunks were discarded** and `receivedChunks` is now `[]`.
  Re-hash the local zip. If it changed, create a new upload; otherwise re-send all chunks to the same upload.

### `GET /v1/jobs/{jobID}` → 200
```json
{"jobID": "job_…", "captureID": "6F1C…", "title": "Kitchen north wall",
 "state": "processing", "queuePosition": 0, "progress": 0.42, "etaSeconds": 180,
 "stage": "meshGeneration", "message": "Building full-detail model: 41%",
 "detail": "full", "obj": true, "polygons": null, "textures": null,
 "createdAt": "…", "startedAt": "…", "finishedAt": null, "buildSeconds": null,
 "restarts": 0, "error": null,
 "files": [{"name": "recon-log.txt", "bytes": 2101, "sha256": null, "url": "/v1/jobs/job_…/files/recon-log.txt"}]}
```
| field | meaning |
|---|---|
| `state` | `queued` → `processing` → `done` \| `failed`. A server restart puts `processing` back to `queued` at the head of the queue (`restarts` += 1) |
| `queuePosition` | `queued`: 1 = next. `processing`: 0. Otherwise `null` |
| `progress` | 0-1, monotonic within one attempt. It can drop back if Apple's auto-retry kicks in ("retrying with different settings") or after a restart |
| `etaSeconds` | Apple's estimate while processing, else `null`. It's noisy, so smooth it |
| `stage` | `preProcessing`, `imageAlignment`, `pointCloudGeneration`, `meshGeneration`, `textureMapping`, `optimization`, `extracting`, `inspecting`, or `null` |
| `message` | plain language, ready to show |
| `polygons`, `textures` | when `done`: triangle count and `[{name, width, height}]` |
| `error` | when `failed`: `{"code": "build_failed", "message": "<plain language, e.g. photos couldn't be aligned>", "exitCode": 1, "technical": "<Apple error dump>"}` |
| `glb`, `glbInfo`, `glbError` | `glb` echoes the upload option. When `done` with a GLB: `glbInfo` = `{triangles, vertices, bytes, textures: [{name, mimeType}]}`. If the conversion failed: `glbError` = `{code: "glb_failed", message}` (the USDZ is still there) |
| `files` | when `done`: `model.usdz`, `recon-log.txt`, `thumbnail.png`, `model-obj.zip` if `obj`, and `model.glb` if `glb`. Each is `{name, bytes, sha256, url}`, where `url` is relative to the base URL. Before `done` only the live `recon-log.txt` (sha `null`) is listed |

404 `job_not_found` means it was deleted or expired.

### `GET /v1/jobs?captureID=<id>` → 200 `{"jobs": [<job>, …]}`
Newest first, max 100. Without `captureID` it returns all jobs. Use this after a reinstall, or if the app lost a jobID,
to re-find work for a capture. If the list is empty, also check any upload you remember with `GET /v1/uploads/{id}`.

### `DELETE /v1/jobs/{jobID}` → 200 `{"deleted": true, "jobID": "…", "previousState": "processing"}`
Cancels a running build (it stops within about 10 s) or removes a finished one and its files.

### `GET /v1/jobs/{jobID}/files/{name}` → 200 / 206
`name` ∈ `model.usdz` | `model-obj.zip` | `model.glb` | `recon-log.txt` | `thumbnail.png`. `HEAD` is supported.
- Headers: `Content-Length`, `Accept-Ranges: bytes`, `ETag: "<sha256>"`, `X-Content-SHA256: <sha256>`,
  `Content-Type` (`model/vnd.usdz+zip`, `application/zip`, `model/gltf-binary`, `text/plain; charset=utf-8`, `image/png`).
- **Range**: `Range: bytes=<start>-` (or `start-end`, or `-suffix`) → **206** with `Content-Range: bytes s-e/total`.
  Send `If-Range: "<sha256>"` so that if the file changed you get a full 200 instead of a wrong splice.
  Start beyond the end → **416** with `Content-Range: bytes */<total>` and an empty body.
- 404 `file_not_found`: the name is unknown or the file isn't ready yet.
- After download, **verify the sha256** against `files[].sha256` before importing into the job.

## 5. Flow and resume rules (what the app must do)

```
zip Images/ → Caches/recon/<captureID>/Images.zip ; sha256 it (streamed)
POST /v1/uploads                      → save {uploadID, chunkSize, chunkCount} in the capture record
for n in 0..<chunkCount not in receivedChunks:
    write chunk n to Caches/recon/<captureID>/chunk-n.bin
    background URLSession uploadTask(fromFile:) PUT …/chunks/n   (X-Chunk-SHA256 set)
    on 200: delete chunk-n.bin, record n
POST …/complete                       → save jobID
poll GET /v1/jobs/{jobID}
on done: download model.usdz (+ model-obj.zip) with Range resume → verify sha256 → attach to job
         (optionally DELETE the job afterwards to free Mac disk)
```
Rules:
1. **Persist `uploadID` and `jobID` in the capture record immediately.** Everything is resumable from those two IDs.
2. **On any interruption** (app killed, network change, URL change), call `GET /v1/uploads/{id}` and send only
   the chunks missing from `receivedChunks`. Never assume a chunk arrived without a 200.
3. Up to **3 chunks in parallel** is fine. Retry a failed chunk with exponential backoff (2, 4, 8 … 60 s, unlimited
   while the user wants the build). On 400 `chunk_sha256_mismatch`, re-read the chunk from the zip and re-send it.
4. When all chunks are in, call `complete`. On 409 `missing_chunks`, send them and call again. On 422, see above.
5. 404 `upload_not_found` (expired after 7 days): start a new upload.
6. 409 `upload_completed` on a PUT: stop uploading and use the returned `jobID`.
7. 401 means the key is wrong (a config bug), so don't retry-loop. 429: wait `Retry-After`.
8. 507 on create: tell the user "The Mac is out of space" and retry later. 413: "Capture too large for Mac
   processing (max 8 GB)".
9. 5xx, connection errors, or the Cloudflare 52x/530 pages (HTML, not our JSON): treat as offline, re-resolve the base URL
   (§1), back off, and resume.

## 6. Polling and notifications

- **While the app is in the foreground and a job is queued or processing: poll `GET /v1/jobs/{id}` every 5 s.**
- In the background, register a `BGAppRefreshTask` (`earliestBeginDate` about 15 min). In it, poll every pending job once.
  On `done`, start the background downloads and post a local notification.
- The Mac also sends one iMessage to the owner on done or failed (when `notify` is true), so the user knows to open the app.
- Don't poll faster than every 2 s. The server is single-machine.

## 7. Error codes

| HTTP | code | when / extra fields |
|---|---|---|
| 400 | `invalid_json`, `bad_request` | body isn't a JSON object / bad Content-Length |
| 400 | `invalid_field` | +`field` |
| 400 | `invalid_header` | bad `X-Chunk-SHA256` |
| 400 | `invalid_chunk_index` | +`chunkCount` |
| 400 | `chunk_size_mismatch` | +`expectedBytes`, `receivedBytes` |
| 400 | `chunk_sha256_mismatch` | +`expected`, `actual` |
| 401 | `unauthorized` | missing or wrong key |
| 404 | `not_found`, `upload_not_found`, `job_not_found`, `file_not_found` | |
| 405 | `method_not_allowed` | +`allow` (also an `Allow` header) |
| 409 | `upload_completed` | +`jobID` |
| 409 | `missing_chunks` | +`missingChunks`, `missingCount` |
| 411 | `length_required` | chunk PUT without Content-Length |
| 413 | `upload_too_large`, `body_too_large`, `chunk_too_large` | |
| 416 | (empty body) | download Range past the end |
| 422 | `sha256_mismatch` | +`expected`, `actual`; chunks discarded |
| 429 | `rate_limited` | +`retryAfterSeconds`, `Retry-After` header |
| 500 | `internal_error` | |
| 507 | `insufficient_storage` | +`freeBytes`, `requiredBytes` |

Job failure is not an HTTP error: the job reads `state: "failed"` with `error.message` in plain language. For example,
"Apple's photogrammetry couldn't line up the photos … Re-shoot with 3 slow passes …". The Mac has already retried once
with sequential ordering, high sensitivity and no masking before reporting failure.

## 8. Android implementation notes (`Android/`)

- Same flow and resume rules as §5, in `Android/core` (pure Kotlin/JVM, unit tested with MockWebServer):
  8 MiB chunks, 3 in flight, per-chunk retry with backoff (2…60 s), Cloudflare HTML / 5xx / 429 / IO errors are
  retryable, 401/404/413 are fatal, `waitingForMac` after repeated failures, discovery re-resolve on any
  connection failure, `model.glb` downloaded with Range resume and sha256-verified.
- Runs in a foreground service (`dataSync`) with a progress notification, so it survives backgrounding.
- The API key / base URL / discovery URL are `BuildConfig` fields injected by `.github/workflows/android.yml`
  from the same GitHub secrets; a Settings override is stored with `EncryptedSharedPreferences`.

## 9. iOS implementation notes

- **Uploads**: background `URLSessionConfiguration.background(withIdentifier: "com.asbuilt.recon.upload")`,
  `isDiscretionary = false`, `sessionSendsLaunchEvents = true`, and `allowsCellularAccess` per user setting.
  Use one `uploadTask(with: request, fromFile: chunkURL)` per chunk. Background sessions require **file**
  uploads, so write each chunk to `Caches/recon/<captureID>/chunk-<n>.bin` first (≤3 on disk at a time) and delete it
  after its 200. Set `Content-Length` and `X-Chunk-SHA256` on the request. Map task → (uploadID, n) via `taskDescription`.
- **Downloads**: a background session `downloadTask`. For resume use `cancel(byProducingResumeData:)` /
  `downloadTask(withResumeData:)`. The server supports the Range + ETag/If-Range that URLSession needs. Verify the sha256,
  then move the file into the job's folder.
- Small JSON calls (`POST /v1/uploads`, `complete`, `GET` job) can use a default session in the foreground, or
  run inside the background task's completion handler.
- Hash with `CryptoKit.SHA256` streaming in 4 MiB reads. Don't load the zip into memory.
- The zip is the same STORE zip as the "Export photos" feature (Images/ + reconstruction-log.txt).
- Key handling: read `ReconAPIKey` from Info.plist (injected by CI from the `RECON_API_KEY` secret), keep it in the Keychain,
  never log it, and never put it in URLs. Same for `ReconBaseURL` / `ReconDiscoveryURL` (from `RECON_BASE_URL`,
  `RECON_DISCOVERY_URL`).
- ATS: the base URL is HTTPS with a valid Cloudflare certificate, so no exceptions are needed.
