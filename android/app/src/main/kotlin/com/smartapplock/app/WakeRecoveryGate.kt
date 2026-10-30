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

// -- F3: fail-closed restore in a fresh WatcherService process ---------------

/**
 * What UsageEvents can say about the foreground at a process restart. It is
 * historical: [App] is only the latest activity resume since boot that is
 * not this app, a system/framework window or the keyboard. It is never
 * proof of the current foreground on its own; see [RestartRecoveryPolicy].
 */
sealed class ForegroundEvidence {
    /** No Usage Access, query failure, clock anomaly or no usable event. */
    object Unknown : ForegroundEvidence()

    data class App(val packageName: String, val eventWallMs: Long) : ForegroundEvidence()
}

/**
 * Pure selection over UsageEvents in stream order. Only activity resumes
 * count. Own, transient (H-1 classification) and blank packages can never
 * prove a foreground change and are skipped. A future-dated event means the
 * wall clock moved after it was logged, so ordering is unreliable and the
 * whole result is [ForegroundEvidence.Unknown] (fail closed).
 */
class RestartForegroundEvidenceSelector(
    private val ownPackage: String,
    private val imePackage: String?,
    private val nowWallMs: Long,
    private val lowerBoundWallMs: Long,
) {
    private var bestPackage: String? = null
    private var bestWallMs = Long.MIN_VALUE
    private var clockAnomaly = false

    fun offer(packageName: String?, eventWallMs: Long, isActivityResume: Boolean) {
        if (!isActivityResume || packageName.isNullOrBlank() || eventWallMs <= 0L) return
        if (eventWallMs > nowWallMs + FUTURE_TOLERANCE_MS) {
            clockAnomaly = true
            return
        }
        if (eventWallMs < lowerBoundWallMs) return
        if (packageName == ownPackage) return
        if (ChallengeAbandonPolicy.isTransientWindow(packageName, imePackage)) return
        if (eventWallMs >= bestWallMs) {
            bestWallMs = eventWallMs
            bestPackage = packageName
        }
    }

    fun result(): ForegroundEvidence {
        val packageName = bestPackage
        return if (clockAnomaly || packageName == null) {
            ForegroundEvidence.Unknown
        } else {
            ForegroundEvidence.App(packageName, bestWallMs)
        }
    }

    companion object {
        const val MAX_LOOKBACK_MS = 24L * 60L * 60L * 1_000L
        const val FUTURE_TOLERANCE_MS = 10_000L

        /** Events from before this boot, or older than the cap, are ignored. */
        fun lowerBoundWallMs(nowWallMs: Long, nowElapsedMs: Long): Long =
            maxOf(nowWallMs - MAX_LOOKBACK_MS, nowWallMs - nowElapsedMs)
    }
}

/**
 * F3 UsageEvents query window for the restart decision: one query over
 * [begin, end). `queryEvents` treats begin as inclusive and end as
 * EXCLUSIVE, so the end must lie well beyond
 * [RestartForegroundEvidenceSelector.FUTURE_TOLERANCE_MS]: future-dated
 * resumes (the wall clock was set back after they were logged) have to reach
 * the selector, which turns them into [ForegroundEvidence.Unknown] (fail
 * closed) instead of letting an older unprotected resume look newer than
 * the identity stamp.
 *
 * The end is a bounded horizon, not `Long.MAX_VALUE`: it mirrors the 24 h
 * lookback, keeps the scanned span (at most ~48 h) bounded on every
 * implementation, and avoids depending on how an OEM UsageStats service
 * treats extreme end times. A single resume between 10 s and 24 h in the
 * future is enough to fail closed.
 *
 * Mitigation only, not a clock-rollback guarantee: Android may rebase
 * (AOSP time-change correction), omit or filter future-dated events, and a
 * rollback that leaves no resume beyond the tolerance is undetectable here.
 */
object RestartUsageEventsQuery {
    const val FUTURE_HORIZON_MS = 24L * 60L * 60L * 1_000L

    fun beginWallMs(nowWallMs: Long, nowElapsedMs: Long): Long =
        RestartForegroundEvidenceSelector.lowerBoundWallMs(nowWallMs, nowElapsedMs)

    /** Null when the window cannot be represented; the caller fails closed. */
    fun endWallMs(nowWallMs: Long): Long? =
        if (nowWallMs > Long.MAX_VALUE - FUTURE_HORIZON_MS) null else nowWallMs + FUTURE_HORIZON_MS

    /**
     * Runs exactly one [query] over the window and selects the evidence.
     * Events outside the window that an implementation still returns are
     * handled by the selector (old: ignored, future: Unknown).
     */
    fun collect(
        ownPackage: String,
        imePackage: String?,
        nowWallMs: Long,
        nowElapsedMs: Long,
        query: (beginWallMs: Long, endWallMs: Long, sink: (String?, Long, Boolean) -> Unit) -> Unit,
    ): ForegroundEvidence {
        val begin = beginWallMs(nowWallMs, nowElapsedMs)
        val end = endWallMs(nowWallMs) ?: return ForegroundEvidence.Unknown
        val selector = RestartForegroundEvidenceSelector(
            ownPackage = ownPackage,
            imePackage = imePackage,
            nowWallMs = nowWallMs,
            lowerBoundWallMs = begin,
        )
        query(begin, end) { packageName, eventWallMs, isActivityResume ->
            selector.offer(packageName, eventWallMs, isActivityResume)
        }
        return selector.result()
    }
}

/** Boot scoping and wall-clock ordering for the remembered wake identity. */
object WakeIdentityBootScope {
    const val WALL_CLOCK_TOLERANCE_MS = 10_000L

    /**
     * True only when the identity provably belongs to the current boot.
     * `Settings.Global.BOOT_COUNT` decides when both sides know it; an
     * elapsedRealtime regression always means another boot. Without a boot
     * count, the boot-time wall anchor (wall - elapsed) must match.
     */
    fun sameBoot(
        storedBootCount: Int?,
        currentBootCount: Int?,
        storedElapsedMs: Long?,
        storedWallMs: Long?,
        nowElapsedMs: Long,
        nowWallMs: Long,
    ): Boolean {
        if (storedElapsedMs == null || storedElapsedMs > nowElapsedMs) return false
        if (storedBootCount != null && storedBootCount >= 0 &&
            currentBootCount != null && currentBootCount >= 0
        ) {
            return storedBootCount == currentBootCount
        }
        return wallClockConsistent(storedElapsedMs, storedWallMs, nowElapsedMs, nowWallMs)
    }

    /** No wall-clock change (beyond tolerance) since the stamp was written. */
    fun wallClockConsistent(
        storedElapsedMs: Long?,
        storedWallMs: Long?,
        nowElapsedMs: Long,
        nowWallMs: Long,
    ): Boolean {
        if (storedElapsedMs == null || storedWallMs == null) return false
        val drift = (nowWallMs - nowElapsedMs) - (storedWallMs - storedElapsedMs)
        return kotlin.math.abs(drift) <= WALL_CLOCK_TOLERANCE_MS
    }
}

data class RestartRecoveryInput(
    val protectionEnabled: Boolean,
    val pendingExists: Boolean,
    val uiActivityResumed: Boolean,
    val rememberedPackage: String?,
    val rememberedSameBoot: Boolean,
    val rememberedStampWallMs: Long?,
    val wallClockConsistent: Boolean,
    val evidence: ForegroundEvidence,
)

enum class RestartRecoveryDecision(val challenges: Boolean) {
    SKIP_PROTECTION_DISABLED(false),
    SKIP_PENDING_TICKET(false),
    SKIP_UI_RESUMED(false),
    CHALLENGE_PROTECTED_FOREGROUND_EVIDENCE(true),
    CHALLENGE_REMEMBERED_FOREGROUND_UNKNOWN(true),
    CHALLENGE_REMEMBERED_EVIDENCE_NOT_NEWER(true),
    CHALLENGE_REMEMBERED_EVIDENCE_UNORDERED(true),
    NONE_NEWER_UNPROTECTED_EVIDENCE(false),
    NONE_REMEMBERED_OTHER_BOOT(false),
    NONE_NO_PROTECTED_TARGET(false),
}

data class RestartRecoveryResult(
    val decision: RestartRecoveryDecision,
    val targetPackage: String?,
)

/**
 * F3 one-shot restart decision. Evidence is asymmetric: a protected latest
 * resume may ADD a challenge (fail closed); an unprotected one may only
 * SUPPRESS the remembered same-boot identity when it is strictly newer than
 * the identity stamp under a provably unchanged wall clock. Stale, equal,
 * unordered and unknown evidence fall back to the remembered identity.
 * An existing ticket is never replaced and nothing is ever authorized here.
 */
object RestartRecoveryPolicy {
    fun decide(
        input: RestartRecoveryInput,
        isProtected: (String) -> Boolean,
    ): RestartRecoveryResult {
        if (!input.protectionEnabled) return none(RestartRecoveryDecision.SKIP_PROTECTION_DISABLED)
        if (input.pendingExists) return none(RestartRecoveryDecision.SKIP_PENDING_TICKET)
        if (input.uiActivityResumed) return none(RestartRecoveryDecision.SKIP_UI_RESUMED)

        val evidence = input.evidence
        if (evidence is ForegroundEvidence.App && evidence.packageName.isNotBlank() &&
            isProtected(evidence.packageName)
        ) {
            return challenge(
                RestartRecoveryDecision.CHALLENGE_PROTECTED_FOREGROUND_EVIDENCE,
                evidence.packageName,
            )
        }
        val remembered = input.rememberedPackage
            ?.takeIf { it.isNotBlank() && isProtected(it) }
            ?: return none(RestartRecoveryDecision.NONE_NO_PROTECTED_TARGET)
        if (!input.rememberedSameBoot) return none(RestartRecoveryDecision.NONE_REMEMBERED_OTHER_BOOT)
        if (evidence !is ForegroundEvidence.App) {
            return challenge(RestartRecoveryDecision.CHALLENGE_REMEMBERED_FOREGROUND_UNKNOWN, remembered)
        }
        val stamp = input.rememberedStampWallMs
        if (!input.wallClockConsistent || stamp == null) {
            return challenge(RestartRecoveryDecision.CHALLENGE_REMEMBERED_EVIDENCE_UNORDERED, remembered)
        }
        if (evidence.eventWallMs > stamp) {
            return none(RestartRecoveryDecision.NONE_NEWER_UNPROTECTED_EVIDENCE)
        }
        return challenge(RestartRecoveryDecision.CHALLENGE_REMEMBERED_EVIDENCE_NOT_NEWER, remembered)
    }

    private fun none(decision: RestartRecoveryDecision) = RestartRecoveryResult(decision, null)

    private fun challenge(decision: RestartRecoveryDecision, target: String) =
        RestartRecoveryResult(decision, target)
}

/** Exactly one successful [tryAcquire] per instance (per process when static). */
class OneShotLatch {
    private val acquired = java.util.concurrent.atomic.AtomicBoolean(false)

    fun tryAcquire(): Boolean = acquired.compareAndSet(false, true)
}
