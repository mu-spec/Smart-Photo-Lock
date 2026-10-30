package com.smartapplock.app

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * F3: the one-shot restore decision a fresh WatcherService process makes at
 * its first onStartCommand. In-memory authorization never survives death;
 * this policy only decides whether a fresh fail-closed ticket is needed.
 */
class RestartRecoveryPolicyTest {
    private val locked = "com.example.locked"
    private val vault = "com.example.vault"
    private val launcher = "com.android.launcher3"
    private val stampWall = 1_000_000L

    private fun decide(
        enabled: Boolean = true,
        pending: Boolean = false,
        uiResumed: Boolean = false,
        remembered: String? = locked,
        sameBoot: Boolean = true,
        stamp: Long? = stampWall,
        clockConsistent: Boolean = true,
        evidence: ForegroundEvidence = ForegroundEvidence.Unknown,
        protectedPackages: Set<String> = setOf(locked, vault),
    ): RestartRecoveryResult = RestartRecoveryPolicy.decide(
        RestartRecoveryInput(
            protectionEnabled = enabled,
            pendingExists = pending,
            uiActivityResumed = uiResumed,
            rememberedPackage = remembered,
            rememberedSameBoot = sameBoot,
            rememberedStampWallMs = stamp,
            wallClockConsistent = clockConsistent,
            evidence = evidence,
        ),
    ) { it in protectedPackages }

    private fun assertChallenge(
        result: RestartRecoveryResult,
        decision: RestartRecoveryDecision,
        target: String,
    ) {
        assertEquals(decision, result.decision)
        assertEquals(target, result.targetPackage)
        assertTrue(result.decision.challenges)
    }

    private fun assertNoChallenge(
        result: RestartRecoveryResult,
        decision: RestartRecoveryDecision,
    ) {
        assertEquals(decision, result.decision)
        assertNull(result.targetPackage)
        assertFalse(result.decision.challenges)
    }

    // -- Death during authorized use ---------------------------------------

    @Test
    fun usageAccessOffAuthorizedSessionFailsClosedOnRememberedIdentity() {
        assertChallenge(
            decide(evidence = ForegroundEvidence.Unknown),
            RestartRecoveryDecision.CHALLENGE_REMEMBERED_FOREGROUND_UNKNOWN,
            locked,
        )
    }

    @Test
    fun usageAccessOnProtectedLatestResumeChallengesThatPackage() {
        assertChallenge(
            decide(evidence = ForegroundEvidence.App(locked, stampWall + 5_000L)),
            RestartRecoveryDecision.CHALLENGE_PROTECTED_FOREGROUND_EVIDENCE,
            locked,
        )
    }

    @Test
    fun protectedEvidenceChallengesEvenWhenTheIdentityWasForgotten() {
        assertChallenge(
            decide(remembered = null, evidence = ForegroundEvidence.App(locked, 10L)),
            RestartRecoveryDecision.CHALLENGE_PROTECTED_FOREGROUND_EVIDENCE,
            locked,
        )
    }

    @Test
    fun protectedEvidenceSinceBootChallengesEvenWithAnOldBootIdentity() {
        assertChallenge(
            decide(sameBoot = false, evidence = ForegroundEvidence.App(vault, 10L)),
            RestartRecoveryDecision.CHALLENGE_PROTECTED_FOREGROUND_EVIDENCE,
            vault,
        )
    }

    @Test
    fun protectedEvidenceIsNeverSuppressedByAnInconsistentClock() {
        assertChallenge(
            decide(
                clockConsistent = false,
                evidence = ForegroundEvidence.App(vault, stampWall - 1L),
            ),
            RestartRecoveryDecision.CHALLENGE_PROTECTED_FOREGROUND_EVIDENCE,
            vault,
        )
    }

    // -- Genuine unprotected foreground: no false challenge ----------------

    @Test
    fun strictlyNewerUnprotectedResumeSuppressesTheRememberedIdentity() {
        assertNoChallenge(
            decide(evidence = ForegroundEvidence.App(launcher, stampWall + 1L)),
            RestartRecoveryDecision.NONE_NEWER_UNPROTECTED_EVIDENCE,
        )
    }

    // -- Stale, ambiguous and conflicting evidence: fail closed ------------

    @Test
    fun unprotectedResumeOlderThanTheIdentityStampIsStaleAndFailsClosed() {
        assertChallenge(
            decide(evidence = ForegroundEvidence.App(launcher, stampWall - 60_000L)),
            RestartRecoveryDecision.CHALLENGE_REMEMBERED_EVIDENCE_NOT_NEWER,
            locked,
        )
    }

    @Test
    fun equalTimestampsCannotOrderTheEvidenceAndFailClosed() {
        assertChallenge(
            decide(evidence = ForegroundEvidence.App(launcher, stampWall)),
            RestartRecoveryDecision.CHALLENGE_REMEMBERED_EVIDENCE_NOT_NEWER,
            locked,
        )
    }

    @Test
    fun wallClockChangeSinceTheStampMakesUnprotectedEvidenceUnordered() {
        assertChallenge(
            decide(
                clockConsistent = false,
                evidence = ForegroundEvidence.App(launcher, stampWall + 3_600_000L),
            ),
            RestartRecoveryDecision.CHALLENGE_REMEMBERED_EVIDENCE_UNORDERED,
            locked,
        )
    }

    @Test
    fun missingIdentityStampMakesUnprotectedEvidenceUnordered() {
        assertChallenge(
            decide(stamp = null, evidence = ForegroundEvidence.App(launcher, stampWall)),
            RestartRecoveryDecision.CHALLENGE_REMEMBERED_EVIDENCE_UNORDERED,
            locked,
        )
    }

    // -- Boot scope --------------------------------------------------------

    @Test
    fun oldBootIdentityWithoutEvidenceIsNotAStartupChallenge() {
        assertNoChallenge(
            decide(sameBoot = false),
            RestartRecoveryDecision.NONE_REMEMBERED_OTHER_BOOT,
        )
    }

    @Test
    fun oldBootIdentityWithLauncherEvidenceIsNotAStartupChallenge() {
        assertNoChallenge(
            decide(sameBoot = false, evidence = ForegroundEvidence.App(launcher, 5L)),
            RestartRecoveryDecision.NONE_REMEMBERED_OTHER_BOOT,
        )
    }

    // -- Existing tickets, UI, configuration -------------------------------

    @Test
    fun anExistingPendingTicketIsNeverReplaced() {
        assertNoChallenge(
            decide(pending = true, evidence = ForegroundEvidence.App(vault, stampWall + 9L)),
            RestartRecoveryDecision.SKIP_PENDING_TICKET,
        )
    }

    @Test
    fun resumedSmartAppLockUiIsNeverCoveredByARestartChallenge() {
        assertNoChallenge(
            decide(uiResumed = true, evidence = ForegroundEvidence.App(locked, stampWall + 9L)),
            RestartRecoveryDecision.SKIP_UI_RESUMED,
        )
    }

    @Test
    fun disabledProtectionNeverRestores() {
        assertNoChallenge(
            decide(enabled = false, evidence = ForegroundEvidence.App(locked, stampWall + 9L)),
            RestartRecoveryDecision.SKIP_PROTECTION_DISABLED,
        )
    }

    @Test
    fun rememberedPackageThatIsNoLongerProtectedIsIgnored() {
        assertNoChallenge(
            decide(protectedPackages = setOf(vault)),
            RestartRecoveryDecision.NONE_NO_PROTECTED_TARGET,
        )
    }

    @Test
    fun evidenceForAPackageThatIsNoLongerProtectedIsNotAChallenge() {
        assertNoChallenge(
            decide(
                remembered = null,
                evidence = ForegroundEvidence.App(locked, stampWall + 9L),
                protectedPackages = emptySet(),
            ),
            RestartRecoveryDecision.NONE_NO_PROTECTED_TARGET,
        )
    }

    @Test
    fun blankOrMissingIdentityWithoutEvidenceIsNotAChallenge() {
        assertNoChallenge(decide(remembered = "  "), RestartRecoveryDecision.NONE_NO_PROTECTED_TARGET)
        assertNoChallenge(decide(remembered = null), RestartRecoveryDecision.NONE_NO_PROTECTED_TARGET)
    }

    @Test
    fun everyChallengeDecisionCarriesATargetAndNoOtherDoes() {
        for (decision in RestartRecoveryDecision.values()) {
            // The enum flag is the single source of truth WatcherService uses.
            val expected = decision.name.startsWith("CHALLENGE_")
            assertEquals(decision.name, expected, decision.challenges)
        }
    }

    // -- One decision per process ------------------------------------------

    @Test
    fun oneShotLatchAllowsExactlyOneDecisionPerProcess() {
        val latch = OneShotLatch()
        assertTrue(latch.tryAcquire())
        assertFalse(latch.tryAcquire())
        assertFalse(latch.tryAcquire())
    }

    @Test
    fun oneShotLatchIsExclusiveUnderConcurrentStarts() {
        val latch = OneShotLatch()
        val winners = AtomicInteger(0)
        val pool = Executors.newFixedThreadPool(8)
        val start = CountDownLatch(1)
        repeat(32) {
            pool.execute {
                start.await()
                if (latch.tryAcquire()) winners.incrementAndGet()
            }
        }
        start.countDown()
        pool.shutdown()
        assertTrue(pool.awaitTermination(10, TimeUnit.SECONDS))
        assertEquals(1, winners.get())
    }
}
