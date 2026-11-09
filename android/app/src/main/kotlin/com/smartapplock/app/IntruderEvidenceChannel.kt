package com.smartapplock.app

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.PowerManager
import android.view.Surface
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * Phase 12 / M2: owner-opted-in intruder evidence + alarm bridge.
 *
 *  * `cameraPermission` / `requestCameraPermission` — the runtime CAMERA
 *    permission. Dart only requests it from the owner-verified enable flow.
 *  * `captureStill` — ONE front-camera still via framework Camera2, only
 *    while MainActivity (the challenge host) is resumed and the screen is
 *    interactive. No foreground service, no background use, no preview UI,
 *    no audio, no location, no file: the JPEG goes back over the channel in
 *    memory and is re-encoded from a Bitmap (no EXIF survives). Aborted on
 *    pause/destroy; bounded by open/capture timeouts. The system privacy
 *    indicator is shown by Android as usual — nothing here suppresses it.
 *  * `startAlarm` / `stopAlarm` — [IntruderAlarm].
 *
 * Every failure is returned as an error code; nothing here touches
 * authentication, sessions, tickets or the shield.
 */
object IntruderEvidenceChannel {

    const val CHANNEL = "com.smartapplock.app/intruder_evidence"
    const val PERMISSION_REQUEST_CODE = 0x5A1C

    private val main = Handler(Looper.getMainLooper())
    private var pendingPermission: MethodChannel.Result? = null
    private var session: StillCaptureMachine<CameraDevice, CameraCaptureSession>? = null

    fun register(engine: FlutterEngine, activity: MainActivity) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "cameraPermission" -> result.success(permissionState(activity))
                    "requestCameraPermission" -> requestPermission(activity, result)
                    "captureStill" -> {
                        val maxBytes = IntruderDefensePolicy.clampMaxBytes(
                            call.argument<Int>("maxBytes") ?: IntruderDefensePolicy.MAX_MAX_BYTES,
                        )
                        capture(activity, maxBytes, result)
                    }
                    "startAlarm" -> {
                        val ms = call.argument<Number>("durationMs")?.toLong()
                            ?: IntruderDefensePolicy.MAX_ALARM_MS
                        result.success(IntruderAlarm.start(activity, ms))
                    }
                    "abortCapture" -> {
                        session?.abort("cancelled")
                        result.success(null)
                    }
                    "stopAlarm" -> {
                        IntruderAlarm.stop()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("error", "intruder evidence failure", null)
            }
        }
    }

    private fun hasFrontCamera(context: Context): Boolean =
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_FRONT)

    private fun granted(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    private fun permissionState(context: Context): String = when {
        !hasFrontCamera(context) -> "unavailable"
        granted(context) -> "granted"
        else -> "denied"
    }

    private fun requestPermission(activity: MainActivity, result: MethodChannel.Result) {
        val state = permissionState(activity)
        if (state != "denied") {
            result.success(state)
            return
        }
        if (pendingPermission != null) {
            result.success("denied") // one dialog at a time
            return
        }
        pendingPermission = result
        activity.requestPermissions(arrayOf(Manifest.permission.CAMERA), PERMISSION_REQUEST_CODE)
    }

    /** From MainActivity.onRequestPermissionsResult. True when consumed. */
    fun onRequestPermissionsResult(activity: MainActivity, requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val pending = pendingPermission ?: return true
        pendingPermission = null
        val ok = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        pending.success(if (ok && granted(activity)) "granted" else "denied")
        return true
    }

    private fun capture(activity: MainActivity, maxBytes: Int, result: MethodChannel.Result) {
        val power = activity.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val blocked = IntruderDefensePolicy.captureBlockReason(
            permissionGranted = granted(activity),
            hasFrontCamera = hasFrontCamera(activity),
            activityResumed = ProtectionRuntime.activityResumed,
            interactive = power?.isInteractive == true,
            captureInFlight = session != null,
        )
        if (blocked != null) {
            result.error(blocked, blocked, null)
            return
        }
        val port = Camera2Port(activity.applicationContext, maxBytes, displayRotationDegrees(activity))
        lateinit var machine: StillCaptureMachine<CameraDevice, CameraCaptureSession>
        machine = StillCaptureMachine(port) { bytes, code ->
            main.post {
                // Only clear the slot if it is still ours (a late completion of
                // an aborted capture never clears a newer one).
                if (session === machine) session = null
                if (bytes != null) result.success(bytes) else result.error(code, code, null)
            }
        }
        port.machine = machine
        session = machine
        machine.start()
    }

    @Suppress("DEPRECATION")
    private fun displayRotationDegrees(activity: MainActivity): Int = try {
        when (activity.windowManager.defaultDisplay.rotation) {
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }
    } catch (_: Exception) {
        0
    }

    /** MainActivity.onPause: the challenge left the foreground. */
    fun onActivityPaused() {
        session?.abort("aborted")
        IntruderAlarm.stop()
    }

    fun onActivityDestroyed() {
        onActivityPaused()
        pendingPermission?.success("denied")
        pendingPermission = null
    }

    /**
     * Thin Camera2 adapter for [StillCaptureMachine]: owns the Android
     * objects, forwards every callback to the machine on the camera thread,
     * and executes the machine's commands. It makes NO lifecycle decisions.
     */
    private class Camera2Port(
        private val context: Context,
        private val maxBytes: Int,
        private val deviceRotation: Int,
    ) : StillCaptureMachine.Port<CameraDevice, CameraCaptureSession> {
        lateinit var machine: StillCaptureMachine<CameraDevice, CameraCaptureSession>
        private val thread = HandlerThread("intruder-camera").apply { start() }
        private val handler = Handler(thread.looper)
        private var cameraId: String? = null
        private var sensorOrientation = 0
        private var reader: ImageReader? = null
        private var previewTexture: SurfaceTexture? = null
        private var previewSurface: Surface? = null

        override fun post(task: () -> Unit) {
            handler.post(task)
        }

        override fun postDelayed(task: () -> Unit, delayMs: Long): Any {
            val r = Runnable(task)
            handler.postDelayed(r, delayMs)
            return r
        }

        override fun cancel(token: Any) {
            handler.removeCallbacks(token as Runnable)
        }

        override fun prepareOutputs(): Boolean {
            val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val id = manager.cameraIdList.firstOrNull {
                manager.getCameraCharacteristics(it)
                    .get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT
            } ?: return false
            val chars = manager.getCameraCharacteristics(id)
            sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
            val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            val size = IntruderDefensePolicy.chooseSize(
                map?.getOutputSizes(ImageFormat.JPEG)?.map { it.width to it.height }.orEmpty(),
            ) ?: return false
            val r = ImageReader.newInstance(size.first, size.second, ImageFormat.JPEG, 1)
            r.setOnImageAvailableListener({ ir ->
                val raw = try {
                    ir.acquireLatestImage()?.use { image ->
                        val buffer = image.planes[0].buffer
                        ByteArray(buffer.remaining()).also { buffer.get(it) }
                    }
                } catch (_: Exception) {
                    null
                }
                if (raw != null) machine.onImage(raw)
            }, handler)
            reader = r
            val texture = SurfaceTexture(0).apply { setDefaultBufferSize(320, 240) }
            previewTexture = texture
            previewSurface = Surface(texture)
            cameraId = id
            return true
        }

        @SuppressLint("MissingPermission") // checked by captureBlockReason
        override fun openCamera() {
            val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            manager.openCamera(cameraId!!, object : CameraDevice.StateCallback() {
                override fun onOpened(device: CameraDevice) = machine.onOpened(device)
                override fun onDisconnected(device: CameraDevice) = machine.onDisconnected(device)
                override fun onError(device: CameraDevice, error: Int) = machine.onOpenError(device)
            }, handler)
        }

        @Suppress("DEPRECATION") // createCaptureSession(List) is valid on API 24+
        override fun configure(device: CameraDevice) {
            device.createCaptureSession(
                listOf(previewSurface!!, reader!!.surface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(s: CameraCaptureSession) = machine.onConfigured(s)
                    override fun onConfigureFailed(s: CameraCaptureSession) {
                        try {
                            s.close()
                        } catch (_: Exception) {
                        }
                        machine.onConfigureFailed()
                    }
                },
                handler,
            )
        }

        override fun startWarmup(device: CameraDevice, session: CameraCaptureSession) {
            // Short metering warm-up so the still is not black.
            val warm = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                addTarget(previewSurface!!)
            }.build()
            session.setRepeatingRequest(warm, null, handler)
        }

        override fun shoot(device: CameraDevice, session: CameraCaptureSession) {
            val still = device.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE).apply {
                addTarget(reader!!.surface)
                set(CaptureRequest.JPEG_QUALITY, 90.toByte())
            }.build()
            session.capture(still, null, handler)
        }

        override fun closeSession(session: CameraCaptureSession) {
            try {
                session.close()
            } catch (_: Exception) {
            }
        }

        override fun closeDevice(device: CameraDevice) {
            try {
                device.close()
            } catch (_: Exception) {
            }
        }

        override fun releaseOutputs() {
            try {
                reader?.close()
            } catch (_: Exception) {
            }
            reader = null
            previewSurface?.release()
            previewSurface = null
            previewTexture?.release()
            previewTexture = null
        }

        override fun quitWorker() {
            thread.quitSafely()
        }

        /** Decode -> rotate upright -> JPEG without metadata, within maxBytes. */
        override fun reencode(raw: ByteArray): ByteArray? {
            val decoded = BitmapFactory.decodeByteArray(raw, 0, raw.size) ?: return null
            val degrees = IntruderDefensePolicy.rotationDegrees(sensorOrientation, deviceRotation, true)
            val upright = if (degrees == 0) decoded else Bitmap.createBitmap(
                decoded, 0, 0, decoded.width, decoded.height,
                Matrix().apply { postRotate(degrees.toFloat()) }, true,
            )
            try {
                for (q in IntruderDefensePolicy.QUALITY_LADDER) {
                    val out = ByteArrayOutputStream()
                    if (!upright.compress(Bitmap.CompressFormat.JPEG, q, out)) return null
                    val bytes = out.toByteArray()
                    if (bytes.size in 1..maxBytes) return bytes
                }
                return null
            } finally {
                if (upright !== decoded) upright.recycle()
                decoded.recycle()
            }
        }
    }
}
