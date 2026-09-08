package com.smartapplock.app

/** Why native wake recovery is being requested. */
enum class WakeRecoverySignal { SCREEN_ON, USER_PRESENT, FOREGROUND, RETRY }

/**
 * Pure, deterministic arbitration for wake recovery attempts.
 *
 * SCREEN_ON and USER_PRESENT each get one immediate attempt per screen cycle.
 * This matters because SCREEN_ON normally arrives while the keyguard is still
 * active, whereas USER_PRESENT arrives only after the user has unlocked it.
 * Detector and timer retries are rate-limited without suppressing that second,
 * semantically different attempt.
 */
class WakeRecoveryGate(
    private val retryIntervalMs: Long,
) {
    private var screenCycle = 0L
    private var lastScreenOnCycle = -1L
    private var lastUserPresentCycle = -1L
    private var lastPackage: String? = null
    private var lastAttemptElapsedMs = Long.MIN_VALUE

    fun onScreenOff() {
        screenCycle++
        lastScreenOnCycle = -1L
        lastUserPresentCycle = -1L
        resetAttempts()
    }

    fun shouldAttempt(
        packageName: String,
        signal: WakeRecoverySignal,
        nowElapsedMs: Long,
    ): Boolean {
        if (packageName.isBlank()) return false
        when (signal) {
            WakeRecoverySignal.SCREEN_ON -> {
                if (lastScreenOnCycle == screenCycle && lastPackage == packageName) {
                    return false
                }
                lastScreenOnCycle = screenCycle
                record(packageName, nowElapsedMs)
                return true
            }
            WakeRecoverySignal.USER_PRESENT -> {
                if (lastUserPresentCycle == screenCycle && lastPackage == packageName) {
                    return false
                }
                lastUserPresentCycle = screenCycle
                record(packageName, nowElapsedMs)
                return true
            }
            WakeRecoverySignal.FOREGROUND,
            WakeRecoverySignal.RETRY,
            -> {
                val packageChanged = lastPackage != packageName
                val retryDue = lastAttemptElapsedMs == Long.MIN_VALUE ||
                    nowElapsedMs - lastAttemptElapsedMs >= retryIntervalMs
                if (!packageChanged && !retryDue) return false
                record(packageName, nowElapsedMs)
                return true
            }
        }
    }

    fun reset(packageName: String? = null) {
        if (packageName == null || packageName == lastPackage) {
            resetAttempts()
        }
    }

    private fun record(packageName: String, nowElapsedMs: Long) {
        lastPackage = packageName
        lastAttemptElapsedMs = nowElapsedMs
    }

    private fun resetAttempts() {
        lastPackage = null
        lastAttemptElapsedMs = Long.MIN_VALUE
    }
}
