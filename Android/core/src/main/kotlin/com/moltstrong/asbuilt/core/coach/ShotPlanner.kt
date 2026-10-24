package com.moltstrong.asbuilt.core.coach

import kotlin.math.acos
import kotlin.math.max

/**
 * Laplacian-variance sharpness on a luminance plane (the ARCore CPU image's Y plane works directly).
 * Downsamples by [step] for speed; returns the variance of the 4-neighbour Laplacian. A sharp, textured
 * object at 640x480 scores in the hundreds; motion blur drops it below ~50.
 */
object Sharpness {
    fun laplacianVariance(y: ByteArray, width: Int, height: Int, rowStride: Int = width, pixelStride: Int = 1, step: Int = 2): Float {
        if (width < 3 * step || height < 3 * step) return 0f
        var sum = 0.0
        var sumSq = 0.0
        var n = 0
        fun px(x: Int, yy: Int) = (y[yy * rowStride + x * pixelStride].toInt() and 0xff)
        // Central 80 % of the frame (where the object is).
        val x0 = max(step, width / 10)
        val x1 = width - max(step, width / 10)
        val y0 = max(step, height / 10)
        val y1 = height - max(step, height / 10)
        var yy = y0
        while (yy < y1) {
            var x = x0
            while (x < x1) {
                val c = px(x, yy)
                val lap = px(x - step, yy) + px(x + step, yy) + px(x, yy - step) + px(x, yy + step) - 4 * c
                sum += lap
                sumSq += lap.toDouble() * lap
                n++
                x += step
            }
            yy += step
        }
        if (n == 0) return 0f
        val mean = sum / n
        return (sumSq / n - mean * mean).toFloat()
    }
}

/**
 * Auto-shutter: decides when the current frame should become a photo. A shot is taken when the coach
 * says technique is good (in range, slow enough, tracked), the preview is sharp, and the camera has
 * moved to a new viewpoint: at least [minAngleDeg] around the object from every earlier shot in the same
 * height band, or [minTranslation] metres from the last shot while still looking at a new angle.
 * [minIntervalS] spaces shots so the camera isn't saturated. Targets 80-200 photos for an orbit of 3 bands.
 */
class ShotPlanner(
    val minAngleDeg: Float = 8f,
    val minTranslation: Float = 0.12f,
    val minIntervalS: Double = 0.4,
    val maxShots: Int = 200,
    val targetShots: Int = 120,
    val minShots: Int = 80,
) {
    data class Shot(val time: Double, val position: Vec3, val viewDir: Vec3, val band: CoachBand?)

    private val shots = ArrayList<Shot>()
    val count: Int get() = shots.size
    val isFull: Boolean get() = shots.size >= maxShots

    enum class Decision { SHOOT, WAIT_TECHNIQUE, WAIT_SHARPNESS, WAIT_MOVE, WAIT_INTERVAL, FULL }

    /**
     * [centroid]: the object's centre from the coach (null early on: then translation-only spacing).
     */
    fun decide(time: Double, pose: Pose4, output: CoachOutput, sharpness: Float?, minSharpness: Float, centroid: Vec3?): Decision {
        if (isFull) return Decision.FULL
        if (!output.shouldIntegrate) return Decision.WAIT_TECHNIQUE
        if (sharpness != null && sharpness < minSharpness) return Decision.WAIT_SHARPNESS
        val last = shots.lastOrNull()
        if (last != null && time - last.time < minIntervalS) return Decision.WAIT_INTERVAL
        if (last == null) return Decision.SHOOT
        val pos = pose.translation()
        val dir = viewDirection(pose, centroid)
        val band = output.coverage.currentBand
        // Nearest earlier shot by viewing angle (around the object), any band.
        var minAngle = 180f
        for (s in shots) {
            val a = angleDeg(dir, s.viewDir)
            if (a < minAngle) minAngle = a
        }
        if (minAngle >= minAngleDeg) return Decision.SHOOT
        // Same angle but a clearly different distance/height (e.g. a closer detail pass) also counts.
        if (pos.distance(last.position) >= minTranslation && minAngle >= minAngleDeg / 2 && band != last.band) return Decision.SHOOT
        return Decision.WAIT_MOVE
    }

    fun record(time: Double, pose: Pose4, band: CoachBand?, centroid: Vec3?) {
        shots.add(Shot(time, pose.translation(), viewDirection(pose, centroid), band))
    }

    fun reset() = shots.clear()

    private fun viewDirection(pose: Pose4, centroid: Vec3?): Vec3 =
        if (centroid != null) (pose.translation() - centroid).normalized() else (-pose.forward()).normalized()

    private fun angleDeg(a: Vec3, b: Vec3): Float {
        val d = (a.x * b.x + a.y * b.y + a.z * b.z).coerceIn(-1f, 1f)
        return Math.toDegrees(acos(d).toDouble()).toFloat()
    }
}
