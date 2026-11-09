package com.smartapplock.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Phase 12 / M2: pure intruder evidence / alarm decisions (SIMULATED, JVM). */
class IntruderDefensePolicyTest {

    private fun capture(
        permission: Boolean = true,
        front: Boolean = true,
        resumed: Boolean = true,
        interactive: Boolean = true,
        busy: Boolean = false,
    ) = IntruderDefensePolicy.captureBlockReason(permission, front, resumed, interactive, busy)

    @Test fun captureAllowedOnlyWhenEveryConditionHolds() {
        assertNull(capture())
        assertEquals("permission", capture(permission = false))
        assertEquals("no_front_camera", capture(front = false))
        assertEquals("not_foreground", capture(resumed = false))
        assertEquals("screen_off", capture(interactive = false))
        assertEquals("busy", capture(busy = true))
    }

    @Test fun permissionIsCheckedBeforeEverythingElse() {
        assertEquals("permission", capture(permission = false, front = false, resumed = false, interactive = false, busy = true))
    }

    @Test fun backgroundCaptureIsNeverAllowed() {
        for (perm in listOf(true, false)) for (inter in listOf(true, false)) {
            assert(capture(permission = perm, resumed = false, interactive = inter) != null)
        }
    }

    private fun alarm(playing: Boolean = false, resumed: Boolean = true, all: Boolean = true, normal: Boolean = true) =
        IntruderDefensePolicy.alarmBlockReason(playing, resumed, all, normal)

    @Test fun alarmRespectsDndRingerForegroundAndCoalesces() {
        assertNull(alarm())
        assertEquals("alreadyPlaying", alarm(playing = true))
        assertEquals("notForeground", alarm(resumed = false))
        assertEquals("suppressedByDnd", alarm(all = false))
        assertEquals("suppressedByRinger", alarm(normal = false))
        assertEquals("suppressedByDnd", alarm(all = false, normal = false))
    }

    @Test fun alarmDurationIsBounded() {
        assertEquals(30_000L, IntruderDefensePolicy.clampAlarmMs(Long.MAX_VALUE))
        assertEquals(1_000L, IntruderDefensePolicy.clampAlarmMs(-5))
        assertEquals(30_000L, IntruderDefensePolicy.clampAlarmMs(30_000))
    }

    @Test fun maxBytesIsBounded() {
        assertEquals(256 * 1024, IntruderDefensePolicy.clampMaxBytes(Int.MAX_VALUE))
        assertEquals(16 * 1024, IntruderDefensePolicy.clampMaxBytes(0))
    }

    @Test fun chooseSizePrefersLargestWithinLimitElseSmallest() {
        assertEquals(1280 to 960, IntruderDefensePolicy.chooseSize(listOf(4000 to 3000, 1280 to 960, 640 to 480, 1280 to 720)))
        assertEquals(1920 to 1080, IntruderDefensePolicy.chooseSize(listOf(4000 to 3000, 1920 to 1080)))
        assertNull(IntruderDefensePolicy.chooseSize(emptyList()))
        assertNull(IntruderDefensePolicy.chooseSize(listOf(0 to 0)))
    }

    @Test fun rotationFollowsCamera2Formula() {
        assertEquals(270, IntruderDefensePolicy.rotationDegrees(270, 0, true))
        assertEquals(180, IntruderDefensePolicy.rotationDegrees(270, 90, true))
        assertEquals(0, IntruderDefensePolicy.rotationDegrees(270, 270, true))
        assertEquals(180, IntruderDefensePolicy.rotationDegrees(90, 90, false))
        assertEquals(270, IntruderDefensePolicy.rotationDegrees(270, 45, true)) // normalised
    }

    @Test fun qualityLadderSelectsFirstFit() {
        assertEquals(0, IntruderDefensePolicy.firstFitting(listOf(100, 90), 200))
        assertEquals(2, IntruderDefensePolicy.firstFitting(listOf(300, 260, 200), 256))
        assertEquals(-1, IntruderDefensePolicy.firstFitting(listOf(300, 290), 256))
        assertEquals(-1, IntruderDefensePolicy.firstFitting(listOf(0), 256))
    }
}
