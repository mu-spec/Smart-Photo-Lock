package com.smartapplock.app

import android.os.SystemClock

/**
 * Process-local authorization mirror used by the native early-enforcement
 * path.
 *
 * This is deliberately NOT persisted: process death and reboot erase every
 * authorization and therefore recover fail closed. Dart remains the only
 * component that can grant access, after a successful credential challenge.
 */
object ProtectionAccessState {
    enum class Decision { ALLOW, CHALLENGE }

    private data class Authorization(
        var activeUntilElapsedMs: Long,
        val sessionWindowMs: Long,
        var awaySinceElapsedMs: Long? = null,
    )

    private val authorizations = mutableMapOf<String, Authorization>()
    private var currentForegroundPackage: String? = null
    private var gracePeriodMs = 0L

    @Synchronized
    fun setGracePeriod(milliseconds: Long) {
        gracePeriodMs = milliseconds.coerceAtLeast(0L)
        if (gracePeriodMs == 0L) {
            val awayPackages = authorizations
                .filterValues { it.awaySinceElapsedMs != null }
                .keys
            authorizations.keys.removeAll(awayPackages)
        }
    }

    /** Called only after Dart has observed explicit authentication success. */
    @Synchronized
    fun authorize(
        packageName: String,
        sessionWindowMs: Long,
        nowElapsedMs: Long = SystemClock.elapsedRealtime(),
    ) {
        if (packageName.isBlank()) return
        val safeWindow = sessionWindowMs.coerceAtLeast(0L)
        authorizations[packageName] = Authorization(
            activeUntilElapsedMs = nowElapsedMs + safeWindow,
            sessionWindowMs = safeWindow,
        )
        currentForegroundPackage = packageName
    }

    /**
     * Records an actual foreground observation and returns whether native
     * presentation must fail closed for it.
     *
     * A transition away applies immediate re-lock or starts the configured
     * grace window. OD6: only an authorization still valid at departure
     * (`now < activeUntilElapsedMs`) gets a grace window; one already at or
     * past its deadline is removed, so a leave and quick return can never
     * revive an expired session.
     *
     * H-2 sliding inactivity window: a same-package observation of the
     * current foreground package whose authorization exists, is not away
     * (no grace window running) and has not yet expired slides
     * `activeUntilElapsedMs` to `now + sessionWindowMs` (monotonic
     * `elapsedRealtime`). Such observations are a proxy for continued
     * foreground presence only; they do not prove human activity. Nothing
     * else extends an authorization: an observation at or after the
     * deadline challenges and removes it, so an expired authorization is
     * never revived, and sliding never extends a grace window.
     *
     * U1-R: [mayRenew] is false for a protected UsageEvents report that the
     * latest Accessibility evidence does not corroborate. Such a report is
     * still enforced (it may revoke or challenge) but it can neither re-admit
     * an away authorization within grace nor slide the H-2 deadline.
     */
    @Synchronized
    fun observeForeground(
        packageName: String,
        protected: Boolean,
        nowElapsedMs: Long = SystemClock.elapsedRealtime(),
        mayRenew: Boolean = true,
    ): Decision {
        val previous = currentForegroundPackage
        if (previous != packageName) {
            currentForegroundPackage = packageName
            val previousAuthorization = previous?.let(authorizations::get)
            if (previousAuthorization != null) {
                if (gracePeriodMs == 0L ||
                    nowElapsedMs >= previousAuthorization.activeUntilElapsedMs
                ) {
                    authorizations.remove(previous)
                } else {
                    previousAuthorization.awaySinceElapsedMs = nowElapsedMs
                }
            }
        }

        if (!protected) return Decision.ALLOW
        val authorization = authorizations[packageName] ?: return Decision.CHALLENGE
        val awaySince = authorization.awaySinceElapsedMs
        if (awaySince != null) {
            if (mayRenew && gracePeriodMs > 0L && nowElapsedMs - awaySince < gracePeriodMs) {
                authorization.awaySinceElapsedMs = null
                authorization.activeUntilElapsedMs =
                    nowElapsedMs + authorization.sessionWindowMs
                return Decision.ALLOW
            }
            authorizations.remove(packageName)
            return Decision.CHALLENGE
        }
        if (nowElapsedMs < authorization.activeUntilElapsedMs) {
            // H-2: only continued presence in the SAME foreground package
            // slides the still-valid window; a transition never does.
            if (previous == packageName && mayRenew) {
                slidDeadline(nowElapsedMs, authorization)?.let {
                    authorization.activeUntilElapsedMs = it
                }
            }
            return Decision.ALLOW
        }
        authorizations.remove(packageName)
        return Decision.CHALLENGE
    }

    /**
     * `now + window` when that moves the deadline later without overflowing;
     * otherwise null and the existing deadline is kept (never shortened,
     * never wrapped).
     */
    private fun slidDeadline(nowElapsedMs: Long, authorization: Authorization): Long? {
        val window = authorization.sessionWindowMs
        if (window <= 0L || nowElapsedMs > Long.MAX_VALUE - window) return null
        val candidate = nowElapsedMs + window
        return if (candidate > authorization.activeUntilElapsedMs) candidate else null
    }

    @Synchronized
    fun revokeAll() {
        authorizations.clear()
    }

    @Synchronized
    fun retainProtectedPackages(packages: Set<String>) {
        authorizations.keys.retainAll(packages)
        if (currentForegroundPackage !in packages) {
            currentForegroundPackage = null
        }
    }

    @Synchronized
    fun currentForegroundPackage(): String? = currentForegroundPackage
}
