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
}
