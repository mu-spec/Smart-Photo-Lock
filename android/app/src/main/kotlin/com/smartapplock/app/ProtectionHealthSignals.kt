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

    fun onConnected() {
        connected = true
    }

    fun onDisconnected() {
        connected = false
    }
}
