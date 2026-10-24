package com.moltstrong.asbuilt.android.ui

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.opengl.GLSurfaceView
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import android.view.WindowManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Height
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Straighten
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.google.ar.core.ArCoreApk
import com.moltstrong.asbuilt.android.capture.ArAvailability
import com.moltstrong.asbuilt.android.capture.ArCaptureEngine
import com.moltstrong.asbuilt.android.capture.ArSupport
import com.moltstrong.asbuilt.android.capture.CaptureHud
import com.moltstrong.asbuilt.core.coach.CoachHaptic
import com.moltstrong.asbuilt.core.coach.CoachReport
import com.moltstrong.asbuilt.core.coach.CoverageSnapshot
import com.moltstrong.asbuilt.core.coach.DistanceZone
import com.moltstrong.asbuilt.core.coach.Guidance
import java.io.File

/** Result of a finished capture handed back to the app. */
data class CaptureResult(val photos: Int, val report: CoachReport)

private enum class Stage { INTRO, LIVE, REVIEW }

/**
 * Capture flow: intro (how to scan + AR availability) -> live AR capture with the coach HUD and
 * auto-shutter -> review with the A-F grade -> "Build full detail".
 */
@Composable
fun CaptureScreen(
    captureDir: File,
    captureID: String,
    title: String,
    /** Screenshot demo: skip the real ARCore check and show this state. */
    demoSupport: ArSupport? = null,
    onClose: () -> Unit,
    onFinished: (CaptureResult, build: Boolean) -> Unit,
) {
    val context = LocalContext.current
    var support by remember { mutableStateOf(demoSupport ?: ArSupport.CHECKING) }
    var stage by remember { mutableStateOf(Stage.INTRO) }
    var result by remember { mutableStateOf<CaptureResult?>(null) }
    var permissionDenied by remember { mutableStateOf(false) }

    LaunchedEffect(demoSupport) {
        if (demoSupport != null) return@LaunchedEffect
        repeat(20) {
            support = ArAvailability.check(context)
            if (support != ArSupport.CHECKING) return@LaunchedEffect
            kotlinx.coroutines.delay(250)
        }
        if (support == ArSupport.CHECKING) support = ArSupport.UNSUPPORTED
    }
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        permissionDenied = !granted
        if (granted) stage = Stage.LIVE
    }

    fun start() {
        if (support == ArSupport.NEEDS_INSTALL) {
            try {
                val activity = context as? Activity
                if (activity != null && ArCoreApk.getInstance().requestInstall(activity, true) == ArCoreApk.InstallStatus.INSTALLED) {
                    support = ArSupport.SUPPORTED
                }
            } catch (e: Throwable) {
                Log.w("AsBuiltAR", "install request: ${e.javaClass.simpleName}")
                support = ArSupport.UNSUPPORTED
            }
            return
        }
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) stage = Stage.LIVE
        else permissionLauncher.launch(Manifest.permission.CAMERA)
    }

    when (stage) {
        Stage.INTRO -> CaptureIntro(support, permissionDenied, onClose = onClose, onStart = ::start)
        Stage.LIVE -> LiveCapture(captureDir, captureID, title, onClose = onClose) { r ->
            result = r
            stage = Stage.REVIEW
        }
        Stage.REVIEW -> result?.let { r ->
            CaptureReview(r, onBuild = { onFinished(r, true) }, onSave = { onFinished(r, false) })
        }
    }
}

@Composable
fun CaptureIntro(support: ArSupport, permissionDenied: Boolean, onClose: () -> Unit, onStart: () -> Unit) {
    Column(
        Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).statusBarsPadding().navigationBarsPadding()
            .verticalScroll(rememberScrollState()).padding(horizontal = 24.dp),
    ) {
        Row(Modifier.fillMaxWidth().padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
        }
        Spacer(Modifier.height(8.dp))
        Text("Scan an object", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(6.dp))
        Text(
            "AsBuilt takes the photos for you. Walk slowly around the object three times — low, middle, high.",
            style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(20.dp))
        Tip(Icons.Filled.Straighten, "Stay 30-90 cm away", "The ring turns green in the sweet spot.")
        Tip(Icons.Filled.Speed, "Move slowly", "Blurry or rushed frames are skipped automatically.")
        Tip(Icons.Filled.Autorenew, "Go all the way around", "Fill the 12 x 3 coverage ring; aim for 80-200 photos.")
        Tip(Icons.Filled.Height, "Three heights", "Low, middle, then high looking down. The coach tells you when.")
        Tip(Icons.Filled.Lightbulb, "Even light, no shine", "Soft daylight is best. Matte objects work best.")
        Spacer(Modifier.height(20.dp))
        when (support) {
            ArSupport.UNSUPPORTED -> UnsupportedCard()
            ArSupport.CHECKING -> Text("Checking this phone's AR support…", color = MaterialTheme.colorScheme.onSurfaceVariant)
            else -> {
                if (permissionDenied) {
                    Text(
                        "AsBuilt needs the camera to take the photos. Allow it in Android Settings › Apps › AsBuilt › Permissions.",
                        color = AsBuiltColors.Warning, style = MaterialTheme.typography.bodyMedium,
                    )
                    Spacer(Modifier.height(12.dp))
                }
                Button(
                    onClick = onStart, modifier = Modifier.fillMaxWidth().height(54.dp), shape = RoundedCornerShape(14.dp),
                ) {
                    Icon(Icons.Filled.CameraAlt, null)
                    Spacer(Modifier.width(8.dp))
                    Text(if (support == ArSupport.NEEDS_INSTALL) "Install Google Play Services for AR" else "Start capture", style = MaterialTheme.typography.titleMedium)
                }
            }
        }
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun UnsupportedCard() {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(MaterialTheme.colorScheme.surfaceContainerHigh).padding(16.dp),
    ) {
        Text("This phone can't do AR capture", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(6.dp))
        Text(
            "Capture needs Google Play Services for AR (ARCore), which this device doesn't support. You can still view models built on your Mac from the list.",
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun Tip(icon: ImageVector, title: String, body: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.Top) {
        Box(Modifier.size(36.dp).clip(CircleShape).background(MaterialTheme.colorScheme.surfaceContainerHigh), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.width(14.dp))
        Column {
            Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            Text(body, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun LiveCapture(captureDir: File, captureID: String, title: String, onClose: () -> Unit, onDone: (CaptureResult) -> Unit) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var hud by remember { mutableStateOf(CaptureHud()) }
    var fatal by remember { mutableStateOf<String?>(null) }
    var scanning by remember { mutableStateOf(false) }
    val vibrator = remember { vibrator(context) }
    val engine = remember {
        ArCaptureEngine(context, captureDir, captureID, title, onHud = { hud = it }, onHaptic = { h -> haptic(vibrator, h) })
    }
    var glView by remember { mutableStateOf<GLSurfaceView?>(null) }

    DisposableEffect(Unit) {
        (context as? Activity)?.window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        fatal = engine.createSession()
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> {
                    if (fatal == null) fatal = engine.resume()
                    glView?.onResume()
                }
                Lifecycle.Event.ON_PAUSE -> {
                    glView?.onPause()
                    engine.pause()
                }
                else -> {}
            }
        }
        lifecycle.addObserver(observer)
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && fatal == null) fatal = engine.resume()
        onDispose {
            lifecycle.removeObserver(observer)
            (context as? Activity)?.window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            glView?.onPause()
            engine.pause()
            engine.close()
        }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        if (fatal == null) {
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { ctx ->
                    GLSurfaceView(ctx).apply {
                        preserveEGLContextOnPause = true
                        setEGLContextClientVersion(2)
                        setEGLConfigChooser(8, 8, 8, 8, 16, 0)
                        setRenderer(engine)
                        renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY
                        @Suppress("DEPRECATION")
                        engine.setDisplayRotation((ctx.getSystemService(android.content.Context.WINDOW_SERVICE) as WindowManager).defaultDisplay.rotation)
                        glView = this
                    }
                },
            )
        } else {
            CenteredMessage("Camera unavailable", fatal ?: "", action = { OutlinedButton(onClick = onClose) { Text("Back") } })
        }
        if (fatal == null) {
            CoachHud(
                hud = hud, scanning = scanning,
                onClose = onClose,
                onStart = {
                    scanning = true
                    engine.startScanning()
                },
                onFinish = {
                    scanning = false
                    val n = engine.finish()
                    onDone(CaptureResult(n, engine.report()))
                },
                onKeepGoing = { engine.dismissFinish() },
            )
        }
    }
}

/** HUD over the camera feed (also used by the screenshot demo with synthetic coach output). */
@Composable
fun CoachHud(
    hud: CaptureHud,
    scanning: Boolean,
    onClose: () -> Unit,
    onStart: () -> Unit,
    onFinish: () -> Unit,
    onKeepGoing: () -> Unit,
) {
    val out = hud.output
    Box(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onClose, modifier = Modifier.clip(CircleShape).background(Color.Black.copy(alpha = 0.45f))) {
                Icon(Icons.Filled.Close, contentDescription = "Close", tint = Color.White)
            }
            Spacer(Modifier.weight(1f))
            Pill("${hud.photos} photos")
            Spacer(Modifier.width(8.dp))
            Pill(hud.tracking)
        }
        Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
            val ringColor = when (out?.distanceZone) {
                DistanceZone.GOOD -> AsBuiltColors.Good
                DistanceZone.TOO_CLOSE, DistanceZone.TOO_FAR -> AsBuiltColors.Warning
                else -> Color.White.copy(alpha = 0.7f)
            }
            Box(Modifier.size(22.dp).clip(CircleShape).background(ringColor.copy(alpha = 0.85f)))
            out?.distance?.let {
                Spacer(Modifier.height(6.dp))
                Text("${(it * 100).toInt()} cm", color = Color.White, style = MaterialTheme.typography.labelLarge)
            }
        }
        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            if (out != null) {
                GuidanceChip(out.guidance)
                Spacer(Modifier.height(12.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CoverageRing(out.coverage, Modifier.size(132.dp))
                    Spacer(Modifier.width(16.dp))
                    Column {
                        Text("${(out.coverage.fraction * 100).toInt()}% covered", color = Color.White, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                        Text(bandLine(out.coverage), color = Color.White.copy(alpha = 0.75f), style = MaterialTheme.typography.bodySmall)
                        Spacer(Modifier.height(6.dp))
                        SpeedBar(out.speedFraction)
                    }
                }
                Spacer(Modifier.height(14.dp))
            }
            if (!scanning) {
                Button(onClick = onStart, enabled = out?.isReady != false, modifier = Modifier.fillMaxWidth().height(54.dp), shape = RoundedCornerShape(14.dp)) {
                    Text(if (out?.isReady == false) "Aim at the object…" else "Start scanning", style = MaterialTheme.typography.titleMedium)
                }
            } else {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (out?.suggestFinish == true) {
                        OutlinedButton(onClick = onKeepGoing, modifier = Modifier.weight(1f).height(54.dp), shape = RoundedCornerShape(14.dp)) { Text("Keep going") }
                    }
                    Button(
                        onClick = onFinish, modifier = Modifier.weight(1f).height(54.dp), shape = RoundedCornerShape(14.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = if (out?.suggestFinish == true) AsBuiltColors.Good else MaterialTheme.colorScheme.primary),
                        enabled = hud.photos > 0,
                    ) { Text("Finish", style = MaterialTheme.typography.titleMedium) }
                }
            }
            hud.error?.let {
                Spacer(Modifier.height(8.dp))
                Text(it, color = AsBuiltColors.Warning, style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center)
            }
        }
    }
}

private fun bandLine(c: CoverageSnapshot): String {
    val names = listOf("Low", "Middle", "High")
    return names.indices.joinToString("  ") { i -> (if (c.bandsComplete.getOrElse(i) { false }) "✓ " else "") + names[i] }
}

@Composable
private fun GuidanceChip(g: Guidance) {
    val bg = if (g.isProblem) AsBuiltColors.Warning else if (g == Guidance.Complete || g == Guidance.Good) AsBuiltColors.Good else Color.Black.copy(alpha = 0.6f)
    Text(
        g.label, color = if (g.isProblem || g == Guidance.Good || g == Guidance.Complete) Color.Black else Color.White,
        style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold,
        modifier = Modifier.clip(RoundedCornerShape(24.dp)).background(bg).padding(horizontal = 20.dp, vertical = 10.dp),
    )
}

@Composable
private fun SpeedBar(fraction: Float) {
    val f = fraction.coerceIn(0f, 1.5f)
    val color = if (f > 1f) AsBuiltColors.Problem else if (f > 0.75f) AsBuiltColors.Warning else AsBuiltColors.Good
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("Speed", color = Color.White.copy(alpha = 0.75f), style = MaterialTheme.typography.labelSmall)
        Spacer(Modifier.width(6.dp))
        Box(Modifier.width(90.dp).height(6.dp).clip(RoundedCornerShape(3.dp)).background(Color.White.copy(alpha = 0.2f))) {
            Box(Modifier.fillMaxWidth((f / 1.5f).coerceIn(0.02f, 1f)).height(6.dp).background(color))
        }
    }
}

@Composable
private fun Pill(text: String) {
    Text(
        text, color = Color.White, style = MaterialTheme.typography.labelLarge,
        modifier = Modifier.clip(RoundedCornerShape(16.dp)).background(Color.Black.copy(alpha = 0.5f)).padding(horizontal = 12.dp, vertical = 6.dp),
    )
}

@Composable
fun CaptureReview(result: CaptureResult, onBuild: () -> Unit, onSave: () -> Unit) {
    val r = result.report
    val gradeColor = when (r.grade) {
        CoachReport.Grade.A, CoachReport.Grade.B -> AsBuiltColors.Good
        CoachReport.Grade.C -> AsBuiltColors.Warning
        else -> AsBuiltColors.Problem
    }
    Column(
        Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).statusBarsPadding().navigationBarsPadding()
            .verticalScroll(rememberScrollState()).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(24.dp))
        Box(Modifier.size(112.dp).clip(CircleShape).background(gradeColor.copy(alpha = 0.18f)), contentAlignment = Alignment.Center) {
            Text(r.grade.name, color = gradeColor, style = MaterialTheme.typography.displayMedium, fontWeight = FontWeight.Bold)
        }
        Spacer(Modifier.height(16.dp))
        Text("${result.photos} photos", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(6.dp))
        Text(
            r.fix ?: "Great coverage. Ready for a full-detail build.", style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(20.dp))
        Stat("Coverage", r.coverageFraction)
        Stat("Good technique", r.goodFraction)
        Stat("Too fast", r.tooFastFraction, invert = true)
        Stat("Too dark", r.tooDarkFraction, invert = true)
        Stat("Distance off", r.distanceFraction, invert = true)
        Stat("Blurry", r.blurryFraction, invert = true)
        Spacer(Modifier.height(24.dp))
        Button(onClick = onBuild, modifier = Modifier.fillMaxWidth().height(54.dp), shape = RoundedCornerShape(14.dp), enabled = result.photos > 0) {
            Text("Build full detail", style = MaterialTheme.typography.titleMedium)
        }
        Spacer(Modifier.height(10.dp))
        OutlinedButton(onClick = onSave, modifier = Modifier.fillMaxWidth().height(50.dp), shape = RoundedCornerShape(14.dp)) {
            Text("Save for later")
        }
    }
}

@Composable
private fun Stat(label: String, value: Float, invert: Boolean = false) {
    val good = if (invert) value < 0.15f else value > 0.7f
    Row(Modifier.fillMaxWidth().padding(vertical = 5.dp)) {
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
        Text("${(value * 100).toInt()}%", style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold,
            color = if (good) AsBuiltColors.Good else AsBuiltColors.Warning)
    }
}

private fun vibrator(context: android.content.Context): Vibrator? = try {
    if (Build.VERSION.SDK_INT >= 31) (context.getSystemService(VibratorManager::class.java))?.defaultVibrator
    else @Suppress("DEPRECATION") context.getSystemService(android.content.Context.VIBRATOR_SERVICE) as? Vibrator
} catch (_: Throwable) {
    null
}

private fun haptic(v: Vibrator?, h: CoachHaptic) {
    if (v == null || h == CoachHaptic.NONE) return
    try {
        val effect = when (h) {
            CoachHaptic.TICK -> VibrationEffect.createOneShot(12, 80)
            CoachHaptic.WARNING -> VibrationEffect.createWaveform(longArrayOf(0, 40, 60, 40), -1)
            CoachHaptic.SUCCESS, CoachHaptic.READY -> VibrationEffect.createOneShot(30, 160)
            CoachHaptic.COMPLETE -> VibrationEffect.createWaveform(longArrayOf(0, 30, 80, 30, 80, 60), -1)
            CoachHaptic.NONE -> return
        }
        v.vibrate(effect)
    } catch (_: Throwable) {
    }
}
