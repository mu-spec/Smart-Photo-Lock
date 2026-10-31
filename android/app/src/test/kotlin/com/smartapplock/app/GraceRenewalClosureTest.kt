package com.smartapplock.app

import com.smartapplock.app.ProtectionAccessState.Decision
import com.smartapplock.app.ProtectionAccessState.Decision.ALLOW
import com.smartapplock.app.ProtectionAccessState.Decision.CHALLENGE
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Phase 5 closure regression tests for OD6 and U1-R.
 *
 * OD6: an authorization already expired at departure (deadline equality
 * included) must never be re-admitted by a leave and a return within grace.
 * U1-R: a protected UsageEvents report that the latest Accessibility evidence
 * does not corroborate must neither revive a grace window nor slide the H-2
 * deadline; it is still enforced (it may challenge).
 *
 * SIMULATED, JVM only. [Pipeline] is a test-side port of the relevant chain
 * of `WatcherService.reportForeground`: Accessibility reports feed the REAL
 * [UsageLeaveCorroboration]; a UsageEvents report within 5 s of an
 * Accessibility report is dropped (`ACCESSIBILITY_AUTHORITY_MS`); otherwise
 * the REAL [ProtectionAccessState.observeForeground] runs with
 * `mayRenew` from the REAL [UsageLeaveCorroboration.mayRenewAuthorization].
 * Safe exit, pending tickets, the overlay and recovery are not modelled.
 * This is not device, APK or `WatcherService` execution evidence.
 */
class GraceRenewalClosureTest {
    private val p = "com.whatsapp"
    private val x = "com.example.chat"
    private val home = "com.android.launcher"

    @Before
    fun resetAccess() {
        ProtectionAccessState.revokeAll()
        ProtectionAccessState.retainProtectedPackages(emptySet())
        ProtectionAccessState.setGracePeriod(0L)
    }

    @After
    fun restoreAccess() = resetAccess()

    private class Pipeline(private val accessibilityEnabled: Boolean = true) {
        private val corroboration = UsageLeaveCorroboration()
        private var lastAccessibilityMs = 0L

        fun a11y(pkg: String, protected: Boolean, now: Long): Decision {
            corroboration.onAccessibilityReport(pkg, transient = false)
            lastAccessibilityMs = now
            return observe(pkg, protected, now, fromUsageEvents = false)
        }

        /** Null when dropped by the 5 s Accessibility authority window. */
        fun usage(pkg: String, protected: Boolean, now: Long): Decision? {
            if (lastAccessibilityMs > 0L && now - lastAccessibilityMs < AUTHORITY_MS) return null
            return observe(pkg, protected, now, fromUsageEvents = true)
        }

        private fun observe(pkg: String, protected: Boolean, now: Long, fromUsageEvents: Boolean) =
            ProtectionAccessState.observeForeground(
                packageName = pkg,
                protected = protected,
                nowElapsedMs = now,
                mayRenew = corroboration.mayRenewAuthorization(
                    packageName = pkg,
                    protected = protected,
                    fromUsageEvents = fromUsageEvents,
                ) { accessibilityEnabled },
            )
    }

    private fun s(seconds: Long) = T0 + seconds * 1_000L

    private fun authorize(grace: Long) {
        ProtectionAccessState.setGracePeriod(grace)
        ProtectionAccessState.authorize(p, WINDOW, T0)
    }

    // ------------------------------------------------------------------ OD6

    @Test
    fun validSessionLeaveAndReturnWithinGraceIsAllowed() {
        authorize(GRACE)
        val k = Pipeline()
        k.a11y(home, false, s(100))
        assertEquals(ALLOW, k.a11y(p, true, s(110)))
    }

    @Test
    fun expiredSessionDirectObservationChallenges() {
        authorize(GRACE)
        assertEquals(CHALLENGE, Pipeline().a11y(p, true, s(200)))
    }

    @Test
    fun expiredSessionReturnAfterGraceChallenges() {
        authorize(GRACE)
        val k = Pipeline()
        k.a11y(home, false, s(200))
        assertEquals(CHALLENGE, k.a11y(p, true, s(240)))
    }

    @Test
    fun zeroGraceExpiredLeaveAndReturnChallenges() {
        authorize(0L)
        val k = Pipeline()
        k.a11y(home, false, s(200))
        assertEquals(CHALLENGE, k.a11y(p, true, s(205)))
    }

    @Test
    fun leaveOneMillisecondBeforeDeadlineKeepsGrace() {
        authorize(GRACE)
        val k = Pipeline()
        k.a11y(home, false, T0 + WINDOW - 1)
        assertEquals(ALLOW, k.a11y(p, true, T0 + WINDOW + 5_000L))
    }

    @Test
    fun od6ExpiredUnobservedSessionIsNotRevivedByReturnWithinGrace() {
        authorize(GRACE)
        val k = Pipeline()
        k.a11y(home, false, s(200))
        assertEquals(CHALLENGE, k.a11y(p, true, s(205)))
    }

    @Test
    fun od6LeaveExactlyAtDeadlineCountsAsExpired() {
        authorize(GRACE)
        val k = Pipeline()
        k.a11y(home, false, T0 + WINDOW)
        assertEquals(CHALLENGE, k.a11y(p, true, T0 + WINDOW + 5_000L))
    }

    @Test
    fun od6ExpiredSessionIsNotReArmedForLaterObservations() {
        authorize(GRACE)
        val k = Pipeline()
        k.a11y(home, false, s(200))
        k.a11y(p, true, s(205))
        assertEquals(CHALLENGE, k.a11y(p, true, s(260)))
    }

    /** Ordinary use: P's resume ages out of the 60 s lookback after t+60. */
    @Test
    fun ordinaryTimelineNewScreenAfterLapseChallenges() {
        authorize(GRACE)
        val k = Pipeline()
        k.a11y(p, true, s(0))
        for (t in 6L..60L) assertEquals(ALLOW, k.usage(p, true, s(t)))
        assertEquals(CHALLENGE, k.a11y(p, true, s(300)))
    }

    @Test
    fun od6OrdinaryTimelineHomeAndBackAfterLapseChallenges() {
        authorize(GRACE)
        val k = Pipeline()
        k.a11y(p, true, s(0))
        for (t in 6L..60L) assertEquals(ALLOW, k.usage(p, true, s(t)))
        k.a11y(home, false, s(300))
        assertEquals(CHALLENGE, k.a11y(p, true, s(305)))
    }

    @Test
    fun genuineSameAppActivityStillSlidesTheSession() {
        authorize(GRACE)
        val k = Pipeline()
        k.a11y(p, true, s(0))
        assertEquals(ALLOW, k.a11y(p, true, s(100)))
        assertEquals(ALLOW, k.a11y(p, true, s(200)))
        k.a11y(home, false, s(300))
        assertEquals(ALLOW, k.a11y(p, true, s(310)))
    }

    // ----------------------------------------------------------------- U1-R

    @Test
    fun zeroGraceStaleProtectedUsageChallengesFailClosed() {
        authorize(0L)
        val k = Pipeline()
        k.a11y(p, true, s(0))
        k.a11y(x, false, s(10))
        assertEquals(CHALLENGE, k.usage(p, true, s(16)))
    }

    @Test
    fun accessibilityOffUsageOnlyReturnWithinGraceIsAllowed() {
        authorize(GRACE)
        val k = Pipeline(accessibilityEnabled = false)
        k.usage(p, true, s(1))
        k.usage(x, false, s(10))
        assertEquals(ALLOW, k.usage(p, true, s(20)))
    }

    @Test
    fun accessibilityOffUsageOnlyPresenceStillSlides() {
        authorize(GRACE)
        val k = Pipeline(accessibilityEnabled = false)
        assertEquals(ALLOW, k.usage(p, true, s(1)))
        assertEquals(ALLOW, k.usage(p, true, s(100)))
        assertEquals(ALLOW, k.usage(p, true, s(200)))
    }

    @Test
    fun genuineAccessibilityReturnThenCorroboratedUsageIsAllowed() {
        authorize(GRACE)
        val k = Pipeline()
        k.a11y(p, true, s(0))
        k.a11y(x, false, s(10))
        assertEquals(ALLOW, k.a11y(p, true, s(20)))
        assertEquals(ALLOW, k.usage(p, true, s(26)))
    }

    @Test
    fun u1rStaleProtectedUsageWhileOtherAppVisibleDoesNotReviveGrace() {
        authorize(GRACE)
        val k = Pipeline()
        k.a11y(p, true, s(0))
        k.a11y(x, false, s(10))
        assertEquals(CHALLENGE, k.usage(p, true, s(16)))
    }

    @Test
    fun u1rRepeatedStaleUsageNeverAllowsAndCannotOutliveGrace() {
        authorize(GRACE)
        val k = Pipeline()
        k.a11y(p, true, s(0))
        k.a11y(x, false, s(10))
        for (t in 16L..99L) {
            assertEquals("stale report at t+$t", CHALLENGE, k.usage(p, true, s(t)))
        }
        assertEquals(CHALLENGE, k.a11y(p, true, s(100)))
    }

    @Test
    fun uncorroboratedSamePackageReportDoesNotSlide() {
        authorize(GRACE)
        assertEquals(ALLOW, ProtectionAccessState.observeForeground(p, true, s(100), mayRenew = false))
        assertEquals(CHALLENGE, ProtectionAccessState.observeForeground(p, true, s(125)))
    }

    @Test
    fun mayRenewRefusesOnlyUncorroboratedProtectedUsageReports() {
        val c = UsageLeaveCorroboration()
        c.onAccessibilityReport(x, transient = false)
        assertFalse(c.mayRenewAuthorization(p, protected = true, fromUsageEvents = true) { true })
        assertTrue(c.mayRenewAuthorization(p, protected = true, fromUsageEvents = true) { false })
        assertTrue(c.mayRenewAuthorization(p, protected = true, fromUsageEvents = false) { true })
        assertTrue(c.mayRenewAuthorization(x, protected = false, fromUsageEvents = true) { true })
        c.onAccessibilityReport(p, transient = false)
        assertTrue(c.mayRenewAuthorization(p, protected = true, fromUsageEvents = true) { true })
    }

    @Test
    fun transientAccessibilityReportDoesNotCorroborateRenewal() {
        val c = UsageLeaveCorroboration()
        c.onAccessibilityReport(x, transient = false)
        c.onAccessibilityReport(p, transient = true)
        assertFalse(c.mayRenewAuthorization(p, protected = true, fromUsageEvents = true) { true })
    }

    private companion object {
        const val T0 = 3_600_000L
        const val WINDOW = 120_000L
        const val GRACE = 30_000L
        const val AUTHORITY_MS = 5_000L
    }
}
