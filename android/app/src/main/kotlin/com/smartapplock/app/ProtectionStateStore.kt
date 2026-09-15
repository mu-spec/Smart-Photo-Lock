package com.smartapplock.app

import android.content.Context
import android.os.SystemClock

/** Minimal non-secret state required to recover enforcement without Dart. */
object ProtectionStateStore {
    data class PendingChallenge(
        val packageName: String,
        val generation: Long,
    ) {
        fun toMap(): Map<String, Any> = mapOf(
            "packageName" to packageName,
            "generation" to generation,
        )
    }

    private const val PREFS = "smart_app_lock_protection_bootstrap"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_PACKAGES = "protected_packages"
    private const val KEY_PENDING = "pending_challenge"
    private const val KEY_PENDING_GENERATION = "pending_challenge_generation"
    private const val KEY_NEXT_GENERATION = "next_challenge_generation"
    private const val KEY_WAKE_REAUTH_PACKAGE = "wake_reauth_package"
    private const val KEY_LAST_ERROR = "last_error"

    fun configure(context: Context, enabled: Boolean, packages: Set<String>) {
        val normalized = packages.filter { it.isNotBlank() }.toSet()
        ProtectionAccessState.retainProtectedPackages(normalized)
        if (!enabled || normalized.isEmpty()) {
            ProtectionAccessState.revokeAll()
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(KEY_ENABLED, enabled && normalized.isNotEmpty())
            .putStringSet(KEY_PACKAGES, normalized)
            .apply()
        val pending = pendingChallenge(context)
        if (!enabled || (pending != null && pending.packageName !in normalized)) {
            clearPendingChallenge(context)
            ProtectionRuntime.invalidateChallengeHandoff()
        }
        val wakePackage = rememberedWakeReauthPackage(context)
        if (!enabled || (wakePackage != null && wakePackage !in normalized)) {
            rememberWakeReauthPackage(context, null)
        }
    }

    fun isEnabled(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_ENABLED, false)

    fun protectedPackages(context: Context): Set<String> =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getStringSet(KEY_PACKAGES, emptySet())?.toSet() ?: emptySet()

    fun isProtected(context: Context, packageName: String): Boolean =
        isEnabled(context) && protectedPackages(context).contains(packageName)

    /**
     * Returns the current ticket for [packageName], creating one when needed.
     * Repeated detector/retry events for the same package keep one generation.
     */
    @Synchronized
    fun ensurePendingChallenge(
        context: Context,
        packageName: String,
    ): PendingChallenge {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val current = readPendingChallenge(preferences)
        if (current?.packageName == packageName) return current
        return replacePendingChallenge(context, packageName)
    }

    /**
     * Creates a new ticket even when the package is unchanged. Screen-off uses
     * this to invalidate every pre-sleep ready/authentication callback.
     */
    @Synchronized
    fun replacePendingChallenge(
        context: Context,
        packageName: String,
    ): PendingChallenge {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val generation = preferences.getLong(KEY_NEXT_GENERATION, 0L) + 1L
        val pending = PendingChallenge(packageName, generation)
        // commit() is intentional: the fail-closed recovery ticket must reach
        // disk before Android can kill the process during screen-off/wake.
        preferences.edit()
            .putString(KEY_PENDING, packageName)
            .putLong(KEY_PENDING_GENERATION, generation)
            .putLong(KEY_NEXT_GENERATION, generation)
            .commit()
        ProtectionRuntime.invalidateChallengeHandoff()
        return pending
    }

    fun takePendingChallenge(context: Context): PendingChallenge? {
        // Pending represents unresolved authentication, not merely an overlay
        // transition. Reading it during Flutter reconstruction and rendering
        // the route must not clear it. It is cleared only by exact successful
        // authorization, confirmed safe exit, or exact bounded emergency
        // abandonment of the current presentation.
        return pendingChallenge(context)
    }

    fun pendingChallenge(context: Context): PendingChallenge? =
        readPendingChallenge(
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE),
        )

    /**
     * Persists only the non-secret package identity needed to reconstruct a
     * screen-off challenge after native/Flutter process recreation. This is
     * deliberately separate from the pending presentation latch: a rendered
     * challenge clears the latch, but the active protected package must still
     * be known if the screen turns off a moment later.
     */
    @Synchronized
    fun rememberWakeReauthPackage(context: Context, packageName: String?) {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val normalized = packageName?.takeIf { it.isNotBlank() }
        if (preferences.getString(KEY_WAKE_REAUTH_PACKAGE, null) == normalized) return
        val editor = preferences.edit()
        if (normalized == null) {
            editor.remove(KEY_WAKE_REAUTH_PACKAGE)
        } else {
            editor.putString(KEY_WAKE_REAUTH_PACKAGE, normalized)
        }
        // This state is written on foreground transitions, not every poll.
        // Synchronous persistence ensures SCREEN_OFF/process death cannot
        // leave authorization revoked without the package identity.
        editor.commit()
    }

    fun wakeReauthPackage(context: Context): String? =
        rememberedWakeReauthPackage(context)
            ?.takeIf { it.isNotBlank() && isProtected(context, it) }

    private fun rememberedWakeReauthPackage(context: Context): String? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_WAKE_REAUTH_PACKAGE, null)

    /** Restores a pending ticket from the separate wake identity if needed. */
    @Synchronized
    fun restoreWakeReauthChallenge(context: Context): PendingChallenge? {
        pendingChallenge(context)?.let { return it }
        val packageName = wakeReauthPackage(context) ?: return null
        return replacePendingChallenge(context, packageName)
    }

    @Synchronized
    fun clearPendingChallenge(
        context: Context,
        expectedPackage: String? = null,
        expectedGeneration: Long? = null,
    ): Boolean {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val pending = readPendingChallenge(preferences)
        if (expectedPackage != null && pending?.packageName != expectedPackage) {
            return false
        }
        if (expectedGeneration != null && pending?.generation != expectedGeneration) {
            return false
        }
        preferences.edit()
            .remove(KEY_PENDING)
            .remove(KEY_PENDING_GENERATION)
            .apply()
        return true
    }

    private fun readPendingChallenge(
        preferences: android.content.SharedPreferences,
    ): PendingChallenge? {
        val packageName = preferences.getString(KEY_PENDING, null)
            ?.takeIf { it.isNotBlank() } ?: return null
        val generation = preferences.getLong(KEY_PENDING_GENERATION, 0L)
        // Legacy state from an older build is still fail-closed. Upgrade it
        // to generation zero; the next replacement gets a fresh generation.
        return PendingChallenge(packageName, generation)
    }

    fun setLastError(context: Context, message: String?) {
        val editor = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
        if (message == null) {
            editor.remove(KEY_LAST_ERROR)
        } else {
            editor.putString(KEY_LAST_ERROR, message)
        }
        editor.apply()
    }

    fun lastError(context: Context): String? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_LAST_ERROR, null)
}

/** Process-local liveness. It intentionally resets after genuine process death. */
object ProtectionRuntime {
    private const val HEARTBEAT_LEASE_MS = 6_000L

    @Volatile private var lastHeartbeatElapsedMs = 0L
    @Volatile var activityResumed = false

    @Volatile private var readyChallenge: ProtectionStateStore.PendingChallenge? = null

    fun heartbeat() {
        lastHeartbeatElapsedMs = SystemClock.elapsedRealtime()
    }

    fun markEngineUnavailable() {
        lastHeartbeatElapsedMs = 0L
    }

    @Synchronized
    fun markChallengeReady(challenge: ProtectionStateStore.PendingChallenge) {
        readyChallenge = challenge
    }

    @Synchronized
    fun isChallengeReady(challenge: ProtectionStateStore.PendingChallenge): Boolean =
        readyChallenge == challenge

    @Synchronized
    fun readyChallenge(): ProtectionStateStore.PendingChallenge? = readyChallenge

    @Synchronized
    fun consumeChallengeHandoff(
        packageName: String,
        generation: Long,
    ): Boolean {
        val ready = readyChallenge
        if (ready?.packageName != packageName || ready.generation != generation) {
            return false
        }
        readyChallenge = null
        return true
    }

    @Synchronized
    fun invalidateChallengeHandoff() {
        readyChallenge = null
    }

    fun isEngineHealthy(nowElapsedMs: Long = SystemClock.elapsedRealtime()): Boolean =
        lastHeartbeatElapsedMs > 0L &&
            nowElapsedMs - lastHeartbeatElapsedMs <= HEARTBEAT_LEASE_MS
}
