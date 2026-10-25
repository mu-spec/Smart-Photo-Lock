package com.smartapplock.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Phase 5 / H-1 (F1 + F2) pure policy regression tests.
 *
 * These exercise [ChallengeAbandonPolicy] and its composition with the
 * existing [WakeReauthTargetPolicy]. They do not run `WatcherService`.
 */
class ChallengeAbandonPolicyTest {
    private val locked = "com.example.locked"
    private val launcher = "com.oppo.launcher"
    private val ime = "com.google.android.inputmethod.latin"
    private val ticket = ProtectionStateStore.PendingChallenge(locked, 7L)
    private val replaced = ProtectionStateStore.PendingChallenge(locked, 8L)

    private fun candidate(
        at: Long = 1_000L,
        challenge: ProtectionStateStore.PendingChallenge = ticket,
    ) = ChallengeAbandonCandidate(challenge, launcher, at)

    // -- Transient classification ---------------------------------------------

    @Test
    fun imePackageIsParsedFromTheFlattenedComponent() {
        assertEquals(
            ime,
            ChallengeAbandonPolicy.imePackageFromSetting(
                "$ime/com.android.inputmethod.latin.LatinIME",
            ),
        )
        assertEquals(ime, ChallengeAbandonPolicy.imePackageFromSetting(" $ime/.Ime "))
        assertEquals(ime, ChallengeAbandonPolicy.imePackageFromSetting(ime))
        assertNull(ChallengeAbandonPolicy.imePackageFromSetting(null))
        assertNull(ChallengeAbandonPolicy.imePackageFromSetting(""))
        assertNull(ChallengeAbandonPolicy.imePackageFromSetting("/.Ime"))
    }

    @Test
    fun systemUiFrameworkKeyboardAndBlankReportsAreTransient() {
        assertTrue(ChallengeAbandonPolicy.isTransientWindow("com.android.systemui", null))
        assertTrue(ChallengeAbandonPolicy.isTransientWindow("android", null))
        assertTrue(ChallengeAbandonPolicy.isTransientWindow(ime, ime))
        assertTrue(ChallengeAbandonPolicy.isTransientWindow("", null))
        assertTrue(ChallengeAbandonPolicy.isTransientWindow("   ", ime))
    }

    @Test
    fun launcherAppsAndUnlistedOemWindowsAreNotTransient() {
        assertFalse(ChallengeAbandonPolicy.isTransientWindow(launcher, ime))
        assertFalse(
            ChallengeAbandonPolicy.isTransientWindow(
                "com.google.android.googlequicksearchbox",
                ime,
            ),
        )
        assertFalse(ChallengeAbandonPolicy.isTransientWindow("com.example.other", ime))
        // Documented residual: OEM overlays are not classified (F4 deferred).
        assertFalse(ChallengeAbandonPolicy.isTransientWindow("com.coloros.gesture", ime))
        // The keyboard package only matches when it is the default IME.
        assertFalse(ChallengeAbandonPolicy.isTransientWindow(ime, null))
        assertFalse(ChallengeAbandonPolicy.isTransientWindow(ime, ""))
        assertFalse(ChallengeAbandonPolicy.isTransientWindow(ime, "com.other.ime"))
    }

    // -- F2: wake identity ------------------------------------------------------

    @Test
    fun onlyANonTransientUnprotectedTargetMayForgetTheWakeIdentity() {
        assertTrue(ChallengeAbandonPolicy.mayForgetWakeIdentity(false, false))
        assertFalse(ChallengeAbandonPolicy.mayForgetWakeIdentity(false, true))
        assertFalse(ChallengeAbandonPolicy.mayForgetWakeIdentity(true, false))
        assertFalse(ChallengeAbandonPolicy.mayForgetWakeIdentity(true, true))
    }

    @Test
    fun transientWindowOverAuthorizedAppStillYieldsTheWakeTarget() {
        // Authorized `locked` is remembered; the shade is reported (observed).
        val transient = ChallengeAbandonPolicy.isTransientWindow("com.android.systemui", ime)
        val remembered =
            if (ChallengeAbandonPolicy.mayForgetWakeIdentity(false, transient)) null else locked
        val wake = WakeReauthTargetPolicy.resolve(
            observedPackage = "com.android.systemui",
            rememberedPackage = remembered,
        ) { it == locked }
        assertEquals(locked, wake)
    }

    @Test
    fun genuineLeaveToLauncherClearsTheWakeTarget() {
        val transient = ChallengeAbandonPolicy.isTransientWindow(launcher, ime)
        val remembered =
            if (ChallengeAbandonPolicy.mayForgetWakeIdentity(false, transient)) null else locked
        val wake = WakeReauthTargetPolicy.resolve(
            observedPackage = launcher,
            rememberedPackage = remembered,
        ) { it == locked }
        assertNull(wake)
    }

    // -- F1: immediate action ---------------------------------------------------

    @Test
    fun readyTicketActionTruthTable() {
        for (protectedTarget in listOf(false, true)) {
            for (transient in listOf(false, true)) {
                for (resumed in listOf(false, true)) {
                    for (interactive in listOf(false, true)) {
                        val expected = when {
                            protectedTarget || transient || !interactive ->
                                ReadyTicketAction.KEEP
                            resumed -> ReadyTicketAction.DEFER
                            else -> ReadyTicketAction.ABANDON
                        }
                        assertEquals(
                            "protected=$protectedTarget transient=$transient " +
                                "resumed=$resumed interactive=$interactive",
                            expected,
                            ChallengeAbandonPolicy.readyTicketAction(
                                protectedTarget,
                                transient,
                                resumed,
                                interactive,
                            ),
                        )
                    }
                }
            }
        }
    }

    @Test
    fun transientWindowOverRenderedChallengeKeepsTheTicket() {
        assertEquals(
            ReadyTicketAction.KEEP,
            ChallengeAbandonPolicy.readyTicketAction(
                protectedTarget = false,
                transient = true,
                challengeActivityResumed = true,
                screenInteractive = true,
            ),
        )
        // Even if a transient window pauses the Activity, it proves nothing.
        assertEquals(
            ReadyTicketAction.KEEP,
            ChallengeAbandonPolicy.readyTicketAction(false, true, false, true),
        )
    }

    @Test
    fun genuineLeaveAfterPauseAbandonsAndBeforePauseDefers() {
        assertEquals(
            ReadyTicketAction.ABANDON,
            ChallengeAbandonPolicy.readyTicketAction(false, false, false, true),
        )
        assertEquals(
            ReadyTicketAction.DEFER,
            ChallengeAbandonPolicy.readyTicketAction(false, false, true, true),
        )
    }

    // -- F1: deferred confirmation ---------------------------------------------

    @Test
    fun deferredLeaveIsConfirmedForTheExactTicketInsideTheWindow() {
        for (elapsed in listOf(0L, 1L, ChallengeAbandonPolicy.CONFIRM_WINDOW_MS)) {
            assertTrue(
                "elapsed=$elapsed",
                ChallengeAbandonPolicy.confirmsDeferred(
                    candidate = candidate(at = 1_000L),
                    ready = ticket,
                    pending = ticket,
                    challengeActivityResumed = false,
                    screenInteractive = true,
                    nowElapsedMs = 1_000L + elapsed,
                ),
            )
        }
    }

    @Test
    fun deferredLeaveExpiresOutsideTheWindowOrWithClockSkew() {
        assertFalse(
            ChallengeAbandonPolicy.confirmsDeferred(
                candidate(at = 1_000L), ticket, ticket, false, true,
                1_000L + ChallengeAbandonPolicy.CONFIRM_WINDOW_MS + 1L,
            ),
        )
        assertFalse(
            ChallengeAbandonPolicy.confirmsDeferred(
                candidate(at = 1_000L), ticket, ticket, false, true, 999L,
            ),
        )
    }

    @Test
    fun deferredLeaveNeedsAPausedActivityAndInteractiveScreen() {
        assertFalse(
            ChallengeAbandonPolicy.confirmsDeferred(
                candidate(), ticket, ticket, true, true, 1_100L,
            ),
        )
        // A pause caused by screen-off is not a leave; SCREEN_OFF owns it.
        assertFalse(
            ChallengeAbandonPolicy.confirmsDeferred(
                candidate(), ticket, ticket, false, false, 1_100L,
            ),
        )
        assertFalse(
            ChallengeAbandonPolicy.confirmsDeferred(
                null, ticket, ticket, false, true, 1_100L,
            ),
        )
    }

    @Test
    fun staleCandidateNeverClearsAReplacedConsumedOrClearedTicket() {
        // Screen-off / handoff failure replaced the generation.
        assertFalse(
            ChallengeAbandonPolicy.confirmsDeferred(
                candidate(), replaced, replaced, false, true, 1_100L,
            ),
        )
        assertFalse(
            ChallengeAbandonPolicy.confirmsDeferred(
                candidate(), ticket, replaced, false, true, 1_100L,
            ),
        )
        // Correct authentication consumed the ready handoff.
        assertFalse(
            ChallengeAbandonPolicy.confirmsDeferred(
                candidate(), null, ticket, false, true, 1_100L,
            ),
        )
        // Safe exit / authorization / reconfiguration cleared the ticket.
        assertFalse(
            ChallengeAbandonPolicy.confirmsDeferred(
                candidate(), ticket, null, false, true, 1_100L,
            ),
        )
        // A different protected package now owns the ticket.
        val other = ProtectionStateStore.PendingChallenge("com.example.other", 7L)
        assertFalse(
            ChallengeAbandonPolicy.confirmsDeferred(
                candidate(), other, other, false, true, 1_100L,
            ),
        )
    }

    @Test
    fun candidateRecordedForAnOlderTicketCannotConfirmTheNewOne() {
        assertFalse(
            ChallengeAbandonPolicy.confirmsDeferred(
                candidate(challenge = ticket), replaced, replaced, false, true, 1_000L,
            ),
        )
        assertTrue(
            ChallengeAbandonPolicy.confirmsDeferred(
                candidate(challenge = replaced), replaced, replaced, false, true, 1_000L,
            ),
        )
    }
}
