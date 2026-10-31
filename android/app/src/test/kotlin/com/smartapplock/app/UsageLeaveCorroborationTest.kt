package com.smartapplock.app

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Phase 5 / M2 U1-C regression tests: a stale UsageEvents result (the latest
 * activity resume in a 60 s lookback, not proof of the current foreground)
 * must not erase the protected wake identity or abandon a ready ticket while
 * Accessibility is enabled and has not reported that package.
 *
 * SIMULATED, JVM only. [ReportModel] is a test-side port of the decision
 * chain of `WatcherService.reportForeground` and of its SCREEN_OFF receiver.
 * It drives the REAL production policies ([UsageLeaveCorroboration],
 * [WindowLeavePolicy], [ChallengeAbandonPolicy], [ScreenOffForegroundPolicy],
 * [WakeReauthTargetPolicy], [ProtectionAccessState]); persistence, the
 * overlay, recovery and the safe-exit gate are in-memory stand-ins. This is
 * not device, APK or `WatcherService` execution evidence.
 */
class UsageLeaveCorroborationTest {
    private val locked = "com.whatsapp"
    private val stale = "com.cloudflare.onedotonedotonedotone"
    private val other = "com.example.notes"
    private val home = "com.oppo.launcher"
    private val ime = "com.google.android.inputmethod.latin"

    @Before
    fun resetAccess() {
        ProtectionAccessState.revokeAll()
        ProtectionAccessState.retainProtectedPackages(emptySet())
        ProtectionAccessState.setGracePeriod(0L)
    }

    @After
    fun restoreAccess() = resetAccess()

    /** SIMULATED port of WatcherService.reportForeground + SCREEN_OFF. */
    private inner class ReportModel(
        var accessibilityEnabled: Boolean = true,
        val protectedPackages: Set<String> = setOf(locked),
    ) {
        val corroboration = UsageLeaveCorroboration()
        var wakePackage: String? = null
        var pending: ProtectionStateStore.PendingChallenge? = null
        var ready: ProtectionStateStore.PendingChallenge? = null
        var candidate: ChallengeAbandonCandidate? = null
        var challengeResumed = false
        var screenInteractive = true
        var shieldVisible = false
        var enabledQueries = 0
        private var lastAccessibilityElapsedMs = 0L
        private var generation = 0L

        fun ticket(pkg: String = locked) {
            val t = ProtectionStateStore.PendingChallenge(pkg, ++generation)
            pending = t
            ready = t
            shieldVisible = true
        }

        /**
         * [t] is an offset from a non-zero base: `elapsedRealtime` is never 0,
         * and 0 is the production "no Accessibility report yet" sentinel.
         * [resolves]: whether the Accessibility class resolves to an Activity.
         */
        fun report(pkg: String, a11y: Boolean, t: Long, resolves: Boolean = true): String {
            val now = BASE + t
            if (a11y) {
                corroboration.onAccessibilityReport(
                    pkg,
                    ChallengeAbandonPolicy.isTransientWindow(pkg, ime),
                )
            }
            if (a11y) {
                lastAccessibilityElapsedMs = now
            } else if (lastAccessibilityElapsedMs > 0L &&
                now - lastAccessibilityElapsedMs < AUTHORITY_MS
            ) {
                return "IGNORED"
            }
            val isProtected = pkg in protectedPackages
            if (!isProtected &&
                ScreenOffForegroundPolicy.shouldPreservePending(
                    screenInteractive,
                    pending,
                    wakePackage,
                )
            ) {
                if (pending != null && wakePackage == null) wakePackage = pending!!.packageName
                ProtectionAccessState.revokeAll()
                return "PRESERVE"
            }
            if (isProtected) {
                candidate = null
                wakePackage = pkg
            } else {
                val transient = ChallengeAbandonPolicy.isTransientWindow(pkg, ime)
                val provesNothing = transient || WindowLeavePolicy.provesNothing(
                    transient = false,
                    kind = WindowLeavePolicy.classify(
                        packageName = pkg,
                        fromUsageEvents = !a11y,
                        usageCorroborated = a11y || corroboration.corroborates(pkg) {
                            enabledQueries++
                            accessibilityEnabled
                        },
                        homePackage = home,
                        windowClass = if (a11y) "$pkg.Window" else null,
                        resolveActivity = { p, c -> if (resolves) ResolvedActivity(p, c) else null },
                    ),
                )
                if (ChallengeAbandonPolicy.mayForgetWakeIdentity(false, provesNothing)) {
                    wakePackage = null
                }
                ready?.let { r ->
                    when (
                        ChallengeAbandonPolicy.readyTicketAction(
                            false,
                            provesNothing,
                            challengeResumed,
                            screenInteractive,
                        )
                    ) {
                        ReadyTicketAction.ABANDON -> { ready = null; pending = null }
                        ReadyTicketAction.DEFER -> candidate = ChallengeAbandonCandidate(r, pkg, now)
                        ReadyTicketAction.KEEP -> Unit
                    }
                }
            }
            val decision = ProtectionAccessState.observeForeground(pkg, isProtected, now)
            return if (!isProtected || decision == ProtectionAccessState.Decision.ALLOW) {
                if (pending == null) shieldVisible = false
                "ALLOW"
            } else {
                shieldVisible = true
                "CHALLENGE"
            }
        }

        fun screenOff(): String? {
            ProtectionAccessState.revokeAll()
            val target = WakeReauthTargetPolicy.resolve(
                ProtectionAccessState.currentForegroundPackage(),
                wakePackage,
            ) { it in protectedPackages }
            if (target != null) {
                wakePackage = target
                pending = ProtectionStateStore.PendingChallenge(target, ++generation)
                shieldVisible = true
            }
            screenInteractive = false
            return target
        }
    }

    // -- Tracker (production class, pure) --------------------------------------

    @Test
    fun theTrackerRemembersOnlyTheLatestNonTransientAccessibilityPackage() {
        val c = UsageLeaveCorroboration()
        c.onAccessibilityReport(stale, transient = false)
        c.onAccessibilityReport(locked, transient = false)
        c.onAccessibilityReport("com.android.systemui", transient = true)
        c.onAccessibilityReport(" ", transient = false)
        c.onAccessibilityReport("", transient = false)
        assertTrue(c.corroborates(locked) { true })
        assertFalse(c.corroborates(stale) { true })
    }

    @Test
    fun aFreshTrackerCorroboratesNothingWhileAccessibilityIsEnabled() {
        val c = UsageLeaveCorroboration()
        assertFalse(c.corroborates(stale) { true })
        assertFalse(c.corroborates(home) { true })
    }

    @Test
    fun accessibilityDisabledCorroboratesEveryNonBlankPackage() {
        val c = UsageLeaveCorroboration()
        c.onAccessibilityReport(locked, transient = false)
        assertTrue(c.corroborates(stale) { false })
        assertFalse(c.corroborates(" ") { false })
        assertFalse(c.corroborates("") { false })
    }

    @Test
    fun aMatchingReportCorroboratesWithoutReadingTheEnabledSetting() {
        val c = UsageLeaveCorroboration()
        c.onAccessibilityReport(other, transient = false)
        var queries = 0
        assertTrue(c.corroborates(other) { queries++; true })
        assertEquals(0, queries)
        assertFalse(c.corroborates(stale) { queries++; true })
        assertEquals(1, queries)
    }

    // -- U1-a: stale unprotected UsageEvents after the 5 s window ----------------

    @Test
    fun staleUsageAfterTheAuthorityWindowKeepsTheWakeIdentityThroughScreenOff() {
        val m = ReportModel()
        ProtectionAccessState.authorize(locked, 300_000L, BASE)
        m.wakePackage = locked
        assertEquals("ALLOW", m.report(locked, a11y = true, t = 0))
        assertEquals("IGNORED", m.report(stale, a11y = false, t = 3_000))
        assertEquals("ALLOW", m.report(stale, a11y = false, t = 6_000))
        assertEquals(locked, m.wakePackage)
        assertEquals(locked, m.screenOff())
        assertEquals(locked, m.pending?.packageName)
        assertTrue(m.shieldVisible)
    }

    @Test
    fun staleUsageNeverAbandonsOrDefersAReadyTicket() {
        for (resumed in listOf(false, true)) {
            resetAccess()
            val m = ReportModel()
            m.report(locked, a11y = true, t = 0)
            m.ticket()
            val ticket = m.pending
            m.challengeResumed = resumed
            m.report(stale, a11y = false, t = 6_000)
            assertEquals("resumed=$resumed", ticket, m.pending)
            assertEquals("resumed=$resumed", ticket, m.ready)
            assertNull("resumed=$resumed", m.candidate)
            assertTrue("resumed=$resumed", m.shieldVisible)
            assertEquals("resumed=$resumed", locked, m.wakePackage)
        }
    }

    @Test
    fun usageHomeNeedsCorroborationButAccessibilityHomeStillClearsTheIdentity() {
        val m = ReportModel()
        m.report(locked, a11y = true, t = 0)
        m.report(home, a11y = false, t = 6_000)
        assertEquals(locked, m.wakePackage)
        m.report(home, a11y = true, t = 7_000, resolves = false)
        assertNull(m.wakePackage)
        assertNull(m.screenOff())
    }

    // -- Genuine leaves --------------------------------------------------------

    @Test
    fun aGenuineAccessibilityActivityLeaveStillClearsIdentityAndTicket() {
        val m = ReportModel()
        m.report(locked, a11y = true, t = 0)
        m.ticket()
        m.report(other, a11y = true, t = 1_000)
        assertNull(m.wakePackage)
        assertNull(m.pending)
        m.report(other, a11y = false, t = 7_000)
        assertNull(m.screenOff())
    }

    @Test
    fun anOverlayReportCorroboratesALaterUsageResumeOfTheSamePackage() {
        // API 30+: an invisible package's class does not resolve (UNCONFIRMED);
        // the matching UsageEvents resume then confirms the leave.
        val m = ReportModel()
        m.report(locked, a11y = true, t = 0)
        m.report(other, a11y = true, t = 1_000, resolves = false)
        assertEquals(locked, m.wakePackage)
        m.report(other, a11y = false, t = 7_000)
        assertNull(m.wakePackage)
        assertNull(m.screenOff())
    }

    // -- Transient windows -----------------------------------------------------

    @Test
    fun transientWindowsDoNotCorroborateAStaleUsageResume() {
        val m = ReportModel()
        m.report(locked, a11y = true, t = 0)
        m.report("com.android.systemui", a11y = true, t = 1_000)
        m.report(ime, a11y = true, t = 1_500)
        m.report("android", a11y = true, t = 2_000)
        m.report(stale, a11y = false, t = 8_000)
        assertEquals(locked, m.wakePackage)
        assertEquals(locked, m.screenOff())
    }

    @Test
    fun transientWindowsDoNotOverwriteAGenuineCorroboration() {
        val m = ReportModel()
        m.report(locked, a11y = true, t = 0)
        m.report(other, a11y = true, t = 1_000, resolves = false)
        m.report("com.android.systemui", a11y = true, t = 1_500)
        m.report(ime, a11y = true, t = 2_000)
        m.report(other, a11y = false, t = 8_000)
        assertNull(m.wakePackage)
    }

    @Test
    fun theLatestNonTransientReportWins() {
        val m = ReportModel()
        m.report(stale, a11y = true, t = 0, resolves = false)
        m.report(locked, a11y = true, t = 1_000)
        m.report(stale, a11y = false, t = 7_000)
        assertEquals(locked, m.wakePackage)
    }

    // -- Fresh process, Accessibility off, enabled-but-silent --------------------

    @Test
    fun aFreshProcessKeepsTheRestoredIdentityWhileAccessibilityIsEnabled() {
        // R-4: no Accessibility report yet, so UsageEvents is authoritative at
        // once; U1-C still refuses to treat the stale result as a leave.
        val m = ReportModel()
        m.wakePackage = locked
        assertEquals("ALLOW", m.report(stale, a11y = false, t = 500))
        assertEquals(locked, m.wakePackage)
        assertEquals(locked, m.screenOff())
    }

    @Test
    fun theAccessibilityDisabledFallbackIsUnchanged() {
        val m = ReportModel(accessibilityEnabled = false)
        assertEquals("CHALLENGE", m.report(locked, a11y = false, t = 0))
        assertEquals(locked, m.wakePackage)
        m.report(other, a11y = false, t = 1_000)
        assertNull(m.wakePackage)
        val n = ReportModel(accessibilityEnabled = false)
        n.report(locked, a11y = false, t = 0)
        n.report(home, a11y = false, t = 1_000)
        assertNull(n.wakePackage)
        assertNull(n.screenOff())
    }

    @Test
    fun enabledButSilentAccessibilityFailsClosedWithAnExitableWakeChallenge() {
        // Limitation (G-4): ENABLED_ACCESSIBILITY_SERVICES lists the service but
        // it delivers nothing. A genuine UsageEvents-only leave is not confirmed,
        // so the identity is kept: over-protection, never exposure.
        val m = ReportModel(accessibilityEnabled = true)
        m.report(locked, a11y = false, t = 0)
        m.report(other, a11y = false, t = 1_000)
        assertEquals(locked, m.wakePackage)
        assertEquals(locked, m.screenOff())
        assertTrue(m.enabledQueries > 0)
    }

    // -- Authorization and protected detection are unchanged --------------------

    @Test
    fun anUncorroboratedUsageReportStillRevokesAuthorizationGraceZero() {
        val m = ReportModel()
        ProtectionAccessState.authorize(locked, 300_000L, BASE)
        m.report(locked, a11y = true, t = 0)
        m.report(stale, a11y = false, t = 6_000)
        assertEquals(locked, m.wakePackage)
        assertEquals(stale, ProtectionAccessState.currentForegroundPackage())
        assertEquals("CHALLENGE", m.report(locked, a11y = true, t = 8_000))
    }

    @Test
    fun anUncorroboratedUsageReportStillStartsTheGraceWindow() {
        ProtectionAccessState.setGracePeriod(10_000L)
        val m = ReportModel()
        ProtectionAccessState.authorize(locked, 300_000L, BASE)
        m.report(locked, a11y = true, t = 0)
        m.report(stale, a11y = false, t = 6_000)
        assertEquals("ALLOW", m.report(locked, a11y = true, t = 9_000))
        m.report(stale, a11y = false, t = 15_000)
        assertEquals("CHALLENGE", m.report(locked, a11y = true, t = 26_000))
    }

    @Test
    fun protectedUsageDetectionIsUnchangedWhenUncorroborated() {
        val m = ReportModel()
        m.report(other, a11y = true, t = 0)
        assertEquals("CHALLENGE", m.report(locked, a11y = false, t = 6_000))
        assertEquals(locked, m.wakePackage)
        assertTrue(m.shieldVisible)
    }

    @Test
    fun protectedUsageStillSlidesAValidSessionExactlyAsBefore() {
        val m = ReportModel()
        ProtectionAccessState.authorize(locked, 300_000L, BASE)
        m.report(locked, a11y = true, t = 0)
        assertEquals("ALLOW", m.report(locked, a11y = false, t = 6_000))
        assertEquals("ALLOW", m.report(locked, a11y = false, t = 305_000))
    }

    // -- Delayed / ordered events and the screen-off branch ----------------------

    @Test
    fun aStaleUsageResumeInsideTheAuthorityWindowIsStillIgnored() {
        val m = ReportModel(accessibilityEnabled = false)
        m.report(locked, a11y = true, t = 0)
        assertEquals("IGNORED", m.report(stale, a11y = false, t = 4_999))
        assertEquals(locked, m.wakePackage)
    }

    @Test
    fun residualALateAccessibilityReportCanCorroborateAStaleUsageResume() {
        // Documented residual: if Accessibility itself delivers a late report
        // for X after P is back in front AND UsageEvents also returns a stale X,
        // the two sources agree and the leave is confirmed (as a late resolved
        // Activity report alone already did before U1-C).
        val m = ReportModel()
        m.report(locked, a11y = true, t = 0)
        m.report(stale, a11y = true, t = 300, resolves = false)
        assertEquals(locked, m.wakePackage)
        m.report(stale, a11y = false, t = 6_000)
        assertNull(m.wakePackage)
    }

    @Test
    fun theScreenOffPreserveBranchIsUnchanged() {
        val m = ReportModel()
        m.report(locked, a11y = true, t = 0)
        m.screenInteractive = false
        assertEquals("PRESERVE", m.report(stale, a11y = false, t = 6_000))
        assertEquals(locked, m.wakePackage)
    }

    private companion object {
        const val BASE = 3_600_000L
        const val AUTHORITY_MS = 5_000L
    }
}
