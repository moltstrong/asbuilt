package com.moltstrong.asbuilt.android

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.util.Log
import com.moltstrong.asbuilt.android.data.CaptureStore
import com.moltstrong.asbuilt.android.data.ServerSettings
import java.io.File

class AsBuiltApp : Application() {
    lateinit var store: CaptureStore
        private set
    lateinit var settings: ServerSettings
        private set

    override fun onCreate() {
        super.onCreate()
        instance = this
        installCrashLog()
        store = CaptureStore(File(filesDir, "captures"))
        settings = ServerSettings(this)
        createChannels()
    }

    private fun createChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_BUILD, "Mac builds", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Progress of photo uploads and full-detail builds on your Mac"
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_DONE, "Models ready", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "A full-detail model is ready to view"
            },
        )
    }

    /** Last uncaught exception goes to files/last-crash.txt (shown in Settings) before the default handler runs. */
    private fun installCrashLog() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            try {
                File(filesDir, "last-crash.txt").writeText("${java.util.Date()} thread=${t.name}\n${Log.getStackTraceString(e)}")
            } catch (_: Throwable) {
            }
            previous?.uncaughtException(t, e)
        }
    }

    companion object {
        const val CHANNEL_BUILD = "build"
        const val CHANNEL_DONE = "done"
        lateinit var instance: AsBuiltApp
            private set
    }
}
