package com.moltstrong.asbuilt.core.capture

import com.moltstrong.asbuilt.core.recon.ReconJson
import com.moltstrong.asbuilt.core.zip.StoreZipWriter
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import java.io.File

/**
 * poses.json: per-photo ARCore camera pose + intrinsics (metric scale for later use: scale bars,
 * pose priors). The Mac's Object Capture ignores it today; it travels in the same zip.
 *
 * Conventions: `cameraToWorld` is ARCore's camera pose (`Frame.camera.pose`, OpenGL camera: X right,
 * Y up, looking down -Z) as a column-major 4x4 in metres. `intrinsics` are for the saved JPEG's pixel
 * grid (scaled from the CPU image intrinsics when the JPEG has a different resolution), in its
 * stored orientation (sensor landscape; `exifOrientation` tells viewers how to rotate it).
 */
@Serializable
data class PosesFile(
    val format: String = "asbuilt-android-poses",
    val version: Int = 1,
    val captureID: String,
    val title: String? = null,
    val device: String? = null,
    val arcoreVersion: String? = null,
    val coordinateSystem: String = "ARCore world: metres, Y up, gravity-aligned; camera looks down -Z (OpenGL)",
    val depthSupported: Boolean = false,
    val photos: List<PhotoPose> = emptyList(),
)

@Serializable
data class PhotoPose(
    val file: String,
    val timestampNs: Long,
    /** Column-major 4x4. */
    val cameraToWorld: List<Float>,
    val intrinsics: Intrinsics,
    val imageWidth: Int,
    val imageHeight: Int,
    val exifOrientation: Int = 1,
    val trackingState: String = "TRACKING",
    /** Metres to what the reticle was on (depth / hit test), if known. */
    val centerDepth: Float? = null,
    val sharpness: Float? = null,
    val band: String? = null,
    val source: String = "arcore-cpu-image",
)

@Serializable
data class Intrinsics(val fx: Float, val fy: Float, val cx: Float, val cy: Float, val width: Int, val height: Int) {
    /** Intrinsics for the same camera sampled at a different resolution (same aspect / field of view). */
    fun scaledTo(w: Int, h: Int): Intrinsics {
        val sx = w.toFloat() / width
        val sy = h.toFloat() / height
        return Intrinsics(fx * sx, fy * sy, cx * sx, cy * sy, w, h)
    }
}

/**
 * Packs a capture folder into the upload zip, matching what recon_server.py / ReconKit expect:
 * a STORE zip with `Images/IMG_0001.jpg …` (the folder with the most images is used) plus
 * `poses.json` and `coach-report.txt` at the root (ignored by the builder).
 */
object PhotoZip {
    fun imageFiles(imagesDir: File): List<File> =
        (imagesDir.listFiles() ?: emptyArray()).filter { it.isFile && it.length() > 0 && it.extension.lowercase() in setOf("jpg", "jpeg") }
            .sortedBy { it.name }

    fun write(imagesDir: File, poses: PosesFile?, extraText: Map<String, String>, dest: File, onProgress: (Double) -> Unit = {}): File {
        val images = imageFiles(imagesDir)
        if (images.isEmpty()) throw IllegalStateException("No photos in this capture.")
        val total = images.sumOf { it.length() }.coerceAtLeast(1)
        var done = 0L
        dest.parentFile?.mkdirs()
        StoreZipWriter(dest).use { zip ->
            for (f in images) {
                zip.addFile("Images/${f.name}", f)
                done += f.length()
                onProgress(done.toDouble() / total)
            }
            if (poses != null) zip.addBytes("poses.json", ReconJson.encodeToString(poses).toByteArray())
            for ((name, text) in extraText) zip.addBytes(name, text.toByteArray())
        }
        return dest
    }
}
