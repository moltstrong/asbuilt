package com.moltstrong.asbuilt.android.capture

import android.content.Context
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.media.Image
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.os.Build
import android.util.Log
import androidx.exifinterface.media.ExifInterface
import com.google.ar.core.ArCoreApk
import com.google.ar.core.CameraConfig
import com.google.ar.core.CameraConfigFilter
import com.google.ar.core.Config
import com.google.ar.core.Frame
import com.google.ar.core.Session
import com.google.ar.core.TrackingFailureReason
import com.google.ar.core.TrackingState
import com.google.ar.core.exceptions.NotYetAvailableException
import com.moltstrong.asbuilt.core.capture.Intrinsics
import com.moltstrong.asbuilt.core.capture.PhotoPose
import com.moltstrong.asbuilt.core.capture.PosesFile
import com.moltstrong.asbuilt.core.coach.CaptureCoach
import com.moltstrong.asbuilt.core.coach.CoachFrame
import com.moltstrong.asbuilt.core.coach.CoachOutput
import com.moltstrong.asbuilt.core.coach.CoachTracking
import com.moltstrong.asbuilt.core.coach.Pose4
import com.moltstrong.asbuilt.core.coach.Sharpness
import com.moltstrong.asbuilt.core.coach.ShotPlanner
import com.moltstrong.asbuilt.core.recon.ReconJson
import kotlinx.serialization.encodeToString
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/** Can this phone do AR capture? */
enum class ArSupport { CHECKING, SUPPORTED, NEEDS_INSTALL, UNSUPPORTED }

object ArAvailability {
    fun check(context: Context): ArSupport = try {
        val a = ArCoreApk.getInstance().checkAvailability(context)
        when {
            a.isTransient -> ArSupport.CHECKING
            a == ArCoreApk.Availability.SUPPORTED_INSTALLED -> ArSupport.SUPPORTED
            a == ArCoreApk.Availability.SUPPORTED_APK_TOO_OLD || a == ArCoreApk.Availability.SUPPORTED_NOT_INSTALLED -> ArSupport.NEEDS_INSTALL
            else -> ArSupport.UNSUPPORTED
        }
    } catch (e: Throwable) {
        Log.w("AsBuiltAR", "availability check failed: ${e.javaClass.simpleName}")
        ArSupport.UNSUPPORTED
    }
}

/** HUD state published at <= 15 Hz. */
data class CaptureHud(
    val output: CoachOutput? = null,
    val photos: Int = 0,
    val tracking: String = "Starting camera",
    val imageSize: String = "",
    val depth: Boolean = false,
    val lastShotAtMs: Long = 0,
    val error: String? = null,
    val decision: ShotPlanner.Decision? = null,
)

/**
 * ARCore session + GL renderer for the capture screen. Picks the camera config with the highest CPU
 * image resolution, runs the [CaptureCoach] on every frame (pose, light, depth at the reticle, preview
 * sharpness), and when the [ShotPlanner] says so, saves that frame's full-resolution CPU image as a
 * JPEG (EXIF focal length + orientation) and records the camera pose + intrinsics for poses.json.
 * JPEG encoding happens on a background thread; at most one shot is in flight.
 */
class ArCaptureEngine(
    private val context: Context,
    private val captureDir: File,
    private val captureID: String,
    private val title: String,
    private val onHud: (CaptureHud) -> Unit,
    private val onHaptic: (com.moltstrong.asbuilt.core.coach.CoachHaptic) -> Unit,
) : GLSurfaceView.Renderer {
    var session: Session? = null
        private set
    private val background = BackgroundRenderer()
    private val coach = CaptureCoach()
    private val planner = ShotPlanner()
    private val poses = ArrayList<PhotoPose>()
    private val encoder = Executors.newSingleThreadExecutor()
    private val shotInFlight = AtomicBoolean(false)
    private val photoCounter = AtomicInteger(0)
    private var viewportW = 1
    private var viewportH = 1
    private var displayRotation = 0
    private var depthSupported = false
    private var cpuSize = ""
    private var lastHud = 0L
    private var lastSharp: Float? = null
    private var lastSharpAt = 0L
    @Volatile var scanning = false
        private set
    @Volatile private var error: String? = null
    private var lastShotAtMs = 0L

    val imagesDir: File get() = File(captureDir, "Images")
    val photoCount: Int get() = photoCounter.get()

    /** Creates the session (call from onResume after camera permission). Returns an error message or null. */
    fun createSession(): String? {
        if (session != null) return null
        return try {
            val s = Session(context)
            // Highest CPU image resolution (the photos), back camera, 30 fps preferred.
            val filter = CameraConfigFilter(s).setFacingDirection(CameraConfig.FacingDirection.BACK)
            val configs = s.getSupportedCameraConfigs(filter)
            val best = configs.maxWithOrNull(compareBy<CameraConfig> { it.imageSize.width.toLong() * it.imageSize.height }
                .thenBy { if (it.depthSensorUsage == CameraConfig.DepthSensorUsage.REQUIRE_AND_USE) 1 else 0 })
            if (best != null) s.cameraConfig = best
            cpuSize = best?.let { "${it.imageSize.width}x${it.imageSize.height}" } ?: ""
            val config = Config(s).apply {
                focusMode = Config.FocusMode.AUTO
                updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
                lightEstimationMode = Config.LightEstimationMode.AMBIENT_INTENSITY
                planeFindingMode = Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
                depthSupported = s.isDepthModeSupported(Config.DepthMode.AUTOMATIC)
                depthMode = if (depthSupported) Config.DepthMode.AUTOMATIC else Config.DepthMode.DISABLED
            }
            s.configure(config)
            session = s
            null
        } catch (e: Throwable) {
            Log.e(TAG, "session create failed", e)
            "This phone's AR camera couldn't start (${e.javaClass.simpleName})."
        }
    }

    fun resume(): String? = try {
        session?.resume(); null
    } catch (e: Throwable) {
        Log.e(TAG, "resume failed", e)
        "The camera is busy or unavailable (${e.javaClass.simpleName})."
    }

    fun pause() {
        try {
            session?.pause()
        } catch (_: Throwable) {
        }
    }

    fun close() {
        try {
            session?.close()
        } catch (_: Throwable) {
        }
        session = null
        encoder.shutdown()
    }

    fun setDisplayRotation(rotation: Int) {
        displayRotation = rotation
        try {
            session?.setDisplayGeometry(rotation, viewportW, viewportH)
        } catch (_: Throwable) {
        }
    }

    fun startScanning() {
        scanning = true
        coach.beginScanning()
    }

    fun stopScanning() {
        scanning = false
        coach.endScanning()
    }

    fun dismissFinish() = coach.dismissFinish()

    fun report() = coach.report(photoCounter.get())

    /** Writes poses.json + coach-report.txt; returns the number of photos. */
    fun finish(): Int {
        stopScanning()
        try {
            encoder.submit {}.get() // drain the JPEG queue
        } catch (_: Exception) {
        }
        val file = PosesFile(
            captureID = captureID, title = title, device = "${Build.MANUFACTURER} ${Build.MODEL}",
            arcoreVersion = try {
                context.packageManager.getPackageInfo("com.google.ar.core", 0).versionName
            } catch (_: Exception) {
                null
            },
            depthSupported = depthSupported, photos = synchronized(poses) { poses.toList() },
        )
        try {
            File(captureDir, "poses.json").writeText(ReconJson.encodeToString(file))
            File(captureDir, "coach-report.txt").writeText(report().text(title, coach.thresholds))
        } catch (e: Exception) {
            Log.e(TAG, "couldn't write poses.json", e)
        }
        return photoCounter.get()
    }

    // GLSurfaceView.Renderer

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        try {
            background.createOnGlThread()
            session?.setCameraTextureName(background.textureId)
        } catch (e: Throwable) {
            error = "Camera preview failed to start."
            Log.e(TAG, "gl init", e)
        }
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        viewportW = width
        viewportH = height
        GLES20.glViewport(0, 0, width, height)
        try {
            session?.setDisplayGeometry(displayRotation, width, height)
        } catch (_: Throwable) {
        }
    }

    override fun onDrawFrame(gl: GL10?) {
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)
        val s = session ?: return
        try {
            s.setCameraTextureName(background.textureId)
            val frame = s.update()
            background.draw(frame)
            process(frame)
        } catch (e: Throwable) {
            // Never crash the GL thread: report and keep going (next frame may succeed).
            if (error == null) Log.e(TAG, "frame failed", e)
            error = when (e) {
                is com.google.ar.core.exceptions.CameraNotAvailableException -> "The camera was taken by another app. Close it and come back."
                else -> null
            }
        }
    }

    private fun process(frame: Frame) {
        val camera = frame.camera
        val now = System.currentTimeMillis()
        val t = frame.timestamp / 1e9
        val tracking = when (camera.trackingState) {
            TrackingState.TRACKING -> CoachTracking.NORMAL
            TrackingState.PAUSED -> when (camera.trackingFailureReason) {
                TrackingFailureReason.EXCESSIVE_MOTION -> CoachTracking.EXCESSIVE_MOTION
                TrackingFailureReason.INSUFFICIENT_FEATURES, TrackingFailureReason.INSUFFICIENT_LIGHT -> CoachTracking.INSUFFICIENT_FEATURES
                TrackingFailureReason.NONE -> CoachTracking.INITIALIZING
                else -> CoachTracking.RELOCALIZING
            }
            else -> CoachTracking.NOT_AVAILABLE
        }
        val poseMatrix = FloatArray(16)
        val pose = if (camera.trackingState == TrackingState.TRACKING) {
            camera.pose.toMatrix(poseMatrix, 0); Pose4(poseMatrix.copyOf())
        } else null
        val light = try {
            frame.lightEstimate.takeIf { it.state == com.google.ar.core.LightEstimate.State.VALID }?.pixelIntensity?.let { it * 2000f }
        } catch (_: Throwable) {
            null
        }
        val centerDepth = if (pose != null) centerDepth(frame) else null
        // Preview sharpness every ~150 ms (Y plane of the CPU image, downsampled).
        if (now - lastSharpAt > 150 && pose != null) {
            lastSharpAt = now
            lastSharp = try {
                frame.acquireCameraImage().use { img -> sharpnessOf(img) }
            } catch (_: NotYetAvailableException) {
                lastSharp
            } catch (_: Throwable) {
                null
            }
        }
        val out = coach.update(CoachFrame(t, pose, light, centerDepth, null, tracking, frame.acquirePointCloud().use { it.ids.remaining() }, lastSharp))
        if (out.haptic != com.moltstrong.asbuilt.core.coach.CoachHaptic.NONE) onHaptic(out.haptic)

        var decision: ShotPlanner.Decision? = null
        if (scanning && pose != null) {
            decision = planner.decide(t, pose, out, lastSharp, coach.thresholds.minSharpness, coach.centroid)
            if (decision == ShotPlanner.Decision.SHOOT && shotInFlight.compareAndSet(false, true)) {
                if (takeShot(frame, poseMatrix, centerDepth, out)) {
                    planner.record(t, pose, out.coverage.currentBand, coach.centroid)
                    lastShotAtMs = now
                } else {
                    shotInFlight.set(false)
                }
            }
        }
        if (now - lastHud > 66) {
            lastHud = now
            onHud(CaptureHud(out, photoCounter.get(), trackingText(camera.trackingState, camera.trackingFailureReason), cpuSize,
                depthSupported, lastShotAtMs, error, decision))
        }
    }

    private fun centerDepth(frame: Frame): Float? {
        if (depthSupported) {
            try {
                frame.acquireDepthImage16Bits().use { depth ->
                    val w = depth.width
                    val h = depth.height
                    val plane = depth.planes[0]
                    val buf = plane.buffer.order(java.nio.ByteOrder.nativeOrder())
                    // Median of a small centre patch (mm, 16-bit).
                    val vals = ArrayList<Int>()
                    for (dy in -3..3) for (dx in -3..3) {
                        val x = w / 2 + dx * 2
                        val y = h / 2 + dy * 2
                        val idx = y * plane.rowStride + x * plane.pixelStride
                        val v = buf.getShort(idx).toInt() and 0xffff
                        if (v in 1..8000) vals.add(v)
                    }
                    if (vals.size >= 5) return vals.sorted()[vals.size / 2] / 1000f
                }
            } catch (_: NotYetAvailableException) {
            } catch (_: Throwable) {
            }
        }
        // Fallback: hit test at the screen centre (planes / feature points).
        return try {
            val hits = frame.hitTest(viewportW / 2f, viewportH / 2f)
            hits.firstOrNull()?.distance?.takeIf { it > 0 } ?: 0f
        } catch (_: Throwable) {
            null
        }
    }

    private fun sharpnessOf(img: Image): Float {
        val y = img.planes[0]
        val buf = y.buffer
        val step = maxOf(2, img.width / 320)
        val bytes = ByteArray(buf.remaining())
        buf.get(bytes)
        return Sharpness.laplacianVariance(bytes, img.width, img.height, y.rowStride, y.pixelStride, step)
    }

    /** Copies the CPU image now (frame-bound), encodes the JPEG on [encoder]. */
    private fun takeShot(frame: Frame, poseMatrix: FloatArray, centerDepth: Float?, out: CoachOutput): Boolean {
        val image = try {
            frame.acquireCameraImage()
        } catch (_: NotYetAvailableException) {
            return false
        } catch (e: Throwable) {
            Log.w(TAG, "acquireCameraImage: ${e.javaClass.simpleName}")
            return false
        }
        val nv21: ByteArray
        val w: Int
        val h: Int
        val tsNs = frame.timestamp
        try {
            w = image.width; h = image.height
            nv21 = yuv420ToNv21(image)
        } catch (e: Throwable) {
            Log.w(TAG, "copy image failed: ${e.javaClass.simpleName}")
            return false
        } finally {
            image.close()
        }
        val k = frame.camera.imageIntrinsics
        val focal = k.focalLength
        val pp = k.principalPoint
        val dims = k.imageDimensions
        val intr = Intrinsics(focal[0], focal[1], pp[0], pp[1], dims[0], dims[1]).let { if (dims[0] != w) it.scaledTo(w, h) else it }
        val sharp = lastSharp
        val band = out.coverage.currentBand?.name
        val exifOrientation = exifOrientation()
        encoder.execute {
            try {
                val n = photoCounter.get() + 1
                val name = "IMG_%04d.jpg".format(n)
                imagesDir.mkdirs()
                val file = File(imagesDir, name)
                val tmp = File(imagesDir, "$name.tmp")
                FileOutputStream(tmp).use { fos ->
                    YuvImage(nv21, ImageFormat.NV21, w, h, null).compressToJpeg(Rect(0, 0, w, h), 95, fos)
                }
                writeExif(tmp, intr, exifOrientation)
                if (!tmp.renameTo(file)) throw java.io.IOException("rename failed")
                synchronized(poses) {
                    poses.add(PhotoPose(name, tsNs, poseMatrix.toList(), intr, w, h, exifOrientation, "TRACKING", centerDepth, sharp, band))
                }
                photoCounter.set(n)
            } catch (e: Throwable) {
                Log.e(TAG, "JPEG save failed", e)
                error = "Couldn't save a photo (storage full?)."
            } finally {
                shotInFlight.set(false)
            }
        }
        return true
    }

    private fun writeExif(file: File, k: Intrinsics, orientation: Int) {
        try {
            val exif = ExifInterface(file)
            exif.setAttribute(ExifInterface.TAG_MAKE, Build.MANUFACTURER)
            exif.setAttribute(ExifInterface.TAG_MODEL, Build.MODEL)
            exif.setAttribute(ExifInterface.TAG_ORIENTATION, orientation.toString())
            // Focal length in 35 mm equivalent from fx (36 mm sensor width equivalent).
            val f35 = (k.fx / k.width * 36f).toInt().coerceIn(10, 200)
            exif.setAttribute(ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM, f35.toString())
            exif.setAttribute(ExifInterface.TAG_IMAGE_DESCRIPTION, "AsBuilt Android capture fx=${k.fx} fy=${k.fy} cx=${k.cx} cy=${k.cy}")
            exif.saveAttributes()
        } catch (e: Throwable) {
            Log.w(TAG, "exif: ${e.javaClass.simpleName}")
        }
    }

    /** CPU images are sensor-landscape; in a portrait-locked activity they display rotated 90° (typical back camera). */
    private fun exifOrientation(): Int = when (displayRotation) {
        android.view.Surface.ROTATION_0 -> ExifInterface.ORIENTATION_ROTATE_90
        android.view.Surface.ROTATION_90 -> ExifInterface.ORIENTATION_NORMAL
        android.view.Surface.ROTATION_180 -> ExifInterface.ORIENTATION_ROTATE_270
        else -> ExifInterface.ORIENTATION_ROTATE_180
    }

    private fun trackingText(state: TrackingState, reason: TrackingFailureReason): String = when (state) {
        TrackingState.TRACKING -> "Tracking"
        TrackingState.PAUSED -> when (reason) {
            TrackingFailureReason.NONE -> "Move the phone slowly to start"
            TrackingFailureReason.BAD_STATE -> "AR restarting"
            TrackingFailureReason.INSUFFICIENT_LIGHT -> "Too dark to track"
            TrackingFailureReason.EXCESSIVE_MOTION -> "Moving too fast"
            TrackingFailureReason.INSUFFICIENT_FEATURES -> "Aim at something with more detail"
            TrackingFailureReason.CAMERA_UNAVAILABLE -> "Camera unavailable"
            else -> "Tracking paused"
        }
        TrackingState.STOPPED -> "Tracking stopped"
    }

    companion object {
        private const val TAG = "AsBuiltAR"

        /** YUV_420_888 -> NV21 (handles row/pixel strides). */
        fun yuv420ToNv21(image: Image): ByteArray {
            val w = image.width
            val h = image.height
            val out = ByteArray(w * h * 3 / 2)
            val yPlane = image.planes[0]
            val yBuf = yPlane.buffer
            var pos = 0
            if (yPlane.pixelStride == 1 && yPlane.rowStride == w) {
                yBuf.get(out, 0, w * h); pos = w * h
            } else {
                val row = ByteArray(yPlane.rowStride)
                for (r in 0 until h) {
                    yBuf.position(r * yPlane.rowStride)
                    val len = minOf(yPlane.rowStride, yBuf.remaining())
                    yBuf.get(row, 0, len)
                    for (c in 0 until w) out[pos++] = row[c * yPlane.pixelStride]
                }
            }
            val u = image.planes[1]
            val v = image.planes[2]
            val uBuf = u.buffer
            val vBuf = v.buffer
            for (r in 0 until h / 2) {
                for (c in 0 until w / 2) {
                    val vi = r * v.rowStride + c * v.pixelStride
                    val ui = r * u.rowStride + c * u.pixelStride
                    out[pos++] = vBuf.get(vi)
                    out[pos++] = uBuf.get(ui)
                }
            }
            return out
        }
    }
}

@Suppress("unused")
private fun ByteArrayOutputStream.size64() = size().toLong()
