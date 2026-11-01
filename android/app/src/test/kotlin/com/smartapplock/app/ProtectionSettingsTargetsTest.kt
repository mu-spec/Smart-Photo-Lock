package com.smartapplock.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Phase 7 / M2 — Fix Protection settings links.
 *
 * PRODUCTION code: [ProtectionSettingsTargets] runs as-is on the JVM. The
 * WatcherChannel wiring is checked by source contract; whether an OEM
 * build actually resolves each Settings screen is device-only (UNVERIFIED).
 */
class ProtectionSettingsTargetsTest {
    private val sdks = listOf(24, 25, 26, 28, 30, 33, 34, 36)

    @Test
    fun onlyTheThreeAllowlistedTargetsResolve() {
        for (sdk in sdks) {
            assertNotNull(ProtectionSettingsTargets.spec("notifications", sdk))
            assertNotNull(ProtectionSettingsTargets.spec("app_details", sdk))
            assertNotNull(ProtectionSettingsTargets.spec("battery_saver", sdk))
            for (other in listOf(
                null, "", "overlay", "accessibility", "usage_access", "biometric",
                "biometric_enroll", "ignore_battery_optimizations", "APP_DETAILS",
                "android.settings.APPLICATION_DETAILS_SETTINGS",
            )) {
                assertNull("$other must not resolve", ProtectionSettingsTargets.spec(other, sdk))
            }
        }
    }

    @Test
    fun notificationSettingsUseTheAppScreenFromApi26WithAppInfoFallback() {
        for (sdk in sdks) {
            val spec = ProtectionSettingsTargets.spec("notifications", sdk)!!
            if (sdk >= 26) {
                assertEquals("android.settings.APP_NOTIFICATION_SETTINGS", spec.action)
                assertTrue(spec.packageExtra)
                assertEquals(
                    "android.settings.APPLICATION_DETAILS_SETTINGS",
                    spec.fallback!!.action,
                )
                assertTrue(spec.fallback!!.packageData)
            } else {
                assertEquals("android.settings.APPLICATION_DETAILS_SETTINGS", spec.action)
                assertTrue(spec.packageData)
            }
        }
    }

    @Test
    fun appDetailsAndBatterySaverTargets() {
        val details = ProtectionSettingsTargets.spec("app_details", 28)!!
        assertEquals("android.settings.APPLICATION_DETAILS_SETTINGS", details.action)
        assertTrue(details.packageData)
        assertNull(details.fallback)
        val saver = ProtectionSettingsTargets.spec("battery_saver", 28)!!
        assertEquals("android.settings.BATTERY_SAVER_SETTINGS", saver.action)
        assertFalse(saver.packageData || saver.packageExtra)
        assertEquals("android.provider.extra.APP_PACKAGE", ProtectionSettingsTargets.EXTRA_APP_PACKAGE)
    }

    @Test
    fun noGrantExemptionOrEnrollmentIntentIsReachable() {
        val policy = source("ProtectionSettingsTargets.kt")
        for (forbidden in listOf(
            "IGNORE_BATTERY_OPTIMIZATION", "BIOMETRIC_ENROLL", "FINGERPRINT_ENROLL",
            "MANAGE_OVERLAY_PERMISSION", "ACCESSIBILITY_SETTINGS", "USAGE_ACCESS_SETTINGS",
            "REQUEST_",
        )) {
            assertFalse("policy must not contain $forbidden", policy.contains(forbidden))
        }
    }

    @Test
    fun channelOpenerOnlyStartsTheAllowlistedSettingsActivity() {
        val channel = source("WatcherChannel.kt")
        assertTrue(channel.contains("\"openProtectionSettings\" -> result.success("))
        val opener = body(channel, "private fun openProtectionSettings(")
        assertTrue(opener.contains("ProtectionSettingsTargets.spec(target, Build.VERSION.SDK_INT)"))
        assertTrue(opener.contains("activity.startActivity(intent)"))
        assertTrue("a failed start falls back, never throws", opener.contains("spec = spec.fallback"))
        assertTrue(opener.contains("return false"))
        for (forbidden in listOf(
            "authorize", "revokeAll", "clearPendingChallenge", "takePendingChallenge",
            "ProtectionOverlayController", "WatcherService.", "ProtectionStateStore",
            "configure(", "heartbeat(", "setLastError", "requestPermissions",
        )) {
            assertFalse("opener must not call $forbidden", opener.contains(forbidden))
        }
    }

    // -- helpers ----------------------------------------------------------------

    private fun body(src: String, signature: String): String {
        val start = src.indexOf(signature)
        assertTrue("missing $signature", start >= 0)
        var depth = 0
        var i = src.indexOf('{', start)
        val open = i
        while (i < src.length) {
            when (src[i]) {
                '{' -> depth++
                '}' -> if (--depth == 0) return src.substring(open, i + 1)
            }
            i++
        }
        error("unbalanced $signature")
    }

    private fun source(name: String): String {
        val relative = "src/main/kotlin/com/smartapplock/app"
        val dir = listOf(File(relative), File("android/app/$relative")).firstOrNull { it.isDirectory }
        assertNotNull("source dir not found", dir)
        return File(dir!!, name).readText()
    }
}
