package com.moltstrong.asbuilt.core.coach

import kotlin.math.cos
import kotlin.math.sin

/**
 * Synthetic coach sessions (iOS CoachDemo equivalent) for emulator screenshots and tests: frames run
 * through the real [CaptureCoach] and [ShotPlanner], so the HUD shows exactly what the coach produces.
 */
object CoachDemo {
    enum class Scenario(val key: String) { MID_SCAN("coach"), TOO_FAST("coach-fast"), TOO_FAR("coach-far"), GRADE("coach-grade") }

    data class Result(val output: CoachOutput, val report: CoachReport?, val photos: Int, val pose: Pose4)

    val target = Vec3(0f, 0.17f, -0.07f)

    fun orbitPose(azimuthDeg: Float, elevationDeg: Float, distance: Float): Pose4 {
        val az = Math.toRadians(azimuthDeg.toDouble())
        val el = Math.toRadians(elevationDeg.toDouble())
        val eye = Vec3(
            target.x + (distance * cos(el) * sin(az)).toFloat(),
            target.y + (distance * sin(el)).toFloat(),
            target.z + (distance * cos(el) * cos(az)).toFloat(),
        )
        return Pose4.lookAt(eye, target)
    }

    fun run(scenario: Scenario): Result {
        val coach = CaptureCoach()
        val planner = ShotPlanner()
        val fps = 30.0
        var t = 0.0
        var last: CoachOutput? = null
        var pose = orbitPose(0f, 0f, 0.45f)

        fun step(az: Float, el: Float, dist: Float, light: Float = 900f, sharp: Float = 300f) {
            pose = orbitPose(az, el, dist)
            val out = coach.update(CoachFrame(t, pose, light, dist, 0.8f, CoachTracking.NORMAL, 300, sharp))
            if (planner.decide(t, pose, out, sharp, coach.thresholds.minSharpness, coach.centroid) == ShotPlanner.Decision.SHOOT) {
                planner.record(t, pose, out.coverage.currentBand, coach.centroid)
            }
            last = out
            t += 1 / fps
        }

        fun sweep(start: Float, degrees: Float, el: Float, dps: Float, dist: Float = 0.45f): Float {
            val frames = (degrees / dps * fps).toInt()
            var az = start
            repeat(frames) {
                az = start + degrees * it / frames
                step(az, el, dist)
            }
            return start + degrees
        }

        repeat(30) { step(0f, 0f, 0.45f) }
        coach.beginScanning()
        when (scenario) {
            Scenario.MID_SCAN -> {
                var az = sweep(0f, 360f, 25f, 20f) // middle band
                az = sweep(az, 180f, 2f, 20f) // half the low band
                repeat(10) { step(az, 2f, 0.45f) }
            }
            Scenario.TOO_FAST -> {
                val az = sweep(0f, 120f, 25f, 20f)
                sweep(az, 120f, 25f, 90f)
            }
            Scenario.TOO_FAR -> {
                val az = sweep(0f, 90f, 25f, 20f)
                repeat(45) { step(az, 25f, 1.45f) }
            }
            Scenario.GRADE -> {
                var az = sweep(0f, 360f, 25f, 20f)
                az = sweep(az, 360f, 2f, 20f)
                sweep(az, 270f, 55f, 20f) // top band with a gap at the back
                coach.endScanning()
            }
        }
        val report = if (scenario == Scenario.GRADE) coach.report(planner.count) else null
        return Result(last!!, report, planner.count, pose)
    }
}
