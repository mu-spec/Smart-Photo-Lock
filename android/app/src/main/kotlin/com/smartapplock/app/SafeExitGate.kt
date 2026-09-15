package com.smartapplock.app

/**
 * The native state machine for the emergency Return-to-Home presentation.
 *
 * A safe exit abandons the current challenge presentation; it never
 * authorizes the protected package. The pending challenge/generation is
 * supplied by the caller on every resolution so an old exit cannot consume a
 * newer security ticket.
 */
data class SafeExitRequest(
    val challenge: ProtectionStateStore.PendingChallenge,
    val homePackage: String,
)

enum class SafeExitResolution {
    NONE,
    WAITING,
    CONFIRMED,
    FALLBACK,
    STALE,
}

class SafeExitGate {
    private var activeRequest: SafeExitRequest? = null

    /**
     * Starts an exit. Repeated requests for the same ticket are idempotent
     * and do not extend the bounded coordination window.
     *
     * Returns true only when a new request replaced the previous request.
     */
    @Synchronized
    fun begin(request: SafeExitRequest): Boolean {
        if (activeRequest == request) return false
        activeRequest = request
        return true
    }

    @Synchronized
    fun request(): SafeExitRequest? = activeRequest

    @Synchronized
    fun isInProgress(): Boolean = activeRequest != null

    /**
     * Resolves a foreground report. Only the exact requested Home package
     * and exact current challenge generation can confirm the exit. A stale
     * request is discarded without touching the newer ticket.
     */
    @Synchronized
    fun resolveForeground(
        currentChallenge: ProtectionStateStore.PendingChallenge?,
        foregroundPackage: String,
    ): SafeExitResolution {
        val request = activeRequest ?: return SafeExitResolution.NONE
        if (currentChallenge != request.challenge) {
            activeRequest = null
            return SafeExitResolution.STALE
        }
        if (foregroundPackage != request.homePackage) {
            return SafeExitResolution.WAITING
        }
        activeRequest = null
        return SafeExitResolution.CONFIRMED
    }

    /**
     * Resolves the bounded detector-independent fallback. It is valid only
     * while the exact challenge ticket still exists; otherwise the newer
     * security state wins and the old exit is discarded.
     */
    @Synchronized
    fun resolveTimeout(
        currentChallenge: ProtectionStateStore.PendingChallenge?,
    ): SafeExitResolution {
        val request = activeRequest ?: return SafeExitResolution.NONE
        if (currentChallenge != request.challenge) {
            activeRequest = null
            return SafeExitResolution.STALE
        }
        activeRequest = null
        return SafeExitResolution.FALLBACK
    }

    @Synchronized
    fun cancel() {
        activeRequest = null
    }
}
