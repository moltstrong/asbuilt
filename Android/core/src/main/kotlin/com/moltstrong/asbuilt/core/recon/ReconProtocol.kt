package com.moltstrong.asbuilt.core.recon

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** asbuilt-recon v1 wire types (MacRecon/API.md). Mirrors AsBuiltCore/ReconProtocol.swift. */

val ReconJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = true
    coerceInputValues = true
}

/** Where the Mac server lives and the key. Never logged. */
data class ReconConfig(
    val baseUrl: String?,
    val discoveryUrl: String?,
    val apiKey: String,
) {
    val isUsable: Boolean get() = apiKey.isNotBlank() && (!baseUrl.isNullOrBlank() || !discoveryUrl.isNullOrBlank())

    override fun toString(): String =
        "ReconConfig(base=${if (baseUrl.isNullOrBlank()) "none" else "set"}, discovery=${if (discoveryUrl.isNullOrBlank()) "none" else "set"}, key=${if (apiKey.isBlank()) "none" else "set"})"
}

@Serializable
data class ReconHealth(val ok: Boolean = false, val apiVersion: Int? = null, val queueLength: Int? = null, val processing: Boolean? = null)

object ReconDetail {
    /** Apple's maximum on the Mac packaged for phones: 250k triangles + 8K maps. */
    const val PHONE = "phone"
    const val FULL = "full"
}

@Serializable
data class ReconCreateUpload(
    val captureID: String,
    val filename: String = "Images.zip",
    val totalBytes: Long,
    val sha256: String,
    val detail: String = ReconDetail.PHONE,
    val title: String? = null,
    val notify: Boolean = true,
    val chunkSize: Int,
    val autoComplete: Boolean = true,
    val obj: Boolean = false,
    /** Android: also build model.glb (Filament/SceneView can't open USDZ). */
    val glb: Boolean = true,
    /** Cap for the textures embedded in model.glb (1024/2048/4096/8192); null keeps the build's 8K. */
    val glbTextureSize: Int? = null,
)

@Serializable
data class ReconUpload(
    val uploadID: String,
    val captureID: String? = null,
    val totalBytes: Long = 0,
    val sha256: String? = null,
    val chunkSize: Int = 0,
    val chunkCount: Int = 0,
    val receivedChunks: List<Int> = emptyList(),
    val receivedBytes: Long? = null,
    val state: String? = null,
    val jobID: String? = null,
    val detail: String? = null,
    val glb: Boolean? = null,
)

@Serializable
data class ReconChunkReceipt(
    val uploadID: String? = null,
    val index: Int,
    val bytes: Long? = null,
    val sha256: String? = null,
    val receivedChunks: List<Int> = emptyList(),
    val chunkCount: Int? = null,
)

@Serializable
data class ReconComplete(val jobID: String, val uploadID: String? = null, val alreadyCompleted: Boolean? = null)

@Serializable
data class ReconTexture(val name: String = "", val width: Int = 0, val height: Int = 0)

@Serializable
data class ReconJobFile(
    val name: String,
    val bytes: Long? = null,
    val sha256: String? = null,
    val url: String,
    val contentType: String? = null,
)

@Serializable
data class ReconJobError(val code: String? = null, val message: String? = null)

@Serializable
data class ReconGlbInfo(val triangles: Int? = null, val vertices: Int? = null, val bytes: Long? = null)

@Serializable
data class ReconJob(
    val jobID: String,
    val captureID: String? = null,
    val title: String? = null,
    val state: String,
    val queuePosition: Int? = null,
    val progress: Double? = null,
    val etaSeconds: Int? = null,
    val stage: String? = null,
    val message: String? = null,
    val detail: String? = null,
    val polygons: Int? = null,
    val textures: List<ReconTexture>? = null,
    val files: List<ReconJobFile>? = null,
    val error: ReconJobError? = null,
    val buildSeconds: Double? = null,
    val glb: Boolean? = null,
    val glbInfo: ReconGlbInfo? = null,
    val glbError: ReconJobError? = null,
) {
    fun file(name: String): ReconJobFile? = files?.firstOrNull { it.name == name }
}

@Serializable
data class ReconJobList(val jobs: List<ReconJob> = emptyList())

/** Phone-side event for POST /v1/diagnostics (logged on the Mac; never contains the key). */
@Serializable
data class ReconDiagnostic(
    val captureID: String,
    val uploadID: String? = null,
    val event: String,
    val phase: String? = null,
    val message: String? = null,
    val errorDomain: String? = null,
    val errorCode: Int? = null,
    val chunk: Int? = null,
    val chunkSize: Int? = null,
    val received: Int? = null,
    val chunkCount: Int? = null,
    val appBuild: String? = null,
    val device: String? = null,
    val appState: String? = null,
)

/** The server's JSON error envelope `{"error": {"code", "message", …}}`. */
class ReconApiError(
    val code: String,
    override val message: String? = null,
    val status: Int = 0,
    val missingChunks: List<Int>? = null,
    val jobID: String? = null,
    val retryAfterSeconds: Int? = null,
) : Exception(message ?: code) {
    companion object {
        fun parse(body: String?, status: Int = 0): ReconApiError? {
            if (body.isNullOrBlank()) return null
            return try {
                val root = ReconJson.parseToJsonElement(body).jsonObject
                val e = root["error"] as? JsonObject ?: return null
                val code = e["code"]?.jsonPrimitive?.contentOrNull ?: return null
                ReconApiError(
                    code = code,
                    message = e["message"]?.jsonPrimitive?.contentOrNull,
                    status = status,
                    missingChunks = (e["missingChunks"] as? kotlinx.serialization.json.JsonArray)?.mapNotNull { it.jsonPrimitive.intOrNull },
                    jobID = e["jobID"]?.jsonPrimitive?.contentOrNull,
                    retryAfterSeconds = e["retryAfterSeconds"]?.jsonPrimitive?.intOrNull,
                )
            } catch (_: Exception) {
                null // Cloudflare HTML error page, truncated body, …
            }
        }
    }
}

/** Retryable trouble: offline, tunnel URL changed, Mac asleep, Cloudflare error page, 5xx. */
class ReconOffline(message: String? = null, cause: Throwable? = null) : Exception(message, cause)

/** Retrying won't help (wrong key, capture too large, no photos). */
class ReconFatal(message: String) : Exception(message)

/** Discovery gist: `files["asbuilt-recon.json"].content = {"baseURL": "https://…", "apiVersion": 1}` or the raw JSON. */
object ReconDiscovery {
    fun baseUrl(fromGist: String): String? = try {
        val root = ReconJson.parseToJsonElement(fromGist).jsonObject
        val files = root["files"] as? JsonObject
        val file = files?.get("asbuilt-recon.json") as? JsonObject
        when {
            file != null -> {
                val content = file["content"]?.jsonPrimitive?.contentOrNull
                content?.let { urlFrom(ReconJson.parseToJsonElement(it).jsonObject) }
            }
            root["baseURL"] != null -> urlFrom(root)
            else -> null
        }
    } catch (_: Exception) {
        null
    }

    private fun urlFrom(obj: JsonObject): String? {
        val s = obj["baseURL"]?.jsonPrimitive?.contentOrNull?.trim() ?: return null
        val version = obj["apiVersion"]?.jsonPrimitive?.intOrNull
        if (version != null && version != 1) return null
        val url = s.toHttpUrlOrNullCompat() ?: return null
        if (url.scheme != "https" || url.host.isBlank()) return null
        return s.trimEnd('/')
    }
}

internal fun String.toHttpUrlOrNullCompat(): okhttp3.HttpUrl? = this.toHttpUrlOrNull()

/** Byte/time formatting shared by the progress card (matches iOS ReconFormat). */
object ReconFormat {
    fun bytes(n: Long): String {
        val units = listOf("bytes", "KB", "MB", "GB", "TB")
        var value = maxOf(0L, n).toDouble()
        var i = 0
        while (value >= 1000 && i < units.size - 1) {
            value /= 1000; i++
        }
        if (i == 0) return "${value.toLong()} bytes"
        return if (value >= 100) "${value.toLong()} ${units[i]}" else String.format(java.util.Locale.US, "%.1f %s", value, units[i])
    }

    fun count(n: Int): String = String.format(java.util.Locale.US, "%,d", n)

    fun duration(seconds: Int): String = when {
        seconds < 60 -> "${seconds}s"
        seconds < 3600 -> "${seconds / 60} min ${seconds % 60}s".replace(" 0s", "")
        else -> "${seconds / 3600} h ${(seconds % 3600) / 60} min"
    }

    fun timeLeft(seconds: Int): String = when {
        seconds < 60 -> "under a minute left"
        seconds < 3600 -> "about ${(seconds + 30) / 60} min left"
        else -> "about ${seconds / 3600} h ${(seconds % 3600) / 60} min left"
    }

    fun stage(stage: String?): String = when (stage) {
        "preProcessing" -> "Preparing photos"
        "imageAlignment" -> "Lining up photos"
        "pointCloudGeneration" -> "Building point cloud"
        "meshGeneration" -> "Building mesh"
        "textureMapping" -> "Painting 8K textures"
        "optimization" -> "Optimizing"
        "extracting", "starting" -> "Unpacking photos"
        "inspecting" -> "Checking the model"
        "glb" -> "Packing the model for Android"
        "waiting" -> "Waiting for another build"
        null, "" -> "Building"
        else -> "Building"
    }
}
