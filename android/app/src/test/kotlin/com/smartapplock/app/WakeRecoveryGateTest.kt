package com.smartapplock.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WakeRecoveryGateTest {
    private val locked = "com.example.locked"

    @Test
    fun userPresentGetsImmediateAttemptAfterScreenOnAttempt() {
        val gate = WakeRecoveryGate(retryIntervalMs = 3_000L)
        gate.onScreenOff()

        assertTrue(gate.shouldAttempt(locked, WakeRecoverySignal.SCREEN_ON, 1_000L))
        assertTrue(gate.shouldAttempt(locked, WakeRecoverySignal.USER_PRESENT, 1_050L))
    }

    @Test
    fun duplicateWakeBroadcastsDoNotLaunchDuplicateActivities() {
        val gate = WakeRecoveryGate(retryIntervalMs = 3_000L)
        gate.onScreenOff()

        assertTrue(gate.shouldAttempt(locked, WakeRecoverySignal.SCREEN_ON, 1_000L))
        assertFalse(gate.shouldAttempt(locked, WakeRecoverySignal.SCREEN_ON, 1_001L))
        assertTrue(gate.shouldAttempt(locked, WakeRecoverySignal.USER_PRESENT, 1_002L))
        assertFalse(gate.shouldAttempt(locked, WakeRecoverySignal.USER_PRESENT, 1_003L))
    }

    @Test
    fun retryContinuesUntilHandoffButRemainsRateLimited() {
        val gate = WakeRecoveryGate(retryIntervalMs = 3_000L)

        assertTrue(gate.shouldAttempt(locked, WakeRecoverySignal.FOREGROUND, 10_000L))
        assertFalse(gate.shouldAttempt(locked, WakeRecoverySignal.RETRY, 12_999L))
        assertTrue(gate.shouldAttempt(locked, WakeRecoverySignal.RETRY, 13_000L))
    }

    @Test
    fun aNewScreenCycleCanRecoverTheSamePackageAgain() {
        val gate = WakeRecoveryGate(retryIntervalMs = 3_000L)
        gate.onScreenOff()
        assertTrue(gate.shouldAttempt(locked, WakeRecoverySignal.SCREEN_ON, 1_000L))

        gate.onScreenOff()
        assertTrue(gate.shouldAttempt(locked, WakeRecoverySignal.SCREEN_ON, 1_100L))
    }

    @Test
    fun screenOffRetainsObservedProtectedPackageIdentity() {
        assertTrue(
            WakeReauthTargetPolicy.resolve(
                observedPackage = locked,
                rememberedPackage = null,
                isProtected = { it == locked },
            ) == locked,
        )
    }

    @Test
    fun screenOffRestoresRememberedPackageAfterProcessStateLoss() {
        assertTrue(
            WakeReauthTargetPolicy.resolve(
                observedPackage = null,
                rememberedPackage = locked,
                isProtected = { it == locked },
            ) == locked,
        )
    }

    @Test
    fun staleOrUnprotectedWakeIdentityIsNeverRecovered() {
        assertTrue(
            WakeReauthTargetPolicy.resolve(
                observedPackage = "com.example.launcher",
                rememberedPackage = "com.example.removed",
                isProtected = { false },
            ) == null,
        )
    }

    @Test
    fun existingActivityAcceptsOnlyItsExactWakeRecoveryIntent() {
        val pending = ProtectionStateStore.PendingChallenge(locked, 17L)

        assertTrue(RecoveryIntentPolicy.matches(pending, locked, 17L))
        assertFalse(RecoveryIntentPolicy.matches(pending, locked, 16L))
        assertFalse(
            RecoveryIntentPolicy.matches(pending, "com.example.other", 17L),
        )
    }

    @Test
    fun keyguardCoveredResumeCannotConsumeUnresolvedChallenge() {
        assertFalse(
            ChallengeReadyPolicy.canHandOff(
                activityResumed = true,
                keyguardLocked = true,
                pendingMatches = true,
            ),
        )
    }

    @Test
    fun userPresentCanHandOffOnlyTheCurrentGeneration() {
        assertTrue(
            ChallengeReadyPolicy.canHandOff(
                activityResumed = true,
                keyguardLocked = false,
                pendingMatches = true,
            ),
        )
        assertFalse(
            ChallengeReadyPolicy.canHandOff(
                activityResumed = true,
                keyguardLocked = false,
                pendingMatches = false,
            ),
        )
    }
}
