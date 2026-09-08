package com.smartapplock.app

import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

class ProtectionAccessStateTest {
    private val locked = "com.example.locked"
    private val launcher = "com.example.launcher"

    @Before
    fun resetAuthorizationState() {
        ProtectionAccessState.revokeAll()
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
}
