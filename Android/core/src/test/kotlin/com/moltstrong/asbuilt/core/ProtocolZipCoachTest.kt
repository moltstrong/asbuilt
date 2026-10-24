package com.moltstrong.asbuilt.core

import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import com.moltstrong.asbuilt.core.capture.Intrinsics
import com.moltstrong.asbuilt.core.capture.PhotoPose
import com.moltstrong.asbuilt.core.capture.PhotoZip
import com.moltstrong.asbuilt.core.capture.PosesFile
import com.moltstrong.asbuilt.core.coach.CaptureCoach
import com.moltstrong.asbuilt.core.coach.CoachBand
import com.moltstrong.asbuilt.core.coach.CoachDemo
import com.moltstrong.asbuilt.core.coach.CoachFrame
import com.moltstrong.asbuilt.core.coach.CoachHaptic
import com.moltstrong.asbuilt.core.coach.CoachReport
import com.moltstrong.asbuilt.core.coach.Guidance
import com.moltstrong.asbuilt.core.coach.Pose4
import com.moltstrong.asbuilt.core.coach.Sharpness
import com.moltstrong.asbuilt.core.coach.ShotPlanner
import com.moltstrong.asbuilt.core.coach.Vec3
import com.moltstrong.asbuilt.core.recon.ReconApiError
import com.moltstrong.asbuilt.core.recon.ReconDiscovery
import com.moltstrong.asbuilt.core.recon.ReconJob
import com.moltstrong.asbuilt.core.recon.ReconJson
import com.moltstrong.asbuilt.core.recon.RemoteBuild
import com.moltstrong.asbuilt.core.zip.StoreZipWriter
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import kotlin.math.abs
import kotlin.random.Random
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ProtocolZipCoachTest {
    @get:Rule
    val tmp = TemporaryFolder()

    // ---- protocol ----

    @Test
    fun apiErrorParsing_handlesJsonAndCloudflareHtml() {
        val e = ReconApiError.parse("""{"error": {"code": "upload_completed", "message": "done", "jobID": "job_9"}}""", 409)!!
        assertEquals("upload_completed", e.code)
        assertEquals("job_9", e.jobID)
        assertNull(ReconApiError.parse("<!DOCTYPE html><title>502 Bad gateway</title>", 502))
        assertNull(ReconApiError.parse("", 500))
        val r = ReconApiError.parse("""{"error": {"code": "rate_limited", "retryAfterSeconds": 30}}""")!!
        assertEquals(30, r.retryAfterSeconds)
    }

    @Test
    fun discovery_acceptsGistAndRawJson_rejectsHttpAndOtherVersions() {
        val gist = """{"files": {"asbuilt-recon.json": {"content": "{\"baseURL\": \"https://a-b.trycloudflare.com/\", \"apiVersion\": 1}"}}}"""
        assertEquals("https://a-b.trycloudflare.com", ReconDiscovery.baseUrl(gist))
        assertEquals("https://x.example", ReconDiscovery.baseUrl("""{"baseURL": "https://x.example", "apiVersion": 1}"""))
        assertNull(ReconDiscovery.baseUrl("""{"baseURL": "http://x.example"}"""))
        assertNull(ReconDiscovery.baseUrl("""{"baseURL": "https://x.example", "apiVersion": 2}"""))
        assertNull(ReconDiscovery.baseUrl("not json"))
    }

    @Test
    fun jobDecoding_toleratesUnknownFields_andProgressMapping() {
        val job = ReconJson.decodeFromString<ReconJob>(
            """{"jobID": "j", "state": "processing", "progress": 0.5, "stage": "textureMapping", "etaSeconds": 90, "newField": [1,2]}""",
        )
        var b = RemoteBuild(phase = RemoteBuild.Phase.QUEUED, totalBytes = 10).applying(job)
        assertEquals(RemoteBuild.Phase.BUILDING, b.phase)
        assertTrue(abs(b.overallFraction - (0.40 + 0.55 * 0.5)) < 1e-9)
        assertEquals("Painting 8K textures · about 2 min left", b.detailLine)
        assertEquals(2, b.step)
        // Progress never goes backwards within a build.
        b = b.applying(job.copy(progress = 0.2))
        assertEquals(0.5, b.phaseProgress)
        // Done -> downloading (the app still has to fetch the GLB).
        b = b.applying(job.copy(state = "done", polygons = 250000, textures = listOf(com.moltstrong.asbuilt.core.recon.ReconTexture("d", 8192, 8192))))
        assertEquals(RemoteBuild.Phase.DOWNLOADING, b.phase)
        assertEquals(8192, b.textureSize)
        // Old persisted JSON with missing fields still decodes.
        val old = ReconJson.decodeFromString<RemoteBuild>("""{"phase": "UPLOADING", "uploadID": "up"}""")
        assertEquals(RemoteBuild.Phase.UPLOADING, old.phase)
    }

    @Test
    fun createUpload_sendsGlbAndPhoneDefaults_textureCapOnlyWhenSet() {
        val base = com.moltstrong.asbuilt.core.recon.ReconCreateUpload(captureID = "C1", totalBytes = 10, sha256 = "a".repeat(64), chunkSize = 8 shl 20)
        val json = ReconJson.parseToJsonElement(ReconJson.encodeToString(com.moltstrong.asbuilt.core.recon.ReconCreateUpload.serializer(), base)).jsonObject
        assertEquals("phone", json["detail"]!!.jsonPrimitive.content)
        assertEquals("true", json["glb"]!!.jsonPrimitive.content)
        assertEquals("true", json["autoComplete"]!!.jsonPrimitive.content)
        assertEquals("Images.zip", json["filename"]!!.jsonPrimitive.content)
        assertTrue("glbTextureSize" !in json, "null cap must not be sent (server would reject null)")
        val capped = ReconJson.parseToJsonElement(ReconJson.encodeToString(com.moltstrong.asbuilt.core.recon.ReconCreateUpload.serializer(), base.copy(glbTextureSize = 4096))).jsonObject
        assertEquals(4096, capped["glbTextureSize"]!!.jsonPrimitive.content.toInt())
    }

    @Test
    fun uploadProgress_countsReceivedAndInFlightBytes() {
        val b = RemoteBuild(phase = RemoteBuild.Phase.UPLOADING, totalBytes = 20L * 1024 * 1024 + 5, chunkSize = 8 * 1024 * 1024,
            chunkCount = 3, receivedChunks = listOf(0, 2), inFlightBytes = 1024)
        assertEquals(8L * 1024 * 1024 + 4L * 1024 * 1024 + 5, b.uploadedBytes)
        assertEquals(listOf(1), b.missingChunks)
        assertTrue(b.detailLine.contains(" of "))
        assertEquals(1, b.step)
    }

    // ---- zip ----

    @Test
    fun storeZip_isReadableByJavaZip_andUncompressed() {
        val dir = tmp.newFolder("Images")
        val rnd = Random(3)
        val contents = (1..5).associate { "IMG_%04d.jpg".format(it) to rnd.nextBytes(10_000 + it) }
        contents.forEach { (n, b) -> File(dir, n).writeBytes(b) }
        File(dir, "notes.txt").writeText("ignored")
        val poses = PosesFile(captureID = "c", photos = listOf(
            PhotoPose("IMG_0001.jpg", 1, List(16) { 0f }, Intrinsics(1500f, 1500f, 960f, 720f, 1920, 1440), 1920, 1440),
        ))
        val zip = PhotoZip.write(dir, poses, mapOf("coach-report.txt" to "Grade: A"), File(tmp.root, "out/Images.zip"))
        ZipFile(zip).use { z ->
            val entries = z.entries().toList()
            assertEquals(contents.keys.map { "Images/$it" } + listOf("poses.json", "coach-report.txt"), entries.map { it.name })
            assertTrue(entries.all { it.method == ZipEntry.STORED })
            for ((n, b) in contents) assertTrue(z.getInputStream(z.getEntry("Images/$n")).readBytes().contentEquals(b))
            val pj = String(z.getInputStream(z.getEntry("poses.json")).readBytes())
            val back = ReconJson.decodeFromString<PosesFile>(pj)
            assertEquals(1500f, back.photos[0].intrinsics.fx)
        }
        // `unzip -t` style integrity via a second reader (ZipInputStream streams local headers).
        java.util.zip.ZipInputStream(zip.inputStream()).use { zin ->
            var n = 0
            while (zin.nextEntry != null) { zin.readBytes(); n++ }
            assertEquals(7, n)
        }
    }

    @Test
    fun storeZip_emptyArchiveIsValid() {
        val f = File(tmp.root, "e.zip")
        StoreZipWriter(f).use { }
        ZipFile(f).use { assertEquals(0, it.size()) }
    }

    @Test
    fun intrinsics_scaleWithResolution() {
        val k = Intrinsics(1000f, 1000f, 640f, 480f, 1280, 960).scaledTo(4000, 3000)
        assertEquals(3125f, k.fx)
        assertEquals(1500f, k.cy)
    }

    // ---- coach ----

    @Test
    fun rotationAngle_isPreciseForSmallRotations() {
        val a = Pose4.lookAt(Vec3(0f, 0f, 1f), Vec3(0f, 0f, 0f))
        val b = Pose4.lookAt(Vec3(0.01f, 0f, 1f), Vec3(0.01f, 0f, 0f))
        assertTrue(Pose4.rotationAngle(a, b) < 1e-3f)
        val c = Pose4.lookAt(Vec3(1f, 0f, 0f), Vec3(0f, 0f, 0f)) // 90 degrees around Y
        assertTrue(abs(Math.toDegrees(Pose4.rotationAngle(a, c).toDouble()) - 90) < 0.5)
    }

    @Test
    fun coach_midScan_fillsMiddleBand_andAsksForNextBand() {
        val r = CoachDemo.run(CoachDemo.Scenario.MID_SCAN)
        val cov = r.output.coverage
        assertTrue(cov.bandsComplete[CoachBand.MID.ordinal], "middle band done: ${cov.fill}")
        assertTrue(cov.fill[CoachBand.LOW.ordinal].count { it >= 1f } in 4..8, "half of low band: ${cov.fill[0]}")
        assertTrue(r.output.guidance == Guidance.Good || r.output.guidance is Guidance.NextBand, "${r.output.guidance}")
        assertTrue(r.photos in 40..90, "auto-shutter photos: ${r.photos}")
    }

    @Test
    fun coach_tooFast_gatesAndWarns() {
        val r = CoachDemo.run(CoachDemo.Scenario.TOO_FAST)
        assertEquals(Guidance.TooFast, r.output.guidance)
        assertTrue(!r.output.shouldIntegrate)
        assertTrue(r.output.speedFraction > 1f)
    }

    @Test
    fun coach_tooFar_showsCloser() {
        val r = CoachDemo.run(CoachDemo.Scenario.TOO_FAR)
        assertEquals(Guidance.TooFar, r.output.guidance)
    }

    @Test
    fun coach_grade_reportsGapsAndPhotoCount() {
        val r = CoachDemo.run(CoachDemo.Scenario.GRADE)
        val rep = r.report!!
        assertTrue(rep.coverageFraction in 0.8f..0.97f, "coverage ${rep.coverageFraction}")
        assertTrue(rep.grade == CoachReport.Grade.A || rep.grade == CoachReport.Grade.B, "grade ${rep.grade} ${rep.score}")
        assertTrue(r.photos in 80..200, "photos ${r.photos}")
        assertTrue(rep.text("Demo", com.moltstrong.asbuilt.core.coach.CoachThresholds.OBJECT).contains("Grade: ${rep.grade}"))
    }

    @Test
    fun coach_noFlicker_atThreshold() {
        // Distance oscillating around the 1.0 m limit must not toggle the cue every frame.
        val coach = CaptureCoach()
        var changes = 0
        var last: Guidance? = null
        coach.beginScanning()
        for (i in 0 until 300) {
            val d = if (i % 2 == 0) 0.98f else 1.02f
            val pose = CoachDemo.orbitPose(i * 0.2f, 20f, d)
            val out = coach.update(CoachFrame(i / 30.0, pose, 900f, d, 0.8f))
            if (last != null && out.guidance != last) changes++
            last = out.guidance
        }
        assertTrue(changes <= 2, "guidance changed $changes times")
    }

    @Test
    fun coach_blurGatesShots_andDarkWarns() {
        val coach = CaptureCoach()
        coach.beginScanning()
        var out = coach.update(CoachFrame(0.0, CoachDemo.orbitPose(0f, 20f, 0.5f), 900f, 0.5f, 0.8f, sharpness = 300f))
        for (i in 1..30) out = coach.update(CoachFrame(i / 30.0, CoachDemo.orbitPose(0f, 20f, 0.5f), 900f, 0.5f, 0.8f, sharpness = 10f))
        assertEquals(Guidance.Blurry, out.guidance)
        assertTrue(!out.shouldIntegrate)
        val dark = CaptureCoach()
        dark.beginScanning()
        var haptics = mutableListOf<CoachHaptic>()
        for (i in 0..30) {
            val o = dark.update(CoachFrame(i / 30.0, CoachDemo.orbitPose(0f, 20f, 0.5f), 50f, 0.5f, 0.8f))
            haptics.add(o.haptic); out = o
        }
        assertEquals(Guidance.TooDark, out.guidance)
        assertTrue(CoachHaptic.WARNING in haptics)
    }

    @Test
    fun shotPlanner_requiresNewAngle_andSharpness() {
        val planner = ShotPlanner()
        val coach = CaptureCoach()
        coach.beginScanning()
        var shots = 0
        var t = 0.0
        // Standing still for 5 s: one shot only.
        repeat(150) {
            val p = CoachDemo.orbitPose(0f, 20f, 0.5f)
            val o = coach.update(CoachFrame(t, p, 900f, 0.5f, 0.8f, sharpness = 300f))
            if (planner.decide(t, p, o, 300f, 60f, coach.centroid) == ShotPlanner.Decision.SHOOT) {
                planner.record(t, p, o.coverage.currentBand, coach.centroid); shots++
            }
            t += 1 / 30.0
        }
        assertEquals(1, shots)
        // Blurry preview never shoots.
        val p = CoachDemo.orbitPose(90f, 20f, 0.5f)
        val o = coach.update(CoachFrame(t, p, 900f, 0.5f, 0.8f, sharpness = 300f))
        assertEquals(ShotPlanner.Decision.WAIT_SHARPNESS, planner.decide(t + 1, p, o, 5f, 60f, coach.centroid))
    }

    @Test
    fun sharpness_laplacianVariance_dropsWithBlur() {
        val w = 160
        val h = 120
        val sharp = ByteArray(w * h) { i -> if (((i % w) / 4 + (i / w) / 4) % 2 == 0) 20 else 230.toByte() }
        val blurred = ByteArray(w * h)
        for (y in 0 until h) for (x in 0 until w) {
            var s = 0
            var n = 0
            for (dy in -4..4) for (dx in -4..4) {
                val xx = (x + dx).coerceIn(0, w - 1)
                val yy = (y + dy).coerceIn(0, h - 1)
                s += sharp[yy * w + xx].toInt() and 0xff; n++
            }
            blurred[y * w + x] = (s / n).toByte()
        }
        val vs = Sharpness.laplacianVariance(sharp, w, h, step = 1)
        val vb = Sharpness.laplacianVariance(blurred, w, h, step = 1)
        assertTrue(vs > 10 * vb, "sharp $vs vs blurred $vb")
    }
}
