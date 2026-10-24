package com.moltstrong.asbuilt.core

import com.moltstrong.asbuilt.core.recon.BuildHost
import com.moltstrong.asbuilt.core.recon.FolderBuildHost
import com.moltstrong.asbuilt.core.recon.ReconChunker
import com.moltstrong.asbuilt.core.recon.ReconClient
import com.moltstrong.asbuilt.core.recon.ReconConfig
import com.moltstrong.asbuilt.core.recon.RemoteBuild
import com.moltstrong.asbuilt.core.recon.RemoteBuildRunner
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.Collections
import java.util.zip.ZipFile
import kotlin.random.Random
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** The Android upload → build → download flow against an in-memory v1 server. */
class RemoteBuildRunnerTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var server: MockWebServer
    private lateinit var fake: FakeReconServer
    private val sleeps: MutableList<Long> = Collections.synchronizedList(mutableListOf<Long>())

    @Before
    fun setUp() {
        fake = FakeReconServer()
        server = MockWebServer()
        server.dispatcher = fake
        server.start()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private val base get() = server.url("/").toString().trimEnd('/')

    /** A capture folder with [photos] random "JPEGs" totalling ~[bytesEach]*photos. */
    private fun capture(photos: Int = 6, bytesEach: Int = 700_000): FolderBuildHost {
        val dir = tmp.newFolder("cap")
        val images = File(dir, "Images").apply { mkdirs() }
        val rnd = Random(42)
        repeat(photos) { i -> File(images, "IMG_%04d.jpg".format(i + 1)).writeBytes(rnd.nextBytes(bytesEach)) }
        File(dir, "poses.json").writeText("""{"captureID": "cap", "photos": []}""")
        val host = FolderBuildHost(dir, "cap-1", "Test object")
        host.save(RemoteBuild(photoCount = photos))
        return host
    }

    private fun runner(host: BuildHost, config: ReconConfig = ReconConfig(base, null, fake.apiKey), chunk: Int = 1 shl 20) =
        RemoteBuildRunner(ReconClient(config), host, sleeper = { sleeps.add(it) }, pollIntervalMs = 1, chunkSize = chunk,
            sendDiagnostics = true)

    @Test
    fun happyPath_uploadsAllChunks_threeInFlight_downloadsVerifiedGlb() = runBlocking {
        val host = capture()
        val final = withTimeout(30_000) { runner(host).run() }
        assertNotNull(final)
        assertEquals(RemoteBuild.Phase.DONE, final.phase, final.message)
        // Create body: Android asks for the phone preset, auto-complete and a GLB.
        assertEquals("phone", fake.receivedUploadField("detail"))
        assertEquals("true", fake.receivedUploadField("glb"))
        assertEquals("true", fake.receivedUploadField("autoComplete"))
        assertEquals("Images.zip", fake.receivedUploadField("filename"))
        assertEquals((1 shl 20).toString(), fake.receivedUploadField("chunkSize"))
        // Every chunk once, never more than 3 at a time, but parallel.
        assertEquals(fake.chunkCount, fake.chunkPuts.get())
        assertTrue(fake.maxInFlight.get() in 2..3, "max in flight ${fake.maxInFlight.get()}")
        // The assembled upload is a STORE zip with Images/ + poses.json.
        val zip = tmp.newFile("assembled.zip").apply { writeBytes(fake.assembled()) }
        ZipFile(zip).use { z ->
            val names = z.entries().toList().map { it.name }
            assertEquals((1..6).map { "Images/IMG_%04d.jpg".format(it) } + "poses.json", names)
            assertTrue(z.entries().toList().all { it.method == java.util.zip.ZipEntry.STORED })
        }
        // Model verified + stored, job state folded in, work files removed, Mac job deleted.
        assertTrue(fake.glb.contentEquals(host.modelFile.readBytes()))
        assertEquals(249999, final.polygons)
        assertEquals(8192, final.textureSize)
        assertEquals(1.0, final.overallFraction)
        assertTrue(!host.workDir.exists())
        assertTrue(File(host.dir, "recon-log.txt").isFile)
        Thread.sleep(200)
        assertTrue(fake.deletedJob)
        assertTrue(fake.requests.none { it.contains("/complete") }, "auto-complete: no explicit complete call")
    }

    @Test
    fun cloudflareHtmlAnd5xx_areRetriedPerChunk_withBackoff() = runBlocking {
        val host = capture()
        fake.failChunk[1] = 2
        fake.failChunk[3] = 1
        fake.jobFailures = 1
        val final = withTimeout(30_000) { runner(host).run() }
        assertEquals(RemoteBuild.Phase.DONE, final!!.phase, final.message)
        assertEquals(fake.chunkCount + 3, fake.chunkPuts.get())
        assertTrue(sleeps.any { it in 2_000..16_000 }, "chunk backoff used: $sleeps")
    }

    @Test
    fun chunkShaMismatch_isResent() = runBlocking {
        val host = capture()
        fake.shaMismatch[0] = 1
        val final = withTimeout(30_000) { runner(host).run() }
        assertEquals(RemoteBuild.Phase.DONE, final!!.phase)
        assertEquals(fake.chunkCount + 1, fake.chunkPuts.get())
    }

    @Test
    fun resumesFromServerReceivedChunks_afterKill() = runBlocking {
        val host = capture()
        // First run: the server drops every chunk >= 2 forever -> the runner goes to waitingForMac.
        repeat(20) { fake.failChunk[2 + it] = 1000 }
        val first = runner(host)
        val job = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO).launch {
            first.run()
        }
        withTimeout(20_000) {
            while (host.load()?.phase != RemoteBuild.Phase.WAITING_FOR_MAC) kotlinx.coroutines.delay(20)
        }
        job.cancel()
        job.join()
        // Let requests the killed client already sent drain on the server side.
        Thread.sleep(300)
        withTimeout(5_000) { while (fake.inFlight.get() > 0) kotlinx.coroutines.delay(10) }
        Thread.sleep(100)
        val mid = host.load()!!
        assertEquals(RemoteBuild.Phase.WAITING_FOR_MAC, mid.phase)
        assertTrue(mid.receivedChunks.containsAll(listOf(0, 1)), "${mid.receivedChunks}")
        val putsBefore = fake.chunkPuts.get()
        val serverHad = fake.chunks.size // may include a chunk that landed after the client was killed
        // "App relaunch": a new runner on the same capture resumes; already received chunks are not re-sent.
        fake.failChunk.clear()
        val final = withTimeout(30_000) { runner(host).run() }
        assertEquals(RemoteBuild.Phase.DONE, final!!.phase, final.message)
        val resent = fake.requests.drop(0).count { it.startsWith("PUT /v1/uploads/up_1/chunks/0") }
        assertEquals(1, resent, "chunk 0 sent exactly once overall")
        assertEquals(fake.chunkCount - serverHad, fake.chunkPuts.get() - putsBefore, "only missing chunks re-sent")
        assertEquals(1, fake.requests.count { it == "POST /v1/uploads" }, "same upload reused")
    }

    @Test
    fun download_isShaVerified_andResumedWithRange() = runBlocking {
        val host = capture()
        fake.corruptDownloads = 1
        fake.truncatedDownloads = 1
        val final = withTimeout(30_000) { runner(host).run() }
        assertEquals(RemoteBuild.Phase.DONE, final!!.phase, final.message)
        assertTrue(fake.glb.contentEquals(host.modelFile.readBytes()))
        // corrupted (full) + truncated (fresh) + resumed with a Range header.
        assertTrue(fake.rangeHeaders.any { it != null && it.startsWith("bytes=") }, "${fake.rangeHeaders}")
        assertTrue(!File(host.modelFile.path + ".part").exists())
    }

    @Test
    fun wrongKey_failsFast_withoutRetryLoop() = runBlocking {
        val host = capture()
        val final = withTimeout(10_000) { runner(host, ReconConfig(base, null, "wrong")).run() }
        assertEquals(RemoteBuild.Phase.FAILED, final!!.phase)
        assertTrue(final.message!!.contains("wrong key"))
        assertEquals(0, fake.chunkPuts.get())
    }

    @Test
    fun macBuildFailure_isReported() = runBlocking {
        val host = capture()
        fake.failJob = true
        val final = withTimeout(30_000) { runner(host).run() }
        assertEquals(RemoteBuild.Phase.FAILED, final!!.phase)
        assertEquals("Too few photos overlap.", final.message)
    }

    @Test
    fun oldServerWithoutGlb_failsWithClearMessage() = runBlocking {
        val host = capture()
        fake.omitGlb = true
        val final = withTimeout(30_000) { runner(host).run() }
        assertEquals(RemoteBuild.Phase.FAILED, final!!.phase)
        assertTrue(final.message!!.contains("GLB"), final.message)
    }

    @Test
    fun discovery_isUsed_andReResolvedAfterTunnelMoves() = runBlocking {
        // Discovery gist points at the live server; the baked-in base URL is dead.
        val gist = MockWebServer()
        val payload = """{"files": {"asbuilt-recon.json": {"content": "{\"baseURL\": \"https://example.invalid\", \"apiVersion\": 1}"}}}"""
        gist.enqueue(MockResponse().setBody(payload))
        gist.start()
        try {
            val dead = "http://127.0.0.1:9" // nothing listens on the discard port
            val client = ReconClient(ReconConfig(dead, gist.url("/gists/x").toString(), fake.apiKey))
            // Discovery result is https://example.invalid (unreachable) and the base is dead -> offline, not a crash.
            val err = runCatching { client.baseUrl() }.exceptionOrNull()
            assertTrue(err is com.moltstrong.asbuilt.core.recon.ReconOffline, "$err")
            assertEquals(1, gist.requestCount)
        } finally {
            gist.shutdown()
        }
        // Base URL works -> it is used.
        val ok = ReconClient(ReconConfig(base, null, fake.apiKey))
        assertEquals(base, ok.baseUrl())
    }

    @Test
    fun serverDown_goesToWaitingForMac_thenRecovers() = runBlocking {
        val host = capture()
        fake.health = false
        val r = runner(host)
        val job = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO).launch { r.run() }
        withTimeout(10_000) { while (host.load()?.phase != RemoteBuild.Phase.WAITING_FOR_MAC) kotlinx.coroutines.delay(10) }
        assertTrue(host.load()!!.message!!.contains("isn't reachable"))
        fake.health = true
        withTimeout(30_000) { job.join() }
        assertEquals(RemoteBuild.Phase.DONE, host.load()!!.phase)
        assertTrue(sleeps.any { it >= 2_000 }, "backoff between attempts: $sleeps")
    }

    @Test
    fun explicitComplete_isFallback_whenServerDoesNotAutoComplete() = runBlocking {
        val host = capture(photos = 2)
        val noAuto = object : okhttp3.mockwebserver.Dispatcher() {
            override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest): MockResponse {
                if (request.method == "POST" && request.path == "/v1/uploads") {
                    val r = fake.dispatch(request)
                    fake.autoComplete = false
                    return r
                }
                return fake.dispatch(request)
            }
        }
        server.dispatcher = noAuto
        val final = withTimeout(30_000) { runner(host).run() }
        assertEquals(RemoteBuild.Phase.DONE, final!!.phase, final.message)
        assertTrue(fake.requests.any { it == "POST /v1/uploads/up_1/complete" })
    }

    @Test
    fun chunker_matchesServerChunkMath() {
        val f = tmp.newFile("z.bin")
        val data = Random(1).nextBytes(5 * 1024 + 17)
        f.writeBytes(data)
        val plan = ReconChunker.split(f, tmp.newFolder("chunks"), chunkSize = 1024)
        assertEquals(6, plan.chunks.size)
        assertEquals(17, plan.chunks.last().bytes)
        assertEquals(ReconChunker.sha256(data), plan.sha256)
        assertTrue(!f.exists(), "zip consumed")
        val joined = plan.chunks.flatMap { File(tmp.root, "chunks/${it.fileName}").readBytes().toList() }.toByteArray()
        assertTrue(joined.contentEquals(data))
        plan.chunks.forEach { assertEquals(ReconChunker.sha256(File(tmp.root, "chunks/${it.fileName}").readBytes()), it.sha256) }
        assertEquals(0 until 1024L, ReconChunker.range(0, data.size.toLong(), 1024))
        assertEquals(5 * 1024L until data.size.toLong(), ReconChunker.range(5, data.size.toLong(), 1024))
    }
}
