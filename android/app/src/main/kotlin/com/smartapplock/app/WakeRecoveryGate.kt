package com.smartapplock.app

/** Why native wake recovery is being requested. */
enum class WakeRecoverySignal { SCREEN_ON, USER_PRESENT, FOREGROUND, RETRY }

/** Selects the protected package that SCREEN_OFF must preserve. */
object WakeReauthTargetPolicy {
    fun resolve(
        observedPackage: String?,
        rememberedPackage: String?,
        isProtected: (String) -> Boolean,
    ): String? {
        if (!observedPackage.isNullOrBlank() && isProtected(observedPackage)) {
            return observedPackage
        }
        return rememberedPackage
            ?.takeIf { it.isNotBlank() && isProtected(it) }
    }
}

/**
 * Prevents an unprotected foreground report during display-off transition
 * from consuming an unresolved protected-app ticket before ACTION_SCREEN_OFF
 * creates the fresh wake generation.
 */
object ScreenOffForegroundPolicy {
    fun shouldPreservePending(
        screenInteractive: Boolean,
        pending: ProtectionStateStore.PendingChallenge?,
        wakeReauthPackage: String?,
    ): Boolean = !screenInteractive &&
        (pending != null || !wakeReauthPackage.isNullOrBlank())
}

/** Exact-match guard shared by onCreate/onResume/onNewIntent recovery. */
object RecoveryIntentPolicy {
    fun matches(
        pending: ProtectionStateStore.PendingChallenge?,
        packageName: String?,
        generation: Long,
    ): Boolean = !packageName.isNullOrBlank() &&
        generation >= 0L &&
        pending?.packageName == packageName &&
        pending.generation == generation
}

/** A route is safe to hand off only when it is current and not keyguard-covered. */
object ChallengeReadyPolicy {
    fun canHandOff(
        activityResumed: Boolean,
        keyguardLocked: Boolean,
        pendingMatches: Boolean,
    ): Boolean = activityResumed && !keyguardLocked && pendingMatches
}

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

/** What an unprotected foreground report may do to a READY challenge ticket. */
enum class ReadyTicketAction {
    /** Not proof of a leave: the rendered ticket stays valid. */
    KEEP,

    /** Confirmed genuine leave: clear exactly this ticket. */
    ABANDON,

    /** Possible leave reported while the challenge Activity is still resumed. */
    DEFER,
}

/**
 * A non-transient unprotected report that arrived while the challenge
 * Activity was still resumed. It can only be confirmed by the following
 * `MainActivity.onPause` for the same exact ticket within a bounded window.
 */
data class ChallengeAbandonCandidate(
    val ticket: ProtectionStateStore.PendingChallenge,
    val packageName: String,
    val reportedAtElapsedMs: Long,
)

/**
 * Phase 5 / H-1 (F1 + F2): decides whether an unprotected foreground report
 * proves the user left a rendered challenge.
 *
 * Accessibility reports windows, not apps. System UI (shade, volume, power
 * menu, keyguard, BiometricPrompt), framework dialogs and the keyboard emit
 * window-state events without the user leaving. Such reports must neither
 * abandon an unresolved ticket nor erase the wake re-authentication identity.
 * A genuine leave is an unprotected, non-transient target AND a challenge
 * Activity that is no longer resumed. Every non-ABANDON outcome keeps state,
 * which is the fail-closed direction.
 */
object ChallengeAbandonPolicy {
    /** Bound between the leave report and the matching onPause. */
    const val CONFIRM_WINDOW_MS = 1_500L

    val SYSTEM_TRANSIENT_PACKAGES: Set<String> = setOf(
        "android",
        "com.android.systemui",
    )

    /** `Settings.Secure.DEFAULT_INPUT_METHOD` is "package/service". */
    fun imePackageFromSetting(value: String?): String? =
        value?.substringBefore('/')?.trim()?.takeIf { it.isNotEmpty() }

    /** A report that can never prove the user left. Blank is never proof. */
    fun isTransientWindow(packageName: String, imePackage: String?): Boolean =
        packageName.isBlank() ||
            packageName in SYSTEM_TRANSIENT_PACKAGES ||
            (!imePackage.isNullOrBlank() && packageName == imePackage)

    /** F2: only a non-transient unprotected target may forget the wake identity. */
    fun mayForgetWakeIdentity(protectedTarget: Boolean, transient: Boolean): Boolean =
        !protectedTarget && !transient

    /** F1: the action for the current ready ticket on this report. */
    fun readyTicketAction(
        protectedTarget: Boolean,
        transient: Boolean,
        challengeActivityResumed: Boolean,
        screenInteractive: Boolean,
    ): ReadyTicketAction = when {
        protectedTarget || transient || !screenInteractive -> ReadyTicketAction.KEEP
        challengeActivityResumed -> ReadyTicketAction.DEFER
        else -> ReadyTicketAction.ABANDON
    }

    /**
     * F1 deferred confirmation at `MainActivity.onPause`. Only the exact
     * ticket that was ready when the candidate was recorded, still ready and
     * still pending, can be abandoned. A replaced, consumed or cleared ticket
     * (screen-off, authorization, safe exit, reconfiguration) is never touched.
     */
    fun confirmsDeferred(
        candidate: ChallengeAbandonCandidate?,
        ready: ProtectionStateStore.PendingChallenge?,
        pending: ProtectionStateStore.PendingChallenge?,
        challengeActivityResumed: Boolean,
        screenInteractive: Boolean,
        nowElapsedMs: Long,
    ): Boolean {
        if (candidate == null || challengeActivityResumed || !screenInteractive) {
            return false
        }
        if (ready != candidate.ticket || pending != candidate.ticket) return false
        val elapsed = nowElapsedMs - candidate.reportedAtElapsedMs
        return elapsed in 0L..CONFIRM_WINDOW_MS
    }
}
