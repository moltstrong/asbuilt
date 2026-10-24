package com.moltstrong.asbuilt.android.build

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.moltstrong.asbuilt.android.AsBuiltApp
import com.moltstrong.asbuilt.android.BuildConfig
import com.moltstrong.asbuilt.android.MainActivity
import com.moltstrong.asbuilt.android.R
import com.moltstrong.asbuilt.android.data.ServerSettings
import com.moltstrong.asbuilt.core.recon.ReconClient
import com.moltstrong.asbuilt.core.recon.RemoteBuild
import com.moltstrong.asbuilt.core.recon.RemoteBuildRunner
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap

/**
 * Foreground service (type dataSync) that runs every active Mac build — pack, upload, poll, download —
 * so it keeps going when the app is in the background or the screen is off. One notification shows
 * the most relevant build's step and %. Every failure path is caught: a crash here would kill the app.
 */
class BuildService : Service() {
    private val handler = CoroutineExceptionHandler { _, e -> Log.e(TAG, "build coroutine failed", e) }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO + handler)
    private val running = ConcurrentHashMap<String, Job>()
    private var wakeLock: PowerManager.WakeLock? = null
    @Volatile private var lastNotify = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "AsBuilt:build").apply {
                setReferenceCounted(false)
                acquire(6 * 60 * 60 * 1000L)
            }
        } catch (e: Exception) {
            Log.w(TAG, "no wake lock: ${e.javaClass.simpleName}")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            startInForeground(notification(null))
        } catch (e: Exception) {
            // Android 12+ can refuse a background FGS start; the build resumes when the app opens.
            Log.e(TAG, "startForeground failed", e)
            stopSelf()
            return START_NOT_STICKY
        }
        val app = application as AsBuiltApp
        val cancelId = intent?.getStringExtra(EXTRA_CANCEL)
        if (cancelId != null) {
            running.remove(cancelId)?.cancel()
            app.store.item(cancelId)?.build?.let { b ->
                app.store.saveBuild(cancelId, b.copy(phase = RemoteBuild.Phase.CANCELLED, message = "Cancelled on this phone.",
                    finishedAtMs = System.currentTimeMillis(), inFlightBytes = 0))
            }
        }
        // Resume every active build (new ones, and ones interrupted by a kill/reboot).
        app.store.refresh()
        for (item in app.store.items.value) {
            val b = item.build ?: continue
            if (b.isActive && running[item.meta.id]?.isActive != true) start(item.meta.id)
        }
        stopIfIdle()
        return START_STICKY
    }

    private fun start(id: String) {
        val app = application as AsBuiltApp
        val config = app.settings.config()
        val job = scope.launch {
            try {
                val host = app.store.host(id) { b -> onProgress(id, b) } ?: return@launch
                if (!config.isUsable) {
                    host.load()?.let { host.save(it.copy(phase = RemoteBuild.Phase.FAILED, message = "Add your Mac's build server in Settings first.")) }
                    return@launch
                }
                val runner = RemoteBuildRunner(
                    ReconClient(config, userAgent = "AsBuilt-Android/${BuildConfig.VERSION_NAME}"), host,
                    appBuild = BuildConfig.VERSION_CODE.toString(), device = "${Build.MANUFACTURER} ${Build.MODEL} (API ${Build.VERSION.SDK_INT})",
                    appState = { "service" }, log = { Log.i(TAG, "[$id] $it") },
                    glbTextureSize = app.settings.glbTextureSize.takeIf { it in ServerSettings.TEXTURE_CHOICES && it != 8192 },
                )
                val final = runner.run()
                if (final?.phase == RemoteBuild.Phase.DONE) notifyDone(id, app.store.item(id)?.meta?.title ?: "Model")
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Throwable) {
                Log.e(TAG, "build $id crashed", e)
                try {
                    app.store.item(id)?.build?.let { b ->
                        app.store.saveBuild(id, b.copy(phase = RemoteBuild.Phase.FAILED,
                            message = "Something went wrong on this phone (${e.javaClass.simpleName}). Tap Retry."))
                    }
                } catch (_: Throwable) {
                }
            } finally {
                running.remove(id)
                stopIfIdle()
            }
        }
        running[id] = job
    }

    private fun onProgress(id: String, b: RemoteBuild) {
        val now = System.currentTimeMillis()
        if (now - lastNotify < 1000 && b.isActive) return
        lastNotify = now
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIF_ID, notification(id to b))
        } catch (_: Exception) {
        }
    }

    private fun stopIfIdle() {
        if (running.values.none { it.isActive }) {
            try {
                if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE) else @Suppress("DEPRECATION") stopForeground(true)
            } catch (_: Exception) {
            }
            stopSelf()
        }
    }

    private fun startInForeground(n: Notification) {
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else startForeground(NOTIF_ID, n)
    }

    private fun contentIntent(): PendingIntent = PendingIntent.getActivity(
        this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun notification(state: Pair<String, RemoteBuild>?): Notification {
        val b = state?.second
        val builder = NotificationCompat.Builder(this, AsBuiltApp.CHANNEL_BUILD)
            .setSmallIcon(R.drawable.ic_stat_build)
            .setContentTitle(b?.headline ?: "Mac build")
            .setContentText(b?.detailLine ?: "Starting…")
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setContentIntent(contentIntent())
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        if (b != null && b.isActive) builder.setProgress(1000, (b.overallFraction * 1000).toInt(), b.phase == RemoteBuild.Phase.PREPARING && b.phaseProgress == 0.0)
        return builder.build()
    }

    private fun notifyDone(id: String, title: String) {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val intent = PendingIntent.getActivity(
                this, id.hashCode(), Intent(this, MainActivity::class.java).putExtra(MainActivity.EXTRA_OPEN_MODEL, id)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            nm.notify(id.hashCode(), NotificationCompat.Builder(this, AsBuiltApp.CHANNEL_DONE)
                .setSmallIcon(R.drawable.ic_stat_build)
                .setContentTitle("$title is ready")
                .setContentText("Full-detail model built on your Mac. Tap to view in 3D.")
                .setAutoCancel(true)
                .setContentIntent(intent)
                .build())
        } catch (_: Exception) {
        }
    }

    override fun onDestroy() {
        scope.cancel()
        try {
            wakeLock?.takeIf { it.isHeld }?.release()
        } catch (_: Exception) {
        }
        super.onDestroy()
    }

    companion object {
        private const val TAG = "AsBuiltBuild"
        private const val NOTIF_ID = 42
        const val EXTRA_CANCEL = "cancel"

        /** Starts/resumes all active builds. Safe to call any time (no-op if nothing is active). */
        fun kick(context: Context) {
            try {
                ContextCompat.startForegroundService(context, Intent(context, BuildService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "can't start build service now: ${e.javaClass.simpleName}")
            }
        }

        fun cancel(context: Context, id: String) {
            try {
                ContextCompat.startForegroundService(context, Intent(context, BuildService::class.java).putExtra(EXTRA_CANCEL, id))
            } catch (e: Exception) {
                Log.w(TAG, "can't cancel now: ${e.javaClass.simpleName}")
            }
        }
    }
}
