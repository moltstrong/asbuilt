package com.moltstrong.asbuilt.core.recon

import kotlinx.serialization.Serializable

/**
 * The Mac build of one capture, persisted with the capture so uploads and builds resume after the
 * app is killed. Mirrors iOS `RemoteBuild` (ReconProtocol.swift): same phases, same progress mapping.
 */
@Serializable
data class RemoteBuild(
    val phase: Phase = Phase.PREPARING,
    val detail: String = ReconDetail.PHONE,
    val uploadID: String? = null,
    val jobID: String? = null,
    val totalBytes: Long? = null,
    val chunkSize: Int? = null,
    val chunkCount: Int? = null,
    val receivedChunks: List<Int> = emptyList(),
    /** Fraction of the current phase (0..1). */
    val phaseProgress: Double = 0.0,
    val etaSeconds: Int? = null,
    val stage: String? = null,
    val queuePosition: Int? = null,
    val message: String? = null,
    val photoCount: Int? = null,
    val polygons: Int? = null,
    val textureSize: Int? = null,
    val textureCount: Int? = null,
    val modelBytes: Long? = null,
    val startedAtMs: Long = 0,
    val updatedAtMs: Long = 0,
    val finishedAtMs: Long? = null,
    val buildSeconds: Double? = null,
    val failureCount: Int = 0,
    /** Bytes of chunks currently on the wire (not persisted meaningfully; smooths the bar). */
    val inFlightBytes: Long = 0,
) {
    @Serializable
    enum class Phase { PREPARING, UPLOADING, QUEUED, BUILDING, DOWNLOADING, DONE, FAILED, WAITING_FOR_MAC, CANCELLED }

    val isActive: Boolean
        get() = when (phase) {
            Phase.PREPARING, Phase.UPLOADING, Phase.QUEUED, Phase.BUILDING, Phase.DOWNLOADING, Phase.WAITING_FOR_MAC -> true
            Phase.DONE, Phase.FAILED, Phase.CANCELLED -> false
        }

    val uploadedBytes: Long
        get() {
            val total = totalBytes ?: return 0
            val size = chunkSize ?: return 0
            val count = chunkCount ?: return 0
            if (count <= 0) return 0
            var bytes = 0L
            for (i in receivedChunks.toSet()) {
                if (i in 0 until count) {
                    val r = ReconChunker.range(i, total, size)
                    bytes += r.last - r.first + 1
                }
            }
            return bytes
        }

    fun uploadFraction(): Double {
        val total = totalBytes ?: return 0.0
        if (total <= 0) return 0.0
        return minOf(1.0, (uploadedBytes + maxOf(0, inFlightBytes)).toDouble() / total)
    }

    val missingChunks: List<Int>
        get() {
            val count = chunkCount ?: return emptyList()
            val have = receivedChunks.toSet()
            return (0 until count).filter { it !in have }
        }

    /** One bar across the whole trip: pack 0-5 %, upload 5-40 %, queue 40 %, build 40-95 %, download 95-100 %. */
    val overallFraction: Double
        get() = when (phase) {
            Phase.PREPARING -> 0.05 * clamp(phaseProgress)
            Phase.UPLOADING, Phase.WAITING_FOR_MAC -> 0.05 + 0.35 * uploadFraction()
            Phase.QUEUED -> 0.40
            Phase.BUILDING -> 0.40 + 0.55 * clamp(phaseProgress)
            Phase.DOWNLOADING -> 0.95 + 0.05 * clamp(phaseProgress)
            Phase.DONE -> 1.0
            Phase.FAILED, Phase.CANCELLED -> 0.0
        }

    /** Current step in the 4-step list (0 pack, 1 send, 2 build, 3 download, 4 done, -1 failed). */
    val step: Int
        get() = when (phase) {
            Phase.PREPARING -> 0
            Phase.UPLOADING, Phase.WAITING_FOR_MAC -> if (totalBytes == null) 0 else 1
            Phase.QUEUED, Phase.BUILDING -> 2
            Phase.DOWNLOADING -> 3
            Phase.DONE -> 4
            Phase.FAILED, Phase.CANCELLED -> -1
        }

    val headline: String
        get() = when (phase) {
            Phase.PREPARING -> "Packing photos"
            Phase.UPLOADING -> "Sending photos to your Mac"
            Phase.WAITING_FOR_MAC -> "Waiting for your Mac"
            Phase.QUEUED -> "On your Mac, next in line"
            Phase.BUILDING -> "Building full detail"
            Phase.DOWNLOADING -> "Bringing it to your phone"
            Phase.DONE -> "Full-detail model ready"
            Phase.FAILED -> "Mac build didn't finish"
            Phase.CANCELLED -> "Mac build cancelled"
        }

    val detailLine: String
        get() = when (phase) {
            Phase.PREPARING -> photoCount?.let { "$it photos" } ?: "Getting photos ready"
            Phase.UPLOADING -> {
                val total = totalBytes
                if (total == null) "Starting upload"
                else "${ReconFormat.bytes(minOf(total, uploadedBytes + maxOf(0, inFlightBytes)))} of ${ReconFormat.bytes(total)}"
            }
            Phase.WAITING_FOR_MAC -> message ?: "Your Mac isn't reachable right now. AsBuilt keeps trying."
            Phase.QUEUED -> {
                val q = queuePosition
                if (q != null && q > 1) "${q - 1} build${if (q == 2) "" else "s"} ahead of yours" else "Starting in a moment"
            }
            Phase.BUILDING -> {
                val parts = mutableListOf(ReconFormat.stage(stage))
                etaSeconds?.takeIf { it > 0 }?.let { parts.add(ReconFormat.timeLeft(it)) }
                parts.joinToString(" · ")
            }
            Phase.DOWNLOADING -> modelBytes?.let { "${ReconFormat.bytes(it)} model" } ?: "Downloading"
            Phase.DONE -> {
                val parts = mutableListOf<String>()
                polygons?.let { parts.add("${ReconFormat.count(it)} triangles") }
                textureSize?.let { parts.add("${it / 1024}K textures") }
                buildSeconds?.let { parts.add("built in ${ReconFormat.duration(it.toInt())}") }
                if (parts.isEmpty()) "Tap to open in 3D" else parts.joinToString(" · ")
            }
            Phase.FAILED, Phase.CANCELLED -> message ?: "The photos are safe on this phone. Try again."
        }

    /** Folds a server job snapshot into the local state (never moves backwards past downloading). */
    fun applying(job: ReconJob, nowMs: Long = System.currentTimeMillis()): RemoteBuild = when (job.state) {
        "queued" -> copy(jobID = job.jobID, updatedAtMs = nowMs, phase = Phase.QUEUED, queuePosition = job.queuePosition,
            phaseProgress = 0.0, message = job.message)
        "processing" -> copy(jobID = job.jobID, updatedAtMs = nowMs, phase = Phase.BUILDING,
            phaseProgress = minOf(1.0, maxOf(phaseProgress, job.progress ?: 0.0)), etaSeconds = job.etaSeconds,
            stage = job.stage, queuePosition = 0, message = job.message)
        "done" -> {
            val tex = job.textures.orEmpty()
            copy(
                jobID = job.jobID, updatedAtMs = nowMs,
                phase = if (phase == Phase.DONE) Phase.DONE else Phase.DOWNLOADING,
                phaseProgress = if (phase == Phase.DONE) phaseProgress else 0.0,
                polygons = job.polygons ?: polygons,
                textureCount = if (tex.isNotEmpty()) tex.size else textureCount,
                textureSize = if (tex.isNotEmpty()) tex.maxOf { maxOf(it.width, it.height) } else textureSize,
                buildSeconds = job.buildSeconds ?: buildSeconds,
                modelBytes = job.file(MODEL_FILE)?.bytes ?: modelBytes,
                etaSeconds = null,
            )
        }
        "failed" -> copy(jobID = job.jobID, updatedAtMs = nowMs, phase = Phase.FAILED, finishedAtMs = nowMs,
            message = job.error?.message ?: job.message ?: "Your Mac couldn't build this model.")
        else -> copy(jobID = job.jobID, updatedAtMs = nowMs)
    }

    /** Folds GET /v1/uploads/{id}. */
    fun applying(upload: ReconUpload, nowMs: Long = System.currentTimeMillis()): RemoteBuild {
        var b = copy(uploadID = upload.uploadID, totalBytes = upload.totalBytes, chunkSize = upload.chunkSize,
            chunkCount = upload.chunkCount, receivedChunks = upload.receivedChunks.sorted(), updatedAtMs = nowMs)
        val jid = upload.jobID
        if (jid != null) {
            b = b.copy(jobID = jid)
            if (b.phase == Phase.UPLOADING || b.phase == Phase.WAITING_FOR_MAC || b.phase == Phase.PREPARING) {
                b = b.copy(phase = Phase.QUEUED, phaseProgress = 0.0)
            }
        }
        return b
    }

    fun markingChunkReceived(receipt: ReconChunkReceipt, nowMs: Long = System.currentTimeMillis()): RemoteBuild {
        var b = copy(receivedChunks = (receivedChunks.toSet() + receipt.receivedChunks + receipt.index).sorted(), updatedAtMs = nowMs)
        if (b.missingChunks.isEmpty() && (b.phase == Phase.UPLOADING || b.phase == Phase.WAITING_FOR_MAC)) {
            b = b.copy(phase = Phase.QUEUED, phaseProgress = 0.0)
        }
        return b
    }

    companion object {
        const val MODEL_FILE = "model.glb"
        private fun clamp(x: Double) = if (x.isFinite()) x.coerceIn(0.0, 1.0) else 0.0
    }
}
