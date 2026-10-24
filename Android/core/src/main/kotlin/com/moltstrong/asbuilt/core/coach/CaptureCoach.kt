package com.moltstrong.asbuilt.core.coach

import kotlin.math.abs
import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.exp
import kotlin.math.sqrt

/**
 * Column-major 4x4 camera-to-world pose (ARCore `Pose.toMatrix` layout; same as simd_float4x4 columns).
 * Camera looks down -Z, Y up.
 */
class Pose4(val m: FloatArray) {
    init {
        require(m.size == 16)
    }

    val tx get() = m[12]
    val ty get() = m[13]
    val tz get() = m[14]
    fun translation() = Vec3(m[12], m[13], m[14])
    fun forward() = Vec3(-m[8], -m[9], -m[10])

    companion object {
        /** Camera at [eye] looking at [target] (world up +Y). */
        fun lookAt(eye: Vec3, target: Vec3): Pose4 {
            val f = (target - eye).normalized() // forward
            var r = f.cross(Vec3(0f, 1f, 0f))
            if (r.length() < 1e-5f) r = Vec3(1f, 0f, 0f)
            r = r.normalized()
            val u = r.cross(f)
            val z = -f
            return Pose4(floatArrayOf(r.x, r.y, r.z, 0f, u.x, u.y, u.z, 0f, z.x, z.y, z.z, 0f, eye.x, eye.y, eye.z, 1f))
        }

        /** Rotation angle (radians, 0..pi) between the rotation parts of two poses (via the relative quaternion). */
        fun rotationAngle(a: Pose4, b: Pose4): Float {
            // R = Ra^T * Rb
            val r = Array(3) { FloatArray(3) }
            for (i in 0 until 3) for (j in 0 until 3) {
                var s = 0f
                for (k in 0 until 3) s += a.m[i * 4 + k] * b.m[j * 4 + k] // (Ra^T)[i][k] = Ra[k][i] = a.m[i*4+k]
                r[i][j] = s
            }
            val trace = r[0][0] + r[1][1] + r[2][2]
            val w = sqrt(maxOf(0f, 1f + trace)) / 2f
            val x = sqrt(maxOf(0f, 1f + r[0][0] - r[1][1] - r[2][2])) / 2f
            val y = sqrt(maxOf(0f, 1f - r[0][0] + r[1][1] - r[2][2])) / 2f
            val z = sqrt(maxOf(0f, 1f - r[0][0] - r[1][1] + r[2][2])) / 2f
            val imag = sqrt(x * x + y * y + z * z)
            return 2f * atan2(imag, abs(w))
        }
    }
}

data class Vec3(val x: Float, val y: Float, val z: Float) {
    operator fun plus(o: Vec3) = Vec3(x + o.x, y + o.y, z + o.z)
    operator fun minus(o: Vec3) = Vec3(x - o.x, y - o.y, z - o.z)
    operator fun times(s: Float) = Vec3(x * s, y * s, z * s)
    operator fun unaryMinus() = Vec3(-x, -y, -z)
    fun length() = sqrt(x * x + y * y + z * z)
    fun normalized(): Vec3 = length().let { if (it < 1e-9f) this else Vec3(x / it, y / it, z / it) }
    fun cross(o: Vec3) = Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    fun distance(o: Vec3) = (this - o).length()
}

enum class CoachTracking { NORMAL, INITIALIZING, EXCESSIVE_MOTION, INSUFFICIENT_FEATURES, RELOCALIZING, NOT_AVAILABLE }

enum class CoachBand(val label: String) { LOW("Low"), MID("Middle"), HIGH("High") }

enum class CoachIssue(val gates: Boolean) {
    TRACKING(true), TOO_DARK(true), TOO_FAST(true), TOO_FAR(true), TOO_CLOSE(true), LOW_TEXTURE(false), BLURRY(true)
}

data class CoachFrame(
    val timestamp: Double,
    val cameraToWorld: Pose4? = null,
    /** iOS-ARKit-like lux scale (~1000 = normal room). ARCore pixelIntensity * 2000. */
    val ambientIntensity: Float? = null,
    /** Metres to what the reticle is on (Depth API / hit test); 0 = nothing found. */
    val centerDepth: Float? = null,
    val highConfidenceFraction: Float? = null,
    val tracking: CoachTracking = CoachTracking.NORMAL,
    val featureCount: Int? = null,
    /** Laplacian variance of the latest preview (sharpness), null = unknown. */
    val sharpness: Float? = null,
)

data class CoachThresholds(
    val minDistance: Float = 0.25f,
    val maxDistance: Float = 1.0f,
    val maxLinearSpeed: Float = 0.25f,
    val maxAngularSpeed: Float = 30f,
    val darkIntensity: Float = 250f,
    val brightIntensity: Float = 400f,
    val lowConfidenceFraction: Float = 0.35f,
    val lowFeatureCount: Int = 40,
    val lowTextureSeconds: Double = 2.5,
    /** Laplacian variance below which a frame is too blurry for a photo. */
    val minSharpness: Float = 60f,
    val framesPerCell: Int = 10,
    val bandEdgeLow: Float = 12f,
    val bandEdgeHigh: Float = 40f,
    val sectorsPerBand: Int = 10,
    val finishFraction: Float = 0.9f,
    val hysteresis: Float = 0.15f,
) {
    companion object {
        /** Close-range object photos (the iOS `.detail` preset). */
        val OBJECT = CoachThresholds()
    }
}

sealed class Guidance(val isProblem: Boolean) {
    data object GettingReady : Guidance(false)
    data object TrackingLost : Guidance(true)
    data object TooDark : Guidance(true)
    data object TooFast : Guidance(true)
    data object TooFar : Guidance(true)
    data object TooClose : Guidance(true)
    data object Blurry : Guidance(true)
    data object LowTexture : Guidance(false)
    data class NextBand(val band: CoachBand, val lower: Boolean) : Guidance(false)
    data object Complete : Guidance(false)
    data object Good : Guidance(false)

    /** At most three words. */
    val label: String
        get() = when (this) {
            GettingReady -> "Getting ready"
            TrackingLost -> "Aim back"
            TooDark -> "More light"
            TooFast -> "Slow down"
            TooFar -> "Closer"
            TooClose -> "Back up"
            Blurry -> "Hold steady"
            LowTexture -> "Shiny or plain"
            is NextBand -> if (lower) "Now lower" else "Now higher"
            Complete -> "Looks complete"
            Good -> "Good"
        }

    companion object {
        fun of(issue: CoachIssue, tracking: CoachTracking): Guidance = when (issue) {
            CoachIssue.TRACKING -> when (tracking) {
                CoachTracking.INITIALIZING -> GettingReady
                CoachTracking.EXCESSIVE_MOTION -> TooFast
                else -> TrackingLost
            }
            CoachIssue.TOO_DARK -> TooDark
            CoachIssue.TOO_FAST -> TooFast
            CoachIssue.TOO_FAR -> TooFar
            CoachIssue.TOO_CLOSE -> TooClose
            CoachIssue.BLURRY -> Blurry
            CoachIssue.LOW_TEXTURE -> LowTexture
        }
    }
}

enum class CoachHaptic { NONE, TICK, WARNING, SUCCESS, COMPLETE, READY }

enum class DistanceZone { UNKNOWN, TOO_CLOSE, GOOD, TOO_FAR }

data class CoverageSnapshot(
    /** [band][sector] fill 0..1 (band 0 = low). */
    val fill: List<List<Float>>,
    val currentBand: CoachBand?,
    val currentSector: Int?,
    val targetBand: CoachBand?,
    val bandsComplete: List<Boolean>,
    val fraction: Float,
) {
    companion object {
        const val SECTORS = 12
        val EMPTY = CoverageSnapshot(List(3) { List(12) { 0f } }, null, null, null, listOf(false, false, false), 0f)
    }
}

data class CoachOutput(
    val guidance: Guidance,
    val shouldIntegrate: Boolean,
    val quality: Float,
    val haptic: CoachHaptic,
    val linearSpeed: Float,
    val angularSpeed: Float,
    /** max(linear/max, angular/max): > 1 is too fast. */
    val speedFraction: Float,
    val distance: Float?,
    val distanceZone: DistanceZone,
    val coverage: CoverageSnapshot,
    val showSurfaceTip: Boolean,
    val isReady: Boolean,
    val suggestFinish: Boolean,
)

data class CoachReport(
    val grade: Grade,
    val score: Float,
    val fix: String?,
    val coverageFraction: Float,
    val goodFraction: Float,
    val tooFastFraction: Float,
    val tooDarkFraction: Float,
    val distanceFraction: Float,
    val lowTextureFraction: Float,
    val blurryFraction: Float,
    val seconds: Double,
    val photoCount: Int = 0,
) {
    enum class Grade { A, B, C, D, F }

    fun text(title: String, thresholds: CoachThresholds): String {
        fun pct(f: Float) = "${(f * 100).toInt()}%"
        return listOf(
            "AsBuilt Capture Coach report (Android)",
            "Scan: $title",
            "Grade: $grade  (score ${"%.2f".format(java.util.Locale.US, score)})",
            "Fix next time: ${fix ?: "nothing, clean scan"}",
            "",
            "Photos: $photoCount",
            "Coverage: ${pct(coverageFraction)} of 36 cells (12 directions x 3 heights)",
            "Good technique: ${pct(goodFraction)} of ${seconds.toInt()} s tracked",
            "Too fast: ${pct(tooFastFraction)}",
            "Too dark: ${pct(tooDarkFraction)}",
            "Out of range: ${pct(distanceFraction)}",
            "Blurry: ${pct(blurryFraction)}",
            "Shiny/plain surface: ${pct(lowTextureFraction)}",
            "",
            "Sweet spot: ${"%.2f".format(java.util.Locale.US, thresholds.minDistance)}-${"%.2f".format(java.util.Locale.US, thresholds.maxDistance)} m",
            "Speed limit: ${"%.2f".format(java.util.Locale.US, thresholds.maxLinearSpeed)} m/s, ${thresholds.maxAngularSpeed.toInt()} deg/s",
        ).joinToString("\n") + "\n"
    }
}

/**
 * Kotlin port of AsBuiltCore's CaptureCoach (`.detail` mode) for object photo capture: one glanceable
 * cue with strict priority (tracking > dark > fast > distance > blur > texture > coverage), value and
 * time hysteresis so cues never flicker, a 12x3 coverage ring around the object's centroid with height
 * bands and pass detection, Geiger-counter haptics and an A-F grade with the single most useful fix.
 */
class CaptureCoach(val thresholds: CoachThresholds = CoachThresholds.OBJECT) {
    var enterSeconds = 0.25
    var exitSeconds = 0.45
    var minDisplaySeconds = 0.8
    var speedTimeConstant = 0.25
    var passStallSeconds = 5.0
    var warningCooldown = 2.0

    var isScanning = false
        private set

    private var lastPose: Pose4? = null
    private var lastTime: Double? = null
    private var linearEMA = 0f
    private var angularEMA = 0f
    private var speedSamples = 0

    private class Latch(var active: Boolean = false, var conditionSince: Double? = null, var clearSince: Double? = null)

    private val latches = HashMap<CoachIssue, Latch>()
    private var lowTextureSince: Double? = null

    private var displayed: Guidance = Guidance.GettingReady
    private var displayedSince = -1e18
    private var lastWarning = -1e18
    private var lastTick = -1e18
    private var wasGated = false
    private var surfaceTipShownAt: Double? = null
    private var readySince: Double? = null
    private var announcedReady = false

    private val counts = Array(3) { IntArray(12) }
    var centroid: Vec3? = null
        private set
    private var centroidSamples = 0
    private var currentBand: CoachBand? = null
    private var currentSector: Int? = null
    private var targetBand: CoachBand? = null
    private val bandDone = BooleanArray(3)
    private val passDone = BooleanArray(3)
    private var lastNewCellTime: Double? = null
    private var finishAnnounced = false
    private var finishDismissed = false

    private var trackedSeconds = 0.0
    private var goodSeconds = 0.0
    private val issueSeconds = HashMap<CoachIssue, Double>()
    private var lastStatTime: Double? = null

    fun beginScanning() {
        isScanning = true
        lastStatTime = null
    }

    fun endScanning() {
        isScanning = false
    }

    fun dismissFinish() {
        finishDismissed = true
    }

    fun resumeForGaps() {
        isScanning = true
        finishAnnounced = false
        finishDismissed = false
        lastStatTime = null
        targetBand = firstIncompleteBand(currentBand)
    }

    fun update(frame: CoachFrame): CoachOutput {
        val t = frame.timestamp
        val th = thresholds

        // 1. Speeds (EMA).
        val pose = frame.cameraToWorld
        val lp = lastPose
        val lt = lastTime
        if (pose != null && lp != null && lt != null && t > lt) {
            val dt = t - lt
            if (dt < 1) {
                val lin = lp.translation().distance(pose.translation()) / dt.toFloat()
                val ang = Math.toDegrees(Pose4.rotationAngle(lp, pose).toDouble()).toFloat() / dt.toFloat()
                val alpha = (1 - exp(-dt / speedTimeConstant)).toFloat()
                if (speedSamples == 0) {
                    linearEMA = lin; angularEMA = ang
                } else {
                    linearEMA += alpha * (lin - linearEMA)
                    angularEMA += alpha * (ang - angularEMA)
                }
                speedSamples++
            }
        }
        if (pose != null) {
            lastPose = pose; lastTime = t
        }
        val speedFraction = maxOf(linearEMA / th.maxLinearSpeed, angularEMA / th.maxAngularSpeed)

        // 2. Raw conditions with value hysteresis.
        val h = th.hysteresis
        fun cond(issue: CoachIssue): Boolean {
            val active = latches[issue]?.active ?: false
            return when (issue) {
                CoachIssue.TRACKING -> frame.tracking != CoachTracking.NORMAL
                CoachIssue.TOO_DARK -> frame.ambientIntensity?.let { if (active) it < th.brightIntensity else it < th.darkIntensity } ?: false
                CoachIssue.TOO_FAST -> if (speedSamples == 0) false else if (active) speedFraction > 1 - h else speedFraction > 1
                CoachIssue.TOO_FAR -> {
                    val d = frame.centerDepth
                    if (d == null) false else if (d <= 0f) true else if (active) d > th.maxDistance * (1 - h) else d > th.maxDistance
                }
                CoachIssue.TOO_CLOSE -> {
                    val d = frame.centerDepth
                    if (d == null || d <= 0f) false else if (active) d < th.minDistance * (1 + h) else d < th.minDistance
                }
                CoachIssue.BLURRY -> frame.sharpness?.let { if (active) it < th.minSharpness * (1 + h) else it < th.minSharpness } ?: false
                CoachIssue.LOW_TEXTURE -> {
                    val lowConf = frame.highConfidenceFraction?.let { it < th.lowConfidenceFraction } ?: false
                    val lowFeat = frame.featureCount?.let { it < th.lowFeatureCount } ?: false
                    val low = lowConf || lowFeat
                    if (low) {
                        if (lowTextureSince == null) lowTextureSince = t
                    } else lowTextureSince = null
                    low && t - (lowTextureSince ?: t) >= th.lowTextureSeconds
                }
            }
        }

        // 3. Time hysteresis.
        val active = HashSet<CoachIssue>()
        for (issue in CoachIssue.entries) {
            val c = cond(issue)
            val latch = latches.getOrPut(issue) { Latch() }
            if (c) {
                latch.clearSince = null
                if (latch.conditionSince == null) latch.conditionSince = t
                val immediate = issue == CoachIssue.TRACKING || issue == CoachIssue.LOW_TEXTURE
                if (!latch.active && (immediate || t - latch.conditionSince!! >= enterSeconds)) latch.active = true
            } else {
                latch.conditionSince = null
                if (latch.active) {
                    if (latch.clearSince == null) latch.clearSince = t
                    if (t - latch.clearSince!! >= exitSeconds) latch.active = false
                }
            }
            if (latch.active) active.add(issue)
        }
        if (CoachIssue.TOO_FAR in active && CoachIssue.TOO_CLOSE in active) {
            val d = frame.centerDepth
            if (d != null && d < (th.minDistance + th.maxDistance) / 2) active.remove(CoachIssue.TOO_FAR) else active.remove(CoachIssue.TOO_CLOSE)
        }
        var showSurfaceTip = false
        if (CoachIssue.LOW_TEXTURE in active) {
            val blocked = active.any { it.gates }
            val shown = surfaceTipShownAt
            if (shown != null) {
                if (t - shown > 6) active.remove(CoachIssue.LOW_TEXTURE)
            } else if (isScanning && !blocked) {
                surfaceTipShownAt = t
                showSurfaceTip = true
            } else if (!isScanning) {
                active.remove(CoachIssue.LOW_TEXTURE)
            }
        }
        val gated = active.any { it.gates }
        val shouldIntegrate = isScanning && !gated

        // 4. Readiness.
        var haptic = CoachHaptic.NONE
        val readyNow = frame.tracking == CoachTracking.NORMAL && CoachIssue.TRACKING !in active && CoachIssue.TOO_DARK !in active
        if (readyNow) {
            if (readySince == null) readySince = t
        } else readySince = null
        val isReady = readyNow && t - (readySince ?: t) >= 0.5
        if (isReady && !announcedReady && !isScanning) {
            announcedReady = true
            haptic = CoachHaptic.READY
        }

        // 5. Distance zone and quality.
        val d = frame.centerDepth
        val zone = when {
            d != null && d > 0 -> if (CoachIssue.TOO_FAR in active) DistanceZone.TOO_FAR else if (CoachIssue.TOO_CLOSE in active) DistanceZone.TOO_CLOSE else DistanceZone.GOOD
            d != null -> DistanceZone.TOO_FAR
            else -> DistanceZone.UNKNOWN
        }
        var quality = 0f
        if (!gated && frame.tracking == CoachTracking.NORMAL) {
            val speedQ = if (speedFraction <= 0.5f) 1f else maxOf(0f, 1 - (speedFraction - 0.5f) * 2)
            var distQ = 1f
            if (d != null && d > 0) {
                val mid = (th.minDistance + th.maxDistance) / 2
                distQ = maxOf(0.4f, 1 - abs(d - mid) / (th.maxDistance - th.minDistance))
            }
            val lightQ = frame.ambientIntensity?.let { minOf(1f, maxOf(0.3f, it / (th.brightIntensity * 1.5f))) } ?: 1f
            val confQ = frame.highConfidenceFraction?.let { minOf(1f, maxOf(0.2f, it / 0.7f)) } ?: 1f
            quality = maxOf(0.05f, speedQ * distQ * lightQ * confQ)
        }

        // 6. Coverage (only good scanning frames count).
        var newCell = false
        var bandEvent = false
        if (isScanning && shouldIntegrate && pose != null) {
            val r = updateCoverage(pose, d, t)
            newCell = r.first; bandEvent = r.second
        } else if (pose != null) {
            locate(pose)
        }
        val snapshot = coverageSnapshot()
        var suggestFinish = false
        if (isScanning && snapshot.fraction >= th.finishFraction && !finishDismissed) {
            suggestFinish = true
            if (!finishAnnounced) {
                finishAnnounced = true
                if (haptic == CoachHaptic.NONE) haptic = CoachHaptic.COMPLETE
            }
        }

        // 7. Stats.
        if (isScanning) {
            val last = lastStatTime
            if (last != null && t > last && t - last < 1) {
                val dt = t - last
                if (frame.tracking == CoachTracking.NORMAL || CoachIssue.TRACKING in active) {
                    trackedSeconds += dt
                    if (!gated) goodSeconds += dt
                    active.minByOrNull { it.ordinal }?.let { issueSeconds[it] = (issueSeconds[it] ?: 0.0) + dt }
                }
            }
            lastStatTime = t
        }

        // 8. Primary guidance + display dwell.
        val primary = active.minByOrNull { it.ordinal }
        val tb = targetBand
        val cb = currentBand
        val candidate: Guidance = when {
            primary != null -> Guidance.of(primary, frame.tracking)
            !isScanning && !isReady -> Guidance.GettingReady
            suggestFinish -> Guidance.Complete
            tb != null && cb != null && tb != cb && isScanning -> Guidance.NextBand(tb, tb.ordinal < cb.ordinal)
            else -> Guidance.Good
        }
        if (candidate != displayed) {
            val urgent = candidate.isProblem && !displayed.isProblem
            if (urgent || t - displayedSince >= minDisplaySeconds) {
                displayed = candidate
                displayedSince = t
            }
        }

        // 9. Haptics.
        if (isScanning) {
            if (gated && !wasGated && active.any { it != CoachIssue.TRACKING || frame.tracking != CoachTracking.INITIALIZING }) {
                if (t - lastWarning >= warningCooldown) {
                    haptic = CoachHaptic.WARNING
                    lastWarning = t
                }
            } else if (bandEvent) {
                haptic = CoachHaptic.SUCCESS
            } else if (haptic == CoachHaptic.NONE && shouldIntegrate) {
                val rate = 2 + 6 * quality + (if (newCell) 4 else 0)
                if (t - lastTick >= 1 / rate) {
                    haptic = CoachHaptic.TICK
                    lastTick = t
                }
            }
        }
        wasGated = gated && isScanning

        return CoachOutput(displayed, shouldIntegrate, quality, haptic, linearEMA, angularEMA, speedFraction, d, zone, snapshot,
            showSurfaceTip, isReady, suggestFinish)
    }

    /** (band, sector) of a camera position around the centroid. */
    fun cell(pose: Pose4, center: Vec3? = centroid): Pair<CoachBand, Int>? {
        val c = center ?: return null
        var v = pose.translation() - c
        val len = v.length()
        if (len < 1e-4f) return null
        v = v * (1f / len)
        val elevation = Math.toDegrees(asin(v.y.coerceIn(-1f, 1f).toDouble())).toFloat()
        var azimuth = Math.toDegrees(atan2(v.x.toDouble(), v.z.toDouble())).toFloat()
        if (azimuth < 0) azimuth += 360f
        val sector = minOf(11, (azimuth / 30f).toInt())
        val band = if (elevation < thresholds.bandEdgeLow) CoachBand.LOW else if (elevation < thresholds.bandEdgeHigh) CoachBand.MID else CoachBand.HIGH
        return band to sector
    }

    private fun locate(pose: Pose4) {
        cell(pose)?.let { (b, s) -> currentBand = b; currentSector = s }
    }

    private fun updateCoverage(pose: Pose4, depth: Float?, t: Double): Pair<Boolean, Boolean> {
        val th = thresholds
        if (depth != null && depth > 0) {
            val target = pose.translation() + pose.forward() * depth
            val c = centroid
            if (c != null) {
                centroidSamples++
                val alpha = if (centroidSamples < 90) 1f / (centroidSamples + 1) else 0.005f
                centroid = c + (target - c) * alpha
            } else {
                centroid = target
                centroidSamples = 1
            }
        }
        val (band, sector) = cell(pose) ?: return false to false
        val previousBand = currentBand
        currentBand = band
        currentSector = sector
        if (lastNewCellTime == null) lastNewCellTime = t
        var newCell = false
        var event = false
        val row = counts[band.ordinal]
        if (row[sector] < th.framesPerCell) {
            row[sector]++
            if (row[sector] == th.framesPerCell) {
                newCell = true
                lastNewCellTime = t
            }
        }
        val doneSectors = row.count { it >= th.framesPerCell }
        val lastNew = lastNewCellTime
        if (!bandDone[band.ordinal] && doneSectors >= th.sectorsPerBand) {
            bandDone[band.ordinal] = true
            passDone[band.ordinal] = true
            event = true
            targetBand = firstIncompleteBand(band)
        } else if (!passDone[band.ordinal] && doneSectors >= 5 && lastNew != null && t - lastNew >= passStallSeconds) {
            passDone[band.ordinal] = true
            event = true
            targetBand = firstIncompleteBand(band)
        }
        val tb = targetBand
        if (tb != null && band == tb && previousBand != band) targetBand = null
        val tb2 = targetBand
        if (tb2 != null && passDone[tb2.ordinal]) targetBand = firstIncompleteBand(band)
        return newCell to event
    }

    private fun firstIncompleteBand(after: CoachBand?): CoachBand? {
        val order = when (after) {
            CoachBand.LOW -> listOf(CoachBand.MID, CoachBand.HIGH)
            CoachBand.MID, null -> listOf(CoachBand.LOW, CoachBand.HIGH)
            CoachBand.HIGH -> listOf(CoachBand.MID, CoachBand.LOW)
        }
        return order.firstOrNull { !passDone[it.ordinal] }
    }

    fun coverageSnapshot(): CoverageSnapshot {
        val n = maxOf(1, thresholds.framesPerCell).toFloat()
        val fill = counts.map { row -> row.map { minOf(1f, it / n) } }
        val done = counts.sumOf { row -> row.count { it >= thresholds.framesPerCell } }
        return CoverageSnapshot(fill, currentBand, currentSector, targetBand, bandDone.toList(), done / 36f)
    }

    fun report(photoCount: Int = 0): CoachReport {
        val tracked = maxOf(trackedSeconds, 1e-6)
        fun frac(vararg i: CoachIssue) = (i.sumOf { issueSeconds[it] ?: 0.0 } / tracked).toFloat()
        val fast = frac(CoachIssue.TOO_FAST)
        val dark = frac(CoachIssue.TOO_DARK)
        val dist = frac(CoachIssue.TOO_FAR, CoachIssue.TOO_CLOSE)
        val texture = frac(CoachIssue.LOW_TEXTURE)
        val blur = frac(CoachIssue.BLURRY)
        val lost = frac(CoachIssue.TRACKING)
        val good = if (trackedSeconds > 0) (goodSeconds / tracked).toFloat() else 0f
        val snapshot = coverageSnapshot()

        val full = snapshot.fraction
        val front = frontHalfFraction()
        var coverageScore = minOf(1f, full / thresholds.finishFraction)
        var frontOnly = false
        if (front >= 0.8f && full < 0.65f) {
            frontOnly = true
            coverageScore = maxOf(coverageScore, 0.85f)
        }
        val bandFill = CoachBand.entries.map { b -> counts[b.ordinal].count { it >= thresholds.framesPerCell } / 12f }
        val weakest = CoachBand.entries.minBy { bandFill[it.ordinal] }
        val coverageFix = when {
            bandFill[weakest.ordinal] < 0.4f && bandFill.max() >= 0.4f -> when (weakest) {
                CoachBand.LOW -> "Gaps low down: shoot from lower"
                CoachBand.HIGH -> "Gaps on top: shoot from higher"
                CoachBand.MID -> "Gaps at mid height"
            }
            frontOnly -> "Back side not covered (fine if wall-mounted)"
            else -> "Gaps on the back side"
        }
        val techniqueScore = if (trackedSeconds > 0) good else 0f
        var score = 0.55f * coverageScore + 0.45f * techniqueScore
        // Photo count matters for photogrammetry: under 40 photos rarely builds well.
        if (photoCount in 1 until 40) score = minOf(score, 0.5f)
        val grade = when {
            score >= 0.85f -> CoachReport.Grade.A
            score >= 0.7f -> CoachReport.Grade.B
            score >= 0.55f -> CoachReport.Grade.C
            score >= 0.4f -> CoachReport.Grade.D
            else -> CoachReport.Grade.F
        }
        val technique = listOf(
            fast to "Mostly moved too fast",
            dark to "Low light: turn on lights",
            dist to "Mostly too far: stay within 1 m",
            lost to "Tracking lost often: move slower, add light",
            blur to "Many blurry frames: hold steadier",
            texture * 0.7f to "Shiny or plain surface: matte spray helps",
        )
        val worst = technique.maxBy { it.first }
        var fix: String? = when {
            photoCount in 1 until 40 -> "Too few photos: aim for 80+"
            worst.first >= 0.3f -> worst.second
            (1 - coverageScore) * 0.55f > worst.first * 0.45f -> if (coverageScore >= 0.999f) null else coverageFix
            worst.first >= 0.05f -> worst.second
            else -> null
        }
        if (frontOnly && (fix == null || grade == CoachReport.Grade.A)) fix = coverageFix
        return CoachReport(grade, score, fix, snapshot.fraction, good, fast, dark, dist, texture, blur, trackedSeconds, photoCount)
    }

    private fun frontHalfFraction(): Float {
        var best = 0f
        for (start in 0 until 12) {
            var done = 0
            for (k in 0 until 6) for (b in 0 until 3) if (counts[b][(start + k) % 12] >= thresholds.framesPerCell) done++
            best = maxOf(best, done / 18f)
        }
        return best
    }
}
