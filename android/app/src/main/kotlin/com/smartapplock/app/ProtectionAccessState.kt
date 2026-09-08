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
     * Duplicate observations never refresh an authorization. A transition
     * away applies immediate re-lock or starts the configured grace window.
     */
    @Synchronized
    fun observeForeground(
        packageName: String,
        protected: Boolean,
        nowElapsedMs: Long = SystemClock.elapsedRealtime(),
    ): Decision {
        val previous = currentForegroundPackage
        if (previous != packageName) {
            currentForegroundPackage = packageName
            val previousAuthorization = previous?.let(authorizations::get)
            if (previousAuthorization != null) {
                if (gracePeriodMs == 0L) {
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
            if (gracePeriodMs > 0L && nowElapsedMs - awaySince < gracePeriodMs) {
                authorization.awaySinceElapsedMs = null
                authorization.activeUntilElapsedMs =
                    nowElapsedMs + authorization.sessionWindowMs
                return Decision.ALLOW
            }
            authorizations.remove(packageName)
            return Decision.CHALLENGE
        }
        if (nowElapsedMs < authorization.activeUntilElapsedMs) {
            return Decision.ALLOW
        }
        authorizations.remove(packageName)
        return Decision.CHALLENGE
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
