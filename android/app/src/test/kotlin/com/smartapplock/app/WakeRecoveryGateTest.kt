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
}
