package com.moltstrong.asbuilt.core.recon

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.coroutineContext

/** Where one capture's build state, upload work files and model live (the app's capture store, or a CLI folder). */
interface BuildHost {
    val captureID: String
    val title: String?

    /** Current persisted build; null when the capture was deleted (the runner stops). */
    fun load(): RemoteBuild?

    fun save(build: RemoteBuild)

    /** Upload work folder: Images.zip while packing, then `chunk-<n>.bin` + plan.json. */
    val workDir: File

    /** Writes the STORE photo zip into [into] and returns it. [onProgress] gets 0..1. */
    fun pack(into: File, onProgress: (Double) -> Unit): File

    /** Where the verified model.glb goes. */
    val modelFile: File

    /** Optional: the Mac's build log next to the model. */
    val logFile: File? get() = null
}

/**
 * Upload → build on the Mac → download, resumable at every step. A Kotlin port of the iOS
 * RemoteBuildService flow (AsBuilt/Capture/RemoteBuildService.swift):
 *  - 8 MiB chunks, [ReconChunker.MAX_IN_FLIGHT] in flight, each chunk retried on its own with backoff
 *    (min(16, 2^n) s), so a dropped mobile connection costs one chunk, not the upload;
 *  - Cloudflare HTML pages, 5xx and 429 are retryable; 401/404/413 are not;
 *  - after repeated failures the build goes to WAITING_FOR_MAC and the loop backs off (2…60 s) and
 *    re-resolves the server URL through discovery (the tunnel URL changes when the Mac restarts);
 *  - resumes from the server's receivedChunks; the server auto-completes, /complete is the fallback;
 *  - model.glb is downloaded with Range resume and sha256-verified before it replaces anything.
 */
class RemoteBuildRunner(
    private val client: ReconClient,
    private val host: BuildHost,
    private val sleeper: suspend (Long) -> Unit = { delay(it) },
    private val pollIntervalMs: Long = 5_000,
    private val chunkSize: Int = ReconChunker.CHUNK_SIZE,
    private val maxInFlight: Int = ReconChunker.MAX_IN_FLIGHT,
    private val sendDiagnostics: Boolean = true,
    private val appBuild: String? = null,
    private val device: String? = null,
    private val appState: () -> String? = { null },
    private val log: (String) -> Unit = {},
    private val deleteJobAfterDownload: Boolean = true,
    /** Phone GPU memory: 3 x 8K RGBA textures are ~1 GB once decoded, so the app asks for 4K by default. */
    private val glbTextureSize: Int? = null,
    private val clock: () -> Long = { System.currentTimeMillis() },
) {
    private val diagScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val saveLock = Any()
    private var lastTransientSave = 0L
    /** Progress-only saves are allowed only while a transfer is running (late callbacks from OkHttp's
     *  writer thread must never overwrite a newer state such as WAITING_FOR_MAC). */
    private var transientEnabled = false

    private fun setTransient(enabled: Boolean) = synchronized(saveLock) { transientEnabled = enabled }

    /** Runs until the build is done, failed, cancelled or the capture is gone. Returns the final state. */
    suspend fun run(): RemoteBuild? {
        var backoffS = 2L
        while (true) {
            coroutineContext.ensureActive()
            var build = host.load() ?: return null
            if (!build.isActive) return build
            try {
                val base = client.baseUrl()
                if (build.jobID == null) build = upload(build, base)
                build = waitForMac(build, base)
                if (build.phase == RemoteBuild.Phase.FAILED) {
                    save(build)
                    return build
                }
                download(build, base)
                host.workDir.deleteRecursively()
                return host.load()
            } catch (e: CancellationException) {
                throw e
            } catch (e: ReconFatal) {
                return failWith(e.message ?: "The Mac build couldn't continue.")
            } catch (e: ReconApiError) {
                when (e.code) {
                    "unauthorized" -> return failWith("This copy of AsBuilt has the wrong key for your Mac's build server.")
                    "upload_too_large" -> return failWith("This capture is too large for the Mac build (8 GB max).")
                }
                backoffS = waiting(e, backoffS)
            } catch (e: Exception) {
                backoffS = waiting(e, backoffS)
            }
        }
    }

    private suspend fun waiting(error: Exception, backoffS: Long): Long {
        client.forgetBase()
        var b = host.load() ?: throw CancellationException("capture gone")
        if (!b.isActive) throw CancellationException("build no longer active")
        var waitS = backoffS
        if (error is ReconApiError) {
            if (error.code == "rate_limited") waitS = maxOf(5, (error.retryAfterSeconds ?: 60).toLong())
            if (error.code == "insufficient_storage") waitS = 120
        }
        val toWaiting = b.phase == RemoteBuild.Phase.PREPARING || b.phase == RemoteBuild.Phase.UPLOADING ||
            b.phase == RemoteBuild.Phase.WAITING_FOR_MAC || b.jobID == null
        b = b.copy(failureCount = b.failureCount + 1, message = waitingMessage(error), inFlightBytes = 0,
            phase = if (toWaiting) RemoteBuild.Phase.WAITING_FOR_MAC else b.phase)
        save(b)
        log("waiting ${waitS}s: ${error.javaClass.simpleName}: ${b.message}")
        diagnose(b.uploadID, "waiting", b, "${error.javaClass.simpleName}: ${b.message}")
        sleeper(waitS * 1000)
        return minOf(60, backoffS * 2)
    }

    private fun failWith(message: String): RemoteBuild? {
        val b = host.load() ?: return null
        val f = b.copy(phase = RemoteBuild.Phase.FAILED, message = message, finishedAtMs = clock(), inFlightBytes = 0)
        save(f)
        log("failed: $message")
        diagnose(f.uploadID, "failed", f, message)
        return f
    }

    // MARK: upload

    private fun planFile() = File(host.workDir, "plan.json")

    private fun loadPlan(): ReconChunkPlan? = try {
        planFile().takeIf { it.isFile }?.let { ReconJson.decodeFromString<ReconChunkPlan>(it.readText()) }
    } catch (_: Exception) {
        null
    }

    private suspend fun prepare(): ReconChunkPlan = withContext(Dispatchers.IO) {
        try {
            val work = host.workDir
            work.deleteRecursively()
            work.mkdirs()
            val zip = host.pack(work) { p ->
                host.load()?.let { b -> transient(b.copy(phase = RemoteBuild.Phase.PREPARING, phaseProgress = 0.8 * p)) }
            }
            val plan = ReconChunker.split(zip, work, chunkSize) { !coroutineContext.isActive }
            val tmp = File(work, "plan.json.tmp")
            tmp.writeText(ReconJson.encodeToString(plan))
            if (!tmp.renameTo(planFile())) throw java.io.IOException("couldn't write plan.json")
            plan
        } catch (e: CancellationException) {
            throw e
        } catch (e: java.util.concurrent.CancellationException) {
            throw CancellationException("cancelled while packing")
        } catch (e: ReconFatal) {
            throw e
        } catch (e: Exception) {
            throw ReconFatal("Couldn't pack the photos: ${e.message ?: e.javaClass.simpleName}")
        }
    }

    private suspend fun upload(start: RemoteBuild, base: String): RemoteBuild {
        var build = start
        val work = host.workDir
        var plan = loadPlan()
        if (plan == null) build = build.copy(uploadID = null)

        // Server-side upload still there? Otherwise (expired / chunks we already deleted are needed) start over.
        val existing = build.uploadID
        if (existing != null && plan != null) {
            val r = client.getUpload(base, existing)
            when (r.code) {
                200 -> {
                    val up = ReconJson.decodeFromString<ReconUpload>(r.body)
                    build = build.applying(up, clock())
                    if (up.jobID != null) {
                        save(build)
                        return build
                    }
                }
                404 -> build = build.copy(uploadID = null)
                else -> ReconClient.fail(r)
            }
        }
        if (plan != null && build.uploadID != null) {
            val have = build.receivedChunks.toSet()
            val missingFiles = plan.chunks.filter { it.index !in have && !File(work, it.fileName).exists() }
            if (missingFiles.isNotEmpty()) {
                plan = null
                build = build.copy(uploadID = null)
            }
        }
        if (build.uploadID == null) {
            build = build.copy(receivedChunks = emptyList())
            if (plan == null) {
                build = build.copy(phase = RemoteBuild.Phase.PREPARING, phaseProgress = 0.0, message = null)
                save(build)
                setTransient(true)
                plan = try {
                    prepare()
                } finally {
                    setTransient(false)
                }
            }
            val body = ReconCreateUpload(
                captureID = host.captureID, totalBytes = plan.totalBytes, sha256 = plan.sha256, detail = build.detail,
                title = host.title?.take(120), chunkSize = plan.chunkSize, autoComplete = true, glb = true, glbTextureSize = glbTextureSize,
            )
            val r = client.createUpload(base, body)
            if (r.code != 201) ReconClient.fail(r)
            val up = ReconJson.decodeFromString<ReconUpload>(r.body)
            build = build.applying(up, clock())
            log("upload ${up.uploadID} created: ${plan.totalBytes} bytes, ${up.chunkCount} chunks")
        }
        val p = plan ?: throw ReconFatal("Couldn't pack the photos.")
        build = build.copy(totalBytes = p.totalBytes, phase = RemoteBuild.Phase.UPLOADING, message = null)
        save(build)
        val uploadID = build.uploadID ?: throw ReconOffline()

        val have = build.receivedChunks.toSet()
        val pending = ArrayDeque(p.chunks.filter { it.index !in have })
        val lock = Mutex()
        val inFlight = ConcurrentHashMap<Int, Long>()
        val consecutive = AtomicInteger(0)
        var completedJob: String? = null
        var current = build
        diagnose(uploadID, "upload_start", build, "${pending.size} of ${p.chunks.size} chunks to send, ${ReconFormat.bytes(p.totalBytes)}")

        suspend fun backoff(n: Int) = sleeper(minOf(16L, 1L shl minOf(n, 10)) * 1000)

        suspend fun send(chunk: ReconChunk) {
            while (true) {
                coroutineContext.ensureActive()
                if (lock.withLock { completedJob } != null) return
                val file = File(work, chunk.fileName)
                val r = try {
                    client.putChunk(base, uploadID, chunk, file) { sent ->
                        inFlight[chunk.index] = sent
                        transient(current.copy(inFlightBytes = inFlight.values.sum()))
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    inFlight.remove(chunk.index)
                    val n = consecutive.incrementAndGet()
                    diagnose(uploadID, "chunk_error", current, "${e.javaClass.simpleName}: ${e.message}", chunk = chunk.index)
                    if (n >= 6) throw ReconOffline("The connection to your Mac keeps dropping. AsBuilt keeps trying.", e)
                    backoff(n)
                    continue
                }
                inFlight.remove(chunk.index)
                val err = if (r.code != 200) ReconApiError.parse(r.body, r.code) else null
                when {
                    r.code == 200 -> {
                        val receipt = try {
                            ReconJson.decodeFromString<ReconChunkReceipt>(r.body)
                        } catch (_: Exception) {
                            null
                        }
                        if (receipt == null) { // 200 with a non-JSON body: a proxy page, retry
                            val n = consecutive.incrementAndGet()
                            if (n >= 4) throw ReconOffline()
                            backoff(n)
                            continue
                        }
                        consecutive.set(0)
                        lock.withLock {
                            current = current.markingChunkReceived(receipt, clock()).copy(inFlightBytes = inFlight.values.sum())
                            val latest = host.load()
                            if (latest == null || !latest.isActive) throw CancellationException("build cancelled")
                            save(latest.copy(
                                receivedChunks = current.receivedChunks, totalBytes = current.totalBytes,
                                chunkSize = current.chunkSize, chunkCount = current.chunkCount, failureCount = 0, message = null,
                                phase = if (current.phase == RemoteBuild.Phase.QUEUED) RemoteBuild.Phase.QUEUED else RemoteBuild.Phase.UPLOADING,
                                inFlightBytes = current.inFlightBytes, uploadID = uploadID,
                            ))
                        }
                        file.delete()
                        return
                    }
                    r.code == 409 && err?.code == "upload_completed" -> {
                        lock.withLock { completedJob = err.jobID ?: completedJob }
                        return
                    }
                    r.code == 400 && err?.code == "chunk_sha256_mismatch" -> {
                        diagnose(uploadID, "chunk_sha_mismatch", current, null, chunk = chunk.index)
                        val n = consecutive.incrementAndGet()
                        if (n >= 6) throw ReconOffline("Photos keep getting corrupted on the way. AsBuilt keeps trying.")
                        continue // transport corruption: re-send
                    }
                    r.code == 401 || r.code == 404 || r.code == 413 -> ReconClient.fail(r)
                    else -> {
                        // Cloudflare error page, 5xx, 429: retry this chunk after a pause.
                        val n = consecutive.incrementAndGet()
                        diagnose(uploadID, "chunk_http_${r.code}", current, r.body.take(200), chunk = chunk.index)
                        if (n >= 4) ReconClient.fail(r)
                        if (r.code == 429) sleeper(maxOf(5, err?.retryAfterSeconds ?: 10) * 1000L) else backoff(n)
                        continue
                    }
                }
            }
        }

        setTransient(true)
        try {
            coroutineScope {
                repeat(maxOf(1, minOf(maxInFlight, pending.size))) {
                    launch {
                        while (true) {
                            val next = lock.withLock { if (completedJob != null) null else pending.removeFirstOrNull() } ?: break
                            send(next)
                        }
                    }
                }
            }
        } finally {
            setTransient(false)
        }
        build = host.load() ?: throw CancellationException("capture gone")
        diagnose(uploadID, "upload_chunks_done", build, null)
        completedJob?.let { jid ->
            build = build.copy(jobID = jid, phase = RemoteBuild.Phase.QUEUED, phaseProgress = 0.0, inFlightBytes = 0)
            save(build)
            return build
        }
        // All chunks in: the server auto-completes; fall back to an explicit /complete.
        for (attempt in 0 until 8) {
            val r = client.getUpload(base, uploadID)
            if (r.code == 200) {
                val up = ReconJson.decodeFromString<ReconUpload>(r.body)
                build = build.applying(up, clock())
                if (up.jobID != null) break
                if (build.missingChunks.isNotEmpty()) throw ReconOffline("Some photos didn't arrive. Sending them again.")
            } else {
                ReconClient.fail(r)
            }
            if (attempt >= 2) {
                val c = client.complete(base, uploadID)
                if (c.code == 200 || c.code == 201) {
                    val done = ReconJson.decodeFromString<ReconComplete>(c.body)
                    build = build.copy(jobID = done.jobID)
                    break
                }
                if (c.code == 422) {
                    // Whole-file hash mismatch: the server discarded everything. Pack again.
                    host.workDir.deleteRecursively()
                    save(build.copy(uploadID = null, receivedChunks = emptyList()))
                    throw ReconOffline("The photo upload got corrupted. Sending it again.")
                }
                if (c.code == 409) throw ReconOffline("Some photos didn't arrive. Sending them again.")
                ReconClient.fail(c)
            }
            sleeper(1000)
        }
        if (build.jobID == null) throw ReconOffline()
        build = build.copy(phase = RemoteBuild.Phase.QUEUED, phaseProgress = 0.0, inFlightBytes = 0)
        save(build)
        log("upload complete -> job ${build.jobID}")
        return build
    }

    // MARK: poll

    private suspend fun waitForMac(start: RemoteBuild, base: String): RemoteBuild {
        val remoteJob = start.jobID ?: throw ReconOffline()
        var lastLogged = ""
        while (true) {
            coroutineContext.ensureActive()
            val r = client.getJob(base, remoteJob)
            if (r.code == 404) {
                // Job expired on the Mac before we downloaded it: build again from the photos.
                val b = host.load() ?: throw CancellationException("capture gone")
                host.workDir.deleteRecursively()
                save(b.copy(jobID = null, uploadID = null, receivedChunks = emptyList()))
                throw ReconOffline("Your Mac no longer had this build. Sending the photos again.")
            }
            if (r.code != 200) ReconClient.fail(r)
            val job = ReconJson.decodeFromString<ReconJob>(r.body)
            var b = host.load() ?: throw CancellationException("capture gone")
            if (!b.isActive) throw CancellationException("build no longer active")
            b = b.applying(job, clock()).copy(failureCount = 0, inFlightBytes = 0)
            if (job.state != "failed") b = b.copy(message = null)
            save(b)
            val line = "${job.state} ${job.stage ?: ""} ${((job.progress ?: 0.0) * 100).toInt()}%"
            if (line != lastLogged) {
                log("job $remoteJob: $line eta=${job.etaSeconds ?: "-"} queue=${job.queuePosition ?: "-"}")
                lastLogged = line
            }
            if (job.state == "done" || job.state == "failed") return b
            sleeper(pollIntervalMs)
        }
    }

    // MARK: download

    private suspend fun download(start: RemoteBuild, base: String) {
        val remoteJob = start.jobID ?: throw ReconOffline()
        val jr = client.getJob(base, remoteJob)
        if (jr.code != 200) ReconClient.fail(jr)
        val job = ReconJson.decodeFromString<ReconJob>(jr.body)
        val file = job.file(RemoteBuild.MODEL_FILE)
            ?: throw ReconFatal(job.glbError?.message?.let { "$it Try again from this phone." }
                ?: "Your Mac built the model but not the Android (GLB) version. Update the Mac's build server and try again.")
        var b = (host.load() ?: throw CancellationException("capture gone"))
            .copy(phase = RemoteBuild.Phase.DOWNLOADING, phaseProgress = 0.0, modelBytes = file.bytes)
        save(b)

        val dest = host.modelFile
        dest.parentFile?.mkdirs()
        val part = File(dest.path + ".part")
        val expected = file.bytes
        var offset = if (part.isFile) part.length() else 0L
        if (expected != null && offset > expected) {
            part.delete(); offset = 0
        }
        val started = clock()
        setTransient(true)
        try {
        if (expected == null || offset < expected) {
            val request = client.fileRequest(base, file.url, offset) ?: throw ReconFatal("The Mac sent a bad download link.")
            client.call(request).use { resp ->
                when (resp.code) {
                    206 -> Unit
                    200 -> offset = 0
                    416 -> {
                        part.delete()
                        throw ReconOffline("Download restarted.")
                    }
                    else -> ReconClient.fail(ReconResponse(resp.code, resp.body?.string() ?: ""))
                }
                val body = resp.body ?: throw ReconOffline("Download interrupted. Trying again.")
                withContext(Dispatchers.IO) {
                    FileOutputStream(part, offset > 0).use { out ->
                        val input = body.byteStream()
                        val buf = ByteArray(256 * 1024)
                        var written = offset
                        try {
                            while (true) {
                                coroutineContext.ensureActive()
                                val n = input.read(buf)
                                if (n < 0) break
                                out.write(buf, 0, n)
                                written += n
                                if (expected != null && expected > 0) transient(b.copy(phaseProgress = written.toDouble() / expected))
                            }
                        } catch (e: java.io.IOException) {
                            throw ReconOffline("Download interrupted. Trying again.", e)
                        }
                    }
                }
            }
        }
        } finally {
            setTransient(false)
        }
        val actual = withContext(Dispatchers.IO) { ReconChunker.sha256(part) }
        if (file.sha256 != null && !file.sha256.equals(actual, ignoreCase = true)) {
            part.delete()
            diagnose(start.uploadID, "download_sha_mismatch", b, null)
            throw ReconOffline("The model download got corrupted. Trying again.")
        }
        if (expected != null && part.length() != expected) {
            part.delete()
            throw ReconOffline("The model download was incomplete. Trying again.")
        }
        dest.delete()
        if (!part.renameTo(dest)) throw ReconFatal("Couldn't save the model on this phone (disk full?).")
        val secs = (clock() - started) / 1000.0
        log("downloaded ${RemoteBuild.MODEL_FILE}: ${dest.length()} bytes in ${"%.1f".format(secs)} s, sha256 verified")

        // Build log next to the model (best effort).
        host.logFile?.let { lf ->
            try {
                job.file("recon-log.txt")?.let { f ->
                    client.fileRequest(base, f.url)?.let { req ->
                        client.call(req).use { resp -> if (resp.code == 200) resp.body?.bytes()?.let { lf.writeBytes(it) } }
                    }
                }
            } catch (_: Exception) {
            }
        }
        b = (host.load() ?: return).applying(job, clock()).copy(
            phase = RemoteBuild.Phase.DONE, phaseProgress = 1.0, modelBytes = dest.length(), finishedAtMs = clock(),
            message = null, inFlightBytes = 0, polygons = job.glbInfo?.triangles ?: job.polygons,
        )
        save(b)
        diagnose(start.uploadID, "done", b, "model.glb ${dest.length()} bytes")
        if (deleteJobAfterDownload) {
            // Free the Mac's disk; the model now lives on the phone.
            diagScope.launch { runCatching { client.deleteJob(base, remoteJob) } }
        }
    }

    // MARK: helpers

    private fun save(b: RemoteBuild) = synchronized(saveLock) {
        host.save(b.copy(updatedAtMs = clock()))
    }

    /** Progress-only update (bytes on the wire, download %): at most ~3 per second. */
    private fun transient(b: RemoteBuild) {
        val now = clock()
        synchronized(saveLock) {
            if (!transientEnabled) return
            if (now - lastTransientSave < 333) return
            lastTransientSave = now
            host.save(b.copy(updatedAtMs = now))
        }
    }

    private fun diagnose(uploadID: String?, event: String, build: RemoteBuild?, message: String?, chunk: Int? = null) {
        if (!sendDiagnostics) return
        val base = client.resolvedBase ?: return
        val body = ReconDiagnostic(
            captureID = host.captureID, uploadID = uploadID, event = event.take(64), phase = build?.phase?.name?.lowercase(),
            message = message?.take(500), chunk = chunk, chunkSize = build?.chunkSize, received = build?.receivedChunks?.size,
            chunkCount = build?.chunkCount, appBuild = appBuild, device = device, appState = appState(),
        )
        diagScope.launch { runCatching { client.diagnostics(base, body) } }
    }

    companion object {
        fun waitingMessage(error: Throwable): String {
            if (error is ReconOffline) error.message?.let { return it }
            if (error is ReconApiError) {
                return when (error.code) {
                    "insufficient_storage" -> "Your Mac is out of disk space. Free some up; AsBuilt keeps trying."
                    "rate_limited" -> "Your Mac asked AsBuilt to slow down. Trying again shortly."
                    else -> error.message ?: "Your Mac had a problem (${error.code}). Trying again."
                }
            }
            return "Your Mac isn't reachable right now. AsBuilt keeps trying."
        }

        fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).toHex()
    }
}
