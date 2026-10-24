package com.moltstrong.asbuilt.core.cli

import com.moltstrong.asbuilt.core.capture.Intrinsics
import com.moltstrong.asbuilt.core.capture.PhotoPose
import com.moltstrong.asbuilt.core.capture.PosesFile
import com.moltstrong.asbuilt.core.recon.FolderBuildHost
import com.moltstrong.asbuilt.core.recon.ReconConfig
import com.moltstrong.asbuilt.core.recon.ReconClient
import com.moltstrong.asbuilt.core.recon.ReconJson
import com.moltstrong.asbuilt.core.recon.RemoteBuild
import com.moltstrong.asbuilt.core.recon.RemoteBuildRunner
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import java.io.File
import java.time.Instant
import java.util.UUID
import kotlin.system.exitProcess

/**
 * Real end-to-end with the exact Android upload/poll/download code ([RemoteBuildRunner]) on the JVM:
 *   E2eMain <photos dir> <out dir>
 * Reads RECON_BASE_URL / RECON_DISCOVERY_URL / RECON_API_KEY from the environment (never printed).
 * Copies the JPEGs into a capture folder exactly like the app stores them (Images/IMG_0001.jpg + a
 * synthetic poses.json), then packs, uploads (8 MiB chunks, 3 in flight), polls and downloads model.glb.
 */
fun main(args: Array<String>) {
    val photos = File(args.getOrNull(0)?.takeIf { it.isNotBlank() } ?: run { System.err.println("usage: E2eMain <photos> <out>"); exitProcess(2) })
    val out = File(args.getOrNull(1) ?: "build/e2e")
    val config = ReconConfig(System.getenv("RECON_BASE_URL"), System.getenv("RECON_DISCOVERY_URL"), System.getenv("RECON_API_KEY") ?: "")
    val t0 = System.currentTimeMillis()
    fun log(m: String) = println("[%7.1fs] %s".format((System.currentTimeMillis() - t0) / 1000.0, m))
    log("config: $config")
    if (!config.isUsable) {
        System.err.println("RECON_API_KEY and RECON_BASE_URL or RECON_DISCOVERY_URL are required")
        exitProcess(2)
    }
    val jpgs = (photos.listFiles() ?: emptyArray()).filter { it.extension.lowercase() in setOf("jpg", "jpeg") }.sortedBy { it.name }
    if (jpgs.isEmpty()) {
        System.err.println("no JPEGs in $photos"); exitProcess(2)
    }
    val captureID = "android-e2e-" + UUID.randomUUID().toString().take(8)
    val dir = File(out, captureID)
    val images = File(dir, "Images").apply { mkdirs() }
    val poses = jpgs.mapIndexed { i, f ->
        val name = "IMG_%04d.jpg".format(i + 1)
        f.copyTo(File(images, name), overwrite = true)
        PhotoPose(name, i * 1_000_000_000L, List(16) { if (it % 5 == 0) 1f else 0f }, Intrinsics(0f, 0f, 0f, 0f, 0, 0), 0, 0,
            source = "e2e-test-photo (no ARCore pose)")
    }
    File(dir, "poses.json").writeText(ReconJson.encodeToString(PosesFile(captureID = captureID, title = "Android e2e", device = "jvm", photos = poses)))
    val host = FolderBuildHost(dir, captureID, "Android e2e (JVM)")
    host.save(RemoteBuild(phase = RemoteBuild.Phase.PREPARING, photoCount = jpgs.size, startedAtMs = t0))
    log("capture $captureID: ${jpgs.size} photos, ${jpgs.sumOf { it.length() }} bytes")

    var lastLine = ""
    val progressHost = object : com.moltstrong.asbuilt.core.recon.BuildHost by host {
        override fun save(build: RemoteBuild) {
            host.save(build)
            val line = "${build.phase} step=${build.step} ${(build.overallFraction * 100).toInt()}% ${build.headline} — ${build.detailLine}"
            if (line != lastLine && (build.phase != RemoteBuild.Phase.UPLOADING || build.inFlightBytes == 0L)) {
                log(line); lastLine = line
            }
        }
    }
    val client = ReconClient(config, userAgent = "AsBuilt-Android-e2e")
    val runner = RemoteBuildRunner(client, progressHost, log = { log(it) }, appBuild = "e2e", device = "jvm",
        appState = { "cli" }, deleteJobAfterDownload = true)
    val final = runBlocking { runner.run() }
    val model = host.modelFile
    val summary = mapOf(
        "result" to (if (final?.phase == RemoteBuild.Phase.DONE && model.isFile) "PASS" else "FAIL"),
        "phase" to final?.phase?.name,
        "message" to final?.message,
        "photos" to jpgs.size.toString(),
        "uploadBytes" to final?.totalBytes?.toString(),
        "chunks" to final?.chunkCount?.toString(),
        "polygons" to final?.polygons?.toString(),
        "textureSize" to final?.textureSize?.toString(),
        "textureCount" to final?.textureCount?.toString(),
        "buildSeconds" to final?.buildSeconds?.toString(),
        "glbBytes" to model.takeIf { it.isFile }?.length()?.toString(),
        "totalSeconds" to ((System.currentTimeMillis() - t0) / 1000.0).toString(),
        "finishedAt" to Instant.now().toString(),
    )
    File(dir, "e2e-summary.json").writeText(ReconJson.encodeToString(summary))
    log("SUMMARY $summary")
    log("model: ${model.path}")
    exitProcess(if (summary["result"] == "PASS") 0 else 1)
}
