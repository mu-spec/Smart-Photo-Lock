package com.smartapplock.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * F3: UsageEvents is historical. These tests pin what the restart path may
 * conclude from it (the latest activity resume since boot, excluding events
 * that can never prove a foreground change) and how the remembered
 * identity is scoped to the current boot.
 */
class RestartEvidenceAndBootScopeTest {
    private val own = "com.smartapplock.app"
    private val ime = "com.example.keyboard"
    private val locked = "com.example.locked"
    private val launcher = "com.android.launcher3"
    private val now = 1_800_000_000_000L
    private val lowerBound = now - 3_600_000L

    private fun selector() = RestartForegroundEvidenceSelector(
        ownPackage = own,
        imePackage = ime,
        nowWallMs = now,
        lowerBoundWallMs = lowerBound,
    )

    // -- Evidence selection ------------------------------------------------

    @Test
    fun latestActivityResumeWins() {
        val s = selector()
        s.offer(launcher, now - 2_000L, isActivityResume = true)
        s.offer(locked, now - 1_000L, isActivityResume = true)
        assertEquals(ForegroundEvidence.App(locked, now - 1_000L), s.result())
    }

    @Test
    fun nonResumeEventsNeverChangeTheResult() {
        val s = selector()
        s.offer(locked, now - 2_000L, isActivityResume = true)
        s.offer(launcher, now - 1_000L, isActivityResume = false)
        assertEquals(ForegroundEvidence.App(locked, now - 2_000L), s.result())
    }

    @Test
    fun ownAndTransientResumesCannotProveAForegroundChange() {
        val s = selector()
        s.offer(locked, now - 5_000L, isActivityResume = true)
        s.offer(own, now - 4_000L, isActivityResume = true)
        s.offer("com.android.systemui", now - 3_000L, isActivityResume = true)
        s.offer("android", now - 2_000L, isActivityResume = true)
        s.offer(ime, now - 1_000L, isActivityResume = true)
        assertEquals(ForegroundEvidence.App(locked, now - 5_000L), s.result())
    }

    @Test
    fun onlyOwnOrTransientResumesIsUnknown() {
        val s = selector()
        s.offer(own, now - 4_000L, isActivityResume = true)
        s.offer("com.android.systemui", now - 3_000L, isActivityResume = true)
        assertEquals(ForegroundEvidence.Unknown, s.result())
    }

    @Test
    fun noEventsIsUnknown() {
        assertEquals(ForegroundEvidence.Unknown, selector().result())
    }

    @Test
    fun eventsBeforeTheBootOrLookbackBoundAreIgnored() {
        val s = selector()
        s.offer(locked, lowerBound - 1L, isActivityResume = true)
        assertEquals(ForegroundEvidence.Unknown, s.result())
        s.offer(launcher, lowerBound, isActivityResume = true)
        assertEquals(ForegroundEvidence.App(launcher, lowerBound), s.result())
    }

    @Test
    fun aFutureDatedEventMeansTheClockMovedAndTheEvidenceIsUnknown() {
        val s = selector()
        s.offer(launcher, now - 1_000L, isActivityResume = true)
        s.offer(locked, now + RestartForegroundEvidenceSelector.FUTURE_TOLERANCE_MS + 1L, true)
        assertEquals(ForegroundEvidence.Unknown, s.result())
    }

    @Test
    fun smallFutureSkewWithinToleranceIsAccepted() {
        val s = selector()
        s.offer(launcher, now + 500L, isActivityResume = true)
        assertEquals(ForegroundEvidence.App(launcher, now + 500L), s.result())
    }

    @Test
    fun equalTimestampsResolveDeterministicallyToTheLaterStreamEvent() {
        val s = selector()
        s.offer(launcher, now - 1_000L, isActivityResume = true)
        s.offer(locked, now - 1_000L, isActivityResume = true)
        assertEquals(ForegroundEvidence.App(locked, now - 1_000L), s.result())
    }

    @Test
    fun blankPackagesAndNonPositiveTimestampsAreIgnored() {
        val s = selector()
        s.offer("", now - 1_000L, isActivityResume = true)
        s.offer(null, now - 900L, isActivityResume = true)
        s.offer(launcher, 0L, isActivityResume = true)
        assertEquals(ForegroundEvidence.Unknown, s.result())
    }

    @Test
    fun lookbackIsBoundedBySinceBootAndByTheMaximumWindow() {
        assertEquals(
            now - 60_000L,
            RestartForegroundEvidenceSelector.lowerBoundWallMs(now, nowElapsedMs = 60_000L),
        )
        assertEquals(
            now - RestartForegroundEvidenceSelector.MAX_LOOKBACK_MS,
            RestartForegroundEvidenceSelector.lowerBoundWallMs(
                now,
                nowElapsedMs = 3 * RestartForegroundEvidenceSelector.MAX_LOOKBACK_MS,
            ),
        )
    }

    // -- Boot scope ----------------------------------------------------------

    @Test
    fun sameBootCountIsTheSameBoot() {
        assertTrue(WakeIdentityBootScope.sameBoot(7, 7, 1_000L, now - 9_000L, 10_000L, now))
    }

    @Test
    fun differentBootCountIsAnotherBoot() {
        assertFalse(WakeIdentityBootScope.sameBoot(7, 8, 1_000L, now - 9_000L, 10_000L, now))
    }

    @Test
    fun elapsedRealtimeRegressionIsAnotherBootEvenWithAnEqualCount() {
        assertFalse(WakeIdentityBootScope.sameBoot(7, 7, 50_000L, now - 1_000L, 10_000L, now))
    }

    @Test
    fun unstampedLegacyIdentityCannotBeProvenSameBoot() {
        assertFalse(WakeIdentityBootScope.sameBoot(null, 7, null, null, 10_000L, now))
    }

    @Test
    fun unavailableBootCountFallsBackToTheBootTimeWallAnchor() {
        // Stamped 9 s into this boot, checked at 10 s: same boot anchor.
        assertTrue(WakeIdentityBootScope.sameBoot(-1, -1, 1_000L, now - 9_000L, 10_000L, now))
        assertTrue(WakeIdentityBootScope.sameBoot(null, -1, 1_000L, now - 9_000L, 10_000L, now))
        // Previous boot ended an hour ago; elapsed restarted from zero.
        assertFalse(
            WakeIdentityBootScope.sameBoot(-1, -1, 1_000L, now - 3_600_000L, 10_000L, now),
        )
        assertFalse(WakeIdentityBootScope.sameBoot(-1, -1, 1_000L, null, 10_000L, now))
    }

    @Test
    fun wallClockConsistencyDetectsClockChangesSinceTheStamp() {
        val tolerance = WakeIdentityBootScope.WALL_CLOCK_TOLERANCE_MS
        assertTrue(WakeIdentityBootScope.wallClockConsistent(1_000L, now - 9_000L, 10_000L, now))
        assertTrue(
            WakeIdentityBootScope.wallClockConsistent(1_000L, now - 9_000L - tolerance, 10_000L, now),
        )
        assertFalse(
            WakeIdentityBootScope.wallClockConsistent(1_000L, now - 9_001L - tolerance, 10_000L, now),
        )
        assertFalse(
            WakeIdentityBootScope.wallClockConsistent(1_000L, now + 3_600_000L, 10_000L, now),
        )
        assertFalse(WakeIdentityBootScope.wallClockConsistent(null, now, 10_000L, now))
        assertFalse(WakeIdentityBootScope.wallClockConsistent(1_000L, null, 10_000L, now))
    }

    // -- Query window (F3 correction) -----------------------------------------
    //
    // [androidQuery] is the effective Android filter that the production
    // adapter runs through: AOSP UserUsageStatsService.validRange
    // (begin <= service time && begin < end, otherwise no events), begin
    // INCLUSIVE and end EXCLUSIVE, as documented for queryEvents.

    private data class Ev(val pkg: String?, val wall: Long, val resume: Boolean = true)

    private val bootElapsed = 2 * RestartForegroundEvidenceSelector.MAX_LOOKBACK_MS
    private val tolerance = RestartForegroundEvidenceSelector.FUTURE_TOLERANCE_MS
    private val day = 24L * 60L * 60L * 1_000L

    private fun androidQuery(
        events: List<Ev>,
        serviceNowWallMs: Long = now,
        calls: MutableList<Pair<Long, Long>> = mutableListOf(),
    ): (Long, Long, (String?, Long, Boolean) -> Unit) -> Unit = { begin, end, sink ->
        calls.add(begin to end)
        if (begin <= serviceNowWallMs && begin < end) {
            events.filter { it.wall >= begin && it.wall < end }
                .forEach { sink(it.pkg, it.wall, it.resume) }
        }
    }

    private fun collect(
        events: List<Ev>,
        nowWallMs: Long = now,
        nowElapsedMs: Long = bootElapsed,
        serviceNowWallMs: Long = nowWallMs,
        calls: MutableList<Pair<Long, Long>> = mutableListOf(),
    ): ForegroundEvidence = RestartUsageEventsQuery.collect(
        ownPackage = own,
        imePackage = ime,
        nowWallMs = nowWallMs,
        nowElapsedMs = nowElapsedMs,
        query = androidQuery(events, serviceNowWallMs, calls),
    )

    /** Same-boot remembered protected [locked]; only [locked] is protected. */
    private fun decide(evidence: ForegroundEvidence, stampWallMs: Long, consistent: Boolean = true) =
        RestartRecoveryPolicy.decide(
            RestartRecoveryInput(
                protectionEnabled = true,
                pendingExists = false,
                uiActivityResumed = false,
                rememberedPackage = locked,
                rememberedSameBoot = true,
                rememberedStampWallMs = stampWallMs,
                wallClockConsistent = consistent,
                evidence = evidence,
            ),
        ) { it == locked }

    @Test
    fun queryEndIsExclusiveSoItReachesPastTheFutureTolerance() {
        val end = RestartUsageEventsQuery.endWallMs(now)!!
        assertTrue(end > now + tolerance + 1L)
        // The first instant the selector treats as an anomaly must be fetched.
        assertEquals(
            ForegroundEvidence.Unknown,
            collect(listOf(Ev(launcher, now - 1_000L), Ev(locked, now + tolerance + 1L))),
        )
        assertEquals(
            ForegroundEvidence.Unknown,
            collect(listOf(Ev(launcher, now - 1_000L), Ev(launcher, now + 60L * 60_000L))),
        )
    }

    @Test
    fun queryEndIsABoundedTwentyFourHourHorizonNotLongMax() {
        assertEquals(day, RestartUsageEventsQuery.FUTURE_HORIZON_MS)
        assertTrue(RestartUsageEventsQuery.FUTURE_HORIZON_MS > tolerance + 1L)
        assertEquals(now + day, RestartUsageEventsQuery.endWallMs(now))
        val calls = mutableListOf<Pair<Long, Long>>()
        collect(listOf(Ev(launcher, now - 1_000L)), calls = calls)
        assertEquals(listOf(RestartUsageEventsQuery.beginWallMs(now, bootElapsed) to now + day), calls)
        // The last fetched instant still fails closed.
        assertEquals(
            ForegroundEvidence.Unknown,
            collect(listOf(Ev(launcher, now - 1_000L), Ev(launcher, now + day - 1L))),
        )
    }

    @Test
    fun queryBeginIsTheBootScopedLookbackAndThereIsExactlyOneQuery() {
        val calls = mutableListOf<Pair<Long, Long>>()
        collect(emptyList(), nowElapsedMs = 60_000L, calls = calls)
        assertEquals(1, calls.size)
        assertEquals(now - 60_000L, calls.single().first)
        assertEquals(
            RestartForegroundEvidenceSelector.lowerBoundWallMs(now, 60_000L),
            RestartUsageEventsQuery.beginWallMs(now, 60_000L),
        )
        assertEquals(
            RestartForegroundEvidenceSelector.lowerBoundWallMs(now, bootElapsed),
            RestartUsageEventsQuery.beginWallMs(now, bootElapsed),
        )
    }

    @Test
    fun clockRollbackFutureEventFailsClosedInsteadOfLettingAnOlderUnprotectedEventSuppress() {
        // Real time (s): X unprotected @0, Y unprotected @90, wall clock set
        // back 250 s @100, protected P @200 (identity stamp), restart @300.
        // UsageStats did not rebase, so X/Y keep pre-rollback timestamps.
        val w0 = now - 50_000L
        val rollback = 250_000L
        fun wall(realMs: Long) = if (realMs < 100_000L) w0 + realMs else w0 + realMs - rollback
        val events = listOf(
            Ev("com.example.x", wall(0L)),
            Ev("com.example.y", wall(90_000L)),
            Ev(locked, wall(200_000L)),
        )
        val stamp = wall(200_000L)
        val nowWall = wall(300_000L)
        assertEquals(now, nowWall)
        assertTrue(wall(0L) in (stamp + 1L)..nowWall) // X alone would look "newer"
        assertTrue(wall(90_000L) > nowWall + tolerance) // Y is the anomaly signal
        val evidence = collect(events, nowWallMs = nowWall)
        assertEquals(ForegroundEvidence.Unknown, evidence)
        val result = decide(evidence, stamp)
        assertEquals(RestartRecoveryDecision.CHALLENGE_REMEMBERED_FOREGROUND_UNKNOWN, result.decision)
        assertEquals(locked, result.targetPackage)
    }

    @Test
    fun futureDatedOwnOrTransientResumeStillFailsClosed() {
        assertEquals(
            ForegroundEvidence.Unknown,
            collect(listOf(Ev(launcher, now - 1_000L), Ev(own, now + 120_000L))),
        )
        assertEquals(
            ForegroundEvidence.Unknown,
            collect(listOf(Ev(launcher, now - 1_000L), Ev(ime, now + 120_000L))),
        )
    }

    @Test
    fun futureDatedNonResumeEventsAreNotAnAnomaly() {
        assertEquals(
            ForegroundEvidence.App(launcher, now - 1_000L),
            collect(listOf(Ev(launcher, now - 1_000L), Ev(launcher, now + 120_000L, resume = false))),
        )
    }

    @Test
    fun skewWithinToleranceKeepsNormalSuppression() {
        val stamp = now - 5_000L
        val evidence = collect(listOf(Ev(locked, stamp), Ev(launcher, now + tolerance)))
        assertEquals(ForegroundEvidence.App(launcher, now + tolerance), evidence)
        assertEquals(
            RestartRecoveryDecision.NONE_NEWER_UNPROTECTED_EVIDENCE,
            decide(evidence, stamp).decision,
        )
    }

    @Test
    fun normalTimestampsNewerUnprotectedResumeSuppresses() {
        val stamp = now - 60_000L
        val evidence = collect(listOf(Ev(locked, stamp), Ev(launcher, now - 30_000L)))
        assertEquals(ForegroundEvidence.App(launcher, now - 30_000L), evidence)
        assertEquals(
            RestartRecoveryDecision.NONE_NEWER_UNPROTECTED_EVIDENCE,
            decide(evidence, stamp).decision,
        )
    }

    @Test
    fun normalTimestampsOldUnprotectedResumeDoesNotSuppress() {
        val stamp = now - 60_000L
        val evidence = collect(listOf(Ev(launcher, now - 90_000L)))
        assertEquals(ForegroundEvidence.App(launcher, now - 90_000L), evidence)
        val result = decide(evidence, stamp)
        assertEquals(RestartRecoveryDecision.CHALLENGE_REMEMBERED_EVIDENCE_NOT_NEWER, result.decision)
        assertEquals(locked, result.targetPackage)
    }

    @Test
    fun normalTimestampsProtectedLatestResumeChallenges() {
        val evidence = collect(listOf(Ev(launcher, now - 90_000L), Ev(locked, now - 1_000L)))
        val result = decide(evidence, now - 60_000L)
        assertEquals(RestartRecoveryDecision.CHALLENGE_PROTECTED_FOREGROUND_EVIDENCE, result.decision)
        assertEquals(locked, result.targetPackage)
    }

    @Test
    fun noUsageAccessOrEmptyResultIsUnknownAndChallenges() {
        // Without Usage Access the adapter returns Unknown before querying;
        // AOSP also returns no events to callers without the permission.
        val evidence = collect(emptyList())
        assertEquals(ForegroundEvidence.Unknown, evidence)
        assertEquals(
            RestartRecoveryDecision.CHALLENGE_REMEMBERED_FOREGROUND_UNKNOWN,
            decide(evidence, now - 60_000L).decision,
        )
    }

    @Test
    fun serviceClockMovedBehindTheQueryBeginYieldsNoEventsAndFailsClosed() {
        // Clock set back between the snapshot and the query: validRange fails.
        val evidence = collect(
            listOf(Ev(launcher, now - 1_000L)),
            nowElapsedMs = 60_000L,
            serviceNowWallMs = now - 3_600_000L,
        )
        assertEquals(ForegroundEvidence.Unknown, evidence)
    }

    @Test
    fun anUnrepresentableWindowIsUnknownWithoutQuerying() {
        val nowWall = Long.MAX_VALUE - 1L
        assertEquals(null, RestartUsageEventsQuery.endWallMs(nowWall))
        val calls = mutableListOf<Pair<Long, Long>>()
        assertEquals(
            ForegroundEvidence.Unknown,
            collect(listOf(Ev(launcher, nowWall - 1_000L)), nowWallMs = nowWall, calls = calls),
        )
        assertTrue(calls.isEmpty())
    }

    @Test
    fun knownResidualRollbackWithNoPreRollbackEventBeyondToleranceIsNotDetected() {
        // Accepted residual F.3(b), pinned so it stays visible: X stays in
        // front across the rollback, so no event lands beyond the tolerance.
        // The query window cannot see this; only UsageStats rebasing (AOSP
        // time-change correction, device-unverified) would order X correctly.
        val w0 = now - 50_000L
        fun wall(realMs: Long) = if (realMs < 100_000L) w0 + realMs else w0 + realMs - 250_000L
        val stamp = wall(200_000L)
        val evidence = collect(listOf(Ev("com.example.x", wall(0L)), Ev(locked, stamp)))
        assertEquals(ForegroundEvidence.App("com.example.x", wall(0L)), evidence)
        assertEquals(
            RestartRecoveryDecision.NONE_NEWER_UNPROTECTED_EVIDENCE,
            decide(evidence, stamp).decision,
        )
    }

    @Test
    fun knownResidualClockAnomalyWithoutAProtectedIdentityDegradesToHeadBehaviour() {
        // Accepted residual F.3(b): an anomaly makes all ordering Unknown,
        // including a protected latest resume, so only the remembered
        // same-boot identity can drive the restart challenge. With none
        // (protected app opened while the process was dead) the restart path
        // adds no challenge, exactly as at HEAD; the live detector still runs.
        val evidence = collect(listOf(Ev(locked, now - 1_000L), Ev(launcher, now + 120_000L)))
        assertEquals(ForegroundEvidence.Unknown, evidence)
        val noIdentity = RestartRecoveryPolicy.decide(
            RestartRecoveryInput(
                protectionEnabled = true,
                pendingExists = false,
                uiActivityResumed = false,
                rememberedPackage = null,
                rememberedSameBoot = false,
                rememberedStampWallMs = null,
                wallClockConsistent = false,
                evidence = evidence,
            ),
        ) { it == locked }
        assertEquals(RestartRecoveryDecision.NONE_NO_PROTECTED_TARGET, noIdentity.decision)
        // With the remembered same-boot identity it still fails closed.
        assertEquals(
            RestartRecoveryDecision.CHALLENGE_REMEMBERED_FOREGROUND_UNKNOWN,
            decide(evidence, now - 60_000L).decision,
        )
    }
}
