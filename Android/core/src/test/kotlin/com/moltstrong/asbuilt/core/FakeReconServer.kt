package com.moltstrong.asbuilt.core

import com.moltstrong.asbuilt.core.recon.ReconChunker
import com.moltstrong.asbuilt.core.recon.ReconJson
import com.moltstrong.asbuilt.core.recon.toHex
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.RecordedRequest
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger

/**
 * In-memory asbuilt-recon v1 server for MockWebServer: create/PUT chunks/GET upload/complete/jobs/files
 * with auto-complete, sha checks, Range downloads and injectable faults (Cloudflare HTML pages, 5xx,
 * dropped connections, sha mismatches), like MacRecon/server/recon_server.py.
 */
class FakeReconServer(
    val apiKey: String = "test-key",
    val glb: ByteArray = "glTF-fake-model-bytes".repeat(5000).toByteArray(),
    /** Job polls before the job is done. */
    var processingPolls: Int = 2,
) : Dispatcher() {
    val requests: MutableList<String> = Collections.synchronizedList(mutableListOf<String>())
    val chunkPuts = AtomicInteger(0)
    val inFlight = AtomicInteger(0)
    val maxInFlight = AtomicInteger(0)

    /** chunk index -> remaining injected failures (each: Cloudflare 502 HTML page). */
    val failChunk: MutableMap<Int, Int> = Collections.synchronizedMap(mutableMapOf())
    /** chunk index -> remaining corrupted (sha mismatch) responses. */
    val shaMismatch: MutableMap<Int, Int> = Collections.synchronizedMap(mutableMapOf())
    /** Remaining 503s for the job GET. */
    var jobFailures = 0
    /** Corrupt the first N model downloads (wrong bytes). */
    var corruptDownloads = 0
    /** Cut the first N downloads after half the bytes (simulates a dropped connection). */
    var truncatedDownloads = 0
    var failJob = false
    var omitGlb = false
    var autoComplete = true
    var health = true

    var uploadBody: JsonObject? = null
    var chunkSize = 0
    var chunkCount = 0
    var totalBytes = 0L
    var sha = ""
    val chunks: MutableMap<Int, ByteArray> = Collections.synchronizedMap(sortedMapOf())
    var jobCreated = false
    var polls = 0
    val rangeHeaders: MutableList<String?> = Collections.synchronizedList(mutableListOf<String?>())
    var deletedJob = false
    var diagnostics = AtomicInteger(0)

    val glbSha: String get() = MessageDigest.getInstance("SHA-256").digest(glb).toHex()

    private fun json(code: Int, body: String) = MockResponse().setResponseCode(code).setHeader("Content-Type", "application/json").setBody(body)
    private fun err(code: Int, c: String, extra: String = "") =
        json(code, """{"error": {"code": "$c", "message": "$c"$extra}}""")

    fun assembled(): ByteArray {
        val out = ByteArrayOutputStream()
        for (i in 0 until chunkCount) out.write(chunks[i] ?: return ByteArray(0))
        return out.toByteArray()
    }

    private fun uploadJson(): String {
        val received = synchronized(chunks) { chunks.keys.sorted() }
        return """{"uploadID": "up_1", "captureID": "cap", "totalBytes": $totalBytes, "sha256": "$sha", "chunkSize": $chunkSize,
            "chunkCount": $chunkCount, "receivedChunks": $received, "state": "${if (jobCreated) "completed" else "open"}",
            "jobID": ${if (jobCreated) "\"job_1\"" else "null"}, "detail": "phone", "glb": true}"""
    }

    private fun tryComplete(): Boolean {
        if (chunks.size != chunkCount) return false
        val all = assembled()
        if (MessageDigest.getInstance("SHA-256").digest(all).toHex() != sha) {
            chunks.clear()
            return false
        }
        jobCreated = true
        return true
    }

    override fun dispatch(request: RecordedRequest): MockResponse {
        val path = request.path ?: ""
        requests.add("${request.method} $path")
        if (path == "/v1/health") return if (health) json(200, """{"ok": true, "apiVersion": 1}""") else MockResponse().setResponseCode(502)
            .setHeader("Content-Type", "text/html").setBody("<html>Cloudflare 502</html>")
        if (request.getHeader("Authorization") != "Bearer $apiKey") return err(401, "unauthorized")
        val m = request.method
        return when {
            m == "POST" && path == "/v1/uploads" -> {
                val b = ReconJson.parseToJsonElement(request.body.readUtf8()).jsonObject
                uploadBody = b
                chunkSize = b["chunkSize"]!!.jsonPrimitive.int
                totalBytes = b["totalBytes"]!!.jsonPrimitive.long
                sha = b["sha256"]!!.jsonPrimitive.content
                chunkCount = ReconChunker.chunkCount(totalBytes, chunkSize)
                autoComplete = b["autoComplete"]?.jsonPrimitive?.boolean ?: false
                chunks.clear(); jobCreated = false
                json(201, uploadJson())
            }
            m == "PUT" && path.startsWith("/v1/uploads/up_1/chunks/") -> {
                val n = path.substringAfterLast('/').toInt()
                val now = inFlight.incrementAndGet()
                maxInFlight.updateAndGet { maxOf(it, now) }
                try {
                    Thread.sleep(30)
                    chunkPuts.incrementAndGet()
                    val bytes = request.body.readByteArray()
                    if (jobCreated) return err(409, "upload_completed", ""","jobID": "job_1"""")
                    val f = failChunk[n] ?: 0
                    if (f > 0) {
                        failChunk[n] = f - 1
                        return MockResponse().setResponseCode(502).setHeader("Content-Type", "text/html")
                            .setBody("<!DOCTYPE html><html><title>502 Bad gateway | Cloudflare</title></html>")
                    }
                    val s = shaMismatch[n] ?: 0
                    if (s > 0) {
                        shaMismatch[n] = s - 1
                        return err(400, "chunk_sha256_mismatch")
                    }
                    val expectedLen = if (n == chunkCount - 1) totalBytes - n.toLong() * chunkSize else chunkSize.toLong()
                    if (bytes.size.toLong() != expectedLen) return err(400, "chunk_size_mismatch")
                    val hdr = request.getHeader("X-Chunk-SHA256")
                    if (hdr != null && hdr != MessageDigest.getInstance("SHA-256").digest(bytes).toHex()) return err(400, "chunk_sha256_mismatch")
                    chunks[n] = bytes
                    if (autoComplete) tryComplete()
                    val received = synchronized(chunks) { chunks.keys.sorted() }
                    json(200, """{"uploadID": "up_1", "index": $n, "bytes": ${bytes.size}, "receivedChunks": $received, "chunkCount": $chunkCount}""")
                } finally {
                    inFlight.decrementAndGet()
                }
            }
            m == "GET" && path == "/v1/uploads/up_1" -> json(200, uploadJson())
            m == "POST" && path == "/v1/uploads/up_1/complete" -> {
                if (jobCreated) json(200, """{"jobID": "job_1", "uploadID": "up_1", "alreadyCompleted": true}""")
                else if (chunks.size != chunkCount) err(409, "missing_chunks")
                else if (tryComplete()) json(201, """{"jobID": "job_1", "uploadID": "up_1", "alreadyCompleted": false}""")
                else err(422, "sha256_mismatch")
            }
            m == "GET" && path == "/v1/jobs/job_1" -> {
                if (jobFailures > 0) {
                    jobFailures--
                    return MockResponse().setResponseCode(503).setBody("<html>tunnel</html>")
                }
                polls++
                when {
                    failJob -> json(200, """{"jobID": "job_1", "state": "failed", "error": {"code": "build_failed", "message": "Too few photos overlap."}}""")
                    polls <= processingPolls -> json(200, """{"jobID": "job_1", "state": "processing", "progress": ${0.3 * polls}, "stage": "meshGeneration", "etaSeconds": 120, "queuePosition": 0}""")
                    else -> {
                        val files = mutableListOf("""{"name": "model.usdz", "bytes": 10, "sha256": "x", "url": "/v1/jobs/job_1/files/model.usdz"}""")
                        if (!omitGlb) files.add("""{"name": "model.glb", "bytes": ${glb.size}, "sha256": "$glbSha", "url": "/v1/jobs/job_1/files/model.glb"}""")
                        files.add("""{"name": "recon-log.txt", "bytes": 5, "sha256": "y", "url": "/v1/jobs/job_1/files/recon-log.txt"}""")
                        json(200, """{"jobID": "job_1", "state": "done", "progress": 1.0, "polygons": 249999, "buildSeconds": 200.5,
                            "textures": [{"name": "diffuse", "width": 8192, "height": 8192}, {"name": "normal", "width": 8192, "height": 8192}],
                            "glbInfo": {"triangles": 249999, "vertices": 135000, "bytes": ${glb.size}},
                            "files": [${files.joinToString(",")}]}""")
                    }
                }
            }
            m == "GET" && path == "/v1/jobs/job_1/files/model.glb" -> {
                val range = request.getHeader("Range")
                rangeHeaders.add(range)
                val start = range?.removePrefix("bytes=")?.removeSuffix("-")?.toLongOrNull() ?: 0L
                var body = glb.copyOfRange(start.toInt(), glb.size)
                if (corruptDownloads > 0) {
                    corruptDownloads--
                    body = body.copyOf().also { it[it.size / 2] = (it[it.size / 2] + 1).toByte() }
                }
                if (truncatedDownloads > 0) {
                    truncatedDownloads--
                    return MockResponse().setResponseCode(if (start > 0) 206 else 200)
                        .setHeader("Content-Length", body.size.toString())
                        .setBody(okio.Buffer().write(body.copyOfRange(0, body.size / 2)))
                        .setSocketPolicy(okhttp3.mockwebserver.SocketPolicy.DISCONNECT_DURING_RESPONSE_BODY)
                }
                MockResponse().setResponseCode(if (start > 0) 206 else 200).setHeader("Content-Type", "model/gltf-binary")
                    .setBody(okio.Buffer().write(body))
            }
            m == "GET" && path == "/v1/jobs/job_1/files/recon-log.txt" -> MockResponse().setResponseCode(200).setBody("log\n")
            m == "DELETE" && path == "/v1/jobs/job_1" -> {
                deletedJob = true; json(200, """{"deleted": true}""")
            }
            m == "POST" && path == "/v1/diagnostics" -> {
                diagnostics.incrementAndGet(); json(200, """{"ok": true}""")
            }
            else -> err(404, "not_found")
        }
    }

    fun receivedUploadField(name: String) = uploadBody?.get(name)?.jsonPrimitive?.content

    @Suppress("unused")
    fun receivedArray(name: String) = uploadBody?.get(name)?.jsonArray
}
