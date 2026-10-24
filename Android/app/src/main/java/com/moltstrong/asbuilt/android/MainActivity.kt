package com.moltstrong.asbuilt.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.moltstrong.asbuilt.android.build.BuildService
import com.moltstrong.asbuilt.android.data.CaptureItem
import com.moltstrong.asbuilt.android.data.CaptureMeta
import com.moltstrong.asbuilt.android.ui.AsBuiltTheme
import com.moltstrong.asbuilt.android.ui.BuildProgressCard
import com.moltstrong.asbuilt.android.ui.CaptureResult
import com.moltstrong.asbuilt.android.ui.CaptureReview
import com.moltstrong.asbuilt.android.ui.CaptureScreen
import com.moltstrong.asbuilt.android.ui.CoachHud
import com.moltstrong.asbuilt.android.ui.DemoBuilds
import com.moltstrong.asbuilt.android.ui.JobListScreen
import com.moltstrong.asbuilt.android.ui.ModelScreen
import com.moltstrong.asbuilt.android.ui.ModelSource
import com.moltstrong.asbuilt.android.ui.SectionLabel
import com.moltstrong.asbuilt.android.ui.SettingsScreen
import com.moltstrong.asbuilt.android.capture.ArSupport
import com.moltstrong.asbuilt.android.capture.CaptureHud
import com.moltstrong.asbuilt.core.coach.CoachDemo
import com.moltstrong.asbuilt.core.recon.RemoteBuild
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Screens (simple state-based navigation; no back stack library needed). */
sealed class Screen {
    data object Jobs : Screen()
    data class Capture(val id: String, val demoSupport: ArSupport? = null) : Screen()
    data class Model(val title: String, val subtitle: String?, val source: ModelSource) : Screen()
    data object Settings : Screen()
    // Screenshot/demo screens (launched with --es demo <name>; no camera or network needed).
    data object DemoProgress : Screen()
    data class DemoCoach(val scenario: CoachDemo.Scenario) : Screen()
}

class MainActivity : ComponentActivity() {
    private var screen by mutableStateOf<Screen>(Screen.Jobs)
    private val app get() = application as AsBuiltApp

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        handleIntent(intent)
        setContent { AsBuiltTheme { Root() } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        // Resume any build interrupted by a kill/reboot (no-op when nothing is active).
        if (app.store.items.value.any { it.build?.isActive == true && it.meta.isSample.not() }) BuildService.kick(this)
    }

    private fun handleIntent(intent: Intent?) {
        try {
            intent?.getStringExtra(EXTRA_OPEN_MODEL)?.let { id -> app.store.item(id)?.let { openModel(it) } }
            when (val demo = intent?.getStringExtra(EXTRA_DEMO)) {
                null -> {}
                "jobs" -> {
                    seedDemoJobs(); screen = Screen.Jobs
                }
                "empty" -> screen = Screen.Jobs
                "progress" -> screen = Screen.DemoProgress
                "intro" -> screen = Screen.Capture("demo-intro", demoSupport = ArSupport.SUPPORTED)
                "unsupported" -> screen = Screen.Capture("demo-unsupported", demoSupport = ArSupport.UNSUPPORTED)
                "model" -> screen = Screen.Model("Sample: Monster tree", "20k triangles · 1K textures · built on a Mac", ModelSource.Asset(SAMPLE_ASSET))
                "settings" -> screen = Screen.Settings
                "review" -> screen = Screen.DemoCoach(CoachDemo.Scenario.GRADE)
                else -> CoachDemo.Scenario.entries.firstOrNull { it.key == demo }?.let { screen = Screen.DemoCoach(it) }
            }
        } catch (e: Exception) {
            Log.e(TAG, "intent", e)
        }
    }

    /** Puts one capture per progress-card state into the store (screenshots only). */
    private fun seedDemoJobs() {
        val store = app.store
        if (store.items.value.any { it.meta.isSample }) return
        val names = listOf("Garden chair" to DemoBuilds.building, "Ceramic vase" to DemoBuilds.uploading, "Work boot" to DemoBuilds.done,
            "Toolbox" to DemoBuilds.waiting, "Teapot" to DemoBuilds.failed)
        names.forEachIndexed { i, (title, b) ->
            val m = store.create(title, isSample = true, id = "DEMO-$i")
            store.writeMeta(m.copy(createdAtMs = System.currentTimeMillis() - i * 3_600_000L, photoCount = 142 - i * 9, grade = listOf("A", "B", "A", "B", "C")[i]))
            store.saveBuild(m.id, b)
        }
        store.refresh()
    }

    private fun openModel(item: CaptureItem) {
        val b = item.build
        val sub = listOfNotNull(
            b?.polygons?.let { "%,d triangles".format(it) },
            b?.textureSize?.let { "${it / 1024}K textures" },
        ).joinToString(" · ").ifEmpty { null }
        screen = if (item.hasModel) Screen.Model(item.meta.title, sub, ModelSource.FileSource(item.modelFile))
        else Screen.Model(item.meta.title, "Sample model", ModelSource.Asset(SAMPLE_ASSET))
    }

    private fun newCapture() {
        val title = "Scan " + SimpleDateFormat("MMM d, HH:mm", Locale.getDefault()).format(Date())
        val meta = app.store.create(title)
        screen = Screen.Capture(meta.id)
    }

    private fun startBuild(id: String) {
        try {
            val host = app.store.host(id) ?: return
            val existing = host.load()
            val fresh = RemoteBuild(phase = RemoteBuild.Phase.PREPARING, photoCount = app.store.item(id)?.meta?.photoCount,
                startedAtMs = System.currentTimeMillis())
            // Retry keeps the upload/job IDs so the runner resumes instead of re-sending.
            host.save(existing?.copy(phase = if (existing.jobID != null) RemoteBuild.Phase.QUEUED else if (existing.uploadID != null) RemoteBuild.Phase.UPLOADING else RemoteBuild.Phase.PREPARING,
                message = null, failureCount = 0, finishedAtMs = null) ?: fresh)
            askNotificationPermission()
            BuildService.kick(this)
        } catch (e: Exception) {
            Log.e(TAG, "start build", e)
        }
    }

    private fun askNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            try {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7)
            } catch (_: Exception) {
            }
        }
    }

    @Composable
    private fun Root() {
        val items by app.store.items.collectAsState()
        BackHandler(enabled = screen != Screen.Jobs) { screen = Screen.Jobs }
        when (val s = screen) {
            Screen.Jobs -> JobListScreen(
                items = items,
                serverConfigured = app.settings.isConfigured,
                onNewCapture = ::newCapture,
                onOpen = ::openModel,
                onRetry = { startBuild(it.meta.id) },
                onCancel = { BuildService.cancel(this, it.meta.id) },
                onDelete = {
                    if (it.build?.isActive == true) BuildService.cancel(this, it.meta.id)
                    app.store.delete(it.meta.id)
                },
                onBuild = { startBuild(it.meta.id) },
                onSettings = { screen = Screen.Settings },
            )
            is Screen.Capture -> {
                val dir = app.store.dir(s.id)
                CaptureScreen(
                    captureDir = dir, captureID = s.id, title = app.store.item(s.id)?.meta?.title ?: "Scan",
                    demoSupport = s.demoSupport,
                    onClose = {
                        // Drop an empty capture so the list doesn't fill with blanks.
                        val item = app.store.item(s.id)
                        if (item != null && (File(dir, "Images").listFiles()?.isEmpty() != false)) app.store.delete(s.id)
                        screen = Screen.Jobs
                    },
                    onFinished = { r, build -> finishCapture(s.id, r, build) },
                )
            }
            is Screen.Model -> ModelScreen(s.title, s.subtitle, s.source, onBack = { screen = Screen.Jobs })
            Screen.Settings -> SettingsScreen(app.settings, lastCrash(), onBack = { screen = Screen.Jobs })
            Screen.DemoProgress -> DemoProgressScreen()
            is Screen.DemoCoach -> DemoCoachScreen(s.scenario)
        }
    }

    private fun finishCapture(id: String, r: CaptureResult, build: Boolean) {
        try {
            app.store.item(id)?.meta?.let { m: CaptureMeta ->
                app.store.writeMeta(m.copy(photoCount = r.photos, grade = r.report.grade.name, gradeFix = r.report.fix))
            }
            app.store.refresh()
            if (build && r.photos > 0) startBuild(id)
        } catch (e: Exception) {
            Log.e(TAG, "finish", e)
        }
        screen = Screen.Jobs
    }

    private fun lastCrash(): String? = try {
        File(filesDir, "last-crash.txt").takeIf { it.isFile }?.readText()
    } catch (_: Exception) {
        null
    }

    @OptIn(ExperimentalMaterial3Api::class)
    @Composable
    private fun DemoProgressScreen() {
        Scaffold(
            topBar = {
                TopAppBar(title = { Text("Build progress states") },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background))
            },
            containerColor = MaterialTheme.colorScheme.background,
        ) { pad ->
            LazyColumn(
                Modifier.fillMaxSize().padding(pad), contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(DemoBuilds.all) { (label, b) ->
                    SectionLabel(label)
                    BuildProgressCard(
                        b,
                        onRetry = if (b.phase == RemoteBuild.Phase.FAILED || b.phase == RemoteBuild.Phase.WAITING_FOR_MAC) ({}) else null,
                        onCancel = if (b.isActive && b.phase != RemoteBuild.Phase.DOWNLOADING) ({}) else null,
                        onOpen = if (b.phase == RemoteBuild.Phase.DONE) ({}) else null,
                    )
                }
            }
        }
    }

    @Composable
    private fun DemoCoachScreen(scenario: CoachDemo.Scenario) {
        val r = androidx.compose.runtime.remember(scenario) { CoachDemo.run(scenario) }
        if (scenario == CoachDemo.Scenario.GRADE && r.report != null) {
            CaptureReview(CaptureResult(r.photos, r.report!!), onBuild = { screen = Screen.Jobs }, onSave = { screen = Screen.Jobs })
        } else {
            androidx.compose.foundation.layout.Box(
                Modifier.fillMaxSize().then(Modifier.padding(0.dp)),
            ) {
                // Stand-in for the camera feed.
                androidx.compose.foundation.Canvas(Modifier.fillMaxSize()) {
                    drawRect(androidx.compose.ui.graphics.Brush.verticalGradient(listOf(
                        androidx.compose.ui.graphics.Color(0xFF3A4048), androidx.compose.ui.graphics.Color(0xFF1B1E22))))
                    drawCircle(androidx.compose.ui.graphics.Color(0xFF6B5A44), radius = size.minDimension * 0.22f,
                        center = androidx.compose.ui.geometry.Offset(size.width / 2, size.height * 0.45f))
                }
                CoachHud(
                    CaptureHud(r.output, r.photos, "Tracking", "1920x1080", true, 0, null, null),
                    scanning = true, onClose = { screen = Screen.Jobs }, onStart = {}, onFinish = {}, onKeepGoing = {},
                )
            }
        }
    }

    companion object {
        private const val TAG = "AsBuilt"
        const val EXTRA_OPEN_MODEL = "openModel"
        const val EXTRA_DEMO = "demo"
        const val SAMPLE_ASSET = "sample/monstree-sample.glb"
    }
}
