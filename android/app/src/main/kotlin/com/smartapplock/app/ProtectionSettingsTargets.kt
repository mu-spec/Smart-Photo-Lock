package com.smartapplock.app

/**
 * Phase 7 / M2 (Fix Protection): the ONLY Android Settings screens the
 * health dashboard may open directly, as a pure allowlist (JVM-testable).
 *
 * Opening a Settings screen grants nothing: the user still decides there.
 * No permission, battery-optimization exemption or biometric enrollment
 * intent is reachable from here. Overlay, Accessibility and Usage Access
 * keep their existing disclose → settings → recheck setup screens.
 *
 * Action strings are the platform constant values (Settings.ACTION_*),
 * spelled out so the policy stays testable without android.jar.
 */
object ProtectionSettingsTargets {
    const val NOTIFICATIONS = "notifications"
    const val APP_DETAILS = "app_details"
    const val BATTERY_SAVER = "battery_saver"

    const val ACTION_APP_NOTIFICATION_SETTINGS = "android.settings.APP_NOTIFICATION_SETTINGS"
    const val ACTION_APPLICATION_DETAILS_SETTINGS = "android.settings.APPLICATION_DETAILS_SETTINGS"
    const val ACTION_BATTERY_SAVER_SETTINGS = "android.settings.BATTERY_SAVER_SETTINGS"
    const val EXTRA_APP_PACKAGE = "android.provider.extra.APP_PACKAGE"

    /** One Settings intent: [packageExtra] / [packageData] target this app. */
    data class Spec(
        val action: String,
        val packageExtra: Boolean = false,
        val packageData: Boolean = false,
        val fallback: Spec? = null,
    )

    private val appDetails = Spec(ACTION_APPLICATION_DETAILS_SETTINGS, packageData = true)

    /** Allowlisted spec for [target] on API [sdk]; anything else → null. */
    fun spec(target: String?, sdk: Int): Spec? = when (target) {
        // App notification settings exist from API 26; App info otherwise
        // (and as fallback when an OEM build lacks the screen).
        NOTIFICATIONS -> if (sdk >= 26) {
            Spec(ACTION_APP_NOTIFICATION_SETTINGS, packageExtra = true, fallback = appDetails)
        } else {
            appDetails
        }
        // App info: Android exposes the app's background/battery controls
        // under it. OEM power managers have no public entry point.
        APP_DETAILS -> appDetails
        BATTERY_SAVER -> Spec(ACTION_BATTERY_SAVER_SETTINGS, fallback = null)
        else -> null
    }
}
