package com.moltstrong.asbuilt.android.ui

import com.moltstrong.asbuilt.core.recon.RemoteBuild

/** Fixed RemoteBuild states for the screenshot demo (one per progress-card state). */
object DemoBuilds {
    private const val MB = 1_000_000L
    private val now = 1_790_000_000_000L

    val preparing = RemoteBuild(phase = RemoteBuild.Phase.PREPARING, phaseProgress = 0.62, photoCount = 142, startedAtMs = now)
    val uploading = RemoteBuild(
        phase = RemoteBuild.Phase.UPLOADING, uploadID = "up_demo", totalBytes = 612 * MB, chunkSize = 8 * 1024 * 1024, chunkCount = 73,
        receivedChunks = (0 until 31).toList(), photoCount = 142, startedAtMs = now,
    )
    val queued = RemoteBuild(phase = RemoteBuild.Phase.QUEUED, uploadID = "up_demo", jobID = "job_demo", totalBytes = 612 * MB, queuePosition = 2,
        photoCount = 142, startedAtMs = now)
    val building = RemoteBuild(
        phase = RemoteBuild.Phase.BUILDING, jobID = "job_demo", totalBytes = 612 * MB, phaseProgress = 0.47, stage = "textureMapping",
        etaSeconds = 140, photoCount = 142, startedAtMs = now,
    )
    val downloading = RemoteBuild(phase = RemoteBuild.Phase.DOWNLOADING, jobID = "job_demo", phaseProgress = 0.71, modelBytes = 32 * MB,
        photoCount = 142, startedAtMs = now)
    val waiting = RemoteBuild(phase = RemoteBuild.Phase.WAITING_FOR_MAC, uploadID = "up_demo", totalBytes = 612 * MB, chunkCount = 73,
        receivedChunks = (0 until 50).toList(), photoCount = 142, startedAtMs = now,
        message = "Your Mac isn't reachable right now. AsBuilt keeps trying and resumes where it stopped.")
    val failed = RemoteBuild(phase = RemoteBuild.Phase.FAILED, jobID = "job_demo", photoCount = 142, startedAtMs = now,
        message = "Your Mac couldn't build this one: too few photos overlap. Scan again with slower, overlapping passes.")
    val done = RemoteBuild(phase = RemoteBuild.Phase.DONE, jobID = "job_demo", polygons = 249_999, textureSize = 8192, textureCount = 2,
        modelBytes = 32 * MB, buildSeconds = 471.0, photoCount = 142, startedAtMs = now, finishedAtMs = now + 500_000)

    val all: List<Pair<String, RemoteBuild>> = listOf(
        "Packing" to preparing, "Sending" to uploading, "Queued" to queued, "Building" to building,
        "Downloading" to downloading, "Waiting for Mac" to waiting, "Failed" to failed, "Done" to done,
    )
}
