package com.smartapplock.app

import java.util.concurrent.atomic.AtomicBoolean

/**
 * Phase 12 / M2 (final security gate A): the Android-free lifecycle of ONE
 * intruder still capture. [IntruderEvidenceChannel] drives it with real
 * Camera2 objects through a thin [Port] adapter; JVM tests drive it with a
 * deterministic fake. All decisions live here, so the callback state machine
 * that production runs is the one under test.
 *
 * Threading contract:
 *  * every `on*` callback and every task posted via [Port.post] /
 *    [Port.postDelayed] runs on ONE serial worker (the camera thread);
 *  * [start] and [abort] may be called from any thread;
 *  * [done] is invoked EXACTLY ONCE, by whichever thread finishes first.
 *
 * Guarantees (each covered by StillCaptureMachineTest):
 *  * after [abort] / timeout / failure no capture request is issued, no
 *    image is encoded and no second result is delivered;
 *  * an opened camera device is closed exactly once — including a device
 *    that opens AFTER the capture was aborted (late onOpened/onError/
 *    onDisconnected);
 *  * the worker is quit exactly once and never while openCamera() is still
 *    pending (a quit worker would drop the late callback and leak the
 *    camera, leaving the privacy indicator on);
 *  * outputs (reader/surfaces) and the session are released exactly once.
 */
class StillCaptureMachine<D : Any, S : Any>(
    private val port: Port<D, S>,
    private val openTimeoutMs: Long = IntruderDefensePolicy.OPEN_TIMEOUT_MS,
    private val captureTimeoutMs: Long = IntruderDefensePolicy.CAPTURE_TIMEOUT_MS,
    private val warmupMs: Long = IntruderDefensePolicy.AE_SETTLE_MS,
    private val done: (ByteArray?, String) -> Unit,
) {

    /** Platform operations. Called only on the worker unless noted. */
    interface Port<D, S> {
        /** Any thread → worker. Dropped after [quitWorker]. */
        fun post(task: () -> Unit)
        fun postDelayed(task: () -> Unit, delayMs: Long): Any
        fun cancel(token: Any)

        /** Creates the image reader / preview outputs. False = unavailable. */
        fun prepareOutputs(): Boolean

        /** Starts opening the camera; the result arrives via onOpened/onOpenError/onDisconnected. */
        @Throws(SecurityException::class)
        fun openCamera()
        fun configure(device: D)
        fun startWarmup(device: D, session: S)
        fun shoot(device: D, session: S)
        fun closeSession(session: S)
        fun closeDevice(device: D)
        fun releaseOutputs()
        fun quitWorker()
        fun reencode(raw: ByteArray): ByteArray?
    }

    private val finished = AtomicBoolean(false)

    // Worker-confined state.
    private var opening = false
    private var device: D? = null

    // The device we adopted in onOpened, kept after cleanup so a late
    // onDisconnected/onError for it is recognised (cleanup already closed it).
    private var adopted: D? = null
    private var session: S? = null
    private var outputsPrepared = false
    private var cleanedUp = false
    private var workerQuit = false
    private var openTimeout: Any? = null
    private var captureTimeout: Any? = null

    val isFinished: Boolean get() = finished.get()

    /** Any thread. */
    fun start() {
        port.post {
            if (finished.get()) return@post // aborted before we started
            try {
                // Marked BEFORE preparing so partially created outputs are
                // released (exactly once) even if preparation fails or throws.
                outputsPrepared = true
                if (!port.prepareOutputs()) {
                    finish(null, "unavailable")
                    return@post
                }
                openTimeout = port.postDelayed({ finish(null, "timeout") }, openTimeoutMs)
                opening = true
                port.openCamera()
            } catch (_: SecurityException) {
                opening = false
                finish(null, "permission")
            } catch (_: Exception) {
                opening = false
                finish(null, "unavailable")
            }
        }
    }

    /** Any thread; idempotent. */
    fun abort(code: String = "aborted") = finish(null, code)

    // ---- worker callbacks -------------------------------------------------

    fun onOpened(d: D) {
        opening = false
        if (finished.get()) {
            // Aborted / timed out while opening: close at once and release the
            // worker whose quit was deferred by cleanup.
            port.closeDevice(d)
            if (cleanedUp) quitWorkerOnce()
            return
        }
        openTimeout?.let { port.cancel(it) }
        openTimeout = null
        device = d
        adopted = d
        captureTimeout = port.postDelayed({ finish(null, "timeout") }, captureTimeoutMs)
        try {
            port.configure(d)
        } catch (_: Exception) {
            finish(null, "camera_error")
        }
    }

    fun onDisconnected(d: D) = onDeviceLost(d, "camera_busy")

    fun onOpenError(d: D) = onDeviceLost(d, "camera_error")

    private fun onDeviceLost(d: D, code: String) {
        val wasOpening = opening
        opening = false
        if (adopted === d) {
            // Owned device: cleanup closes it (exactly once), whether cleanup
            // already ran or is still to run.
            finish(null, code)
            return
        }
        // Never adopted (failed while opening, or arrived after abort).
        port.closeDevice(d)
        if (finished.get()) {
            if (wasOpening && cleanedUp) quitWorkerOnce()
        } else {
            finish(null, code)
        }
    }

    fun onConfigured(s: S) {
        val d = device
        if (finished.get() || d == null) {
            port.closeSession(s) // late session: never adopted
            return
        }
        session = s
        try {
            port.startWarmup(d, s)
        } catch (_: Exception) {
            finish(null, "camera_error")
            return
        }
        port.postDelayed({ shootIfActive() }, warmupMs)
    }

    fun onConfigureFailed() = finish(null, "camera_error")

    private fun shootIfActive() {
        val d = device
        val s = session
        if (finished.get() || d == null || s == null) return
        try {
            port.shoot(d, s)
        } catch (_: Exception) {
            finish(null, "camera_error")
        }
    }

    fun onImage(raw: ByteArray) {
        if (finished.get()) return // late frame after abort: never encoded
        val bytes = try {
            port.reencode(raw)
        } catch (_: Exception) {
            null
        }
        finish(bytes, "encode")
    }

    // ---- teardown -----------------------------------------------------------

    private fun finish(bytes: ByteArray?, failureCode: String) {
        if (!finished.compareAndSet(false, true)) return
        port.post { cleanup() }
        done(bytes, if (bytes == null) failureCode else "")
    }

    private fun cleanup() {
        if (cleanedUp) return
        cleanedUp = true
        openTimeout?.let { port.cancel(it) }
        captureTimeout?.let { port.cancel(it) }
        openTimeout = null
        captureTimeout = null
        session?.let { port.closeSession(it) }
        session = null
        device?.let { port.closeDevice(it) }
        device = null
        if (outputsPrepared) {
            outputsPrepared = false
            port.releaseOutputs()
        }
        // Keep the worker while openCamera() is pending; the late callback
        // closes the device and quits (onOpened / onDeviceLost).
        if (!opening) quitWorkerOnce()
    }

    private fun quitWorkerOnce() {
        if (workerQuit) return
        workerQuit = true
        port.quitWorker()
    }
}
