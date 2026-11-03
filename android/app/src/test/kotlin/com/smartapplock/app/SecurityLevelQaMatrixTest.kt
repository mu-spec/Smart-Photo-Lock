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
 * Phase 8 / M3 (PRD 8G): "verify level changes affect protection correctly".
 *
 * Table-driven matrix over the production native engine
 * ([ProtectionAccessState], [SecurityLevelPolicy], [PolicySnapshotResolver],
 * [SecurityLevelStoreCodec], [ProtectionStateStore], [WatcherTeardownPolicy]):
 * every level x scenario, every level transition, unlock-level binding,
 * store integrity and failed persistence followed by process death.
 *
 * Evidence level: JVM, SIMULATED Android inputs (explicit elapsed-time
 * values, a fake SharedPreferences with AOSP commit semantics, process death
 * modelled as "authorizations cleared + store re-read from disk"). Screen-off
 * and watcher teardown are modelled by the exact calls their production
 * handlers make. Not device evidence.
 */
class SecurityLevelQaMatrixTest {
    private val app = "com.example.bank"
    private val other = "com.example.notes"
    private val launcher = "com.example.launcher"
    private val systemUi = "com.android.systemui"
    private val own = "com.smartapplock.app"
    private val pk = setOf(app, other)
    private val configuredGraceMs = 30_000L
    private val requestedWindowMs = 120_000L
    private val allow = ProtectionAccessState.Decision.ALLOW
    private val challenge = ProtectionAccessState.Decision.CHALLENGE
    private val levels = SecurityLevel.values().toList()

    /** 8C/8D/8E expectations with a configured grace of 30 s and a 2-min window. */
    private fun grace(level: SecurityLevel) = when (level) {
        SecurityLevel.STANDARD -> 30_000L
        SecurityLevel.SENSITIVE -> 15_000L
        SecurityLevel.CRITICAL -> 0L
    }

    private fun window(level: SecurityLevel) = when (level) {
        SecurityLevel.STANDARD -> 120_000L
        SecurityLevel.SENSITIVE, SecurityLevel.CRITICAL -> 60_000L
    }

    @Before
    fun reset() {
        ProtectionRuntime.invalidateChallengeHandoff()
        ProtectionAccessState.setGracePeriod(configuredGraceMs)
        fresh()
    }

    private fun fresh() {
        ProtectionAccessState.revokeAll()
        ProtectionAccessState.observeForeground(launcher, false, 0L)
    }

    private fun observe(pkg: String, at: Long, level: SecurityLevel, mayRenew: Boolean = true) =
        ProtectionAccessState.observeForeground(pkg, pkg in pk, at, mayRenew) { level }

    private fun unlock(level: SecurityLevel, at: Long = 1_000L, floor: SecurityLevel? = null) =
        ProtectionAccessState.authorize(app, requestedWindowMs, at, level, floor)

    private fun check(failures: MutableList<String>, label: String, expected: Any?, actual: Any?) {
        if (expected != actual) failures += "$label: expected $expected, got $actual"
    }

    // -- 1. Level x scenario matrix ----------------------------------------------

    @Test
    fun levelScenarioMatrix() {
        val failures = mutableListOf<String>()
        for (l in levels) {
            // Initial access: always challenged.
            fresh()
            check(failures, "$l initial access", challenge, observe(app, 1_000L, l))

            // Same foreground interaction: usable for 5 min of continued presence
            // (H-2 slides on same-package observations), no challenge loop.
            fresh(); unlock(l)
            val same = (1..15).map { observe(app, 1_000L + it * 20_000L, l) }
            check(failures, "$l same interaction", List(15) { allow }, same)

            // Leave (Home/launcher) and re-entry after various times away.
            for (away in listOf(1_000L, 10_000L, 20_000L, 31_000L)) {
                fresh(); unlock(l)
                observe(launcher, 2_000L, l)
                val expected = if (away < grace(l)) allow else challenge
                check(failures, "$l leave+return after ${away}ms", expected, observe(app, 2_000L + away, l))
            }

            // Recents / System UI, own UI, another protected app: all departures.
            for (via in listOf(systemUi, own, other)) {
                fresh(); unlock(l)
                observe(via, 2_000L, l)
                val expected = if (grace(l) > 1_000L) allow else challenge
                check(failures, "$l switch via $via and back after 1s", expected, observe(app, 3_000L, l))
            }

            // Screen off/on: WatcherService's ACTION_SCREEN_OFF handler revokes all.
            fresh(); unlock(l)
            ProtectionAccessState.revokeAll()
            check(failures, "$l screen off/on", challenge, observe(app, 2_000L, l))

            // Inactivity window expiry (event-driven, H-2 unchanged).
            fresh(); unlock(l)
            check(failures, "$l just inside window", allow, observe(app, 1_000L + window(l) - 1L, l))
            fresh(); unlock(l)
            check(failures, "$l window expired", challenge, observe(app, 1_000L + window(l), l))

            // Watcher interruption: the teardown policy while still configured.
            fresh(); unlock(l)
            val teardown = WatcherTeardownPolicy.onDestroy(true)
            if (teardown.revokesAuthorizations) ProtectionAccessState.revokeAll()
            check(failures, "$l watcher interrupted", challenge, observe(app, 2_000L, l))

            // Missing/unknown foreground evidence: an uncorroborated report can
            // neither re-admit within grace nor keep the authorization.
            fresh(); unlock(l)
            observe(launcher, 2_000L, l)
            check(failures, "$l uncorroborated return", challenge, observe(app, 2_500L, l, mayRenew = false))
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun processDeathRecoversFailClosedAndKeepsEachPersistedLevel() {
        for (l in levels) {
            val ctx = FakeContext()
            assertTrue(configure(ctx, mapOf(app to l.id, other to "standard"), session(), 1).persisted)
            fresh(); unlock(ProtectionStateStore.securityLevel(ctx, app))
            // Process death: process-local authorizations are gone; disk survives.
            ProtectionAccessState.revokeAll()
            val restarted = ctx.restarted()
            val level = ProtectionStateStore.securityLevel(restarted, app)
            assertEquals(l, level)
            assertEquals("$l first access after restart", challenge, observe(app, 1_000L, level))
            unlock(level, 2_000L)
            observe(launcher, 3_000L, level)
            val expected = if (10_000L < grace(l)) allow else challenge
            assertEquals("$l re-entry after restart", expected, observe(app, 13_000L, level))
        }
    }

    @Test
    fun unknownOrDamagedLevelStateReadsCriticalNatively() {
        val ctx = FakeContext()
        ctx.prefs.data["enabled"] = true
        ctx.prefs.data["protected_packages"] = pk
        ctx.prefs.data["security_levels_version"] = 1
        ctx.prefs.data["security_levels"] = setOf("$other=standard") // app entry missing
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.securityLevel(ctx, app))
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.securityLevel(ctx, launcher))
        unlock(ProtectionStateStore.securityLevel(ctx, app))
        observe(launcher, 2_000L, SecurityLevel.CRITICAL)
        assertEquals(challenge, observe(app, 2_001L, ProtectionStateStore.securityLevel(ctx, app)))
    }

    // -- 2. Every level transition (native configure) -----------------------------

    @Test
    fun everyTransitionUpgradesAtOnceAndNeverDowngradesWithoutAcknowledgement() {
        val failures = mutableListOf<String>()
        for (from in levels) for (to in levels) {
            if (from == to) continue
            val t = "$from->$to"
            val ctx = FakeContext()
            val s = session()
            configure(ctx, mapOf(app to from.id, other to "standard"), s, 1)
            fresh(); unlock(ProtectionStateStore.securityLevel(ctx, app))
            val ticket = ProtectionStateStore.replacePendingChallenge(ctx, other)

            val out = configure(ctx, mapOf(app to to.id, other to "standard"), s, 2)
            check(failures, "$t applied", true, out.applied)
            check(failures, "$t persisted", true, out.persisted)
            check(failures, "$t ticket kept", ticket, ProtectionStateStore.pendingChallenge(ctx))
            if (to.isStricterThan(from)) {
                check(failures, "$t upgrade effective", to, ProtectionStateStore.securityLevel(ctx, app))
                check(failures, "$t upgrade needs no ack", emptySet<String>(), out.heldDowngrades)
                check(failures, "$t weaker grant revoked", false, ProtectionAccessState.isAuthorized(app))
                check(failures, "$t upgrade durable", to, ProtectionStateStore.securityLevel(ctx.restarted(), app))
            } else {
                // Without the CR-2 acknowledgement: held at the stricter level.
                check(failures, "$t held level", from, ProtectionStateStore.securityLevel(ctx, app))
                check(failures, "$t reported held", setOf(app), out.heldDowngrades)
                check(failures, "$t grant neither revoked nor extended", true, ProtectionAccessState.isAuthorized(app))
                observe(launcher, 2_000L, ProtectionStateStore.securityLevel(ctx, app))
                val back = 2_000L + maxOf(grace(from), 1L)
                check(failures, "$t stricter grace still enforced", challenge,
                    observe(app, back, ProtectionStateStore.securityLevel(ctx, app)))
                check(failures, "$t held after restart", from, ProtectionStateStore.securityLevel(ctx.restarted(), app))

                // With the acknowledgement: applied, but it grants nothing and
                // never lengthens an authorization created at the stricter level.
                fresh(); unlock(ProtectionStateStore.securityLevel(ctx, app), at = 10_000L)
                val acked = configure(ctx, mapOf(app to to.id, other to "standard"), s, 3, setOf(app))
                check(failures, "$t acked applied", to, ProtectionStateStore.securityLevel(ctx, app))
                check(failures, "$t acked durable", to, ProtectionStateStore.securityLevel(ctx.restarted(), app))
                check(failures, "$t acked not held", emptySet<String>(), acked.heldDowngrades)
                check(failures, "$t window not extended", challenge,
                    observe(app, 10_000L + window(from), ProtectionStateStore.securityLevel(ctx, app)))
                ProtectionAccessState.revokeAll()
                configure(ctx, mapOf(app to from.id, other to "standard"), s, 4)
                configure(ctx, mapOf(app to to.id, other to "standard"), s, 5, setOf(app))
                check(failures, "$t level change never authorizes", false, ProtectionAccessState.isAuthorized(app))
                check(failures, "$t ticket still kept", ticket, ProtectionStateStore.pendingChallenge(ctx))
            }
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun reorderedOrRepeatedSnapshotsCannotWeakenOrAuthorize() {
        val ctx = FakeContext()
        val s = session()
        configure(ctx, mapOf(app to "standard", other to "standard"), s, 1)
        configure(ctx, mapOf(app to "critical", other to "sensitive"), s, 3)
        // An older, acknowledged downgrade that arrives late is rejected whole.
        val late = configure(ctx, mapOf(app to "standard", other to "standard"), s, 2, setOf(app, other))
        assertFalse(late.applied)
        assertEquals("stale", late.status)
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.securityLevel(ctx, app))
        assertEquals(SecurityLevel.SENSITIVE, ProtectionStateStore.securityLevel(ctx, other))
        // A replay of the newest revision is stale too.
        assertFalse(configure(ctx, mapOf(app to "standard", other to "standard"), s, 3, setOf(app)).applied)
        // A new Dart session (restart) without acknowledgement is held.
        val restartedSession = configure(ctx, mapOf(app to "standard", other to "standard"), session(), 1)
        assertEquals(pk, restartedSession.heldDowngrades)
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.securityLevel(ctx, app))

        // Many serialized updates (valid, invalid, legacy, stale) never authorize
        // and never clear a still-protected ticket.
        val ticket = ProtectionStateStore.replacePendingChallenge(ctx, app)
        val s2 = session()
        val sequence = listOf<ProtectionStateStore.PolicyInput>(
            ProtectionStateStore.PolicyInput(1, mapOf(app to "sensitive", other to "standard"), s2, 1, setOf(app)),
            ProtectionStateStore.PolicyInput(1, mapOf(app to "bogus", other to "standard"), s2, 2),
            ProtectionStateStore.PolicyInput(),
            ProtectionStateStore.PolicyInput(2, mapOf(app to "standard", other to "standard"), s2, 3),
            ProtectionStateStore.PolicyInput(1, mapOf(app to "standard"), s2, 4, setOf(app)),
            ProtectionStateStore.PolicyInput(1, mapOf(app to "standard", other to "standard"), s2, 4, setOf(app)),
            ProtectionStateStore.PolicyInput(1, mapOf(app to "critical", other to "critical"), s2, 6),
        )
        for (p in sequence) {
            ProtectionStateStore.configure(ctx, true, pk, p)
            assertFalse(ProtectionAccessState.isAuthorized(app))
            assertFalse(ProtectionAccessState.isAuthorized(other))
            assertEquals(ticket, ProtectionStateStore.pendingChallenge(ctx))
            assertEquals(pk, ProtectionStateStore.securityLevels(ctx).keys)
        }
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.securityLevel(ctx, app))
    }

    // -- 3. Unlock-level binding -------------------------------------------------

    @Test
    fun unlockLevelBindingUsesTheStricterOfStoreAndFloor() {
        val failures = mutableListOf<String>()
        for (store in levels) for (floor in listOf<SecurityLevel?>(null) + levels) {
            val eff = floor?.let { SecurityLevel.stricter(store, it) } ?: store
            val t = "store=$store floor=$floor"
            for (away in listOf(1_000L, 10_000L, 20_000L)) {
                fresh(); unlock(store, floor = floor)
                observe(launcher, 2_000L, store)
                check(failures, "$t return after $away", if (away < grace(eff)) allow else challenge,
                    observe(app, 2_000L + away, store))
            }
            fresh(); unlock(store, floor = floor)
            check(failures, "$t inside window", allow, observe(app, 1_000L + window(eff) - 1L, store))
            fresh(); unlock(store, floor = floor)
            check(failures, "$t window end", challenge, observe(app, 1_000L + window(eff), store))
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun unlockLevelFieldNeverAuthorizesAndMalformedIsStrict() {
        // Missing field: no floor; parsing it never creates an authorization.
        assertNull(SecurityLevelPolicy.authorizationFloor(false, null))
        assertEquals(challenge, observe(app, 1_000L, SecurityLevel.STANDARD))
        assertFalse(ProtectionAccessState.isAuthorized(app))
        // Malformed field: Critical; with a Standard store it removes all grace.
        val malformed = SecurityLevelPolicy.authorizationFloor(true, "STANDARD ")
        assertEquals(SecurityLevel.CRITICAL, malformed)
        unlock(SecurityLevel.STANDARD, floor = malformed)
        observe(launcher, 2_000L, SecurityLevel.STANDARD)
        assertEquals(challenge, observe(app, 2_001L, SecurityLevel.STANDARD))
    }

    @Test
    fun nativeAuthorizePathGatesBeforeUsingTheFloorAndClearsOnlyTheExactTicket() {
        // WatcherService is not JVM-compilable; pin the production order.
        val relative = "src/main/kotlin/com/smartapplock/app"
        val dir = listOf(java.io.File(relative), java.io.File("android/app/$relative")).first { it.isDirectory }
        val source = java.io.File(dir, "WatcherService.kt").readText()
        val start = source.indexOf("fun authorizePackage(")
        val body = source.substring(start, source.indexOf("fun revokeAllAuthorizations()", start))
        val gates = listOf(
            "if (!ProtectionStateStore.isProtected(context, packageName)) return false",
            "?: return false",
            "pending.packageName != packageName || pending.generation != generation",
            "if (!ProtectionRuntime.consumeChallengeHandoff(packageName, generation))",
        ).map { body.indexOf(it) }
        val authorize = body.indexOf("ProtectionAccessState.authorize(")
        val clear = body.indexOf("ProtectionStateStore.clearPendingChallenge(")
        assertTrue(gates.all { it in 0 until authorize })
        assertTrue(authorize < clear)
        assertEquals(2, Regex("levelFloor").findAll(body).count()) // declared once, used once
        assertTrue(body.substring(clear).contains("packageName,\n                generation,"))
    }

    // -- 4. Store integrity ------------------------------------------------------

    @Test
    fun storeIntegrityTable() {
        val c = SecurityLevel.CRITICAL
        val sens = SecurityLevel.SENSITIVE
        val std = SecurityLevel.STANDARD
        val cases = listOf<Triple<Int?, Set<String>?, Map<String, SecurityLevel>>>(
            Triple(null, null, mapOf(app to std, other to std)), // pre-M2 legacy store
            Triple(null, setOf("$app=standard"), mapOf(app to c, other to c)), // map without version
            Triple(1, setOf("$app=critical", "$other=sensitive"), mapOf(app to c, other to sens)),
            Triple(1, setOf("$app=standard"), mapOf(app to std, other to c)), // missing entry
            Triple(1, setOf("$app=ULTRA", "$other=standard"), mapOf(app to c, other to std)),
            Triple(1, setOf("garbage", "$other=standard"), mapOf(app to c, other to std)),
            Triple(1, emptySet(), mapOf(app to c, other to c)),
            Triple(1, null, mapOf(app to c, other to c)),
            Triple(2, setOf("$app=standard", "$other=standard"), mapOf(app to c, other to c)),
            Triple(-1, setOf("$app=standard", "$other=standard"), mapOf(app to c, other to c)),
        )
        for ((version, entries, expected) in cases) {
            assertEquals("v=$version entries=$entries", expected, SecurityLevelStoreCodec.decode(version, entries, pk))
        }
    }

    // -- 5. Failed persistence + process death -----------------------------------

    @Test
    fun failedUpgradeThenProcessDeathCannotGiveAFreshUnlockTheWeakerPolicy() {
        val ctx = FakeContext()
        configure(ctx, mapOf(app to "standard", other to "standard"), session(), 1)
        fresh(); unlock(SecurityLevel.STANDARD)
        ctx.prefs.failCommit = true
        val failed = configure(ctx, mapOf(app to "critical", other to "standard"), session(), 1)
        assertFalse(failed.persisted)
        assertFalse(ProtectionAccessState.isAuthorized(app)) // revoked at once
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.securityLevel(ctx, app))

        // Process death before any successful write.
        ProtectionAccessState.revokeAll()
        val restarted = ctx.restarted()
        val stored = ProtectionStateStore.securityLevel(restarted, app)
        assertEquals(SecurityLevel.STANDARD, stored) // last durable (weaker) native level
        assertEquals(challenge, observe(app, 1_000L, stored)) // nothing reusable survives

        // A fresh unlock carries the level Dart enforced (Critical): no grace,
        // 1-minute window, although the store still says Standard.
        unlock(stored, at = 2_000L, floor = SecurityLevel.CRITICAL)
        observe(launcher, 3_000L, stored)
        assertEquals(challenge, observe(app, 3_001L, stored))
        unlock(stored, at = 10_000L, floor = SecurityLevel.CRITICAL)
        assertEquals(challenge, observe(app, 70_000L, stored))

        // Documented dependency: only an unlock WITHOUT the level field (not
        // sent by this build, see host_auth_binding_test) would see Standard.
        unlock(stored, at = 100_000L)
        observe(launcher, 101_000L, stored)
        assertEquals(allow, observe(app, 102_000L, stored))

        // The next Dart sync makes the upgrade durable.
        restarted.prefs.failCommit = false
        assertTrue(configure(restarted, mapOf(app to "critical", other to "standard"), session(), 1).persisted)
        assertFalse(ProtectionAccessState.isAuthorized(app))
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.securityLevel(restarted.restarted(), app))
    }

    // -- fakes -----------------------------------------------------------------

    private var counter = 0
    private fun session() = "m3-${System.nanoTime()}-${counter++}"

    private fun configure(
        ctx: FakeContext,
        levelIds: Map<String, String>,
        session: String,
        revision: Long,
        acks: Set<String> = emptySet(),
    ) = ProtectionStateStore.configure(
        ctx, true, pk, ProtectionStateStore.PolicyInput(1, levelIds, session, revision, acks),
    )

    /** AOSP SharedPreferencesImpl semantics: memory first, never rolled back. */
    private class FakePrefs : SharedPreferences {
        val data = mutableMapOf<String, Any>()
        val disk = mutableMapOf<String, Any>()
        var failCommit = false
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
            prefs.data.clear()
            return this
        }
        override fun apply() {
            commit()
        }
        override fun commit(): Boolean {
            removes.forEach { prefs.data.remove(it) }
            prefs.data.putAll(puts)
            if (prefs.failCommit) return false
            prefs.disk.clear()
            prefs.disk.putAll(prefs.data)
            return true
        }
    }

    private class FakeContext(val prefs: FakePrefs = FakePrefs()) : Context() {
        override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences = prefs
        fun restarted(): FakeContext = FakeContext(FakePrefs().also { it.data.putAll(prefs.disk) })
    }
}
