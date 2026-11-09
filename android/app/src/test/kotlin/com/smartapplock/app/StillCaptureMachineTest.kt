package com.smartapplock.app

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Phase 12 / M2 final security gate A: the intruder still-capture lifecycle
 * (the SAME state machine IntruderEvidenceChannel drives with Camera2),
 * exercised with a deterministic fake Camera2 port.
 *
 * SIMULATED (JVM): the fake models a Looper-backed camera thread — posts
 * after quitWorker() are DROPPED and recorded, exactly how a real quit
 * HandlerThread loses a late CameraDevice callback. Real Camera2 callback
 * delivery, HAL timing and OEM behavior are NOT exercised.
 */
class StillCaptureMachineTest {

    class Dev(val name: String)
    class Sess(val name: String)

    /** Deterministic fake Camera2 port + serial worker with a virtual clock. */
    class FakePort : StillCaptureMachine.Port<Dev, Sess> {
        lateinit var machine: StillCaptureMachine<Dev, Sess>
        private class Task(val at: Long, val seq: Long, val run: () -> Unit, var cancelled: Boolean = false)
        private val tasks = mutableListOf<Task>()
        private var seq = 0L
        var now = 0L
        var quit = false
        var droppedPosts = 0
        val droppedCameraCallbacks = mutableListOf<String>()

        var prepareCalls = 0
        var prepareResult = true
        var prepareThrows = false
        var openCalls = 0
        var openThrows: Exception? = null
        var configureCalls = 0
        var warmups = 0
        var shoots = 0
        var reencodes = 0
        var releaseOutputs = 0
        var quitCalls = 0
        val deviceCloses = mutableMapOf<Dev, Int>()
        val sessionCloses = mutableMapOf<Sess, Int>()
        val openedDevices = mutableListOf<Dev>()
        val deliveredSessions = mutableListOf<Sess>()

        override fun post(task: () -> Unit) {
            if (quit) { droppedPosts++; return }
            tasks += Task(now, seq++, task)
        }

        override fun postDelayed(task: () -> Unit, delayMs: Long): Any {
            val t = Task(now + delayMs, seq++, task)
            if (quit) { droppedPosts++; return t }
            tasks += t
            return t
        }

        override fun cancel(token: Any) {
            (token as Task).cancelled = true
            tasks.remove(token)
        }

        /** Runs every task due at the current time (FIFO by due time, then post order). */
        fun runUntilIdle() {
            while (true) {
                if (quit) { tasks.clear(); return }
                val next = tasks.filter { it.at <= now }.minWithOrNull(compareBy({ it.at }, { it.seq })) ?: return
                tasks.remove(next)
                if (!next.cancelled) next.run()
            }
        }

        fun advance(ms: Long) {
            val target = now + ms
            while (true) {
                runUntilIdle()
                if (quit) return
                val next = tasks.filter { it.at <= target }.minOfOrNull { it.at } ?: break
                now = next
            }
            now = target
            runUntilIdle()
        }

        /** A Camera2 callback: delivered through the camera thread's handler. */
        fun deliver(name: String, cb: () -> Unit) {
            if (quit) { droppedCameraCallbacks += name; return }
            post(cb)
            runUntilIdle()
        }

        override fun prepareOutputs(): Boolean {
            prepareCalls++
            if (prepareThrows) throw IllegalStateException("surface")
            return prepareResult
        }

        override fun openCamera() {
            openCalls++
            openThrows?.let { throw it }
        }

        override fun configure(device: Dev) { configureCalls++ }
        override fun startWarmup(device: Dev, session: Sess) { warmups++ }
        override fun shoot(device: Dev, session: Sess) { shoots++ }
        override fun closeSession(session: Sess) { sessionCloses[session] = (sessionCloses[session] ?: 0) + 1 }
        override fun closeDevice(device: Dev) { deviceCloses[device] = (deviceCloses[device] ?: 0) + 1 }
        override fun releaseOutputs() { releaseOutputs++ }
        override fun quitWorker() { quitCalls++; quit = true }
        override fun reencode(raw: ByteArray): ByteArray? { reencodes++; return raw.reversedArray() }

        fun opened(d: Dev) { openedDevices += d; deliver("onOpened") { machine.onOpened(d) } }
        fun error(d: Dev) { openedDevices += d; deliver("onError") { machine.onOpenError(d) } }
        fun disconnected(d: Dev) { openedDevices += d; deliver("onDisconnected") { machine.onDisconnected(d) } }
        fun configured(s: Sess) { deliveredSessions += s; deliver("onConfigured") { machine.onConfigured(s) } }
    }

    private class Harness {
        val port = FakePort()
        val results = mutableListOf<Pair<ByteArray?, String>>()
        val m = StillCaptureMachine(port, 4_000, 4_000, 700) { b, c -> results += b to c }
            .also { port.machine = it }

        /**
         * No camera remains open and every resource is released exactly once:
         * every device the HAL handed us is closed once, every session closed
         * once, outputs released once (iff preparation was attempted), the
         * worker quit once, no camera callback was lost to a quit worker, and
         * exactly one result was delivered.
         */
        fun assertNoLeaks() {
            assertEquals("exactly one result", 1, results.size)
            for (d in port.openedDevices.distinct()) {
                assertEquals("device ${d.name} closed exactly once", 1, port.deviceCloses[d] ?: 0)
            }
            assertEquals("no unknown device closed", port.openedDevices.distinct().toSet(), port.deviceCloses.keys)
            for (s in port.deliveredSessions.distinct()) {
                assertEquals("session ${s.name} closed exactly once", 1, port.sessionCloses[s] ?: 0)
            }
            assertEquals("outputs released exactly once", if (port.prepareCalls > 0) 1 else 0, port.releaseOutputs)
            assertEquals("worker quit exactly once", 1, port.quitCalls)
            assertEquals("no camera callback dropped", emptyList<String>(), port.droppedCameraCallbacks)
            assertTrue(m.isFinished)
        }

        fun code() = results.single().second
    }

    // ---- 1. onPause before openCamera starts --------------------------------
    @Test fun abortBeforeOpenStarts_neverOpensTheCamera() {
        val h = Harness()
        h.m.start()
        h.m.abort("aborted") // MainActivity.onPause before the worker ran start
        h.port.runUntilIdle()
        assertEquals(0, h.port.prepareCalls)
        assertEquals(0, h.port.openCalls)
        assertEquals("aborted", h.code())
        h.assertNoLeaks()
    }

    // ---- 2 + 3. onPause while openCamera is pending; late onOpened --------
    @Test fun abortWhileOpenPending_thenLateOnOpened_closesDeviceAndQuitsOnce() {
        val h = Harness()
        h.m.start(); h.port.runUntilIdle()
        assertEquals(1, h.port.openCalls)
        h.m.abort("aborted"); h.port.runUntilIdle()
        assertEquals("aborted", h.code())
        assertEquals(1, h.port.releaseOutputs)
        assertEquals("worker kept alive while open is pending", 0, h.port.quitCalls)
        val d = Dev("front")
        h.port.opened(d)
        assertEquals(1, h.port.deviceCloses[d])
        assertEquals("no session configured after abort", 0, h.port.configureCalls)
        assertEquals(0, h.port.shoots)
        h.assertNoLeaks()
    }

    // ---- 4. late onError after abort ------------------------------------------
    @Test fun lateOnErrorAfterAbort_closesDeviceAndQuitsOnce() {
        val h = Harness()
        h.m.start(); h.port.runUntilIdle()
        h.m.abort(); h.port.runUntilIdle()
        val d = Dev("front")
        h.port.error(d)
        assertEquals("aborted", h.code())
        assertEquals(0, h.port.configureCalls)
        h.assertNoLeaks()
    }

    // ---- 5. late onDisconnected after abort ---------------------------------
    @Test fun lateOnDisconnectedAfterAbort_closesDeviceAndQuitsOnce() {
        val h = Harness()
        h.m.start(); h.port.runUntilIdle()
        h.m.abort(); h.port.runUntilIdle()
        h.port.disconnected(Dev("front"))
        assertEquals("aborted", h.code())
        h.assertNoLeaks()
    }

    // ---- 6. open timeout followed by late onOpened ---------------------------
    @Test fun openTimeoutThenLateOnOpened_closesDeviceNoCapture() {
        val h = Harness()
        h.m.start(); h.port.runUntilIdle()
        h.port.advance(3_999)
        assertTrue(h.results.isEmpty())
        h.port.advance(1)
        assertEquals("timeout", h.code())
        assertEquals(0, h.port.quitCalls)
        val d = Dev("front")
        h.port.opened(d)
        assertEquals(0, h.port.configureCalls)
        assertEquals(0, h.port.shoots)
        h.assertNoLeaks()
    }

    // ---- 7. capture timeout -----------------------------------------------------
    @Test fun captureTimeout_noImage_everythingClosedOnce_lateFrameIgnored() {
        val h = Harness()
        h.m.start(); h.port.runUntilIdle()
        val d = Dev("front"); val s = Sess("s1")
        h.port.opened(d)
        h.port.configured(s)
        assertEquals(1, h.port.warmups)
        h.port.advance(700)
        assertEquals(1, h.port.shoots)
        h.port.advance(3_299)
        assertTrue("not yet", h.results.isEmpty())
        h.port.advance(1) // 4 000 ms after open
        assertEquals("timeout", h.code())
        h.assertNoLeaks()
        // A frame that raced the timeout is never encoded or delivered.
        h.m.onImage(byteArrayOf(1, 2, 3))
        assertEquals(0, h.port.reencodes)
        assertEquals(1, h.results.size)
    }

    @Test fun openTimeoutCancelledOnceOpened() {
        val h = Harness()
        h.m.start(); h.port.runUntilIdle()
        h.port.opened(Dev("front"))
        h.port.configured(Sess("s"))
        h.port.advance(700)
        h.m.onImage(byteArrayOf(9)); h.port.runUntilIdle()
        assertEquals("", h.code())
        h.port.advance(10_000) // stale timeouts must not fire anything
        assertEquals(1, h.results.size)
        h.assertNoLeaks()
    }

    // ---- 8. onDestroy during open and during capture ------------------------
    @Test fun destroyDuringOpen() {
        val h = Harness()
        h.m.start(); h.port.runUntilIdle()
        h.m.abort("aborted") // onActivityDestroyed -> onActivityPaused -> abort
        h.port.runUntilIdle()
        h.port.opened(Dev("late"))
        h.assertNoLeaks()
    }

    @Test fun destroyDuringWarmup_noStillRequestIsIssued() {
        val h = Harness()
        h.m.start(); h.port.runUntilIdle()
        h.port.opened(Dev("front"))
        h.port.configured(Sess("s"))
        h.port.advance(300)
        h.m.abort("aborted"); h.port.runUntilIdle()
        h.port.advance(5_000)
        assertEquals("capture must not continue after abort", 0, h.port.shoots)
        assertEquals("aborted", h.code())
        h.assertNoLeaks()
    }

    /** Abort arrives (another thread) when the warm-up timer is ALREADY due on the worker queue. */
    @Test fun abortRacingTheQueuedShootTask_noStillRequestIsIssued() {
        val h = Harness()
        h.m.start(); h.port.runUntilIdle()
        h.port.opened(Dev("front"))
        h.port.configured(Sess("s"))
        h.port.now = 700 // shoot task is due but has not run yet
        h.m.abort("aborted") // cleanup is queued BEHIND the shoot task
        h.port.runUntilIdle()
        assertEquals("capture must not continue after abort", 0, h.port.shoots)
        assertEquals("aborted", h.code())
        h.assertNoLeaks()
    }

    /** Abort arrives while onOpened is already queued on the camera thread. */
    @Test fun abortRacingAQueuedOnOpened_closesDeviceQuitsOnce() {
        val h = Harness()
        h.m.start(); h.port.runUntilIdle()
        val d = Dev("front")
        h.port.openedDevices += d
        h.port.post { h.m.onOpened(d) } // queued, not yet run
        h.m.abort("aborted")
        h.port.runUntilIdle()
        assertEquals(0, h.port.configureCalls)
        assertEquals("aborted", h.code())
        h.assertNoLeaks()
    }

    @Test fun destroyAfterShot_lateImageNotEncoded() {
        val h = Harness()
        h.m.start(); h.port.runUntilIdle()
        h.port.opened(Dev("front"))
        h.port.configured(Sess("s"))
        h.port.advance(700)
        assertEquals(1, h.port.shoots)
        h.m.abort("aborted")
        h.m.onImage(byteArrayOf(1)) // frame lands between abort and cleanup
        h.port.runUntilIdle()
        assertEquals(0, h.port.reencodes)
        assertEquals("aborted", h.code())
        h.assertNoLeaks()
    }

    // ---- 9. repeated abort calls ------------------------------------------------
    @Test fun repeatedAbortsAreIdempotent() {
        val h = Harness()
        h.m.start(); h.port.runUntilIdle()
        h.port.opened(Dev("front"))
        repeat(5) { h.m.abort("aborted") }
        h.port.runUntilIdle()
        h.m.abort("cancelled")
        h.port.runUntilIdle()
        assertEquals("aborted", h.code())
        h.assertNoLeaks()
    }

    @Test fun concurrentAbortsFromManyThreadsDeliverOneResult() {
        repeat(50) {
            val h = Harness()
            h.m.start(); h.port.runUntilIdle()
            val pool = Executors.newFixedThreadPool(8)
            val go = CountDownLatch(1)
            val calls = AtomicInteger()
            repeat(8) { pool.execute { go.await(); h.m.abort("aborted"); calls.incrementAndGet() } }
            go.countDown()
            pool.shutdown()
            assertTrue(pool.awaitTermination(5, TimeUnit.SECONDS))
            assertEquals(8, calls.get())
            h.port.runUntilIdle()
            h.port.opened(Dev("late"))
            h.assertNoLeaks()
        }
    }

    // ---- 10. exactly-once resource handling: other orderings ---------------
    @Test fun happyPath_deliversBytesAndReleasesEverythingOnce() {
        val h = Harness()
        h.m.start(); h.port.runUntilIdle()
        h.port.opened(Dev("front"))
        h.port.configured(Sess("s"))
        h.port.advance(700)
        h.m.onImage(byteArrayOf(1, 2, 3)); h.port.runUntilIdle()
        assertArrayEquals(byteArrayOf(3, 2, 1), h.results.single().first)
        assertEquals(1, h.port.reencodes)
        h.assertNoLeaks()
    }

    @Test fun lateDisconnectOfAdoptedDeviceAfterAbort_isNotClosedTwice() {
        val h = Harness()
        h.m.start(); h.port.runUntilIdle()
        val d = Dev("front")
        h.port.opened(d)
        h.m.abort(); h.port.runUntilIdle()
        assertEquals(1, h.port.deviceCloses[d])
        // Worker already quit: model the callback racing cleanup instead.
        h.m.onDisconnected(d)
        h.m.onOpenError(d)
        assertEquals(1, h.port.deviceCloses[d])
        h.assertNoLeaks()
    }

    @Test fun lateOnConfiguredAfterAbort_sessionClosedNoWarmup() {
        val h = Harness()
        h.m.start(); h.port.runUntilIdle()
        h.port.opened(Dev("front"))
        val s = Sess("late")
        h.m.abort()
        // onConfigured queued before cleanup ran
        h.port.deliveredSessions += s
        h.m.onConfigured(s)
        h.port.runUntilIdle()
        assertEquals(0, h.port.warmups)
        h.assertNoLeaks()
    }

    @Test fun deviceDisconnectedMidCapture_failsAndClosesOnce() {
        val h = Harness()
        h.m.start(); h.port.runUntilIdle()
        val d = Dev("front")
        h.port.opened(d)
        h.port.configured(Sess("s"))
        h.port.deliver("onDisconnected") { h.m.onDisconnected(d) }
        h.port.runUntilIdle()
        assertEquals("camera_busy", h.code())
        h.assertNoLeaks()
    }

    @Test fun openErrorWhileOpening_failsAndClosesOnce() {
        val h = Harness()
        h.m.start(); h.port.runUntilIdle()
        h.port.error(Dev("front"))
        h.port.runUntilIdle()
        assertEquals("camera_error", h.code())
        h.assertNoLeaks()
    }

    @Test fun securityExceptionOnOpen_reportsPermissionAndQuits() {
        val h = Harness()
        h.port.openThrows = SecurityException("revoked")
        h.m.start(); h.port.runUntilIdle(); h.port.runUntilIdle()
        assertEquals("permission", h.code())
        h.assertNoLeaks()
    }

    @Test fun noFrontCamera_and_prepareThrows_releaseOutputsOnce() {
        val a = Harness().apply { port.prepareResult = false }
        a.m.start(); a.port.runUntilIdle()
        assertEquals("unavailable", a.code())
        assertEquals(0, a.port.openCalls)
        a.assertNoLeaks()
        val b = Harness().apply { port.prepareThrows = true }
        b.m.start(); b.port.runUntilIdle()
        assertEquals("unavailable", b.code())
        b.assertNoLeaks()
    }

    @Test fun configureFailure_failsAndClosesOnce() {
        val h = Harness()
        h.m.start(); h.port.runUntilIdle()
        h.port.opened(Dev("front"))
        h.port.deliver("onConfigureFailed") { h.m.onConfigureFailed() }
        assertEquals("camera_error", h.code())
        h.assertNoLeaks()
    }
}
