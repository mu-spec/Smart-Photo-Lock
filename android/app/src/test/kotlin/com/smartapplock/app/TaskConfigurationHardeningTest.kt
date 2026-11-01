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
 * Phase 6 / Milestone 2 — Task & Configuration Hardening (pure native policy
 * plus static source contracts).
 *
 * M2-F1 (Recents / task switching, M1 Concern 3): the detectors drop Smart
 * App Lock's own package, so a direct protected app -> Smart App Lock UI
 * switch was never a leave. `MainActivity.onResume` now applies
 * [OwnUiForegroundPolicy] through [ProtectionAccessState.observeForeground].
 *
 * M2-F2 (split screen / multi-window): a challenge sharing the screen could
 * release the shield while the protected app stayed visible beside it.
 * [MultiWindowChallengePolicy] keeps or raises the shield in multi-window.
 *
 * JVM policy tests and source contracts only. Nothing here runs Android, an
 * Activity lifecycle, Recents, split screen, freeform, rotation or a
 * launcher, and nothing here is evidence of device behaviour.
 */
class TaskConfigurationHardeningTest {
    private val locked = "com.whatsapp"
    private val otherLocked = "com.example.bank"
    private val launcher = "com.example.launcher"
    private val recents = "com.android.systemui"
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

    private fun report(packageName: String, now: Long): ProtectionAccessState.Decision =
        ProtectionAccessState.observeForeground(
            packageName = packageName,
            protected = packageName in protectedSet,
            nowElapsedMs = now,
        )

    /** `WatcherService.onOwnUiResumed`, with the store reads as arguments. */
    private fun ownUiResumed(
        now: Long,
        enabled: Boolean = true,
        pending: Boolean = false,
        pendingPackageAtPause: String? = null,
    ) {
        if (!OwnUiForegroundPolicy.isLeave(
                enabled,
                pending,
                pendingPackageAtPause,
                ProtectionAccessState.currentForegroundPackage(),
            )
        ) {
            return
        }
        ProtectionAccessState.observeForeground(own, protected = false, nowElapsedMs = now)
    }

    // -- Policies -------------------------------------------------------------

    @Test
    fun ownUiPolicyTruthTable() {
        val snapshots = listOf(null, "", locked)
        val currents = listOf(null, locked, otherLocked, own)
        for (enabled in listOf(false, true)) {
            for (pending in listOf(false, true)) {
                for (atPause in snapshots) {
                    for (current in currents) {
                        val freshGrant = !atPause.isNullOrBlank() && atPause == current
                        assertEquals(
                            "enabled=$enabled pending=$pending atPause=$atPause current=$current",
                            enabled && !pending && !freshGrant,
                            OwnUiForegroundPolicy.isLeave(enabled, pending, atPause, current),
                        )
                    }
                }
            }
        }
    }

    @Test
    fun multiWindowPolicyTruthTables() {
        assertTrue(MultiWindowChallengePolicy.mayReleaseShield(inMultiWindow = false))
        assertFalse(MultiWindowChallengePolicy.mayReleaseShield(inMultiWindow = true))
        for (mw in listOf(false, true)) {
            for (pending in listOf(false, true)) {
                assertEquals(
                    "mw=$mw pending=$pending",
                    mw && pending,
                    MultiWindowChallengePolicy.mustReshield(mw, pending),
                )
            }
        }
        for (resumed in listOf(false, true)) {
            for (ready in listOf(false, true)) {
                for (mw in listOf(false, true)) {
                    assertEquals(
                        "resumed=$resumed ready=$ready mw=$mw",
                        resumed && ready && !mw,
                        MultiWindowChallengePolicy.suppressDuplicateRecovery(resumed, ready, mw),
                    )
                }
            }
        }
    }

    /** The H-1 policy is unchanged; multi-window is an additional gate. */
    @Test
    fun challengeReadyPolicyIsUnchangedAndTheMultiWindowGateOnlyNarrowsIt() {
        for (resumed in listOf(false, true)) {
            for (keyguard in listOf(false, true)) {
                for (matches in listOf(false, true)) {
                    val base = ChallengeReadyPolicy.canHandOff(resumed, keyguard, matches)
                    assertEquals(resumed && !keyguard && matches, base)
                    for (mw in listOf(false, true)) {
                        val gated = base && MultiWindowChallengePolicy.mayReleaseShield(mw)
                        // Never more permissive than the base policy.
                        assertTrue(!gated || base)
                        if (mw) assertFalse(gated)
                    }
                }
            }
        }
    }

    // -- M2-F1: own UI as a foreground change ---------------------------------

    @Test
    fun baselineGapWithoutTheHookProtectedToOwnUiKeptTheGrant() {
        // RED reproduction of M1 Concern 3 at the policy level: the own
        // package is never reported, so without the onResume hook the
        // return to the protected app is a same-package observation.
        ProtectionAccessState.authorize(locked, window, T0)
        assertEquals(ProtectionAccessState.Decision.ALLOW, report(locked, T0 + 10))
        // ... user switches to Smart App Lock's own UI: nothing observed ...
        assertEquals(ProtectionAccessState.Decision.ALLOW, report(locked, T0 + 5_000))
    }

    @Test
    fun graceZeroProtectedToOwnUiRevokesImmediately() {
        ProtectionAccessState.authorize(locked, window, T0)
        assertEquals(ProtectionAccessState.Decision.ALLOW, report(locked, T0 + 10))
        ownUiResumed(T0 + 100)
        assertEquals(own, ProtectionAccessState.currentForegroundPackage())
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(locked, T0 + 200))
        // Fail closed afterwards as well: no revival.
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(locked, T0 + 300))
    }

    @Test
    fun configuredGraceAppliesToTheOwnUiLeaveLikeAnyOtherApp() {
        ProtectionAccessState.setGracePeriod(5_000L)
        ProtectionAccessState.authorize(locked, window, T0)
        ownUiResumed(T0 + 100)
        assertEquals(ProtectionAccessState.Decision.ALLOW, report(locked, T0 + 4_000))

        reset()
        ProtectionAccessState.setGracePeriod(5_000L)
        ProtectionAccessState.authorize(locked, window, T0)
        ownUiResumed(T0 + 100)
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(locked, T0 + 5_100))
    }

    @Test
    fun ownUiIsNotALeaveWhileAChallengeIsPendingOrBeingReturnedTo() {
        ProtectionAccessState.authorize(locked, window, T0)
        ownUiResumed(T0 + 100, pending = true)
        assertEquals(locked, ProtectionAccessState.currentForegroundPackage())
        // Credential screen returned to the challenge host after the exact
        // grant for the ticket that was pending at the pause.
        ownUiResumed(T0 + 200, pendingPackageAtPause = locked)
        assertEquals(locked, ProtectionAccessState.currentForegroundPackage())
        // launchApp: the fresh grant survives.
        assertEquals(ProtectionAccessState.Decision.ALLOW, report(locked, T0 + 300))
        // Protection disabled: nothing to enforce, nothing observed.
        ownUiResumed(T0 + 400, enabled = false)
        assertEquals(locked, ProtectionAccessState.currentForegroundPackage())
    }

    /**
     * Final gate: the pause-time snapshot names a ticket that was abandoned,
     * and the user then re-entered ANOTHER app within its grace. A direct
     * switch from that app to our UI must still be a leave.
     */
    @Test
    fun staleSnapshotNeverSuppressesTheLeaveOfAnotherApp() {
        ProtectionAccessState.setGracePeriod(30_000L)
        ProtectionAccessState.authorize(otherLocked, window, T0)
        // otherLocked -> locked (challenge; otherLocked away in grace). Our
        // Activity pauses with locked's ticket pending; it is abandoned.
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(locked, T0 + 100))
        report(launcher, T0 + 200)
        // Re-entry within grace (standard), then straight to our own UI.
        assertEquals(ProtectionAccessState.Decision.ALLOW, report(otherLocked, T0 + 1_000))
        ownUiResumed(T0 + 2_000, pendingPackageAtPause = locked)
        assertEquals(own, ProtectionAccessState.currentForegroundPackage())
        // The away clock started at the own-UI switch: allowed inside grace,
        // challenged after it (no unbounded same-package slide).
        assertEquals(
            ProtectionAccessState.Decision.CHALLENGE,
            report(otherLocked, T0 + 2_000 + 30_000),
        )
    }

    @Test
    fun ownUiObservationNeverCreatesAuthorizationOrTouchesTheHandoff() {
        val ticket = ProtectionStateStore.PendingChallenge(otherLocked, 4L)
        ProtectionRuntime.markChallengeReady(ticket)
        ownUiResumed(T0 + 100)
        ownUiResumed(T0 + 200)
        assertEquals(ticket, ProtectionRuntime.readyChallenge())
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(locked, T0 + 300))
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(otherLocked, T0 + 400))
    }

    @Test
    fun recentsAndLauncherStillRevokeAsBefore() {
        ProtectionAccessState.authorize(locked, window, T0)
        assertEquals(ProtectionAccessState.Decision.ALLOW, report(recents, T0 + 100))
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(locked, T0 + 200))

        reset()
        ProtectionAccessState.authorize(locked, window, T0)
        report(launcher, T0 + 100)
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(locked, T0 + 200))
    }

    @Test
    fun protectedToProtectedToProtectedNeverReusesASession() {
        ProtectionAccessState.authorize(locked, window, T0)
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(otherLocked, T0 + 100))
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(locked, T0 + 200))

        reset()
        ProtectionAccessState.authorize(locked, window, T0)
        report(recents, T0 + 50)
        ownUiResumed(T0 + 60)
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(otherLocked, T0 + 100))
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(locked, T0 + 200))
    }

    @Test
    fun rapidProtectedOwnUiSwitchingNeverAllowsAfterTheFirstLeave() {
        ProtectionAccessState.authorize(locked, window, T0)
        assertEquals(ProtectionAccessState.Decision.ALLOW, report(locked, T0 + 1))
        var t = T0 + 2
        repeat(25) {
            ownUiResumed(t)
            assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(locked, t + 1))
            t += 2
        }
    }

    @Test
    fun exactGrantIsUsedAtLaunchThenBackToOwnUiRevokes() {
        // Authenticate -> authorizePackage -> route pop -> launchApp: the
        // Activity does not resume in between, so the grant is used once.
        ProtectionAccessState.authorize(locked, window, T0)
        assertEquals(ProtectionAccessState.Decision.ALLOW, report(locked, T0 + 50))
        // Back from the launched task returns to our own UI: revoked.
        ownUiResumed(T0 + 1_000)
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(locked, T0 + 1_100))
    }

    // -- M2-F2: multi-window hand-off (pure replay) ---------------------------

    /** `OverlayStatusChannel.markChallengeReady` acceptance, minus I/O. */
    private fun ack(
        ticket: ProtectionStateStore.PendingChallenge,
        pending: ProtectionStateStore.PendingChallenge?,
        inMultiWindow: Boolean,
        keyguardLocked: Boolean = false,
    ): Boolean {
        val exact = pending?.takeIf {
            it.packageName == ticket.packageName && it.generation == ticket.generation
        }
        val accepted = ChallengeReadyPolicy.canHandOff(
            activityResumed = ProtectionRuntime.activityResumed,
            keyguardLocked = keyguardLocked,
            pendingMatches = exact != null,
        ) && MultiWindowChallengePolicy.mayReleaseShield(inMultiWindow)
        if (accepted) ProtectionRuntime.markChallengeReady(exact!!)
        return accepted
    }

    /** `WatcherService.onChallengeActivityMultiWindow`, minus the shield. */
    private fun multiWindowChanged(inMultiWindow: Boolean, protectedPending: Boolean): Boolean {
        ProtectionRuntime.activityInMultiWindow = inMultiWindow
        val reshield = MultiWindowChallengePolicy.mustReshield(inMultiWindow, protectedPending)
        if (reshield) ProtectionRuntime.invalidateChallengeHandoff()
        return reshield
    }

    @Test
    fun aChallengeInMultiWindowCanNeverBeHandedOffOrAuthorized() {
        val ticket = ProtectionStateStore.PendingChallenge(locked, 9L)
        ProtectionRuntime.activityResumed = true
        assertFalse(ack(ticket, ticket, inMultiWindow = true))
        assertNull(ProtectionRuntime.readyChallenge())
        // authorizePackage needs the exact consumed hand-off.
        assertFalse(ProtectionRuntime.consumeChallengeHandoff(locked, 9L))
    }

    @Test
    fun enteringMultiWindowWithdrawsAnEarlierHandoff() {
        val ticket = ProtectionStateStore.PendingChallenge(locked, 9L)
        ProtectionRuntime.activityResumed = true
        assertTrue(ack(ticket, ticket, inMultiWindow = false))
        assertEquals(ticket, ProtectionRuntime.readyChallenge())
        assertTrue(multiWindowChanged(inMultiWindow = true, protectedPending = true))
        assertNull(ProtectionRuntime.readyChallenge())
        assertFalse(ProtectionRuntime.consumeChallengeHandoff(locked, 9L))
        // The protected app reported in the other window is re-covered.
        assertFalse(
            MultiWindowChallengePolicy.suppressDuplicateRecovery(
                ProtectionRuntime.activityResumed,
                ProtectionRuntime.isChallengeReady(ticket),
                ProtectionRuntime.activityInMultiWindow,
            ),
        )
        // Back to full screen: a fresh acknowledgement is accepted again.
        assertFalse(multiWindowChanged(inMultiWindow = false, protectedPending = true))
        assertTrue(ack(ticket, ticket, inMultiWindow = false))
        assertTrue(ProtectionRuntime.consumeChallengeHandoff(locked, 9L))
    }

    @Test
    fun multiWindowNeverAffectsAnUnrelatedOrStaleTicket() {
        val ticket = ProtectionStateStore.PendingChallenge(locked, 9L)
        val stale = ProtectionStateStore.PendingChallenge(locked, 8L)
        ProtectionRuntime.activityResumed = true
        assertFalse(ack(stale, ticket, inMultiWindow = false))
        assertFalse(ack(ticket, null, inMultiWindow = false))
        assertFalse(multiWindowChanged(inMultiWindow = true, protectedPending = false))
        // A ready ticket is suppressed as a duplicate only in full screen.
        ProtectionRuntime.markChallengeReady(ticket)
        assertTrue(MultiWindowChallengePolicy.suppressDuplicateRecovery(true, true, false))
        assertFalse(MultiWindowChallengePolicy.suppressDuplicateRecovery(true, true, true))
    }

    // -- Static source contracts (wiring the JVM cannot execute) -------------

    private fun source(name: String): String {
        val relative = "src/main/kotlin/com/smartapplock/app/$name"
        val file = listOf(File(relative), File("android/app/$relative"))
            .firstOrNull { it.isFile }
        assertNotNull("$name not found from ${File(".").absolutePath}", file)
        return file!!.readText()
    }

    private fun manifest(): String {
        val relative = "src/main/AndroidManifest.xml"
        val file = listOf(File(relative), File("android/app/$relative"))
            .firstOrNull { it.isFile }
        assertNotNull("AndroidManifest.xml not found", file)
        return file!!.readText()
    }

    private fun body(text: String, start: String): String =
        text.substringAfter(start, "").substringBefore("override fun ")

    @Test
    fun mainActivityWiresOwnUiAndMultiWindowHooks() {
        val text = source("MainActivity.kt")
        val onResume = body(text, "override fun onResume(")
        val mw = onResume.indexOf("activityInMultiWindow = isInMultiWindowMode")
        val superResume = onResume.indexOf("super.onResume()")
        val ownUi = onResume.indexOf("WatcherService.onOwnUiResumed(this, pendingPackageAtPause)")
        val reshield = onResume.indexOf("WatcherService.onChallengeActivityMultiWindow(this, isInMultiWindowMode)")
        val accept = onResume.indexOf("acceptRecoveryIntent(intent, \"onResume\")")
        assertTrue("multi-window flag before Flutter resumes", mw in 0 until superResume)
        assertTrue("own-UI hook after super.onResume", ownUi > superResume)
        assertTrue("own-UI hook before recovery intent", ownUi in 0 until accept)
        assertTrue("multi-window re-shield before recovery intent", reshield in 0 until accept)

        val onPause = body(text, "override fun onPause(")
        val abandon = onPause.indexOf("WatcherService.onChallengeActivityPaused(this)")
        val flag = onPause.indexOf(
            "pendingPackageAtPause = ProtectionStateStore.pendingChallenge(this)?.packageName",
        )
        assertTrue("pause-time ticket recorded after F1 abandon", flag > abandon && abandon >= 0)

        val onMw = body(text, "override fun onMultiWindowModeChanged(isInMultiWindowMode: Boolean)")
        assertTrue(onMw.contains("super.onMultiWindowModeChanged(isInMultiWindowMode)"))
        assertTrue(onMw.contains("ProtectionRuntime.activityInMultiWindow = isInMultiWindowMode"))
        assertTrue(onMw.contains("WatcherService.onChallengeActivityMultiWindow(this, isInMultiWindowMode)"))
    }

    @Test
    fun markChallengeReadyRefusesMultiWindowWithoutChangingTheH1Policy() {
        val text = source("OverlayStatusChannel.kt")
        val block = text.substringAfter("\"markChallengeReady\" ->").substringBefore("\"setSecureWindow\" ->")
        assertTrue(block.contains("val inMultiWindow = activity.isInMultiWindowMode"))
        val canHandOff = block.indexOf("ChallengeReadyPolicy.canHandOff(")
        val gate = block.indexOf("MultiWindowChallengePolicy.mayReleaseShield(inMultiWindow)")
        val mark = block.indexOf("ProtectionRuntime.markChallengeReady(")
        val hide = block.indexOf("ProtectionOverlayController.hide()")
        assertTrue("gate joins the acceptance condition", gate > canHandOff && canHandOff >= 0)
        assertTrue("gate precedes the ready mark and shield release", gate < mark && gate < hide)

        val gateSource = source("WakeRecoveryGate.kt")
        assertTrue(
            gateSource.contains(
                "): Boolean = activityResumed && !keyguardLocked && pendingMatches",
            ),
        )
    }

    @Test
    fun watcherServiceWiresDuplicateGuardOwnUiAndReshield() {
        val text = source("WatcherService.kt")
        val recover = text.substringAfter("private fun recoverProtected(").substringBefore("fun foregroundForRecovery")
        assertTrue(recover.contains("MultiWindowChallengePolicy.suppressDuplicateRecovery("))
        assertTrue(recover.contains("inMultiWindow = ProtectionRuntime.activityInMultiWindow"))
        assertFalse(
            "the unconditional duplicate guard is gone",
            Regex("""if \(ProtectionRuntime\.activityResumed &&\s*ProtectionRuntime\.isChallengeReady\(pending\)""")
                .containsMatchIn(recover),
        )

        val ownUi = text.substringAfter("fun onOwnUiResumed(").substringBefore("@Synchronized")
        assertTrue(ownUi.contains("OwnUiForegroundPolicy.isLeave("))
        assertTrue(ownUi.contains("packageName = context.packageName"))
        assertTrue(ownUi.contains("ProtectionAccessState.currentForegroundPackage()"))
        assertTrue(ownUi.contains("protected = false"))
        for (forbidden in listOf("authorize(", "clearPendingChallenge", "hide()", "markChallengeReady")) {
            assertFalse("onOwnUiResumed must not call $forbidden", ownUi.contains(forbidden))
        }

        val reshield = text.substringAfter("fun onChallengeActivityMultiWindow(").substringBefore("fun onChallengeActivityAvailable(")
        val invalidate = reshield.indexOf("ProtectionRuntime.invalidateChallengeHandoff()")
        val show = reshield.indexOf("ProtectionOverlayController.show(context)")
        assertTrue(reshield.contains("MultiWindowChallengePolicy.mustReshield("))
        assertTrue("hand-off withdrawn, then shield raised", invalidate in 0 until show)
        for (forbidden in listOf("authorize(", "clearPendingChallenge", "hide()", "markChallengeReady")) {
            assertFalse("re-shield must not call $forbidden", reshield.contains(forbidden))
        }
        // The detectors still never report our own package (5D).
        assertTrue(text.contains("packageName == context.packageName"))
    }

    @Test
    fun manifestKeepsRotationAndResizeWithoutRecreationAndAddsNoNewModes() {
        val text = manifest()
        val activity = text.substringAfter("android:name=\".MainActivity\"").substringBefore(">")
        val changes = Regex("android:configChanges=\"([^\"]+)\"").find(activity)?.groupValues?.get(1)
        assertNotNull(changes)
        val set = changes!!.split('|').toSet()
        for (required in listOf("orientation", "screenSize", "smallestScreenSize", "screenLayout")) {
            assertTrue("configChanges handles $required", required in set)
        }
        assertFalse(text.contains("resizeableActivity"))
        assertFalse(text.contains("supportsPictureInPicture"))
        assertTrue(activity.contains("android:taskAffinity=\"\""))
    }

    private companion object {
        const val T0 = 3_600_000L
    }
}
