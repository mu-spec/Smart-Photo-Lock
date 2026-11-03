package com.smartapplock.app

import android.content.Context
import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Phase 8 / M2: per-app security level enforcement in the native engine.
 * Production policy, resolver, codec, order gate, [ProtectionAccessState]
 * and [ProtectionStateStore.configure] over an in-memory SharedPreferences
 * (JVM, SIMULATED Android inputs; not device evidence).
 */
class SecurityLevelEnforcementTest {
    private val app = "com.example.bank"
    private val other = "com.example.notes"
    private val launcher = "com.example.launcher"
    private val systemUi = "com.android.systemui"
    private val own = "com.smartapplock.app"

    private val std: (String) -> SecurityLevel = { SecurityLevel.STANDARD }
    private val sens: (String) -> SecurityLevel = { SecurityLevel.SENSITIVE }
    private val crit: (String) -> SecurityLevel = { SecurityLevel.CRITICAL }

    @Before
    fun reset() {
        ProtectionAccessState.revokeAll()
        ProtectionRuntime.invalidateChallengeHandoff()
        ProtectionAccessState.setGracePeriod(0L)
        ProtectionAccessState.observeForeground(launcher, false, 0L)
    }

    private fun observe(pkg: String, at: Long, levelOf: (String) -> SecurityLevel, protected: Boolean = pkg == app || pkg == other, mayRenew: Boolean = true) =
        ProtectionAccessState.observeForeground(pkg, protected, at, mayRenew, levelOf)

    private fun authorize(at: Long, level: SecurityLevel, pkg: String = app, window: Long = 120_000L) =
        ProtectionAccessState.authorize(pkg, window, at, level)

    private val allow = ProtectionAccessState.Decision.ALLOW
    private val challenge = ProtectionAccessState.Decision.CHALLENGE

    // -- policy table ---------------------------------------------------------

    @Test
    fun graceTablePerLevelNeverExceedsConfigured() {
        for (g in listOf(0L, 30_000L, 60_000L, 300_000L)) {
            assertEquals(g, SecurityLevelPolicy.graceMs(SecurityLevel.STANDARD, g))
            assertEquals(minOf(g, 15_000L), SecurityLevelPolicy.graceMs(SecurityLevel.SENSITIVE, g))
            assertEquals(0L, SecurityLevelPolicy.graceMs(SecurityLevel.CRITICAL, g))
            for (l in SecurityLevel.values()) assertTrue(SecurityLevelPolicy.graceMs(l, g) <= g)
        }
        assertEquals(0L, SecurityLevelPolicy.graceMs(SecurityLevel.STANDARD, -5L))
    }

    @Test
    fun sessionWindowIsCappedByLevelNeverExtended() {
        assertEquals(120_000L, SecurityLevelPolicy.sessionWindowMs(SecurityLevel.STANDARD, 120_000L))
        assertEquals(60_000L, SecurityLevelPolicy.sessionWindowMs(SecurityLevel.SENSITIVE, 120_000L))
        assertEquals(60_000L, SecurityLevelPolicy.sessionWindowMs(SecurityLevel.CRITICAL, 120_000L))
        assertEquals(30_000L, SecurityLevelPolicy.sessionWindowMs(SecurityLevel.CRITICAL, 30_000L))
        // Standard is uncapped: exactly the pre-M2 behaviour.
        assertEquals(999_000L, SecurityLevelPolicy.sessionWindowMs(SecurityLevel.STANDARD, 999_000L))
        assertEquals(Long.MAX_VALUE, SecurityLevelPolicy.sessionWindowMs(SecurityLevel.STANDARD, Long.MAX_VALUE))
        assertEquals(0L, SecurityLevelPolicy.sessionWindowMs(SecurityLevel.STANDARD, -1L))
    }

    // -- 8C Standard: unchanged -----------------------------------------------

    @Test
    fun standardKeepsConfiguredGraceExactlyLikeTheLegacyDefault() {
        ProtectionAccessState.setGracePeriod(30_000L)
        authorize(1_000L, SecurityLevel.STANDARD)
        assertEquals(allow, observe(app, 1_001L, std))
        observe(launcher, 2_000L, std)
        assertEquals(allow, observe(app, 31_999L, std)) // inside 30 s
        observe(launcher, 32_000L, std)
        assertEquals(challenge, observe(app, 62_000L, std)) // at 30 s: expired

        // Same sequence through the pre-M2 default (no levelOf) is identical.
        reset()
        ProtectionAccessState.setGracePeriod(30_000L)
        ProtectionAccessState.authorize(app, 120_000L, 1_000L)
        ProtectionAccessState.observeForeground(app, true, 1_001L)
        ProtectionAccessState.observeForeground(launcher, false, 2_000L)
        assertEquals(allow, ProtectionAccessState.observeForeground(app, true, 31_999L))
    }

    @Test
    fun standardImmediateRelockStillChallengesOnReentry() {
        authorize(1_000L, SecurityLevel.STANDARD)
        observe(app, 1_001L, std)
        observe(launcher, 1_002L, std)
        assertEquals(challenge, observe(app, 1_003L, std))
    }

    // -- 8D Sensitive: stricter ------------------------------------------------

    @Test
    fun sensitiveCapsGraceWhereStandardStillAllows() {
        ProtectionAccessState.setGracePeriod(60_000L)
        authorize(1_000L, SecurityLevel.SENSITIVE)
        observe(app, 1_001L, sens)
        observe(launcher, 2_000L, sens)
        assertEquals(allow, observe(app, 16_999L, sens)) // < 15 s away
        observe(launcher, 17_000L, sens)
        assertEquals(challenge, observe(app, 37_000L, sens)) // 20 s away

        reset()
        ProtectionAccessState.setGracePeriod(60_000L)
        authorize(1_000L, SecurityLevel.STANDARD)
        observe(app, 1_001L, std)
        observe(launcher, 17_000L, std)
        assertEquals(allow, observe(app, 37_000L, std)) // Standard: 20 s is fine
    }

    @Test
    fun sensitiveWindowIsShorterThanStandard() {
        authorize(0L, SecurityLevel.SENSITIVE, window = 120_000L)
        assertEquals(allow, observe(app, 10L, sens))
        assertEquals(challenge, observe(app, 61_000L, sens)) // no event for > 60 s

        reset()
        authorize(0L, SecurityLevel.STANDARD, window = 120_000L)
        observe(app, 10L, std)
        assertEquals(allow, observe(app, 61_000L, std))
    }

    @Test
    fun sensitiveUncorroboratedUsageReportCannotReviveGrace() {
        ProtectionAccessState.setGracePeriod(60_000L)
        authorize(0L, SecurityLevel.SENSITIVE)
        observe(app, 1L, sens)
        observe(launcher, 1_000L, sens)
        assertEquals(challenge, observe(app, 2_000L, sens, mayRenew = false))
    }

    // -- 8E Critical -------------------------------------------------------------

    @Test
    fun criticalChallengesEveryIndependentReentryWhateverTheGraceSetting() {
        for (g in listOf(0L, 30_000L, 60_000L, 300_000L)) {
            reset()
            ProtectionAccessState.setGracePeriod(g)
            authorize(1_000L, SecurityLevel.CRITICAL)
            assertEquals(allow, observe(app, 1_001L, crit))
            observe(launcher, 1_002L, crit)
            assertFalse(ProtectionAccessState.isAuthorized(app))
            assertEquals("grace=$g", challenge, observe(app, 1_003L, crit))
        }
    }

    @Test
    fun criticalAuthorizationIsUsableForTheCurrentInteractionWithoutRepeatedChallenge() {
        ProtectionAccessState.setGracePeriod(300_000L)
        authorize(0L, SecurityLevel.CRITICAL)
        // Same-package window events every 30 s for 5 minutes: never challenged.
        var t = 0L
        while (t <= 300_000L) {
            assertEquals("t=$t", allow, observe(app, t, crit))
            t += 30_000L
        }
        assertTrue(ProtectionAccessState.isAuthorized(app))
    }

    @Test
    fun criticalWindowIsCappedNativelyEvenIfALongerOneIsRequested() {
        authorize(0L, SecurityLevel.CRITICAL, window = 600_000L)
        observe(app, 1L, crit)
        assertEquals(challenge, observe(app, 60_001L, crit))
    }

    @Test
    fun criticalHomeTaskSwitchSystemWindowAndOwnUiAreAllDepartures() {
        ProtectionAccessState.setGracePeriod(300_000L)
        for (away in listOf(launcher, other, systemUi, own)) {
            reset()
            ProtectionAccessState.setGracePeriod(300_000L)
            authorize(0L, SecurityLevel.CRITICAL)
            observe(app, 1L, crit)
            observe(away, 2L, crit, protected = away == other)
            assertEquals("via $away", challenge, observe(app, 3L, crit))
        }
    }

    @Test
    fun screenOffRevokesEveryLevel() {
        ProtectionAccessState.setGracePeriod(300_000L)
        authorize(0L, SecurityLevel.STANDARD, pkg = other)
        authorize(0L, SecurityLevel.CRITICAL, pkg = app)
        ProtectionAccessState.revokeAll() // ACTION_SCREEN_OFF path
        assertEquals(challenge, observe(app, 5L, crit))
        assertEquals(challenge, observe(other, 6L, std))
    }

    @Test
    fun mixedLevelsAreIndependentPerPackage() {
        ProtectionAccessState.setGracePeriod(30_000L)
        val levels = mapOf(app to SecurityLevel.CRITICAL, other to SecurityLevel.STANDARD)
        val levelOf: (String) -> SecurityLevel = { levels[it] ?: SecurityLevel.CRITICAL }
        authorize(0L, SecurityLevel.STANDARD, pkg = other)
        observe(other, 1L, levelOf)
        observe(launcher, 2L, levelOf)
        assertEquals(allow, observe(other, 10_000L, levelOf)) // Standard grace
        authorize(10_001L, SecurityLevel.CRITICAL, pkg = app)
        observe(app, 10_002L, levelOf)
        observe(launcher, 10_003L, levelOf)
        assertEquals(challenge, observe(app, 10_004L, levelOf)) // Critical: none
    }

    @Test
    fun revokeForRaisedLevelRemovesAnAwayGraceWindow() {
        ProtectionAccessState.setGracePeriod(300_000L)
        authorize(0L, SecurityLevel.STANDARD)
        observe(app, 1L, std)
        observe(own, 2L, std) // user opens Smart App Lock, app is away in grace
        assertTrue(ProtectionAccessState.isAuthorized(app))
        ProtectionAccessState.revoke(setOf(app))
        assertFalse(ProtectionAccessState.isAuthorized(app))
        assertEquals(challenge, observe(app, 3L, crit))
    }

    // -- resolver: legacy / invalid / downgrade / raised -------------------------

    private val pk = setOf(app, other)

    @Test
    fun legacyTransportKeepsKnownLevelsAndNewPackagesAreStandard() {
        val r = PolicySnapshotResolver.resolve(pk, null, null, mapOf(app to SecurityLevel.CRITICAL), emptySet())
        assertEquals(PolicySnapshotResolver.Status.LEGACY, r.status)
        assertEquals(SecurityLevel.CRITICAL, r.levels[app])
        assertEquals(SecurityLevel.STANDARD, r.levels[other])
        assertTrue(r.raised.isEmpty())
    }

    @Test
    fun validSnapshotAppliesExactLevelsForTheProtectedSetOnly() {
        val r = PolicySnapshotResolver.resolve(pk, 1, mapOf(app to "critical", other to "sensitive"), emptyMap(), emptySet())
        assertEquals(PolicySnapshotResolver.Status.APPLIED, r.status)
        assertEquals(mapOf(app to SecurityLevel.CRITICAL, other to SecurityLevel.SENSITIVE), r.levels)
        assertEquals(pk, r.levels.keys)
    }

    @Test
    fun downgradeIsHeldWithoutAcknowledgementAndAppliedWithIt() {
        val prev = mapOf(app to SecurityLevel.CRITICAL, other to SecurityLevel.SENSITIVE)
        val wanted = mapOf(app to "standard", other to "standard")
        val held = PolicySnapshotResolver.resolve(pk, 1, wanted, prev, emptySet())
        assertEquals(prev, held.levels)
        assertEquals(pk, held.heldDowngrades)
        val acked = PolicySnapshotResolver.resolve(pk, 1, wanted, prev, setOf(app))
        assertEquals(SecurityLevel.STANDARD, acked.levels[app])
        assertEquals(SecurityLevel.SENSITIVE, acked.levels[other])
        assertEquals(setOf(other), acked.heldDowngrades)
    }

    @Test
    fun upgradeNeedsNoAcknowledgementAndIsReportedAsRaised() {
        val r = PolicySnapshotResolver.resolve(pk, 1, mapOf(app to "critical", other to "standard"), mapOf(app to SecurityLevel.STANDARD, other to SecurityLevel.STANDARD), emptySet())
        assertEquals(SecurityLevel.CRITICAL, r.levels[app])
        assertEquals(setOf(app), r.raised)
        assertTrue(r.heldDowngrades.isEmpty())
    }

    @Test
    fun malformedPresentPolicyFailsStrictToCriticalForEveryProtectedPackage() {
        val good = mapOf(app to "standard", other to "standard")
        val cases = listOf<Pair<Any?, Any?>>(
            2 to good, // unknown version
            null to good, // map without version
            1 to null, // version without map
            1.5 to good, // non-integral version
            "1" to good, // wrong version type
            1 to listOf(app), // wrong map type
            1 to mapOf(app to "standard"), // missing key
            1 to mapOf(app to "standard", other to "standard", "x.y" to "standard"), // extra key
            1 to mapOf(app to "standard", other to "ULTRA"), // unknown id
            1 to mapOf(app to "Standard", other to "standard"), // wrong case
            1 to mapOf(app to 1, other to "standard"), // wrong value type
        )
        for ((version, raw) in cases) {
            val r = PolicySnapshotResolver.resolve(pk, version, raw, mapOf(app to SecurityLevel.STANDARD), emptySet())
            assertEquals("$version/$raw", PolicySnapshotResolver.Status.INVALID, r.status)
            assertEquals(pk.associateWith { SecurityLevel.CRITICAL }, r.levels)
            assertEquals(setOf(app), r.raised)
        }
    }

    @Test
    fun malformedUpdateNeverWipesAStricterKnownLevel() {
        val r = PolicySnapshotResolver.resolve(pk, 7, "garbage", mapOf(app to SecurityLevel.CRITICAL, other to SecurityLevel.SENSITIVE), pk)
        assertTrue(r.levels.values.all { it == SecurityLevel.CRITICAL })
    }

    // -- codec: no map yet vs damaged map ---------------------------------------

    @Test
    fun codecDistinguishesLegacyFromDamaged() {
        assertEquals(pk.associateWith { SecurityLevel.STANDARD }, SecurityLevelStoreCodec.decode(null, null, pk))
        val stored = SecurityLevelStoreCodec.encode(mapOf(app to SecurityLevel.SENSITIVE, other to SecurityLevel.CRITICAL))
        assertEquals(mapOf(app to SecurityLevel.SENSITIVE, other to SecurityLevel.CRITICAL), SecurityLevelStoreCodec.decode(1, stored, pk))
        assertEquals(SecurityLevel.CRITICAL, SecurityLevelStoreCodec.decode(1, setOf("$app=ULTRA", "$other=standard"), pk)[app])
        assertEquals(SecurityLevel.STANDARD, SecurityLevelStoreCodec.decode(1, setOf("$app=ULTRA", "$other=standard"), pk)[other])
        assertEquals(SecurityLevel.CRITICAL, SecurityLevelStoreCodec.decode(1, setOf("$other=standard"), pk)[app]) // missing entry
        assertEquals(pk.associateWith { SecurityLevel.CRITICAL }, SecurityLevelStoreCodec.decode(9, stored, pk))
        assertEquals(pk.associateWith { SecurityLevel.CRITICAL }, SecurityLevelStoreCodec.decode(1, setOf("=critical", "nonsense"), pk))
    }

    // -- order gate -----------------------------------------------------------------

    @Test
    fun staleOrOutOfOrderSnapshotsAreRejectedPerSession() {
        val gate = SnapshotOrderGate()
        assertTrue(gate.accept("s1", 1L))
        assertTrue(gate.accept("s1", 3L))
        assertFalse(gate.accept("s1", 2L)) // out of order
        assertFalse(gate.accept("s1", 3L)) // duplicate
        assertTrue(gate.accept("s2", 1L)) // Dart restarted: new session
        assertTrue(gate.accept(null, null)) // legacy transport carries no order
        assertFalse(gate.accept("s2", 1L))
    }

    // -- ProtectionStateStore.configure (in-memory SharedPreferences) -------------

    private class FakePrefs : SharedPreferences {
        val data = mutableMapOf<String, Any>()
        /**
         * Simulates a failed disk write with AOSP SharedPreferencesImpl
         * semantics: the in-memory map is updated FIRST and never rolled
         * back; commit() returns false and [disk] keeps its previous content.
         */
        var failCommit = false
        /** What survives process death: the full map of the last successful write. */
        val disk = mutableMapOf<String, Any>()
        override fun getBoolean(key: String?, defValue: Boolean) = data[key] as? Boolean ?: defValue
        override fun getLong(key: String?, defValue: Long) = data[key] as? Long ?: defValue
        override fun getInt(key: String?, defValue: Int) = data[key] as? Int ?: defValue
        override fun getString(key: String?, defValue: String?) = data[key] as? String ?: defValue
        @Suppress("UNCHECKED_CAST")
        override fun getStringSet(key: String?, defValues: Set<String>?): Set<String>? =
            (data[key] as? Set<String>)?.toSet() ?: defValues
        override fun contains(key: String?) = data.containsKey(key)
        override fun edit(): SharedPreferences.Editor = FakeEditor(this)
    }

    private class FakeEditor(private val prefs: FakePrefs) : SharedPreferences.Editor {
        private val data get() = prefs.data
        private val puts = mutableMapOf<String, Any>()
        private val removes = mutableSetOf<String>()
        private fun put(key: String?, value: Any): SharedPreferences.Editor {
            puts[key!!] = value
            return this
        }
        override fun putBoolean(key: String?, value: Boolean): SharedPreferences.Editor = put(key, value)
        override fun putLong(key: String?, value: Long): SharedPreferences.Editor = put(key, value)
        override fun putInt(key: String?, value: Int): SharedPreferences.Editor = put(key, value)
        override fun putString(key: String?, value: String?): SharedPreferences.Editor = put(key, value!!)
        override fun putStringSet(key: String?, values: Set<String>?): SharedPreferences.Editor =
            put(key, values!!.toSet())
        override fun remove(key: String?): SharedPreferences.Editor {
            removes += key!!
            return this
        }
        override fun clear(): SharedPreferences.Editor {
            data.clear()
            return this
        }
        override fun apply() {
            commit()
        }
        override fun commit(): Boolean {
            removes.forEach { data.remove(it) }
            data.putAll(puts)
            if (prefs.failCommit) return false
            // AOSP writes the WHOLE in-memory map on every disk write.
            prefs.disk.clear()
            prefs.disk.putAll(data)
            return true
        }
    }

    private class FakeContext(val prefs: FakePrefs = FakePrefs()) : Context() {
        /** A new process: only what reached disk is visible. */
        fun restarted(): FakeContext = FakeContext(FakePrefs().also { it.data.putAll(prefs.disk) })

        override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences = prefs
    }

    private var sessionCounter = 0
    private fun session() = "test-${System.nanoTime()}-${sessionCounter++}"

    private fun policy(levels: Map<String, String>, session: String, revision: Long, acks: Set<String> = emptySet()) =
        ProtectionStateStore.PolicyInput(1, levels, session, revision, acks)

    @Test
    fun legacyStoreWithoutLevelMapReadsStandardAndUpgradesWithoutDowngrade() {
        val ctx = FakeContext()
        // A pre-M2 build persisted only the enabled flag and the package set.
        ctx.prefs.data["enabled"] = true
        ctx.prefs.data["protected_packages"] = setOf(app, other)
        assertEquals(pk.associateWith { SecurityLevel.STANDARD }, ProtectionStateStore.securityLevels(ctx))
        val s = session()
        val out = ProtectionStateStore.configure(ctx, true, pk, policy(mapOf(app to "critical", other to "standard"), s, 1))
        assertTrue(out.applied)
        assertEquals("applied", out.status)
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.securityLevel(ctx, app))
        assertEquals(SecurityLevel.STANDARD, ProtectionStateStore.securityLevel(ctx, other))
    }

    @Test
    fun levelsPersistWithThePackageSetAndSurviveARestartRead() {
        val ctx = FakeContext()
        val s = session()
        ProtectionStateStore.configure(ctx, true, pk, policy(mapOf(app to "sensitive", other to "critical"), s, 1))
        // A new process reads the same preferences (no Dart yet).
        val reread = ProtectionStateStore.securityLevels(FakeContext(ctx.prefs))
        assertEquals(mapOf(app to SecurityLevel.SENSITIVE, other to SecurityLevel.CRITICAL), reread)
        assertEquals(pk, ProtectionStateStore.protectedPackages(ctx))
    }

    @Test
    fun staleSnapshotChangesNothing() {
        val ctx = FakeContext()
        val s = session()
        ProtectionStateStore.configure(ctx, true, pk, policy(mapOf(app to "critical", other to "standard"), s, 5))
        val out = ProtectionStateStore.configure(ctx, true, setOf(other), policy(mapOf(other to "standard"), s, 4))
        assertFalse(out.applied)
        assertEquals("stale", out.status)
        assertEquals(pk, ProtectionStateStore.protectedPackages(ctx)) // app NOT dropped
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.securityLevel(ctx, app))
    }

    @Test
    fun raisingALevelRevokesThatAuthorizationButKeepsThePendingTicket() {
        val ctx = FakeContext()
        val s = session()
        ProtectionStateStore.configure(ctx, true, pk, policy(mapOf(app to "standard", other to "standard"), s, 1))
        ProtectionAccessState.setGracePeriod(300_000L)
        authorize(0L, SecurityLevel.STANDARD, pkg = app)
        authorize(0L, SecurityLevel.STANDARD, pkg = other)
        val ticket = ProtectionStateStore.replacePendingChallenge(ctx, other)
        ProtectionStateStore.configure(ctx, true, pk, policy(mapOf(app to "critical", other to "standard"), s, 2))
        assertFalse(ProtectionAccessState.isAuthorized(app))
        assertTrue(ProtectionAccessState.isAuthorized(other))
        assertEquals(ticket, ProtectionStateStore.pendingChallenge(ctx))
    }

    @Test
    fun snapshotIsWrittenDurablyAndAFailedWriteIsReportedNotPersisted() {
        val ctx = FakeContext()
        val ok = ProtectionStateStore.configure(ctx, true, pk, policy(mapOf(app to "critical", other to "standard"), session(), 1))
        assertTrue(ok.persisted)
        assertEquals(true, ok.toMap()["persisted"])
        ctx.prefs.failCommit = true
        val failed = ProtectionStateStore.configure(ctx, true, pk, policy(mapOf(app to "critical", other to "critical"), session(), 1))
        assertFalse(failed.persisted)
        assertEquals(false, failed.toMap()["persisted"])
    }

    @Test
    fun unacknowledgedDowngradeIsHeldAndReportedAcknowledgedOneApplies() {
        val ctx = FakeContext()
        val s = session()
        ProtectionStateStore.configure(ctx, true, pk, policy(mapOf(app to "critical", other to "sensitive"), s, 1))
        val held = ProtectionStateStore.configure(ctx, true, pk, policy(mapOf(app to "standard", other to "sensitive"), s, 2))
        assertEquals(setOf(app), held.heldDowngrades)
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.securityLevel(ctx, app))
        assertEquals("critical", (held.toMap()["effectiveLevels"] as Map<*, *>)[app])
        val acked = ProtectionStateStore.configure(ctx, true, pk, policy(mapOf(app to "standard", other to "sensitive"), s, 3, setOf(app)))
        assertTrue(acked.heldDowngrades.isEmpty())
        assertEquals(SecurityLevel.STANDARD, ProtectionStateStore.securityLevel(ctx, app))
    }

    @Test
    fun aRestartedDartSessionCannotDowngradeWithoutAcknowledgement() {
        val ctx = FakeContext()
        ProtectionStateStore.configure(ctx, true, pk, policy(mapOf(app to "critical", other to "standard"), session(), 9))
        val out = ProtectionStateStore.configure(ctx, true, pk, policy(mapOf(app to "standard", other to "standard"), session(), 1))
        assertTrue(out.applied)
        assertEquals(setOf(app), out.heldDowngrades)
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.securityLevel(ctx, app))
    }

    @Test
    fun invalidSnapshotIsCriticalAndRecordsAnError() {
        val ctx = FakeContext()
        val out = ProtectionStateStore.configure(ctx, true, pk, ProtectionStateStore.PolicyInput(1, mapOf(app to "standard"), session(), 1))
        assertEquals("invalid", out.status)
        assertEquals(pk.associateWith { SecurityLevel.CRITICAL }, ProtectionStateStore.securityLevels(ctx))
        assertEquals(ProtectionStateStore.ERROR_LEVELS_INVALID, ProtectionStateStore.lastError(ctx))
        assertTrue(ProtectionStateStore.isEnabled(ctx)) // protection is never dropped
    }

    @Test
    fun removalRetiresTheLevelAndReAddingStartsStandard() {
        val ctx = FakeContext()
        val s = session()
        ProtectionStateStore.configure(ctx, true, pk, policy(mapOf(app to "critical", other to "standard"), s, 1))
        ProtectionStateStore.configure(ctx, true, setOf(other), policy(mapOf(other to "standard"), s, 2))
        assertFalse(ProtectionStateStore.securityLevels(ctx).containsKey(app))
        ProtectionStateStore.configure(ctx, true, pk, policy(mapOf(app to "standard", other to "standard"), s, 3))
        assertEquals(SecurityLevel.STANDARD, ProtectionStateStore.securityLevel(ctx, app))
    }

    @Test
    fun legacyTransportCallStillWorksAndNeverDowngrades() {
        val ctx = FakeContext()
        ProtectionStateStore.configure(ctx, true, pk, policy(mapOf(app to "critical", other to "standard"), session(), 1))
        val out = ProtectionStateStore.configure(ctx, true, pk)
        assertEquals("legacy", out.status)
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.securityLevel(ctx, app))
    }

    @Test
    fun aPackageOutsideTheProtectedSetHasNoPolicyAndReadsStrict() {
        val ctx = FakeContext()
        ProtectionStateStore.configure(ctx, true, pk, policy(mapOf(app to "standard", other to "standard"), session(), 1))
        assertFalse(ProtectionStateStore.securityLevels(ctx).containsKey(launcher))
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.securityLevel(ctx, launcher))
        assertNull(ProtectionStateStore.pendingChallenge(ctx))
    }

    // -- Final native enforcement gate, finding 1: failed level persistence ------
    // SIMULATED disk failure (FakePrefs.failCommit, AOSP commit semantics).

    private fun persistedLevels(ctx: FakeContext, levels: Map<String, String>): FakeContext {
        val out = ProtectionStateStore.configure(ctx, true, pk, policy(levels, session(), 1))
        assertTrue(out.persisted)
        return ctx
    }

    private fun storeLevelOf(ctx: FakeContext): (String) -> SecurityLevel =
        { ProtectionStateStore.securityLevel(ctx, it) }

    @Test
    fun gateF1_failedCriticalToStandardDowngradeNeverLowersTheConfirmedLevel() {
        val ctx = persistedLevels(FakeContext(), mapOf(app to "critical", other to "standard"))
        ctx.prefs.failCommit = true
        val out = ProtectionStateStore.configure(
            ctx, true, pk, policy(mapOf(app to "standard", other to "standard"), session(), 1, setOf(app)),
        )
        assertTrue(out.applied)
        assertFalse(out.persisted)
        assertEquals(SecurityLevel.CRITICAL, out.levels[app])
        assertEquals(setOf(app), out.heldDowngrades)
        assertEquals("critical", (out.toMap()["effectiveLevels"] as Map<*, *>)[app])
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.securityLevel(ctx, app))
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.securityLevel(ctx.restarted(), app))
    }

    @Test
    fun gateF1_failedSensitiveToStandardDowngradeNeverLowersTheConfirmedLevel() {
        val ctx = persistedLevels(FakeContext(), mapOf(app to "standard", other to "sensitive"))
        ctx.prefs.failCommit = true
        val out = ProtectionStateStore.configure(
            ctx, true, pk, policy(mapOf(app to "standard", other to "standard"), session(), 1, setOf(other)),
        )
        assertFalse(out.persisted)
        assertEquals(SecurityLevel.SENSITIVE, out.levels[other])
        assertEquals(setOf(other), out.heldDowngrades)
        assertEquals(SecurityLevel.SENSITIVE, ProtectionStateStore.securityLevel(ctx, other))
        assertEquals(SecurityLevel.STANDARD, ProtectionStateStore.securityLevel(ctx, app))
        assertEquals(SecurityLevel.SENSITIVE, ProtectionStateStore.securityLevel(ctx.restarted(), other))
    }

    @Test
    fun gateF1_failedDowngradeKeepsStrictGraceAuthorizationAndPendingTicket() {
        val ctx = persistedLevels(FakeContext(), mapOf(app to "critical", other to "sensitive"))
        ProtectionAccessState.setGracePeriod(30_000L)
        ProtectionAccessState.authorize(app, 120_000L, 1_000L, ProtectionStateStore.securityLevel(ctx, app))
        val ticket = ProtectionStateStore.replacePendingChallenge(ctx, other)
        ctx.prefs.failCommit = true
        ProtectionStateStore.configure(
            ctx, true, pk, policy(mapOf(app to "standard", other to "standard"), session(), 1, setOf(app, other)),
        )
        // The failed downgrade neither revokes nor extends the existing grant.
        assertTrue(ProtectionAccessState.isAuthorized(app))
        assertEquals(ticket, ProtectionStateStore.pendingChallenge(ctx))
        // Critical still: leaving gives no grace, re-entry re-challenges.
        assertEquals(allow, observe(app, 2_000L, storeLevelOf(ctx)))
        assertEquals(allow, observe(launcher, 3_000L, storeLevelOf(ctx)))
        assertFalse(ProtectionAccessState.isAuthorized(app))
        assertEquals(challenge, observe(app, 4_000L, storeLevelOf(ctx)))
        // Sensitive grace stays capped at 15 s, not the configured 30 s.
        ProtectionAccessState.authorize(other, 120_000L, 5_000L, ProtectionStateStore.securityLevel(ctx, other))
        assertEquals(allow, observe(launcher, 6_000L, storeLevelOf(ctx)))
        assertEquals(challenge, observe(other, 22_000L, storeLevelOf(ctx)))
    }

    @Test
    fun gateF1_laterUnrelatedWritesAndRestartCannotMakeTheFailedDowngradeDurable() {
        val ctx = persistedLevels(FakeContext(), mapOf(app to "critical", other to "standard"))
        ctx.prefs.failCommit = true
        ProtectionStateStore.configure(
            ctx, true, pk, policy(mapOf(app to "standard", other to "standard"), session(), 1, setOf(app)),
        )
        // The disk recovers; other writers flush the WHOLE in-memory map.
        ctx.prefs.failCommit = false
        ProtectionStateStore.setLastError(ctx, "unrelated")
        ProtectionStateStore.replacePendingChallenge(ctx, other)
        assertTrue(SecurityLevelStoreCodec.encode(mapOf(app to SecurityLevel.CRITICAL)).first() in
            (ctx.prefs.disk["security_levels"] as Set<*>))
        val restarted = ctx.restarted()
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.securityLevel(restarted, app))
        // A later sync without a fresh acknowledgement stays held.
        val retry = ProtectionStateStore.configure(
            restarted, true, pk, policy(mapOf(app to "standard", other to "standard"), session(), 1),
        )
        assertEquals(setOf(app), retry.heldDowngrades)
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.securityLevel(restarted, app))
        // Only an acknowledged AND durable write lowers it.
        val acked = ProtectionStateStore.configure(
            restarted, true, pk, policy(mapOf(app to "standard", other to "standard"), session(), 1, setOf(app)),
        )
        assertTrue(acked.persisted)
        assertEquals(SecurityLevel.STANDARD, ProtectionStateStore.securityLevel(restarted.restarted(), app))
    }

    @Test
    fun gateF1_failedUpgradeIsEnforcedInThisProcessAndRevokesButRestartUsesLastDurableLevel() {
        val ctx = persistedLevels(FakeContext(), mapOf(app to "standard", other to "standard"))
        ProtectionAccessState.authorize(app, 120_000L, 1_000L, SecurityLevel.STANDARD)
        ctx.prefs.failCommit = true
        val out = ProtectionStateStore.configure(
            ctx, true, pk, policy(mapOf(app to "critical", other to "standard"), session(), 1),
        )
        assertFalse(out.persisted)
        assertEquals(SecurityLevel.CRITICAL, out.levels[app])
        assertTrue(out.heldDowngrades.isEmpty())
        assertFalse(ProtectionAccessState.isAuthorized(app))
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.securityLevel(ctx, app))
        // Documented: after process death native has only the last durable
        // level until the next Dart sync (Dart was told "not persisted").
        assertEquals(SecurityLevel.STANDARD, ProtectionStateStore.securityLevel(ctx.restarted(), app))
    }

    @Test
    fun gateF1_unpersistedNeverGoesBelowPreviousAndKeepsUpgrades() {
        val resolved = mapOf(app to SecurityLevel.STANDARD, other to SecurityLevel.CRITICAL, launcher to SecurityLevel.STANDARD)
        val previous = mapOf(app to SecurityLevel.SENSITIVE, other to SecurityLevel.STANDARD)
        assertEquals(
            mapOf(app to SecurityLevel.SENSITIVE, other to SecurityLevel.CRITICAL, launcher to SecurityLevel.STANDARD),
            PolicySnapshotResolver.unpersisted(resolved, previous),
        )
    }

    // -- Final native enforcement gate, finding 2: M1 -> M2 process start --------
    // SIMULATED process start (fresh ProtectionAccessState, legacy prefs).

    private fun legacyM1Store(): FakeContext = FakeContext().also {
        it.prefs.data["enabled"] = true
        it.prefs.data["protected_packages"] = setOf(app, other)
        it.prefs.disk.putAll(it.prefs.data)
    }

    @Test
    fun gateF2_missingHistoricalMapIsLegacyButAVersionlessMapIsDamaged() {
        assertEquals(pk.associateWith { SecurityLevel.STANDARD }, SecurityLevelStoreCodec.decode(null, null, pk))
        assertEquals(pk.associateWith { SecurityLevel.CRITICAL }, SecurityLevelStoreCodec.decode(null, setOf("$app=standard"), pk))
        val ctx = legacyM1Store()
        assertEquals(SecurityLevel.STANDARD, ProtectionStateStore.securityLevel(ctx, app))
        ctx.prefs.data["security_levels"] = setOf("$app=standard")
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.securityLevel(ctx, app))
    }

    @Test
    fun gateF2_afterUpgradeOrRebootNoAuthorizationExistsSoFirstAccessChallenges() {
        val ctx = legacyM1Store().restarted()
        ProtectionAccessState.setGracePeriod(30_000L)
        assertEquals(challenge, observe(app, 1_000L, storeLevelOf(ctx)))
        assertEquals(challenge, observe(other, 2_000L, storeLevelOf(ctx)))
    }

    @Test
    fun gateF2_aGrantBeforeTheFirstLevelSyncIsRevokedWhenTheSyncRaisesIt() {
        val ctx = legacyM1Store()
        ProtectionAccessState.authorize(app, 120_000L, 1_000L, ProtectionStateStore.securityLevel(ctx, app))
        val out = ProtectionStateStore.configure(ctx, true, pk, policy(mapOf(app to "critical", other to "standard"), session(), 1))
        assertTrue(out.persisted)
        assertTrue(out.heldDowngrades.isEmpty())
        assertFalse(ProtectionAccessState.isAuthorized(app))
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.securityLevel(ctx.restarted(), app))
    }

    @Test
    fun gateF2_dartFloorKeepsCriticalWithoutGraceWhileTheStoreIsStillLegacy() {
        val ctx = legacyM1Store()
        ProtectionAccessState.setGracePeriod(30_000L)
        // The first level sync has not been applied (or failed): store is Standard.
        ProtectionAccessState.authorize(app, 120_000L, 1_000L, ProtectionStateStore.securityLevel(ctx, app), SecurityLevel.CRITICAL)
        assertEquals(allow, observe(app, 2_000L, storeLevelOf(ctx)))
        assertEquals(allow, observe(launcher, 3_000L, storeLevelOf(ctx)))
        assertFalse(ProtectionAccessState.isAuthorized(app))
        assertEquals(challenge, observe(app, 4_000L, storeLevelOf(ctx)))
        // Critical window cap (1 min) also applies.
        ProtectionAccessState.authorize(app, 120_000L, 10_000L, SecurityLevel.STANDARD, SecurityLevel.CRITICAL)
        assertEquals(allow, observe(app, 10_001L, storeLevelOf(ctx)))
        assertEquals(challenge, observe(app, 70_002L, storeLevelOf(ctx)))
    }

    @Test
    fun gateF2_sensitiveFloorCapsGraceAndAFloorNeverLoosensTheStore() {
        val ctx = legacyM1Store()
        ProtectionAccessState.setGracePeriod(30_000L)
        ProtectionAccessState.authorize(other, 120_000L, 1_000L, SecurityLevel.STANDARD, SecurityLevel.SENSITIVE)
        assertEquals(allow, observe(launcher, 2_000L, storeLevelOf(ctx)))
        assertEquals(challenge, observe(other, 18_000L, storeLevelOf(ctx)))
        // Store Critical + Standard floor: still no grace.
        ProtectionAccessState.authorize(app, 120_000L, 20_000L, SecurityLevel.CRITICAL, SecurityLevel.STANDARD)
        assertEquals(allow, observe(launcher, 21_000L, crit))
        assertEquals(challenge, observe(app, 22_000L, crit))
        // No floor: pre-M2 Standard behaviour unchanged.
        ProtectionAccessState.authorize(app, 120_000L, 30_000L, SecurityLevel.STANDARD)
        assertEquals(allow, observe(launcher, 31_000L, std))
        assertEquals(allow, observe(app, 40_000L, std))
    }

    @Test
    fun gateF2_authorizationFloorTransportOnlyTightens() {
        assertNull(SecurityLevelPolicy.authorizationFloor(false, null))
        assertNull(SecurityLevelPolicy.authorizationFloor(false, "standard"))
        assertEquals(SecurityLevel.STANDARD, SecurityLevelPolicy.authorizationFloor(true, "standard"))
        assertEquals(SecurityLevel.SENSITIVE, SecurityLevelPolicy.authorizationFloor(true, "sensitive"))
        assertEquals(SecurityLevel.CRITICAL, SecurityLevelPolicy.authorizationFloor(true, "critical"))
        for (bad in listOf<Any?>(null, "", "CRITICAL", "Standard", 2, true, listOf("standard"))) {
            assertEquals(SecurityLevel.CRITICAL, SecurityLevelPolicy.authorizationFloor(true, bad))
        }
    }

    @Test
    fun gateF2_restartPreservesAKnownStricterPolicyAndLegacyTransportKeepsIt() {
        val ctx = legacyM1Store()
        ProtectionStateStore.configure(ctx, true, pk, policy(mapOf(app to "critical", other to "sensitive"), session(), 1))
        val restarted = ctx.restarted()
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.securityLevel(restarted, app))
        assertEquals(SecurityLevel.SENSITIVE, ProtectionStateStore.securityLevel(restarted, other))
        // A legacy (level-less) configure, e.g. an older caller, keeps them.
        ProtectionStateStore.configure(restarted, true, pk)
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.securityLevel(restarted.restarted(), app))
        assertEquals(SecurityLevel.SENSITIVE, ProtectionStateStore.securityLevel(restarted.restarted(), other))
    }

    @Test
    fun gateF2_nativeAuthorizePathForwardsTheDartFloor() {
        // WatcherService/WatcherChannel are not JVM-compilable here; the
        // wiring is pinned by source (the logic is tested above).
        val relative = "src/main/kotlin/com/smartapplock/app"
        val dir = listOf(java.io.File(relative), java.io.File("android/app/$relative")).first { it.isDirectory }
        val service = java.io.File(dir, "WatcherService.kt").readText()
        val channel = java.io.File(dir, "WatcherChannel.kt").readText()
        assertTrue(service.contains("levelFloor: SecurityLevel? = null"))
        assertTrue(service.contains("floor = levelFloor,"))
        assertTrue(channel.contains("SecurityLevelPolicy.authorizationFloor("))
        assertTrue(channel.contains("?.containsKey(\"securityLevel\") == true"))
    }
}
