package com.moltstrong.asbuilt.core.recon

import com.moltstrong.asbuilt.core.capture.PhotoZip
import com.moltstrong.asbuilt.core.capture.PosesFile
import kotlinx.serialization.encodeToString
import java.io.File

/**
 * A capture stored as a folder (used by the Android app's capture store and by the JVM e2e CLI):
 *   <dir>/Images/IMG_0001.jpg…, <dir>/poses.json, <dir>/coach-report.txt, <dir>/build.json, <dir>/model.glb
 * build.json is written atomically (tmp + rename) so a kill mid-write never corrupts it.
 */
class FolderBuildHost(
    val dir: File,
    override val captureID: String,
    override val title: String?,
    private val onSaved: (RemoteBuild) -> Unit = {},
) : BuildHost {
    private val buildFile = File(dir, "build.json")
    private val lock = Any()

    override fun load(): RemoteBuild? = synchronized(lock) {
        if (!dir.isDirectory) return null
        try {
            if (buildFile.isFile) ReconJson.decodeFromString<RemoteBuild>(buildFile.readText()) else null
        } catch (_: Exception) {
            null
        }
    }

    override fun save(build: RemoteBuild) {
        synchronized(lock) {
            if (!dir.isDirectory) return
            val tmp = File(dir, "build.json.tmp")
            tmp.writeText(ReconJson.encodeToString(build))
            if (!tmp.renameTo(buildFile)) {
                buildFile.delete()
                tmp.renameTo(buildFile)
            }
        }
        onSaved(build)
    }

    override val workDir: File get() = File(dir, "upload")

    val imagesDir: File get() = File(dir, "Images")

    override fun pack(into: File, onProgress: (Double) -> Unit): File {
        val poses = File(dir, "poses.json").takeIf { it.isFile }?.let {
            try {
                ReconJson.decodeFromString<PosesFile>(it.readText())
            } catch (_: Exception) {
                null
            }
        }
        val extra = buildMap {
            File(dir, "coach-report.txt").takeIf { it.isFile }?.let { put("coach-report.txt", it.readText()) }
        }
        return PhotoZip.write(imagesDir, poses, extra, File(into, "Images.zip"), onProgress)
    }

    override val modelFile: File get() = File(dir, RemoteBuild.MODEL_FILE)

    override val logFile: File get() = File(dir, "recon-log.txt")
}
