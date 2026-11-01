package com.smartapplock.app

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Phase 6 / Milestone 3 — Background Resilience & Bypass Regression (pure
 * native policy plus static source contracts).
 *
 * M3-F1: `WatcherService.onDestroy` while protection is still configured is
 * a system/OEM interruption (AOSP Android 9+ stops a "Restricted" app's
 * foreground service once it idles; the bound Accessibility service keeps
 * the process and the authorization mirror alive). The screen receiver,
 * poll and retry die with the service, so [WatcherTeardownPolicy] revokes
 * every native authorization and grace window, as process death does.
 *
 * The combination tests pair the interruption with M1 (alternate entry /
 * recovery intents) and M2 (own UI, multi-window) rules and with stale,
 * duplicate and rapid reports. Existing single-feature tests are not
 * repeated here.
 *
 * Nothing here runs Android, Battery Saver, Doze, App Standby, the
 * Restricted setting, ColorOS or a foreground-service stop, and nothing here
 * is evidence of device behaviour.
 */
class BackgroundResilienceRegressionTest {
    private val locked = "com.whatsapp"
    private val otherLocked = "com.example.bank"
    private val launcher = "com.example.launcher"
    private val own = "com.smartapplock.app"
    private val protectedSet = setOf(locked, otherLocked)
    private val window = 120_000L

    @Before
    fun reset() {
        ProtectionAccessState.revokeAll()
        ProtectionRuntime.invalidateChallengeHandoff()
        ProtectionRuntime.activityResumed = false
        ProtectionRuntime.activityInMultiWindow = false
        ProtectionAccessState.setGracePeriod(0L)
        ProtectionAccessState.observeForeground(launcher, false, T0)
    }

    private fun report(
        packageName: String,
        now: Long,
        mayRenew: Boolean = true,
    ): ProtectionAccessState.Decision =
        ProtectionAccessState.observeForeground(
            packageName = packageName,
            protected = packageName in protectedSet,
            nowElapsedMs = now,
            mayRenew = mayRenew,
        )

    /** The `WatcherService.onDestroy` authorization effect, as wired. */
    private fun teardown(protectionEnabled: Boolean): WatcherTeardownPolicy.Action {
        val action = WatcherTeardownPolicy.onDestroy(protectionEnabled)
        if (action.revokesAuthorizations) ProtectionAccessState.revokeAll()
        return action
    }

    private fun authorizedInFront(packageName: String = locked, now: Long = T0) {
        ProtectionAccessState.authorize(packageName, window, now)
        assertEquals(ProtectionAccessState.Decision.ALLOW, report(packageName, now + 10))
    }

    // -- WatcherTeardownPolicy ------------------------------------------------

    @Test
    fun `teardown while protection is configured is an interruption that revokes and keeps the shield armed`() {
        val action = WatcherTeardownPolicy.onDestroy(protectionEnabled = true)
        assertEquals(WatcherTeardownPolicy.Action.INTERRUPTED, action)
        assertTrue(action.revokesAuthorizations)
        assertTrue(action.recordsInterruption)
        assertFalse("the shield must stay available to the a11y path", action.disarmsOverlay)
    }

    @Test
    fun `teardown with protection off keeps the pre-M3 behaviour`() {
        val action = WatcherTeardownPolicy.onDestroy(protectionEnabled = false)
        assertEquals(WatcherTeardownPolicy.Action.PROTECTION_DISABLED, action)
        assertTrue(action.disarmsOverlay)
        assertFalse(action.revokesAuthorizations)
        assertFalse(action.recordsInterruption)
    }

    @Test
    fun `a restart clears only the interruption message, never another error`() {
        assertTrue(
            WatcherTeardownPolicy.clearsLastErrorOnStart(
                WatcherTeardownPolicy.INTERRUPTED_MESSAGE,
            ),
        )
        assertFalse(WatcherTeardownPolicy.clearsLastErrorOnStart(null))
        assertFalse(WatcherTeardownPolicy.clearsLastErrorOnStart("Watcher start failed: x"))
        assertFalse(
            WatcherTeardownPolicy.clearsLastErrorOnStart(
                "Protection service could not restart after boot.",
            ),
        )
    }

    // -- Interruption x authorization mirror ----------------------------------

    @Test
    fun `an interruption during authorized use ends the session - the next same-package report challenges`() {
        authorizedInFront()
        teardown(protectionEnabled = true)
        // H-2 sliding cannot revive it: there is nothing left to slide.
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(locked, T0 + 1_000))
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(locked, T0 + 1_001))
    }

    @Test
    fun `an interruption ends a running grace window - a return inside grace challenges`() {
        ProtectionAccessState.setGracePeriod(60_000L)
        authorizedInFront()
        assertEquals(ProtectionAccessState.Decision.ALLOW, report(launcher, T0 + 1_000))
        teardown(protectionEnabled = true)
        // Corroborated Accessibility return well inside the grace window.
        assertEquals(
            ProtectionAccessState.Decision.CHALLENGE,
            report(locked, T0 + 2_000, mayRenew = true),
        )
    }

    @Test
    fun `without the interruption revocation the same return would be re-admitted (control)`() {
        ProtectionAccessState.setGracePeriod(60_000L)
        authorizedInFront()
        report(launcher, T0 + 1_000)
        teardown(protectionEnabled = false) // not an interruption
        assertEquals(ProtectionAccessState.Decision.ALLOW, report(locked, T0 + 2_000))
    }

    @Test
    fun `stale UsageEvents after an interruption and restart cannot renew anything`() {
        ProtectionAccessState.setGracePeriod(60_000L)
        val corroboration = UsageLeaveCorroboration()
        corroboration.onAccessibilityReport(locked, transient = false)
        authorizedInFront()
        report(launcher, T0 + 1_000)
        corroboration.onAccessibilityReport(launcher, transient = false)
        teardown(protectionEnabled = true)
        // The restarted poll returns the historical resume of the protected
        // app; Accessibility last saw the launcher, so it may not renew.
        val mayRenew = corroboration.mayRenewAuthorization(
            packageName = locked,
            protected = true,
            fromUsageEvents = true,
            accessibilityEnabled = { true },
        )
        assertFalse(mayRenew)
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(locked, T0 + 2_000, mayRenew))
        // A later fresh Accessibility report does not resurrect it either.
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(locked, T0 + 2_100, true))
    }

    @Test
    fun `duplicate teardowns and rapid transitions after an interruption never allow a protected app`() {
        ProtectionAccessState.setGracePeriod(30_000L)
        authorizedInFront(locked)
        ProtectionAccessState.authorize(otherLocked, window, T0 + 20)
        teardown(protectionEnabled = true)
        teardown(protectionEnabled = true) // duplicate onDestroy is harmless
        val sequence = listOf(locked, launcher, otherLocked, own, locked, otherLocked, launcher)
        var now = T0 + 100
        repeat(10) {
            for (pkg in sequence) {
                now += 7
                val decision = report(pkg, now)
                if (pkg in protectedSet) {
                    assertEquals("$pkg at $now", ProtectionAccessState.Decision.CHALLENGE, decision)
                }
            }
        }
    }

    // -- Interruption x M1 / M2 rules -----------------------------------------

    @Test
    fun `M1 x M3 - a hostile or stale recovery intent after an interruption only re-raises and never authorizes`() {
        authorizedInFront()
        teardown(protectionEnabled = true)
        val pending = ProtectionStateStore.PendingChallenge(locked, 7L)
        // Deep link / share / shortcut launch: not the recovery action.
        val deepLink = LaunchIntentPolicy.retain(
            action = "android.intent.action.VIEW",
            recoveryAction = MainActivity_ACTION_RECOVER,
            readRecoveryPackage = { locked },
            readRecoveryGeneration = { 7L },
        )
        assertNull(deepLink.recoveryPackage)
        // Hostile extras on the recovery action are dropped, never thrown.
        val hostile = LaunchIntentPolicy.retain(
            action = MainActivity_ACTION_RECOVER,
            recoveryAction = MainActivity_ACTION_RECOVER,
            readRecoveryPackage = { throw ClassCastException("hostile") },
            readRecoveryGeneration = { 7L },
        )
        assertNull(hostile.recoveryPackage)
        // A stale generation from before the interruption does not match.
        assertFalse(RecoveryIntentPolicy.matches(pending, locked, 6L))
        // Whatever the intent did, the protected app still challenges.
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(locked, T0 + 5_000))
    }

    @Test
    fun `M2 x M3 - the own-UI fresh-grant exception keeps nothing once an interruption revoked the grant`() {
        // Ticket pending at pause; authorizePackage set the grant; the
        // service is then interrupted before onResume / launchApp.
        ProtectionAccessState.authorize(locked, window, T0)
        teardown(protectionEnabled = true)
        val isLeave = OwnUiForegroundPolicy.isLeave(
            protectionEnabled = true,
            hasPendingChallenge = false,
            pendingPackageAtPause = locked,
            currentForegroundPackage = ProtectionAccessState.currentForegroundPackage(),
        )
        assertFalse("returning to the fresh-grant host is still not a leave", isLeave)
        // launchApp: the protected app is reported and must re-authenticate.
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(locked, T0 + 500))
    }

    @Test
    fun `M2 x M3 - the pending ticket and hand-off survive an interruption and multi-window still refuses`() {
        val ticket = ProtectionStateStore.PendingChallenge(locked, 3L)
        ProtectionRuntime.markChallengeReady(ticket)
        teardown(protectionEnabled = true)
        assertTrue(ProtectionRuntime.isChallengeReady(ticket))
        assertFalse(MultiWindowChallengePolicy.mayReleaseShield(inMultiWindow = true))
        assertTrue(MultiWindowChallengePolicy.mustReshield(true, hasProtectedPendingChallenge = true))
        // Only the exact ticket consumes the hand-off.
        assertFalse(ProtectionRuntime.consumeChallengeHandoff(locked, 4L))
        assertFalse(ProtectionRuntime.consumeChallengeHandoff(otherLocked, 3L))
        assertTrue(ProtectionRuntime.consumeChallengeHandoff(locked, 3L))
        assertFalse(ProtectionRuntime.consumeChallengeHandoff(locked, 3L))
    }

    // -- R-M3-2: engine teardown while the watcher is down --------------------

    /** The `MainActivity.onDestroy` authorization effect, as wired. */
    private fun engineDetached(watcherRunning: Boolean, protectionEnabled: Boolean = true) {
        if (WatcherTeardownPolicy.revokesOnEngineDetach(protectionEnabled, watcherRunning)) {
            ProtectionAccessState.revokeAll()
        }
    }

    /**
     * Production sequence: the watcher was interrupted (M3-F1 revoked), its
     * restart did not take effect, a NEW authorization was granted through
     * the live engine, the user left the protected app (grace starts), and
     * then the engine went away (Back out of the shell / task removed). With
     * neither screen-off observer alive, a screen cycle changes nothing in
     * native state, and the return happens inside grace.
     */
    private fun rM32Sequence(applyEngineDetachRule: Boolean): ProtectionAccessState.Decision {
        ProtectionAccessState.setGracePeriod(60_000L)
        teardown(protectionEnabled = true) // M3-F1, watcher now down
        ProtectionAccessState.authorize(locked, window, T0 + 1_000) // via the live engine
        assertEquals(ProtectionAccessState.Decision.ALLOW, report(locked, T0 + 1_100))
        // Back to Smart App Lock's shell: OwnUiForegroundPolicy leave, grace starts.
        assertEquals(ProtectionAccessState.Decision.ALLOW, report(own, T0 + 2_000))
        if (applyEngineDetachRule) engineDetached(watcherRunning = false)
        // Back out of the shell -> launcher; screen off/on: no native
        // receiver and no Dart listener, so nothing revokes.
        report(launcher, T0 + 2_500)
        // Wake, unlock keyguard, open the protected app inside grace (fresh
        // Accessibility report, so it is allowed to renew).
        return report(locked, T0 + 30_000, mayRenew = true)
    }

    @Test
    fun `R-M3-2 vulnerable sequence - without the engine-detach rule the return after a screen cycle is ALLOWED`() {
        // Documents the pre-fix behaviour of the mirror (no revocation at
        // engine teardown): this is the fail-open the rule closes.
        assertEquals(ProtectionAccessState.Decision.ALLOW, rM32Sequence(applyEngineDetachRule = false))
    }

    @Test
    fun `R-M3-2 fixed - engine teardown with the watcher down revokes, the return after a screen cycle challenges`() {
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, rM32Sequence(applyEngineDetachRule = true))
    }

    @Test
    fun `R-M3-2 control - while the watcher runs, engine teardown keeps grace and the native receiver still ends it at screen-off`() {
        assertFalse(WatcherTeardownPolicy.revokesOnEngineDetach(true, watcherRunning = true))
        assertFalse(WatcherTeardownPolicy.revokesOnEngineDetach(false, watcherRunning = false))
        assertFalse(WatcherTeardownPolicy.revokesOnEngineDetach(false, watcherRunning = true))
        assertTrue(WatcherTeardownPolicy.revokesOnEngineDetach(true, watcherRunning = false))
        ProtectionAccessState.setGracePeriod(60_000L)
        authorizedInFront()
        report(own, T0 + 1_000)
        engineDetached(watcherRunning = true)
        report(launcher, T0 + 1_500)
        // No screen cycle: grace is honoured exactly as before.
        assertEquals(ProtectionAccessState.Decision.ALLOW, report(locked, T0 + 5_000))
        report(launcher, T0 + 6_000)
        ProtectionAccessState.revokeAll() // watcher SCREEN_OFF receiver
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(locked, T0 + 7_000))
    }

    @Test
    fun `MainActivity onDestroy applies the engine-detach rule and never clears tickets or the shield`() {
        val destroy = body(source("MainActivity.kt"), "override fun onDestroy()")
        assertTrue(
            Regex(
                """WatcherTeardownPolicy\.revokesOnEngineDetach\(\s*protectionEnabled = ProtectionStateStore\.isEnabled\(this\),\s*watcherRunning = WatcherService\.isRunning\(\),\s*\)\s*\)\s*\{\s*ProtectionAccessState\.revokeAll\(\)""",
            ).containsMatchIn(destroy),
        )
        for (forbidden in listOf(
            "clearPendingChallenge",
            "invalidateChallengeHandoff",
            "ProtectionOverlayController",
            "authorize(",
            "WatcherService.start",
        )) {
            assertFalse("MainActivity.onDestroy must not call $forbidden", destroy.contains(forbidden))
        }
    }

    // -- Static source contracts (wiring the JVM cannot execute) --------------

    @Test
    fun `onDestroy applies the teardown policy and never clears the ticket or grants`() {
        val destroy = body(source("WatcherService.kt"), "override fun onDestroy()")
        assertTrue(destroy.contains("WatcherTeardownPolicy.onDestroy(ProtectionStateStore.isEnabled(this))"))
        assertTrue(
            Regex("""if \(action\.revokesAuthorizations\) \{\s*ProtectionAccessState\.revokeAll\(\)""")
                .containsMatchIn(destroy),
        )
        assertTrue(
            Regex("""if \(action\.disarmsOverlay\) \{\s*ProtectionOverlayController\.disarm\(\)""")
                .containsMatchIn(destroy),
        )
        assertTrue(destroy.contains("WatcherTeardownPolicy.INTERRUPTED_MESSAGE"))
        for (forbidden in listOf(
            "clearPendingChallenge",
            "invalidateChallengeHandoff",
            "authorize(",
            "rememberWakeReauthPackage",
            "startForegroundService",
            "startService",
        )) {
            assertFalse("onDestroy must not call $forbidden", destroy.contains(forbidden))
        }
    }

    @Test
    fun `a duplicate onStartCommand restarts one poll, keeps one restart decision and clears only via the policy`() {
        val start = body(source("WatcherService.kt"), "override fun onStartCommand(")
        val clear = start.indexOf("WatcherTeardownPolicy.clearsLastErrorOnStart(")
        val remove = start.indexOf("handler.removeCallbacks(poll)")
        val post = start.indexOf("handler.post(poll)")
        assertTrue(clear >= 0)
        assertTrue(remove in 0 until post)
        assertTrue(start.contains("restoreAfterProcessRestartIfNeeded(this)"))
        assertTrue(start.contains("return START_STICKY"))
        assertTrue(
            source("WatcherService.kt").contains("restartRecoveryLatch.tryAcquire()"),
        )
    }

    @Test
    fun `no battery-exemption flow, keep-alive scheduling or a11y scope change was added`() {
        val manifest = manifest()
        for (permission in listOf(
            "REQUEST_IGNORE_BATTERY_OPTIMIZATIONS",
            "WAKE_LOCK",
            "SCHEDULE_EXACT_ALARM",
            "USE_EXACT_ALARM",
            "QUERY_ALL_PACKAGES",
        )) {
            assertFalse(
                "manifest must not declare $permission",
                manifest.contains("android:name=\"android.permission.$permission\""),
            )
        }
        val native = File(sourceDir()).listFiles { f -> f.name.endsWith(".kt") }!!
            .joinToString("\n") { it.readText() }
        for (api in listOf(
            "ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS",
            "AlarmManager",
            "WorkManager",
            "newWakeLock",
            "setExactAndAllowWhileIdle",
        )) {
            assertFalse("native sources must not use $api", native.contains(api))
        }
        val a11y = resource("xml/accessibility_service_config.xml")
        assertTrue(a11y.contains("android:accessibilityEventTypes=\"typeWindowStateChanged\""))
        assertTrue(a11y.contains("android:canRetrieveWindowContent=\"false\""))
    }

    @Test
    fun `a failed watcher start is reported and Accessibility enforcement does not depend on the service`() {
        val watcher = source("WatcherService.kt")
        val start = watcher.substringAfter("fun start(context: Context): Boolean = try {")
            .substringBefore("fun stop(")
        assertTrue(start.contains("catch (e: Exception)"))
        assertTrue(start.contains("ProtectionStateStore.setLastError(context, \"Watcher start failed:"))
        assertTrue(start.contains("false"))
        val reportBody = watcher.substringAfter("fun reportForeground(")
            .substringBefore("fun setGracePeriod(")
        assertFalse(reportBody.contains("activeInstance ?: return"))
        assertFalse(reportBody.contains("if (!running)"))
        // Pre-existing restart-on-event: it runs only AFTER the report was
        // enforced, so a stopped service never short-circuits enforcement.
        val restart = reportBody.indexOf("if (!isRunning()) start(context)")
        assertTrue(restart > 0)
        assertEquals(restart, reportBody.lastIndexOf("isRunning()") - 5)
        assertTrue(reportBody.indexOf("recoverProtected(") in 0 until restart)
        assertTrue(reportBody.indexOf("ProtectionAccessState.observeForeground(") in 0 until restart)
        val a11y = source("AccessibilityLockService.kt")
        assertTrue(a11y.contains("WatcherService.reportForeground("))
    }

    private fun sourceDir(): String {
        val relative = "src/main/kotlin/com/smartapplock/app"
        val dir = listOf(File(relative), File("android/app/$relative")).firstOrNull { it.isDirectory }
        assertNotNull("source dir not found from ${File(".").absolutePath}", dir)
        return dir!!.path
    }

    private fun source(name: String): String = File(sourceDir(), name).readText()

    private fun manifest(): String {
        val relative = "src/main/AndroidManifest.xml"
        val file = listOf(File(relative), File("android/app/$relative")).firstOrNull { it.isFile }
        assertNotNull("AndroidManifest.xml not found", file)
        return file!!.readText()
    }

    private fun resource(name: String): String {
        val relative = "src/main/res/$name"
        val file = listOf(File(relative), File("android/app/$relative")).firstOrNull { it.isFile }
        assertNotNull("$name not found", file)
        return file!!.readText()
    }

    private fun body(text: String, start: String): String =
        text.substringAfter(start, "").substringBefore("override fun ")
            .substringBefore("private fun ")

    companion object {
        const val T0 = 3_600_000L

        /** `MainActivity.ACTION_RECOVER_CHALLENGE` (MainActivity is not JVM-compilable). */
        val MainActivity_ACTION_RECOVER: String by lazy {
            val relative = "src/main/kotlin/com/smartapplock/app/MainActivity.kt"
            val file = listOf(File(relative), File("android/app/$relative")).first { it.isFile }
            Regex("""ACTION_RECOVER_CHALLENGE\s*=\s*"([^"]+)"""")
                .find(file.readText())!!.groupValues[1]
        }
    }
}
