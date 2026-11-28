package com.smartapplock.app

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

/**
 * Phase 18 / M1F — F18-4 proposal. SIMULATED (JVM) + STATIC: the
 * foreground-service status never claims active protection when Android
 * reports the overlay or every detection path missing; unknown never counts.
 */
class P18M1FStatusTextPolicyTest {
    private val values = listOf<Boolean?>(true, false, null)

    @Before fun setUp() { AccessibilityConnection.onChange = null; AccessibilityConnection.onDisconnected() }
    @After fun tearDown() { AccessibilityConnection.onChange = null; AccessibilityConnection.onDisconnected() }

    private fun status(e: Boolean, o: Boolean?, a: Boolean?, u: Boolean?) =
        WatcherStatusTextPolicy.status(e, o, a, u)

    // G14 E1: only the bound Accessibility path counts; Usage Access alone is
    // a best-effort backup and never yields ACTIVE or RECOVERING.
    @Test fun activeOnlyWithOverlayAndADetectionPath() {
        for (engine in listOf(true, false)) for (o in values) for (a in values) for (u in values) {
            val core = o == true && a == true
            val expected = when {
                !core -> WatcherStatus.NEEDS_ATTENTION
                engine -> WatcherStatus.ACTIVE
                else -> WatcherStatus.RECOVERING
            }
            assertEquals("engine=$engine overlay=$o a11y=$a usage=$u", expected, status(engine, o, a, u))
        }
    }

    @Test fun bothDetectionPathsRevokedIsNeverActive() {
        for (engine in listOf(true, false)) {
            assertEquals(WatcherStatus.NEEDS_ATTENTION, status(engine, true, false, false))
        }
    }

    @Test fun unknownSignalsAreNeverGranted() {
        assertEquals(WatcherStatus.NEEDS_ATTENTION, status(true, null, true, true))
        assertEquals(WatcherStatus.NEEDS_ATTENTION, status(true, true, null, null))
        assertEquals(WatcherStatus.NEEDS_ATTENTION, status(true, true, null, true))
    }

    @Test fun accessibilityAloneIsEnough() {
        assertEquals(WatcherStatus.ACTIVE, status(true, true, true, false))
        assertEquals(WatcherStatus.RECOVERING, status(false, true, true, false))
    }

    /** G14 E1: Usage Access only (Accessibility off or not connected) is never active. */
    @Test fun usageAccessAloneIsNeverActive() {
        for (engine in listOf(true, false)) {
            assertEquals(WatcherStatus.NEEDS_ATTENTION, status(engine, true, false, true))
            assertEquals(WatcherStatus.NEEDS_ATTENTION, status(engine, true, null, true))
        }
    }

    private fun watcherSource(): String {
        val relative = "src/main/kotlin/com/smartapplock/app/WatcherService.kt"
        return listOf(File(relative), File("android/app/$relative")).first { it.isFile }.readText()
    }

    /** STATIC (C): WatcherService feeds the policy from Android reads and maps every status. */
    @Test fun watcherServiceWiresThePolicy() {
        val src = watcherSource()
        val body = src.substringAfter("private fun notificationText(): String =")
            .substringBefore("private fun buildNotification")
        assertTrue(body.contains("WatcherStatusTextPolicy.status("))
        assertTrue(body.contains("Settings.canDrawOverlays(this)"))
        assertTrue(body.contains("AccessibilityConnection.connected"))
        assertTrue(body.contains("InstalledAppsChannel.hasUsageAccess(this)"))
        assertTrue(body.contains("WatcherStatus.ACTIVE -> \"Protection engine active\""))
        assertTrue(body.contains("WatcherStatus.RECOVERING -> \"Protection recovery active\""))
        assertTrue(body.contains("WatcherStatus.NEEDS_ATTENTION -> \"Protection needs attention. Open Smart App Lock.\""))
        assertEquals(1, Regex("\"Protection engine active\"").findAll(body).count())
        assertTrue(src.contains("AccessibilityConnection.onChange = {"))
        assertTrue(src.contains("AccessibilityConnection.onChange = null"))
    }

    @Test fun attentionTextNamesNoAppOrPermissionDetail() {
        val body = watcherSource().substringAfter("WatcherStatus.NEEDS_ATTENTION -> \"").substringBefore("\"")
        assertEquals("Protection needs attention. Open Smart App Lock.", body)
        assertFalse(body.contains("Accessibility") || body.contains("Usage") || body.contains("overlay"))
    }

    @Test fun bindStateChangesNotifyTheStatusHook() {
        var calls = 0
        AccessibilityConnection.onChange = { calls++ }
        AccessibilityConnection.onConnected()
        AccessibilityConnection.onDisconnected()
        assertEquals(2, calls)
        AccessibilityConnection.onChange = null
        AccessibilityConnection.onConnected()
        assertEquals(2, calls)
    }
}
