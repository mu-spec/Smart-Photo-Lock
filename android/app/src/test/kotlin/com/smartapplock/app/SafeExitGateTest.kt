package com.smartapplock.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class SafeExitGateTest {
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
    fun detectorConfirmedExitRequiresExactHomeAndGeneration() {
        val gate = SafeExitGate()
        val pending = ProtectionStateStore.PendingChallenge(locked, 12L)
        assertTrue(gate.begin(SafeExitRequest(pending, launcher)))

        // A protected or unrelated foreground report cannot complete Home
        // escape and leaves the gate waiting with the shield retained.
        assertEquals(
            SafeExitResolution.WAITING,
            gate.resolveForeground(pending, locked),
        )
        assertEquals(
            SafeExitResolution.WAITING,
            gate.resolveForeground(pending, "com.example.other"),
        )
        assertTrue(gate.isInProgress())

        assertEquals(
            SafeExitResolution.CONFIRMED,
            gate.resolveForeground(pending, launcher),
        )
        assertFalse(gate.isInProgress())
    }

    @Test
    fun detectorUnavailableUsesBoundedFallbackOnlyForCurrentGeneration() {
        val gate = SafeExitGate()
        val pending = ProtectionStateStore.PendingChallenge(locked, 13L)
        assertTrue(gate.begin(SafeExitRequest(pending, launcher)))

        assertEquals(
            SafeExitResolution.FALLBACK,
            gate.resolveTimeout(pending),
        )
        assertFalse(gate.isInProgress())
    }

    @Test
    fun staleExitCannotResolveOrClearNewerChallenge() {
        val gate = SafeExitGate()
        val old = ProtectionStateStore.PendingChallenge(locked, 14L)
        val newer = ProtectionStateStore.PendingChallenge(locked, 15L)
        assertTrue(gate.begin(SafeExitRequest(old, launcher)))

        assertEquals(
            SafeExitResolution.STALE,
            gate.resolveTimeout(newer),
        )
        assertFalse(gate.isInProgress())

        // The newer ticket can independently begin and require exact Home.
        assertTrue(gate.begin(SafeExitRequest(newer, launcher)))
        assertEquals(
            SafeExitResolution.CONFIRMED,
            gate.resolveForeground(newer, launcher),
        )
    }

    @Test
    fun repeatedRequestForSameTicketDoesNotExtendTheExitWindow() {
        val gate = SafeExitGate()
        val pending = ProtectionStateStore.PendingChallenge(locked, 16L)
        val request = SafeExitRequest(pending, launcher)

        assertTrue(gate.begin(request))
        assertFalse(gate.begin(request))
        assertTrue(gate.isInProgress())
        assertEquals(SafeExitResolution.FALLBACK, gate.resolveTimeout(pending))
    }

    @Test
    fun emergencyExitStateCannotAuthorizeProtectedReopen() {
        ProtectionAccessState.authorize(locked, 120_000L, 1_000L)
        ProtectionAccessState.revokeAll()

        assertEquals(
            ProtectionAccessState.Decision.CHALLENGE,
            ProtectionAccessState.observeForeground(locked, true, 1_001L),
        )
    }
}
