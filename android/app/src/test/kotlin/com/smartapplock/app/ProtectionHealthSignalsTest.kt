package com.smartapplock.app

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Phase 7 / M1 — native Protection Health signals.
 *
 * PRODUCTION code: [ProtectionHealthSignals] and [AccessibilityConnection]
 * run as-is on the JVM. The platform reads (ActivityManager, PowerManager,
 * the Accessibility bind lifecycle) are supplied as lambdas or checked by
 * source contracts; no Android device behaviour is proven here.
 */
class ProtectionHealthSignalsTest {
    @After
    fun resetConnection() = AccessibilityConnection.onDisconnected()

    // -- background restriction API gate -------------------------------------

    @Test
    fun backgroundRestrictionBelowApi28IsUnknownAndNeverRead() {
        var reads = 0
        for (sdk in 24..27) {
            assertNull(ProtectionHealthSignals.backgroundRestricted(sdk) { reads++; true })
        }
        assertEquals("the API must not be touched below P", 0, reads)
    }

    @Test
    fun backgroundRestrictionFromApi28ReportsThePlatformValue() {
        for (sdk in listOf(28, 30, 34, 36)) {
            assertEquals(true, ProtectionHealthSignals.backgroundRestricted(sdk) { true })
            assertEquals(false, ProtectionHealthSignals.backgroundRestricted(sdk) { false })
        }
    }

    @Test
    fun failingPlatformReadsAreUnknownNeverFabricated() {
        assertNull(ProtectionHealthSignals.backgroundRestricted(34) { throw SecurityException("x") })
        assertNull(ProtectionHealthSignals.probe { throw IllegalStateException("x") })
        assertNull(ProtectionHealthSignals.probe { throw NullPointerException() })
        assertEquals(true, ProtectionHealthSignals.probe { true })
    }

    // -- wire format ----------------------------------------------------------

    @Test
    fun signalsMapCarriesExactlyTheM1KeysAndPreservesUnknown() {
        val map = ProtectionHealthSignals.signals(
            accessibilityConnected = false,
            shieldArmed = null,
            challengePending = true,
            backgroundRestricted = null,
            powerSaveMode = true,
            ignoringBatteryOptimizations = false,
            sdkInt = 28,
        )
        assertEquals(
            setOf(
                "accessibilityServiceConnected", "shieldArmed", "challengePending",
                "backgroundRestricted", "powerSaveMode", "ignoringBatteryOptimizations",
                "sdkInt",
            ),
            map.keys,
        )
        assertEquals(false, map["accessibilityServiceConnected"])
        assertTrue(map.containsKey("shieldArmed") && map["shieldArmed"] == null)
        assertTrue(map.containsKey("backgroundRestricted") && map["backgroundRestricted"] == null)
        assertEquals(true, map["powerSaveMode"])
        assertEquals(28, map["sdkInt"])
    }

    @Test
    fun dartParserReadsEveryNativeKey() {
        val dart = repoFile("lib/services/watcher_service.dart")
        for (key in ProtectionHealthSignals.signals(false, null, null, null, null, null, 0).keys) {
            assertTrue("Dart fromMap must read '$key'", dart.contains("map['$key']"))
        }
    }

    // -- Accessibility bound state -------------------------------------------

    @Test
    fun accessibilityConnectionFollowsBindLifecycle() {
        assertFalse(AccessibilityConnection.connected)
        AccessibilityConnection.onConnected()
        assertTrue(AccessibilityConnection.connected)
        AccessibilityConnection.onConnected()
        assertTrue(AccessibilityConnection.connected)
        AccessibilityConnection.onDisconnected()
        assertFalse(AccessibilityConnection.connected)
        AccessibilityConnection.onDisconnected()
        assertFalse(AccessibilityConnection.connected)
    }

    @Test
    fun accessibilityServiceWiresConnectAndBothDisconnectCallbacks() {
        val a11y = source("AccessibilityLockService.kt")
        val connected = body(a11y, "override fun onServiceConnected()")
        assertTrue(connected.contains("AccessibilityConnection.onConnected()"))
        assertTrue(body(a11y, "override fun onUnbind(").contains("AccessibilityConnection.onDisconnected()"))
        assertTrue(body(a11y, "override fun onDestroy()").contains("AccessibilityConnection.onDisconnected()"))
        // onUnbind keeps the platform's return value (no rebind behaviour change).
        assertTrue(body(a11y, "override fun onUnbind(").contains("return super.onUnbind(intent)"))
    }

    // -- observational contracts ----------------------------------------------

    @Test
    fun healthReadIsObservationalOnly() {
        val channel = source("WatcherChannel.kt")
        val health = body(channel, "private fun health(") + body(channel, "private fun healthSignals(")
        for (forbidden in listOf(
            "authorize", "revokeAll", "clearPendingChallenge", "takePendingChallenge",
            "invalidateChallengeHandoff", "ProtectionOverlayController.show",
            "ProtectionOverlayController.hide", ".arm(", ".disarm(", "WatcherService.start",
            "WatcherService.stop", "configure(", "setLastError", "startActivity",
            "REQUEST_IGNORE_BATTERY_OPTIMIZATIONS", "heartbeat(",
        )) {
            assertFalse("health must not call $forbidden", health.contains(forbidden))
        }
        assertTrue(health.contains("ProtectionStateStore.pendingChallenge(activity)"))
        assertTrue(health.contains("ProtectionOverlayController.isArmed()"))
        assertTrue(channel.contains(") + healthSignals(activity)"))
    }

    @Test
    fun backgroundRestrictionReadIsApiGuarded() {
        val signals = body(source("WatcherChannel.kt"), "private fun healthSignals(")
        assertTrue(signals.contains("ProtectionHealthSignals.backgroundRestricted(sdk)"))
        assertTrue(signals.contains("sdk >= Build.VERSION_CODES.P"))
        assertTrue(signals.contains("isBackgroundRestricted"))
    }

    @Test
    fun overlayIsArmedIsAPureRead() {
        val overlay = source("ProtectionOverlayController.kt")
        assertTrue(overlay.contains("fun isArmed(): Boolean = shield != null"))
    }

    @Test
    fun noNewPermissionOrExemptionFlow() {
        val manifest = repoFile("android/app/src/main/AndroidManifest.xml")
        assertFalse(manifest.contains("android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"))
        assertFalse(manifest.contains("android.permission.QUERY_ALL_PACKAGES\""))
        val native = File(sourceDir()).listFiles { f -> f.name.endsWith(".kt") }!!
            .joinToString("\n") { it.readText() }
        assertFalse(native.contains("ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"))
        assertFalse(native.contains("ACTION_BIOMETRIC_ENROLL"))
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

    private fun sourceDir(): String {
        val relative = "src/main/kotlin/com/smartapplock/app"
        val dir = listOf(File(relative), File("android/app/$relative")).firstOrNull { it.isDirectory }
        assertNotNull("source dir not found from ${File(".").absolutePath}", dir)
        return dir!!.path
    }

    private fun source(name: String): String = File(sourceDir(), name).readText()

    private fun repoFile(path: String): String {
        val file = listOf(File(path), File("../../$path")).firstOrNull { it.isFile }
        assertNotNull("$path not found", file)
        return file!!.readText()
    }
}
