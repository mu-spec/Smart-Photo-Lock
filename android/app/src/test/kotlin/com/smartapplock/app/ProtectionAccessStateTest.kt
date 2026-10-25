package com.smartapplock.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ProtectionAccessStateTest {
    private val locked = "com.example.locked"
    private val launcher = "com.example.launcher"

    @Before
    fun resetAuthorizationState() {
        ProtectionAccessState.revokeAll()
        ProtectionRuntime.invalidateChallengeHandoff()
        ProtectionAccessState.setGracePeriod(0L)
        ProtectionAccessState.observeForeground(
            packageName = launcher,
            protected = false,
            nowElapsedMs = 0L,
        )
    }

    @Test
    fun immediateRelockChallengesAfterLeavingProtectedPackage() {
        ProtectionAccessState.authorize(locked, 120_000L, 1_000L)

        assertEquals(
            ProtectionAccessState.Decision.ALLOW,
            ProtectionAccessState.observeForeground(locked, true, 1_001L),
        )
        ProtectionAccessState.observeForeground(launcher, false, 1_002L)

        assertEquals(
            ProtectionAccessState.Decision.CHALLENGE,
            ProtectionAccessState.observeForeground(locked, true, 1_003L),
        )
    }

    @Test
    fun graceAllowsOnlyReentryBeforeDeadline() {
        ProtectionAccessState.setGracePeriod(1_000L)
        ProtectionAccessState.authorize(locked, 120_000L, 1_000L)
        ProtectionAccessState.observeForeground(launcher, false, 1_100L)

        assertEquals(
            ProtectionAccessState.Decision.ALLOW,
            ProtectionAccessState.observeForeground(locked, true, 2_099L),
        )

        ProtectionAccessState.observeForeground(launcher, false, 2_100L)
        assertEquals(
            ProtectionAccessState.Decision.CHALLENGE,
            ProtectionAccessState.observeForeground(locked, true, 3_100L),
        )
    }

    @Test
    fun duplicateForegroundEventsDoNotRevokeValidAuthorization() {
        ProtectionAccessState.authorize(locked, 120_000L, 1_000L)

        repeat(5) { index ->
            assertEquals(
                ProtectionAccessState.Decision.ALLOW,
                ProtectionAccessState.observeForeground(
                    locked,
                    true,
                    1_001L + index,
                ),
            )
        }
    }

    @Test
    fun screenOffStyleRevocationFailsClosed() {
        ProtectionAccessState.authorize(locked, 120_000L, 1_000L)
        ProtectionAccessState.revokeAll()

        assertEquals(
            ProtectionAccessState.Decision.CHALLENGE,
            ProtectionAccessState.observeForeground(locked, true, 1_001L),
        )
    }

    @Test
    fun staleChallengeHandoffCannotAuthorizeAfterScreenOffInvalidation() {
        val beforeSleep = ProtectionStateStore.PendingChallenge(locked, 8L)
        ProtectionRuntime.markChallengeReady(beforeSleep)

        // ACTION_SCREEN_OFF performs this invalidation before creating the
        // replacement pending generation.
        ProtectionRuntime.invalidateChallengeHandoff()

        assertFalse(ProtectionRuntime.consumeChallengeHandoff(locked, 8L))
    }

    @Test
    fun challengeHandoffIsPackageGenerationSpecificAndSingleUse() {
        ProtectionRuntime.invalidateChallengeHandoff()
        ProtectionRuntime.markChallengeReady(
            ProtectionStateStore.PendingChallenge(locked, 9L),
        )

        assertFalse(ProtectionRuntime.consumeChallengeHandoff(locked, 8L))
        assertTrue(ProtectionRuntime.consumeChallengeHandoff(locked, 9L))
        assertFalse(ProtectionRuntime.consumeChallengeHandoff(locked, 9L))
    }

    // ---------------------------------------------------------------------
    // H-2 (Phase 5 / Milestone 2, fix N1): native sliding inactivity window.
    // A same-package foreground observation while the authorization is
    // still valid slides activeUntil to now + window. Window-state
    // observations are a proxy for continued foreground presence; they do
    // NOT prove human activity. Expired authorizations are never revived.
    // ---------------------------------------------------------------------

    private val window = 120_000L
    private val allow = ProtectionAccessState.Decision.ALLOW
    private val challenge = ProtectionAccessState.Decision.CHALLENGE

    private fun observe(pkg: String, protected: Boolean, at: Long) =
        ProtectionAccessState.observeForeground(pkg, protected, at)

    @Test
    fun h2ContinuousValidSameAppObservationsSlideTheNativeSession() {
        ProtectionAccessState.authorize(locked, window, 0L)

        // Each observation is < window after the previous one, so the
        // session keeps sliding well past the original 120 s deadline.
        for (at in longArrayOf(100_000L, 200_000L, 300_000L, 419_999L)) {
            assertEquals("observation at $at", allow, observe(locked, true, at))
        }
    }

    @Test
    fun h2SlidDeadlineIsExactlyNowPlusWindow() {
        ProtectionAccessState.authorize(locked, window, 1_000L)

        assertEquals(allow, observe(locked, true, 61_000L)) // -> 181_000
        assertEquals(allow, observe(locked, true, 180_999L)) // -> 300_999
        assertEquals(allow, observe(locked, true, 300_998L)) // -> 420_998
    }

    @Test
    fun h2ExpiryAtTheExactDeadlineStillChallenges() {
        ProtectionAccessState.authorize(locked, window, 1_000L)
        assertEquals(challenge, observe(locked, true, 121_000L))
    }

    @Test
    fun h2ExpiryAtTheExactSlidDeadlineStillChallenges() {
        ProtectionAccessState.authorize(locked, window, 1_000L)
        assertEquals(allow, observe(locked, true, 61_000L)) // -> 181_000
        assertEquals(challenge, observe(locked, true, 181_000L))
    }

    @Test
    fun h2LongInactivityStillChallenges() {
        ProtectionAccessState.authorize(locked, window, 0L)
        assertEquals(allow, observe(locked, true, 119_999L)) // -> 239_999

        assertEquals(challenge, observe(locked, true, 239_999L + 1_000_000L))
    }

    @Test
    fun h2ExpiredSessionCannotBeRevived() {
        ProtectionAccessState.authorize(locked, window, 0L)
        assertEquals(challenge, observe(locked, true, 120_000L))

        // Neither further presence nor a later grace setting or a quick
        // leave-and-return can bring the removed authorization back.
        assertEquals(challenge, observe(locked, true, 120_001L))
        ProtectionAccessState.setGracePeriod(300_000L)
        assertEquals(challenge, observe(locked, true, 120_002L))
        observe(launcher, false, 120_003L)
        assertEquals(challenge, observe(locked, true, 120_004L))
    }

    @Test
    fun h2HomeBackRecentsStillRelockImmediatelyAfterSliding() {
        val leaveTargets = listOf(
            launcher, // Home, or Back to the launcher
            "com.android.launcher3", // Recents hosted by the launcher
            "com.android.systemui", // Recents hosted by System UI
            "com.example.other", // switching to another app
        )
        for ((index, target) in leaveTargets.withIndex()) {
            ProtectionAccessState.revokeAll()
            val base = index * 1_000_000L
            ProtectionAccessState.authorize(locked, window, base)
            assertEquals(allow, observe(locked, true, base + 60_000L)) // slid

            observe(target, false, base + 60_001L)

            assertEquals(
                "leave via $target must relock immediately",
                challenge,
                observe(locked, true, base + 60_002L),
            )
        }
    }

    @Test
    fun h2GraceExpirationIsNeverExtendedBySliding() {
        ProtectionAccessState.setGracePeriod(30_000L)
        ProtectionAccessState.authorize(locked, window, 0L)
        assertEquals(allow, observe(locked, true, 100_000L)) // slid -> 220_000

        observe(launcher, false, 110_000L) // away; grace ends at 140_000
        // Observations of the other package never touch the away entry.
        observe(launcher, false, 120_000L)
        observe(launcher, false, 139_000L)

        assertEquals(challenge, observe(locked, true, 140_000L))
    }

    @Test
    fun h2GraceReentryJustBeforeTheGraceDeadlineIsUnchanged() {
        ProtectionAccessState.setGracePeriod(30_000L)
        ProtectionAccessState.authorize(locked, window, 0L)
        assertEquals(allow, observe(locked, true, 100_000L))
        observe(launcher, false, 110_000L)

        assertEquals(allow, observe(locked, true, 139_999L)) // -> 259_999
        assertEquals(challenge, observe(locked, true, 259_999L))
    }

    @Test
    fun h2ScreenOffRevokeAllClearsASlidAuthorization() {
        ProtectionAccessState.authorize(locked, window, 0L)
        assertEquals(allow, observe(locked, true, 100_000L))

        ProtectionAccessState.revokeAll()

        assertEquals(challenge, observe(locked, true, 100_001L))
    }

    @Test
    fun h2UnprotectingClearsASlidAuthorization() {
        ProtectionAccessState.authorize(locked, window, 0L)
        assertEquals(allow, observe(locked, true, 100_000L))

        ProtectionAccessState.retainProtectedPackages(emptySet())

        assertEquals(challenge, observe(locked, true, 100_001L))
    }

    @Test
    fun h2UnprotectedObservationsNeverCreateOrSlideAuthorization() {
        assertEquals(allow, observe(locked, false, 1_000L))
        assertEquals(challenge, observe(locked, true, 1_001L))

        ProtectionAccessState.revokeAll()
        ProtectionAccessState.authorize(locked, window, 0L)
        // The package is reported while not protected: no slide.
        assertEquals(allow, observe(locked, false, 100_000L))
        assertEquals(challenge, observe(locked, true, 120_000L))
    }

    @Test
    fun h2RapidProtectedAppSwitchingRemainsIsolated() {
        val other = "com.example.locked.other"
        ProtectionAccessState.authorize(locked, window, 0L)
        assertEquals(allow, observe(locked, true, 1_000L))

        // Switching to a second protected app never borrows the first
        // app's authorization, and the first app relocks on return.
        assertEquals(challenge, observe(other, true, 2_000L))
        assertEquals(challenge, observe(locked, true, 3_000L))

        // Sliding the second app's session never authorizes the first.
        ProtectionAccessState.authorize(other, window, 4_000L)
        for (at in longArrayOf(50_000L, 100_000L, 150_000L)) {
            assertEquals(allow, observe(other, true, at))
        }
        assertEquals(challenge, observe(locked, true, 151_000L))
    }

    @Test
    fun h2SlidingInOneAppNeverExtendsAnotherAppsGrace() {
        val other = "com.example.locked.other"
        ProtectionAccessState.setGracePeriod(30_000L)
        ProtectionAccessState.authorize(locked, window, 0L)
        assertEquals(allow, observe(locked, true, 1_000L))
        assertEquals(challenge, observe(other, true, 2_000L)) // locked away @2_000
        ProtectionAccessState.authorize(other, window, 3_000L)
        for (at in longArrayOf(10_000L, 20_000L, 31_000L)) {
            assertEquals(allow, observe(other, true, at))
        }

        assertEquals(challenge, observe(locked, true, 32_000L))
    }

    @Test
    fun h2ATransitionBackNeverSlidesEvenWithoutAnObservedLeave() {
        val other = "com.example.locked.other"
        ProtectionAccessState.authorize(locked, window, 0L)
        // Edge: another package is authorized without an observed leave, so
        // the first authorization was never marked away.
        ProtectionAccessState.authorize(other, window, 1_000L)

        // Returning is a transition, not continued presence: the existing
        // (unchanged) decision applies and the deadline does not slide.
        assertEquals(allow, observe(locked, true, 60_000L))
        assertEquals(challenge, observe(locked, true, 120_000L))
    }

    @Test
    fun h2TransientSystemUiBehaviourIsUnchanged() {
        // Grace 0: a System UI / framework window is a foreground change and
        // still revokes (OD3 policy unchanged by H-2).
        for ((index, transient) in listOf("com.android.systemui", "android").withIndex()) {
            ProtectionAccessState.revokeAll()
            val base = index * 1_000_000L
            ProtectionAccessState.authorize(locked, window, base)
            assertEquals(allow, observe(locked, true, base + 50_000L)) // slid
            assertEquals(allow, observe(transient, false, base + 60_000L))
            assertEquals(challenge, observe(locked, true, base + 60_500L))
        }

        // Grace > 0: return within grace is allowed exactly as before.
        ProtectionAccessState.revokeAll()
        ProtectionAccessState.setGracePeriod(30_000L)
        ProtectionAccessState.authorize(locked, window, 5_000_000L)
        observe("com.android.systemui", false, 5_010_000L)
        assertEquals(allow, observe(locked, true, 5_010_500L))
    }

    @Test
    fun h2OverflowingWindowAtAuthorizationStillFailsClosed() {
        ProtectionAccessState.authorize(locked, Long.MAX_VALUE, 1_000L)
        assertEquals(challenge, observe(locked, true, 1_001L))
    }

    @Test
    fun h2SlideArithmeticNeverWrapsTheDeadline() {
        // now + window would overflow at the second observation: the
        // existing deadline must be kept, not wrapped to a negative value.
        ProtectionAccessState.authorize(locked, Long.MAX_VALUE - 10L, 0L)
        assertEquals(allow, observe(locked, true, 20L))
        assertEquals(allow, observe(locked, true, 21L))
    }
}
