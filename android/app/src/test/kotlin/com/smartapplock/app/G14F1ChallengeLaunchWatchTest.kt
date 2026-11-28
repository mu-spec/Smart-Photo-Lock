package com.smartapplock.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * G14 F1 — SIMULATED (JVM) + STATIC. A reported-successful challenge launch
 * is recorded as blocked only after the grace interval in which the exact
 * ticket's Activity never resumed and was never acknowledged ready, while
 * the screen was interactive and unlocked. Observational: error code only.
 */
class G14F1ChallengeLaunchWatchTest {
    private val grace = 6_000L
    private val bank = ProtectionStateStore.PendingChallenge("com.example.bank", 7L)
    private val bankNext = ProtectionStateStore.PendingChallenge("com.example.bank", 8L)
    private val mail = ProtectionStateStore.PendingChallenge("com.example.mail", 7L)

    private fun ChallengeLaunchWatch.check(
        ticket: ProtectionStateStore.PendingChallenge,
        now: Long,
        resumed: Boolean = false,
        ready: Boolean = false,
        presentable: Boolean = true,
    ) = launchBlocked(ticket, resumed, ready, presentable, now)

    @Test fun firstReportedLaunchIsNeverBlocked() {
        assertFalse(ChallengeLaunchWatch(grace).check(bank, 10_000L))
    }

    @Test fun blockedOnlyOnceTheGraceHasElapsedForTheSameTicket() {
        val watch = ChallengeLaunchWatch(grace)
        assertFalse(watch.check(bank, 10_000L))
        assertFalse("one retry is still slow startup", watch.check(bank, 13_000L))
        assertFalse(watch.check(bank, 15_999L))
        assertTrue(watch.check(bank, 16_000L))
        assertTrue("stays blocked while nothing changes", watch.check(bank, 19_000L))
    }

    @Test fun aResumedActivityIsNeverBlockedAndRestartsTheWindow() {
        val watch = ChallengeLaunchWatch(grace)
        watch.check(bank, 10_000L)
        assertFalse(watch.check(bank, 16_000L, resumed = true))
        // A later pause and relaunch measures from its own first launch.
        assertFalse(watch.check(bank, 17_000L))
        assertFalse(watch.check(bank, 22_999L))
        assertTrue(watch.check(bank, 23_000L))
    }

    @Test fun anExactReadyAcknowledgementIsNeverBlocked() {
        val watch = ChallengeLaunchWatch(grace)
        watch.check(bank, 10_000L)
        assertFalse(watch.check(bank, 30_000L, ready = true))
    }

    @Test fun screenOffOrKeyguardNeverRecordsAndRestartsTheWindow() {
        val watch = ChallengeLaunchWatch(grace)
        watch.check(bank, 10_000L)
        assertFalse(watch.check(bank, 30_000L, presentable = false))
        assertFalse("window restarts after unlock", watch.check(bank, 31_000L))
        assertFalse(watch.check(bank, 36_999L))
        assertTrue(watch.check(bank, 37_000L))
    }

    @Test fun aNewerGenerationOrPackageRestartsTheWindow() {
        val watch = ChallengeLaunchWatch(grace)
        watch.check(bank, 10_000L)
        assertFalse(watch.check(bankNext, 16_000L))
        assertFalse(watch.check(mail, 22_000L))
        assertTrue(watch.check(mail, 28_000L))
    }

    @Test fun aBackwardClockNeverBlocks() {
        val watch = ChallengeLaunchWatch(grace)
        watch.check(bank, 10_000L)
        assertFalse(watch.check(bank, 5_000L))
    }

    private fun watcherSource(): String {
        val relative = "src/main/kotlin/com/smartapplock/app/WatcherService.kt"
        return listOf(File(relative), File("android/app/$relative")).first { it.isFile }.readText()
    }

    /** STATIC: wiring is confined to the recorded code of a reported launch. */
    @Test fun watcherServiceRecordsOnlyTheExistingCode() {
        val src = watcherSource()
        assertTrue(src.contains("private const val CHALLENGE_LAUNCH_GRACE_MS = 2 * RECOVERY_RETRY_MS"))
        assertTrue(src.contains("ChallengeLaunchWatch(CHALLENGE_LAUNCH_GRACE_MS)"))
        assertEquals(1, Regex("challengeLaunchWatch\\.launchBlocked\\(").findAll(src).count())
        val recover = src.substringAfter("private fun recoverProtected(")
            .substringBefore("private fun resetRecovery(")
        // Security-critical order is unchanged: shield first, hand-off second.
        assertTrue(
            recover.indexOf("ProtectionOverlayController.show(context)") <
                recover.indexOf("MainActivity.foregroundForRecovery(context, pending)"),
        )
        val f1 = recover.substringAfter("// G14 F1:").substringBefore("activeInstance?.scheduleRecoveryRetry()")
        assertTrue(f1.contains("ticket = pending"))
        assertTrue(f1.contains("ProtectionRuntime.isChallengeReady(pending)"))
        assertTrue(f1.contains("ProtectionRuntime.activityResumed"))
        assertTrue(f1.contains("isKeyguardLocked(context) == false"))
        assertTrue(f1.contains("LastErrorCode.CHALLENGE_LAUNCH_BLOCKED"))
        for (forbidden in listOf("hide(", "authorize", "clearPendingChallenge", "replacePendingChallenge",
                "revokeAll", "invalidateChallengeHandoff", "cancelRecoveryRetry")) {
            assertFalse("F1 block must not call $forbidden", f1.contains(forbidden))
        }
        // The retry is still scheduled after every attempt.
        assertTrue(recover.contains("activeInstance?.scheduleRecoveryRetry()"))
    }
}
