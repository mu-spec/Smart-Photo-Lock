package com.smartapplock.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Phase 6 / Milestone 1 — Alternate Entry Paths (pure native policy).
 *
 * Android delivers a notification tap, a deep link / external VIEW intent,
 * an ACTION_SEND / ACTION_SEND_MULTIPLE target, a launcher shortcut or a
 * widget click by resuming an Activity of the TARGET package, often inside
 * the caller's task. Smart App Lock cannot intercept those intents; it sees
 * the resulting window as a foreground report for the protected package.
 * These tests replay the report sequence of each path through the same
 * policy calls `WatcherService.reportForeground` makes:
 * [UsageLeaveCorroboration] bookkeeping, then
 * [ProtectionAccessState.observeForeground] with the U1-R `mayRenew` value.
 *
 * JVM policy tests only. Nothing here runs Android, a launcher, a
 * notification, a chooser, Accessibility or UsageEvents, and nothing here is
 * evidence of device behaviour. `WatcherService` itself (Context, overlay,
 * SharedPreferences ticket store) is not executed.
 */
class AlternateEntryPathTest {
    private val locked = "com.whatsapp"
    private val otherLocked = "com.example.bank"
    private val launcher = "com.example.launcher"
    private val systemUi = "com.android.systemui"
    private val browser = "com.android.chrome"
    private val gallery = "com.example.gallery"
    private val frameworkChooser = "android"
    private val intentResolver = "com.android.intentresolver"
    private val protectedSet = setOf(locked, otherLocked)
    private val window = 120_000L

    private lateinit var corroboration: UsageLeaveCorroboration
    private var accessibilityEnabled = true

    @Before
    fun reset() {
        ProtectionAccessState.revokeAll()
        ProtectionRuntime.invalidateChallengeHandoff()
        ProtectionAccessState.setGracePeriod(0L)
        corroboration = UsageLeaveCorroboration()
        accessibilityEnabled = true
        ProtectionAccessState.observeForeground(launcher, false, T0)
    }

    /** The two policy steps of `WatcherService.reportForeground`, in order. */
    private fun report(
        packageName: String,
        now: Long,
        fromUsageEvents: Boolean = false,
    ): ProtectionAccessState.Decision {
        if (!fromUsageEvents) {
            corroboration.onAccessibilityReport(
                packageName,
                ChallengeAbandonPolicy.isTransientWindow(packageName, null),
            )
        }
        val isProtected = packageName in protectedSet
        return ProtectionAccessState.observeForeground(
            packageName = packageName,
            protected = isProtected,
            nowElapsedMs = now,
            mayRenew = corroboration.mayRenewAuthorization(
                packageName = packageName,
                protected = isProtected,
                fromUsageEvents = fromUsageEvents,
            ) { accessibilityEnabled },
        )
    }

    /** Replays [path]; returns the decision for its last report. */
    private fun replay(path: List<String>, start: Long): ProtectionAccessState.Decision {
        var decision = ProtectionAccessState.Decision.ALLOW
        path.forEachIndexed { i, pkg -> decision = report(pkg, start + i) }
        return decision
    }

    private val entryPaths: Map<String, List<String>> = mapOf(
        "notification from Home" to listOf(launcher, systemUi, locked),
        "heads-up notification inside another app" to listOf(browser, systemUi, locked),
        "deep link in the caller task" to listOf(browser, locked),
        "ACTION_SEND via framework chooser" to listOf(gallery, frameworkChooser, locked),
        "ACTION_SEND_MULTIPLE via IntentResolver" to listOf(gallery, intentResolver, locked),
        "launcher shortcut" to listOf(launcher, locked),
        "widget click" to listOf(launcher, locked),
    )

    @Test
    fun everyAlternateEntryPathIsChallengedAndNeverAuthorized() {
        var t = T0
        for ((name, path) in entryPaths) {
            reset()
            assertEquals(name, ProtectionAccessState.Decision.CHALLENGE, replay(path, t))
            // The entry itself created nothing: a repeated report of the same
            // package (onNewIntent pause/resume, a second tap) still challenges.
            assertEquals(
                name,
                ProtectionAccessState.Decision.CHALLENGE,
                report(locked, t + 100),
            )
            assertNull(name, ProtectionRuntime.readyChallenge())
            t += 10_000L
        }
    }

    @Test
    fun noEntryReportCanSatisfyTheExactTicketHandoff() {
        val ticket = ProtectionStateStore.PendingChallenge(locked, 7L)
        for ((_, path) in entryPaths) replay(path, T0)
        // Foreground observations never mark a ticket ready, so the exact
        // handoff that authorizePackage requires is impossible without the
        // challenge route's accepted ready acknowledgement.
        assertFalse(ProtectionRuntime.consumeChallengeHandoff(locked, ticket.generation))
        ProtectionRuntime.markChallengeReady(ticket)
        for ((_, path) in entryPaths) replay(path, T0 + 1_000L)
        assertEquals(ticket, ProtectionRuntime.readyChallenge())
        assertFalse(ProtectionRuntime.consumeChallengeHandoff(locked, ticket.generation + 1))
        assertFalse(ProtectionRuntime.consumeChallengeHandoff(otherLocked, ticket.generation))
    }

    @Test
    fun rapidRepeatedAlternateEntriesNeverAllow() {
        var t = T0
        repeat(50) {
            for ((_, path) in entryPaths) {
                assertEquals(ProtectionAccessState.Decision.CHALLENGE, replay(path, t))
                t += path.size
            }
        }
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(locked, t + 1))
    }

    @Test
    fun entryIntoProtectedBFromAuthorizedANeverInheritsAuthorization() {
        ProtectionAccessState.authorize(locked, window, T0 + 10)
        assertEquals(ProtectionAccessState.Decision.ALLOW, report(locked, T0 + 11))

        // Share or deep link from A into protected B (B runs in A's task).
        assertEquals(
            ProtectionAccessState.Decision.CHALLENGE,
            replay(listOf(frameworkChooser, otherLocked), T0 + 20),
        )
        // Immediate re-lock: the chooser/B transition was a leave of A.
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(locked, T0 + 30))
    }

    @Test
    fun graceIsPerPackageAndOnlyCoversTheAuthorizedPackage() {
        ProtectionAccessState.setGracePeriod(30_000L)
        ProtectionAccessState.authorize(locked, window, T0 + 10)
        report(locked, T0 + 11)

        // A's grace never admits protected B.
        assertEquals(
            ProtectionAccessState.Decision.CHALLENGE,
            replay(listOf(gallery, intentResolver, otherLocked), T0 + 1_000L),
        )
        // A notification re-entry of A inside A's grace is the existing
        // grace policy (an authorization that was valid at departure).
        assertEquals(
            ProtectionAccessState.Decision.ALLOW,
            replay(listOf(systemUi, locked), T0 + 5_000L),
        )
    }

    @Test
    fun alternateEntryStormsNeverExtendAnAwayGraceWindow() {
        ProtectionAccessState.setGracePeriod(30_000L)
        ProtectionAccessState.authorize(locked, window, T0 + 10)
        report(locked, T0 + 11)
        report(launcher, T0 + 1_000L) // A goes away at T0 + 1_000

        // Rapid entries into OTHER packages (unauthorized protected B,
        // browsers, choosers, System UI) for the whole grace period.
        var t = T0 + 1_001L
        while (t < T0 + 30_999L) {
            for (pkg in listOf(systemUi, otherLocked, browser, frameworkChooser, otherLocked)) {
                report(pkg, t)
                t += 1
            }
            t += 997L
        }
        // A's grace is measured from its own departure only.
        assertEquals(
            ProtectionAccessState.Decision.CHALLENGE,
            replay(listOf(systemUi, locked), T0 + 31_000L),
        )
    }

    @Test
    fun graceZeroShadeThenNotificationReEntryChallenges() {
        ProtectionAccessState.authorize(locked, window, T0 + 10)
        report(locked, T0 + 11)
        // Pulling the shade is reported as System UI: fail closed, the
        // authorization is not retained across it with immediate re-lock.
        assertEquals(
            ProtectionAccessState.Decision.CHALLENGE,
            replay(listOf(systemUi, locked), T0 + 20),
        )
    }

    @Test
    fun h2SemanticsUnchangedForSamePackageEntryReports() {
        ProtectionAccessState.authorize(locked, window, T0)
        report(locked, T0 + 1)
        // A same-package report before the deadline (for example a
        // notification for the app already in front) is the accepted H-2
        // presence proxy: it slides the deadline.
        assertEquals(ProtectionAccessState.Decision.ALLOW, report(locked, T0 + 100_000L))
        assertEquals(ProtectionAccessState.Decision.ALLOW, report(locked, T0 + 219_999L))
        // At or after the (slid) deadline it challenges and removes.
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(locked, T0 + 339_999L))
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, report(locked, T0 + 340_000L))
    }

    @Test
    fun uncorroboratedUsageEventsEntryCannotReviveGrace() {
        ProtectionAccessState.setGracePeriod(30_000L)
        ProtectionAccessState.authorize(locked, window, T0 + 10)
        report(locked, T0 + 11)
        report(launcher, T0 + 1_000L)
        // Accessibility is enabled and last saw the launcher: a stale
        // UsageEvents report of the protected app proves nothing (U1-R).
        assertEquals(
            ProtectionAccessState.Decision.CHALLENGE,
            report(locked, T0 + 2_000L, fromUsageEvents = true),
        )
    }

    @Test
    fun accessibilityOffUsageEventsEntryIsStillEnforced() {
        accessibilityEnabled = false
        report(launcher, T0 + 1, fromUsageEvents = true)
        assertEquals(
            ProtectionAccessState.Decision.CHALLENGE,
            report(locked, T0 + 1_000L, fromUsageEvents = true),
        )
    }

    @Test
    fun choosersAndShadeAreTransientButIntentResolverIsAnOrdinaryApp() {
        assertTrue(ChallengeAbandonPolicy.isTransientWindow(frameworkChooser, null))
        assertTrue(ChallengeAbandonPolicy.isTransientWindow(systemUi, null))
        assertFalse(ChallengeAbandonPolicy.isTransientWindow(intentResolver, null))
        // A protected entry always keeps a rendered ticket (never abandons
        // it); a replacement ticket comes only from the ticket store.
        assertEquals(
            ReadyTicketAction.KEEP,
            ChallengeAbandonPolicy.readyTicketAction(
                protectedTarget = true,
                transient = false,
                challengeActivityResumed = false,
                screenInteractive = true,
            ),
        )
    }

    @Test
    fun externalRecoveryIntentsWithGuessedTicketsNeverMatch() {
        val pending = ProtectionStateStore.PendingChallenge(locked, 42L)
        for (generation in listOf(-1L, 0L, 41L, 43L, Long.MAX_VALUE)) {
            assertFalse(RecoveryIntentPolicy.matches(pending, locked, generation))
        }
        assertFalse(RecoveryIntentPolicy.matches(pending, otherLocked, 42L))
        assertFalse(RecoveryIntentPolicy.matches(pending, "", 42L))
        assertFalse(RecoveryIntentPolicy.matches(null, locked, 42L))
        // Even the exact ticket only re-raises the shield in MainActivity;
        // the match is not an authorization.
        assertTrue(RecoveryIntentPolicy.matches(pending, locked, 42L))
    }

    private companion object {
        const val T0 = 3_600_000L
    }
}
