package com.smartapplock.app

/**
 * Phase 7 / M1 — observational native health signals.
 *
 * Everything here only READS platform state. Nothing authorizes, clears a
 * ticket, shows or hides the shield, changes a permission or starts a
 * component. A signal that cannot be observed reliably is reported as
 * `null` (UNKNOWN); Dart's health engine never treats UNKNOWN as healthy.
 */
object ProtectionHealthSignals {
    /** `ActivityManager.isBackgroundRestricted()` exists from API 28 (P). */
    const val MIN_SDK_BACKGROUND_RESTRICTION = 28

    /** Wire keys shared with `ProtectionEngineHealth.fromMap` in Dart. */
    const val KEY_ACCESSIBILITY_CONNECTED = "accessibilityServiceConnected"
    const val KEY_SHIELD_ARMED = "shieldArmed"
    const val KEY_CHALLENGE_PENDING = "challengePending"
    const val KEY_BACKGROUND_RESTRICTED = "backgroundRestricted"
    const val KEY_POWER_SAVE_MODE = "powerSaveMode"
    const val KEY_IGNORING_BATTERY_OPTIMIZATIONS = "ignoringBatteryOptimizations"
    const val KEY_SDK_INT = "sdkInt"

    /**
     * Android's user-facing "Restricted" background state (AOSP 9+).
     * Below API 28 the API does not exist → null (UNKNOWN/unsupported).
     * A failing read → null; never a fabricated "not restricted".
     * OEM power managers (for example ColorOS) are NOT reflected here.
     */
    fun backgroundRestricted(sdkInt: Int, read: () -> Boolean): Boolean? =
        if (sdkInt < MIN_SDK_BACKGROUND_RESTRICTION) null else probe(read)

    /** Any platform read that may throw: failure → null (UNKNOWN). */
    fun probe(read: () -> Boolean): Boolean? =
        try {
            read()
        } catch (_: Exception) {
            null
        }

    /** The additive health keys appended to the watcher `getHealth` map. */
    fun signals(
        accessibilityConnected: Boolean,
        shieldArmed: Boolean?,
        challengePending: Boolean?,
        backgroundRestricted: Boolean?,
        powerSaveMode: Boolean?,
        ignoringBatteryOptimizations: Boolean?,
        sdkInt: Int,
    ): Map<String, Any?> = mapOf(
        KEY_ACCESSIBILITY_CONNECTED to accessibilityConnected,
        KEY_SHIELD_ARMED to shieldArmed,
        KEY_CHALLENGE_PENDING to challengePending,
        KEY_BACKGROUND_RESTRICTED to backgroundRestricted,
        KEY_POWER_SAVE_MODE to powerSaveMode,
        KEY_IGNORING_BATTERY_OPTIMIZATIONS to ignoringBatteryOptimizations,
        KEY_SDK_INT to sdkInt,
    )
}

/**
 * Process-local record of whether Android currently has the detection
 * Accessibility service BOUND. "Enabled in Settings" is not the same as
 * running: an OEM kill, a crash back-off or a force-stop can leave the
 * setting on while no events are delivered. Observational only.
 */
object AccessibilityConnection {
    @Volatile
    var connected: Boolean = false
        private set

    /**
     * Phase 18 / M1F (F18-4 proposal): notified after every bound-state
     * change so the foreground-service status line is re-evaluated at once.
     * Set by WatcherService while it runs. Observational only.
     */
    @Volatile
    var onChange: (() -> Unit)? = null

    /** Phase 18 / M3 (F18-M3-1): see [AccessibilityAuthority]. */
    val authority = AccessibilityAuthority()

    fun onConnected() {
        connected = true
        onChange?.invoke()
    }

    fun onDisconnected() {
        connected = false
        // F18-M3-1: a source that is gone has no authority left, so its last
        // event must not keep suppressing the UsageEvents fallback.
        authority.invalidate()
        onChange?.invoke()
    }
}

/**
 * Phase 18 / M3 (F18-M3-1): whether a fresh Accessibility report still has
 * authority over the historical UsageEvents fallback. Process memory only.
 * The window and the comparison are the former inline WatcherService gate,
 * unchanged. It never grants anything: it only decides whether a UsageEvents
 * report is ignored because a newer Accessibility event already decided.
 */
class AccessibilityAuthority(private val windowMs: Long = WINDOW_MS) {
    @Volatile
    private var lastReportElapsedMs = 0L

    fun onAccessibilityReport(nowElapsedMs: Long) {
        lastReportElapsedMs = nowElapsedMs
    }

    fun invalidate() {
        lastReportElapsedMs = 0L
    }

    fun defersUsageEvents(nowElapsedMs: Long): Boolean {
        val last = lastReportElapsedMs
        return last > 0L && nowElapsedMs - last < windowMs
    }

    companion object {
        const val WINDOW_MS = 5_000L
    }
}

/** Phase 18 / M1F (F18-4 proposal): foreground-service status category. */
enum class WatcherStatus { ACTIVE, RECOVERING, NEEDS_ATTENTION }

/**
 * Phase 18 / M1F (F18-4 proposal): the foreground-service status line.
 *
 * An "active" status is reported only when Android reports the shield
 * permission (overlay) AND the Accessibility detection service bound. An
 * unknown (null) input never counts as granted.
 *
 * G14 E1: Usage Access alone is a best-effort, polling-based backup that
 * Android or a manufacturer battery manager can delay or pause, so on its
 * own it never yields ACTIVE or RECOVERING; it is NEEDS_ATTENTION, matching
 * the Flutter health state (ATTENTION REQUIRED while Accessibility is off or
 * not connected). Status text only: enforcement is unchanged, and
 * [usageAccessGranted] stays wired for the call site but cannot raise the
 * status.
 */
object WatcherStatusTextPolicy {
    fun status(
        engineHealthy: Boolean,
        overlayGranted: Boolean?,
        accessibilityConnected: Boolean?,
        @Suppress("UNUSED_PARAMETER") usageAccessGranted: Boolean?,
    ): WatcherStatus {
        val reliableDetection = accessibilityConnected == true
        if (overlayGranted != true || !reliableDetection) return WatcherStatus.NEEDS_ATTENTION
        return if (engineHealthy) WatcherStatus.ACTIVE else WatcherStatus.RECOVERING
    }
}
