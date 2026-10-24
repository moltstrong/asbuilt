package com.moltstrong.asbuilt.core.recon

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.BufferedSink
import okio.source
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** HTTP status + body text of one call. */
data class ReconResponse(val code: Int, val body: String, val headers: Map<String, String> = emptyMap())

/**
 * The v1 HTTP calls (MacRecon/API.md §4). Every IO failure becomes [ReconOffline]; non-2xx bodies are
 * turned into [ReconApiError] by [fail]. Paths are joined onto the base URL (keeping any path prefix),
 * ids are percent-escaped, and file downloads only follow `/v1/jobs/<id>/files/<name>` URLs so a hostile
 * server can't redirect the key elsewhere.
 */
class ReconClient(
    val config: ReconConfig,
    val http: OkHttpClient = defaultHttp(),
    private val userAgent: String = "AsBuilt-Android",
) {
    @Volatile
    var resolvedBase: String? = null
        private set

    fun forgetBase() {
        resolvedBase = null
    }

    /** Discovery first (the tunnel URL changes when the Mac restarts), then the URL baked into the build. */
    suspend fun baseUrl(): String {
        resolvedBase?.let { return it }
        if (!config.isUsable) throw ReconFatal("Mac builds aren't set up in this copy of AsBuilt. Add the server in Settings.")
        val candidates = mutableListOf<String>()
        config.discoveryUrl?.takeIf { it.isNotBlank() }?.let { disc ->
            try {
                val r = execute(
                    Request.Builder().url(disc).get()
                        .header("Accept", "application/vnd.github+json")
                        .header("User-Agent", userAgent).build(),
                    http.newBuilder().callTimeout(15, TimeUnit.SECONDS).build(),
                )
                if (r.code == 200) ReconDiscovery.baseUrl(r.body)?.let { candidates.add(it) }
            } catch (_: Exception) {
                // fall through to the configured base
            }
        }
        config.baseUrl?.trim()?.trimEnd('/')?.takeIf { it.isNotBlank() && it !in candidates }?.let { candidates.add(it) }
        for (c in candidates) {
            try {
                val r = execute(Request.Builder().url(join(c, "/v1/health")).get().header("Accept", "application/json").build(),
                    http.newBuilder().callTimeout(12, TimeUnit.SECONDS).build())
                if (r.code == 200) {
                    val h = ReconJson.decodeFromString<ReconHealth>(r.body)
                    if (h.ok && (h.apiVersion ?: 1) == 1) {
                        resolvedBase = c
                        return c
                    }
                }
            } catch (_: Exception) {
            }
        }
        throw ReconOffline("Your Mac isn't reachable right now. AsBuilt keeps trying.")
    }

    // MARK: requests

    private fun req(base: String, path: String): Request.Builder =
        Request.Builder().url(join(base, path))
            .header("Authorization", "Bearer ${config.apiKey}")
            .header("Accept", "application/json")
            .header("User-Agent", userAgent)

    suspend fun createUpload(base: String, body: ReconCreateUpload): ReconResponse =
        execute(req(base, "/v1/uploads").post(ReconJson.encodeToString(body).toRequestBody(JSON)).build())

    /** Settings "Test connection": resolves the base (discovery if needed) and checks auth via GET /v1/jobs. */
    suspend fun health(base: String): ReconResponse =
        execute(req(base, "/v1/jobs?captureID=connection-test").get().build(), http.newBuilder().callTimeout(20, TimeUnit.SECONDS).build())

    suspend fun getUpload(base: String, uploadID: String): ReconResponse =
        execute(req(base, "/v1/uploads/${esc(uploadID)}").get().build())

    suspend fun complete(base: String, uploadID: String): ReconResponse =
        execute(req(base, "/v1/uploads/${esc(uploadID)}/complete").post(ByteArray(0).toRequestBody(null)).build(),
            http.newBuilder().readTimeout(120, TimeUnit.SECONDS).build())

    suspend fun getJob(base: String, jobID: String): ReconResponse =
        execute(req(base, "/v1/jobs/${esc(jobID)}").get().build())

    suspend fun deleteJob(base: String, jobID: String): ReconResponse =
        execute(req(base, "/v1/jobs/${esc(jobID)}").delete().build())

    suspend fun deleteUpload(base: String, uploadID: String): ReconResponse =
        execute(req(base, "/v1/uploads/${esc(uploadID)}").delete().build())

    suspend fun diagnostics(base: String, body: ReconDiagnostic): ReconResponse =
        execute(req(base, "/v1/diagnostics").post(ReconJson.encodeToString(body).toRequestBody(JSON)).build(),
            http.newBuilder().callTimeout(20, TimeUnit.SECONDS).build())

    /** PUT one chunk file with Content-Length + X-Chunk-SHA256; [onSent] reports bytes on the wire. */
    suspend fun putChunk(base: String, uploadID: String, chunk: ReconChunk, file: File, onSent: (Long) -> Unit = {}): ReconResponse {
        val body = FileBody(file, OCTET, onSent)
        return execute(
            req(base, "/v1/uploads/${esc(uploadID)}/chunks/${chunk.index}").put(body)
                .header("X-Chunk-SHA256", chunk.sha256).build(),
            http.newBuilder().writeTimeout(600, TimeUnit.SECONDS).readTimeout(600, TimeUnit.SECONDS).build(),
        )
    }

    /** Request for `files[].url` (relative), or null for anything that isn't a job file path. */
    fun fileRequest(base: String, relativeUrl: String, rangeStart: Long = 0): Request? {
        if (!relativeUrl.startsWith("/v1/jobs/") || !relativeUrl.contains("/files/") || relativeUrl.contains("..") ||
            relativeUrl.contains("://")) return null
        val b = req(base, relativeUrl).get()
        if (rangeStart > 0) b.header("Range", "bytes=$rangeStart-")
        return b.build()
    }

    /** Raw call for streaming downloads (caller closes the response). */
    suspend fun call(request: Request, client: OkHttpClient = http.newBuilder().readTimeout(120, TimeUnit.SECONDS).build()): Response =
        withContext(Dispatchers.IO) {
            val c = client.newCall(request)
            suspendCancellableCoroutine { cont ->
                cont.invokeOnCancellation { c.cancel() }
                c.enqueue(object : Callback {
                    override fun onFailure(call: Call, e: IOException) {
                        if (cont.isActive) cont.resumeWithException(ReconOffline(offlineMessage(e), e))
                    }

                    override fun onResponse(call: Call, response: Response) {
                        if (cont.isActive) cont.resume(response) else response.close()
                    }
                })
            }
        }

    suspend fun execute(request: Request, client: OkHttpClient = http): ReconResponse {
        call(request, client).use { r ->
            val text = try {
                withContext(Dispatchers.IO) { r.body?.string() ?: "" }
            } catch (e: IOException) {
                throw ReconOffline(offlineMessage(e), e)
            }
            return ReconResponse(r.code, text, r.headers.associate { it.first.lowercase() to it.second })
        }
    }

    companion object {
        val JSON: MediaType = "application/json; charset=utf-8".toMediaType()
        val OCTET: MediaType = "application/octet-stream".toMediaType()

        fun defaultHttp(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(60, TimeUnit.SECONDS)
            .retryOnConnectionFailure(true)
            .build()

        fun join(base: String, path: String): String = base.trimEnd('/') + path

        fun esc(id: String): String = buildString {
            for (ch in id) {
                if (ch.isLetterOrDigit() && ch.code < 128 || ch == '-' || ch == '.' || ch == '_') append(ch)
                else for (b in ch.toString().toByteArray()) append('%').append(String.format("%02X", b.toInt() and 0xff))
            }
        }

        fun offlineMessage(e: Throwable): String? = when (e) {
            is java.net.UnknownHostException -> "No connection to your Mac (offline or the tunnel moved). AsBuilt keeps trying."
            else -> null
        }

        /** Turns a non-success response into a typed error (our JSON) or [ReconOffline] (Cloudflare HTML, 5xx). */
        fun fail(r: ReconResponse): Nothing {
            ReconApiError.parse(r.body, r.code)?.let { throw it }
            throw ReconOffline(if (r.code == 0) null else "Your Mac's tunnel answered HTTP ${r.code}. AsBuilt keeps trying.")
        }

        fun isValidBase(url: String): Boolean = url.toHttpUrlOrNull()?.let { it.scheme == "https" || it.host == "127.0.0.1" || it.host == "localhost" || it.host.startsWith("10.") } ?: false
    }

    private class FileBody(private val file: File, private val type: MediaType, private val onSent: (Long) -> Unit) : RequestBody() {
        override fun contentType() = type
        override fun contentLength() = file.length()
        override fun writeTo(sink: BufferedSink) {
            var sent = 0L
            file.source().use { src ->
                val buf = okio.Buffer()
                while (true) {
                    val n = src.read(buf, 256 * 1024)
                    if (n < 0) break
                    sink.write(buf, n)
                    sent += n
                    onSent(sent)
                }
            }
        }
    }
}
