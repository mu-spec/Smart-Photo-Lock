package com.smartapplock.app

import android.content.Context
import android.os.SystemClock

/** Minimal non-secret state required to recover enforcement without Dart. */
object ProtectionStateStore {
    private const val PREFS = "smart_app_lock_protection_bootstrap"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_PACKAGES = "protected_packages"
    private const val KEY_PENDING = "pending_challenge"
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
    }

    fun isEnabled(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_ENABLED, false)

    fun protectedPackages(context: Context): Set<String> =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getStringSet(KEY_PACKAGES, emptySet())?.toSet() ?: emptySet()

    fun isProtected(context: Context, packageName: String): Boolean =
        isEnabled(context) && protectedPackages(context).contains(packageName)

    fun setPendingChallenge(context: Context, packageName: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_PENDING, packageName).apply()
    }

    fun takePendingChallenge(context: Context): String? {
        // The pending package is also the native shield's fail-closed latch.
        // Reading it during Flutter reconstruction must not clear it. The
        // latch is cleared only after a resumed, rendered challenge confirms
        // the hand-off through markChallengeReady, or after authentication
        // explicitly authorizes the same package.
        return pendingChallenge(context)
    }

    fun pendingChallenge(context: Context): String? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_PENDING, null)

    fun clearPendingChallenge(context: Context, expectedPackage: String? = null): Boolean {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (expectedPackage != null &&
            preferences.getString(KEY_PENDING, null) != expectedPackage
        ) {
            return false
        }
        preferences.edit().remove(KEY_PENDING).apply()
        return true
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

    fun heartbeat() {
        lastHeartbeatElapsedMs = SystemClock.elapsedRealtime()
    }

    fun markEngineUnavailable() {
        lastHeartbeatElapsedMs = 0L
    }

    fun isEngineHealthy(nowElapsedMs: Long = SystemClock.elapsedRealtime()): Boolean =
        lastHeartbeatElapsedMs > 0L &&
            nowElapsedMs - lastHeartbeatElapsedMs <= HEARTBEAT_LEASE_MS
}
