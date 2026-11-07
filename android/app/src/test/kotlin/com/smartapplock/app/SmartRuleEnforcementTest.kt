package com.smartapplock.app

import android.content.Context
import android.content.SharedPreferences
import java.util.Calendar
import java.util.TimeZone
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Phase 10 / M2: native raise-only Smart Rule enforcement. Production
 * [SmartRulePolicy], transport, codec, resolver, [ProtectionStateStore]
 * (configure + effectiveLevel over an in-memory SharedPreferences with AOSP
 * failed-commit semantics) and [ProtectionAccessState] grant-level
 * revocation. JVM, SIMULATED Android inputs; not device evidence.
 */
class SmartRuleEnforcementTest {
    private val bank = "com.example.bank"
    private val notes = "com.example.notes"
    private val launcher = "com.example.launcher"
    private val pk = setOf(bank, notes)
    private lateinit var savedZone: TimeZone

    @Before
    fun reset() {
        savedZone = TimeZone.getDefault()
        TimeZone.setDefault(TimeZone.getTimeZone("UTC"))
        ProtectionAccessState.revokeAll()
        ProtectionRuntime.invalidateChallengeHandoff()
        ProtectionAccessState.setGracePeriod(0L)
        ProtectionAccessState.observeForeground(launcher, false, 0L)
    }

    @After
    fun restoreZone() {
        TimeZone.setDefault(savedZone)
    }

    private fun window(level: SecurityLevel, days: Set<Int>, start: Int, end: Int, vararg targets: String) =
        SmartRuleSpec(level, days, false, start, end, targets.toSet())

    private fun allDay(level: SecurityLevel, days: Set<Int>, vararg targets: String) =
        SmartRuleSpec(level, days, true, 0, 0, targets.toSet())

    private fun spec(level: String, days: List<Int>, start: Int, end: Int, targets: List<String>, allDay: Boolean = false) =
        mapOf("level" to level, "days" to days, "allDay" to allDay, "start" to start, "end" to end, "targets" to targets)

    /** Wall-clock millis of a local date/time in the CURRENT default zone. */
    private fun wall(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int = 0): Long =
        Calendar.getInstance().apply {
            clear()
            set(year, month - 1, day, hour, minute, second)
        }.timeInMillis

    // 2026-11-02 is a Monday.
    private fun mon(h: Int, m: Int = 0, s: Int = 0) = wall(2026, 11, 2, h, m, s)
    private fun tue(h: Int, m: Int = 0) = wall(2026, 11, 3, h, m)
    private fun sun(h: Int, m: Int = 0) = wall(2026, 11, 8, h, m)
    private fun nextMon(h: Int, m: Int = 0) = wall(2026, 11, 9, h, m)

    // -- semantics (mirror of Dart M1) ------------------------------------------

    @Test
    fun sameDayWindowIsStartInclusiveEndExclusive() {
        val r = window(SecurityLevel.CRITICAL, setOf(1), 540, 1020, bank)
        assertFalse(r.matches(bank, 1, 539))
        assertTrue(r.matches(bank, 1, 540))
        assertTrue(r.matches(bank, 1, 1019))
        assertFalse(r.matches(bank, 1, 1020))
        assertFalse(r.matches(bank, 2, 600)) // Tuesday not selected
    }

    @Test
    fun overnightWindowBelongsToItsStartDay() {
        val r = window(SecurityLevel.CRITICAL, setOf(1), 1320, 360, bank) // Mon 22:00–06:00
        assertTrue(r.matches(bank, 1, 23 * 60)) // Mon 23:00
        assertTrue(r.matches(bank, 2, 2 * 60)) // Tue 02:00 (owner Monday)
        assertFalse(r.matches(bank, 2, 6 * 60)) // Tue 06:00 end exclusive
        assertFalse(r.matches(bank, 2, 23 * 60)) // Tue 23:00, Tuesday not selected
        assertFalse(r.matches(bank, 1, 2 * 60)) // Mon 02:00 belongs to Sunday
    }

    @Test
    fun sundayToMondayRollover() {
        val r = window(SecurityLevel.SENSITIVE, setOf(7), 1320, 360, bank)
        assertTrue(r.matches(bank, 7, 23 * 60))
        assertTrue(r.matches(bank, 1, 60)) // Monday 01:00, owner Sunday
        assertFalse(r.matches(bank, 1, 23 * 60))
    }

    @Test
    fun calendarWeekdayMapsToIso() {
        assertEquals(1, SmartRulePolicy.isoDayFromCalendar(Calendar.MONDAY))
        assertEquals(2, SmartRulePolicy.isoDayFromCalendar(Calendar.TUESDAY))
        assertEquals(6, SmartRulePolicy.isoDayFromCalendar(Calendar.SATURDAY))
        assertEquals(7, SmartRulePolicy.isoDayFromCalendar(Calendar.SUNDAY))
    }

    @Test
    fun packageMatchIsExact() {
        val r = allDay(SecurityLevel.CRITICAL, (1..7).toSet(), bank)
        assertTrue(r.matches(bank, 3, 0))
        for (p in listOf("com.example.ban", "com.example.bank2", "COM.EXAMPLE.BANK", " com.example.bank", "com.example")) {
            assertFalse(p, r.matches(p, 3, 0))
        }
    }

    @Test
    fun effectiveLevelIsNeverBelowTheBaseline() {
        for (baseline in SecurityLevel.values()) {
            for (rule in listOf<SecurityLevel?>(null) + SecurityLevel.values()) {
                val e = SmartRulePolicy.effectiveLevel(baseline, rule)
                assertFalse("$baseline/$rule", baseline.isStricterThan(e))
            }
        }
        assertEquals(SecurityLevel.CRITICAL, SmartRulePolicy.effectiveLevel(SecurityLevel.STANDARD, SecurityLevel.CRITICAL))
        assertEquals(SecurityLevel.SENSITIVE, SmartRulePolicy.effectiveLevel(SecurityLevel.SENSITIVE, SecurityLevel.STANDARD))
        assertEquals(SecurityLevel.CRITICAL, SmartRulePolicy.effectiveLevel(SecurityLevel.CRITICAL, null))
    }

    @Test
    fun severalMatchingRulesGiveTheStrictest() {
        val rules = listOf(
            allDay(SecurityLevel.SENSITIVE, setOf(1), bank),
            window(SecurityLevel.CRITICAL, setOf(1), 540, 600, bank),
        )
        assertEquals(SecurityLevel.CRITICAL, SmartRulePolicy.ruleLevel(rules, bank, 1, 550))
        assertEquals(SecurityLevel.SENSITIVE, SmartRulePolicy.ruleLevel(rules, bank, 1, 700))
        assertNull(SmartRulePolicy.ruleLevel(rules, bank, 2, 550))
        assertNull(SmartRulePolicy.ruleLevel(rules, notes, 1, 550))
    }

    // -- relaxation detection ---------------------------------------------------

    @Test
    fun relaxationDetection() {
        val base = setOf(window(SecurityLevel.CRITICAL, setOf(1, 2), 1320, 360, bank))
        assertFalse(SmartRulePolicy.relaxes(base, base))
        assertFalse(SmartRulePolicy.relaxes(emptySet(), base)) // adding
        assertTrue(SmartRulePolicy.relaxes(base, emptySet())) // removing
        assertTrue(SmartRulePolicy.relaxes(base, setOf(window(SecurityLevel.CRITICAL, setOf(1), 1320, 360, bank)))) // fewer days
        assertTrue(SmartRulePolicy.relaxes(base, setOf(window(SecurityLevel.CRITICAL, setOf(1, 2), 1320, 300, bank)))) // shorter
        assertTrue(SmartRulePolicy.relaxes(base, setOf(window(SecurityLevel.SENSITIVE, setOf(1, 2), 1320, 360, bank)))) // lower
        assertTrue(SmartRulePolicy.relaxes(base, setOf(window(SecurityLevel.CRITICAL, setOf(1, 2), 1320, 360, notes)))) // other app
        assertFalse(SmartRulePolicy.relaxes(base, setOf(allDay(SecurityLevel.CRITICAL, (1..7).toSet(), bank, notes)))) // wider
        assertFalse(SmartRulePolicy.relaxes(base, base + window(SecurityLevel.SENSITIVE, setOf(3), 0, 60, notes)))
    }

    // -- transport --------------------------------------------------------------

    @Test
    fun transportAcceptsOnlyWellFormedRaisingRules() {
        val ok = SmartRuleTransport.parse(1, listOf(spec("critical", listOf(1, 2), 540, 1020, listOf(bank))))
        assertEquals(setOf(window(SecurityLevel.CRITICAL, setOf(1, 2), 540, 1020, bank)), ok)
        assertEquals(emptySet<SmartRuleSpec>(), SmartRuleTransport.parse(1, emptyList<Any>()))
        val bad = listOf(
            listOf(spec("standard", listOf(1), 0, 60, listOf(bank))),
            listOf(spec("unlocked", listOf(1), 0, 60, listOf(bank))),
            listOf(spec("Critical", listOf(1), 0, 60, listOf(bank))),
            listOf(spec("critical", emptyList(), 0, 60, listOf(bank))),
            listOf(spec("critical", listOf(8), 0, 60, listOf(bank))),
            listOf(spec("critical", listOf(0), 0, 60, listOf(bank))),
            listOf(spec("critical", listOf(1), 60, 60, listOf(bank))),
            listOf(spec("critical", listOf(1), 0, 1440, listOf(bank))),
            listOf(spec("critical", listOf(1), -1, 60, listOf(bank))),
            listOf(spec("critical", listOf(1), 0, 60, emptyList())),
            listOf(spec("critical", listOf(1), 0, 60, listOf("android"))),
            listOf(spec("critical", listOf(1), 0, 60, listOf("com.a|b"))),
            listOf(mapOf("level" to "critical", "days" to listOf(1.0), "allDay" to false, "start" to 0, "end" to 60, "targets" to listOf(bank))),
            listOf("not a map"),
        )
        for (b in bad) assertNull(b.toString(), SmartRuleTransport.parse(1, b))
        assertNull(SmartRuleTransport.parse(2, emptyList<Any>()))
        assertNull(SmartRuleTransport.parse(null, emptyList<Any>()))
        assertNull(SmartRuleTransport.parse(1, "x"))
    }

    // -- resolver and codec -----------------------------------------------------

    @Test
    fun resolverKeepsHoldsOrApplies() {
        val prev = setOf(allDay(SecurityLevel.CRITICAL, setOf(1), bank))
        val r = SmartRuleSnapshotResolver
        assertEquals(SmartRuleSnapshotResolver.Resolution(SmartRuleSnapshotResolver.Status.KEPT, null), r.resolve(false, null, null, prev, false, false))
        assertEquals(SmartRuleSnapshotResolver.Resolution(SmartRuleSnapshotResolver.Status.INVALID, null), r.resolve(true, 1, "x", prev, false, true))
        val removed = r.resolve(true, 1, emptyList<Any>(), prev, false, false)
        assertEquals(SmartRuleSnapshotResolver.Status.HELD, removed.status)
        assertEquals(prev, removed.rules)
        assertEquals(SmartRuleSnapshotResolver.Resolution(SmartRuleSnapshotResolver.Status.APPLIED, emptySet()), r.resolve(true, 1, emptyList<Any>(), prev, false, true))
        val added = r.resolve(true, 1, listOf(spec("sensitive", listOf(2), 0, 60, listOf(notes))) + listOf(spec("critical", listOf(1), 0, 0, listOf(bank), allDay = true)), prev, false, false)
        assertEquals(SmartRuleSnapshotResolver.Status.APPLIED, added.status)
        assertEquals(SmartRuleSnapshotResolver.Resolution(SmartRuleSnapshotResolver.Status.HELD, null), r.resolve(true, 1, emptyList<Any>(), emptySet(), true, false))
        assertEquals(SmartRuleSnapshotResolver.Status.APPLIED, r.resolve(true, 1, emptyList<Any>(), emptySet(), true, true).status)
    }

    @Test
    fun codecRoundTripAndDamage() {
        val rules = setOf(
            window(SecurityLevel.CRITICAL, setOf(1, 5), 1320, 360, bank, notes),
            allDay(SecurityLevel.SENSITIVE, setOf(6, 7), notes),
        )
        assertEquals(SmartRuleStoreCodec.Decoded(rules, false), SmartRuleStoreCodec.decode(1, SmartRuleStoreCodec.encode(rules)))
        assertEquals(SmartRuleStoreCodec.Decoded(emptySet(), false), SmartRuleStoreCodec.decode(null, null))
        assertTrue(SmartRuleStoreCodec.decode(null, setOf("critical|1|all|com.a.b")).damaged)
        assertTrue(SmartRuleStoreCodec.decode(2, setOf("critical|1|all|com.a.b")).damaged)
        assertTrue(SmartRuleStoreCodec.decode(1, null).damaged)
        for (bad in listOf("critical|1|all", "unlocked|1|all|com.a.b", "critical|9|all|com.a.b", "critical|1|60-60|com.a.b", "critical|1|0-1440|com.a.b", "critical||all|com.a.b", "critical|1|all|bad")) {
            assertTrue(bad, SmartRuleStoreCodec.decode(1, setOf(bad)).damaged)
        }
    }

    // -- ProtectionStateStore ---------------------------------------------------

    private var counter = 0
    private fun session() = "rules-${System.nanoTime()}-${counter++}"

    private fun input(levels: Map<String, String>, rules: List<Map<String, Any>>?, authorized: Boolean = false, s: String = session(), rev: Long = 1) =
        ProtectionStateStore.PolicyInput(
            version = 1,
            rawLevels = levels,
            session = s,
            revision = rev,
            rulesPresent = rules != null,
            rulesVersion = if (rules != null) 1 else null,
            rawRules = rules,
            authorizedRuleRelaxation = authorized,
        )

    private val standardLevels = mapOf(bank to "standard", notes to "standard")
    private val workCritical = listOf(spec("critical", listOf(1, 2, 3, 4, 5), 540, 1020, listOf(bank)))

    @Test
    fun persistedRuleRaisesOnlyInsideItsWindowAndNeverBelowBaseline() {
        val ctx = FakeContext()
        val out = ProtectionStateStore.configure(ctx, true, pk, input(mapOf(bank to "standard", notes to "critical"), workCritical))
        assertTrue(out.persisted)
        assertEquals("applied", out.ruleStatus)
        assertEquals(SecurityLevel.STANDARD, ProtectionStateStore.effectiveLevel(ctx, bank, mon(8, 59)))
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.effectiveLevel(ctx, bank, mon(9, 0)))
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.effectiveLevel(ctx, bank, mon(16, 59, 59)))
        assertEquals(SecurityLevel.STANDARD, ProtectionStateStore.effectiveLevel(ctx, bank, mon(17, 0)))
        assertEquals(SecurityLevel.STANDARD, ProtectionStateStore.effectiveLevel(ctx, bank, sun(10)))
        // The saved level itself is never rewritten by a rule.
        assertEquals(SecurityLevel.STANDARD, ProtectionStateStore.securityLevel(ctx, bank))
        // A baseline-Critical app stays Critical at every hour.
        for (h in 0..23) assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.effectiveLevel(ctx, notes, mon(h)))
        // Restart: the durable copy enforces the same.
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.effectiveLevel(ctx.restarted(), bank, tue(10)))
    }

    @Test
    fun overnightRuleAcrossTheStoreAndWeekBoundary() {
        val ctx = FakeContext()
        ProtectionStateStore.configure(ctx, true, pk, input(standardLevels, listOf(spec("sensitive", listOf(7), 1320, 360, listOf(notes)))))
        assertEquals(SecurityLevel.SENSITIVE, ProtectionStateStore.effectiveLevel(ctx, notes, sun(23)))
        assertEquals(SecurityLevel.SENSITIVE, ProtectionStateStore.effectiveLevel(ctx, notes, nextMon(5, 59)))
        assertEquals(SecurityLevel.STANDARD, ProtectionStateStore.effectiveLevel(ctx, notes, nextMon(6, 0)))
        assertEquals(SecurityLevel.SENSITIVE, ProtectionStateStore.effectiveLevel(ctx, notes, mon(2))) // owner: Sunday 1 Nov
        assertEquals(SecurityLevel.STANDARD, ProtectionStateStore.effectiveLevel(ctx, notes, tue(2))) // owner Monday: not selected
    }

    @Test
    fun unauthorizedRemovalIsHeldAndAuthorizedRemovalApplies() {
        val ctx = FakeContext()
        val s = session()
        ProtectionStateStore.configure(ctx, true, pk, input(standardLevels, workCritical, s = s, rev = 1))
        val held = ProtectionStateStore.configure(ctx, true, pk, input(standardLevels, emptyList(), s = s, rev = 2))
        assertEquals("held", held.ruleStatus)
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.effectiveLevel(ctx, bank, mon(10)))
        val ok = ProtectionStateStore.configure(ctx, true, pk, input(standardLevels, emptyList(), authorized = true, s = s, rev = 3))
        assertEquals("applied", ok.ruleStatus)
        assertEquals(SecurityLevel.STANDARD, ProtectionStateStore.effectiveLevel(ctx, bank, mon(10)))
    }

    @Test
    fun omittedOrMalformedRulesKeepThePersistedRules() {
        val ctx = FakeContext()
        val s = session()
        ProtectionStateStore.configure(ctx, true, pk, input(standardLevels, workCritical, s = s, rev = 1))
        val kept = ProtectionStateStore.configure(ctx, true, pk, input(standardLevels, null, s = s, rev = 2))
        assertEquals("kept", kept.ruleStatus)
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.effectiveLevel(ctx, bank, mon(10)))
        val bad = ProtectionStateStore.configure(ctx, true, pk, input(standardLevels, listOf(spec("unlocked", listOf(1), 0, 60, listOf(bank))), authorized = true, s = s, rev = 3))
        assertEquals("invalid", bad.ruleStatus)
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.effectiveLevel(ctx, bank, mon(10)))
    }

    @Test
    fun failedCommitNeverWeakensAndReportsNotPersisted() {
        val ctx = FakeContext()
        val s = session()
        ProtectionStateStore.configure(ctx, true, pk, input(standardLevels, workCritical, s = s, rev = 1))
        ctx.prefs.failCommit = true
        // An authorized removal whose write fails keeps the confirmed rule.
        val failed = ProtectionStateStore.configure(ctx, true, pk, input(standardLevels, emptyList(), authorized = true, s = s, rev = 2))
        assertFalse(failed.persisted)
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.effectiveLevel(ctx, bank, mon(10)))
        // A failed new raise still applies in this process (fail closed)...
        val raise = ProtectionStateStore.configure(ctx, true, pk, input(standardLevels, workCritical + spec("sensitive", listOf(1), 0, 0, listOf(notes), allDay = true), s = s, rev = 3))
        assertFalse(raise.persisted)
        assertEquals(SecurityLevel.SENSITIVE, ProtectionStateStore.effectiveLevel(ctx, notes, mon(10)))
        // ...and after process death only the durable rules apply.
        val restarted = ctx.restarted()
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.effectiveLevel(restarted, bank, mon(10)))
        assertEquals(SecurityLevel.STANDARD, ProtectionStateStore.effectiveLevel(restarted, notes, mon(10)))
    }

    @Test
    fun damagedRuleStoreEnforcesCritical() {
        val ctx = FakeContext()
        ProtectionStateStore.configure(ctx, true, pk, input(standardLevels, workCritical))
        ctx.prefs.data["smart_rules"] = setOf("garbage")
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.effectiveLevel(ctx, notes, sun(3)))
        val held = ProtectionStateStore.configure(ctx, true, pk, input(standardLevels, emptyList()))
        assertEquals("held", held.ruleStatus)
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.effectiveLevel(ctx, notes, sun(3)))
        val repaired = ProtectionStateStore.configure(ctx, true, pk, input(standardLevels, emptyList(), authorized = true))
        assertEquals("applied", repaired.ruleStatus)
        assertEquals(SecurityLevel.STANDARD, ProtectionStateStore.effectiveLevel(ctx, notes, sun(3)))
    }

    @Test
    fun legacyStoreWithoutRulesKeepsBaselineBehaviour() {
        val ctx = FakeContext()
        ProtectionStateStore.configure(ctx, true, pk, ProtectionStateStore.PolicyInput(1, mapOf(bank to "sensitive", notes to "standard"), session(), 1))
        assertEquals(SecurityLevel.SENSITIVE, ProtectionStateStore.effectiveLevel(ctx, bank, mon(10)))
        assertEquals(SecurityLevel.STANDARD, ProtectionStateStore.effectiveLevel(ctx, notes, mon(10)))
    }

    // -- clock and time zone ----------------------------------------------------

    @Test
    fun clockMovesOnlySwitchExtraStrictnessNeverTheBaseline() {
        val ctx = FakeContext()
        ProtectionStateStore.configure(ctx, true, pk, input(mapOf(bank to "sensitive", notes to "standard"), workCritical))
        // Sweep a whole week in 7-minute steps (forward), then backward.
        val start = mon(0)
        val steps = (0 until 7 * 24 * 60 / 7).map { start + it * 7L * 60_000L }
        for (t in steps + steps.reversed()) {
            val e = ProtectionStateStore.effectiveLevel(ctx, bank, t)
            assertFalse(SecurityLevel.SENSITIVE.isStricterThan(e))
        }
    }

    @Test
    fun timeZoneChangeIsReadAtEachDecision() {
        val ctx = FakeContext()
        ProtectionStateStore.configure(ctx, true, pk, input(standardLevels, workCritical))
        val instant = mon(8, 30) // 08:30 UTC Monday
        assertEquals(SecurityLevel.STANDARD, ProtectionStateStore.effectiveLevel(ctx, bank, instant))
        TimeZone.setDefault(TimeZone.getTimeZone("Asia/Karachi")) // 13:30 local
        assertEquals(SecurityLevel.CRITICAL, ProtectionStateStore.effectiveLevel(ctx, bank, instant))
        TimeZone.setDefault(TimeZone.getTimeZone("America/Los_Angeles")) // Mon 00:30 local
        assertEquals(SecurityLevel.STANDARD, ProtectionStateStore.effectiveLevel(ctx, bank, instant))
    }

    @Test
    fun dstSkippedAndRepeatedLocalTimes() {
        TimeZone.setDefault(TimeZone.getTimeZone("America/New_York"))
        val ctx = FakeContext()
        // Sunday 02:00–03:00 does not exist on 2026-03-08; 01:00–02:00 happens twice on 2026-11-01.
        ProtectionStateStore.configure(
            ctx, true, pk,
            input(standardLevels, listOf(
                spec("critical", listOf(7), 120, 180, listOf(bank)),
                spec("sensitive", listOf(7), 60, 120, listOf(notes)),
            )),
        )
        val utc = { y: Int, mo: Int, d: Int, h: Int, mi: Int ->
            Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply { clear(); set(y, mo - 1, d, h, mi) }.timeInMillis
        }
        // Spring forward: 06:59Z = 01:59 EST, 07:00Z = 03:00 EDT. The skipped hour never matches.
        assertEquals(SecurityLevel.STANDARD, ProtectionStateStore.effectiveLevel(ctx, bank, utc(2026, 3, 8, 6, 59)))
        assertEquals(SecurityLevel.STANDARD, ProtectionStateStore.effectiveLevel(ctx, bank, utc(2026, 3, 8, 7, 0)))
        // Fall back: 05:30Z = 01:30 EDT and 06:30Z = 01:30 EST both match by wall clock.
        assertEquals(SecurityLevel.SENSITIVE, ProtectionStateStore.effectiveLevel(ctx, notes, utc(2026, 11, 1, 5, 30)))
        assertEquals(SecurityLevel.SENSITIVE, ProtectionStateStore.effectiveLevel(ctx, notes, utc(2026, 11, 1, 6, 30)))
        assertEquals(SecurityLevel.STANDARD, ProtectionStateStore.effectiveLevel(ctx, notes, utc(2026, 11, 1, 7, 0)))
    }

    // -- ProtectionAccessState: grant level --------------------------------------

    private val allow = ProtectionAccessState.Decision.ALLOW
    private val challenge = ProtectionAccessState.Decision.CHALLENGE

    @Test
    fun ruleStartRevokesALowerGrantAtTheNextDecision() {
        var level = SecurityLevel.STANDARD
        val levelOf: (String) -> SecurityLevel = { level }
        ProtectionAccessState.authorize(bank, 120_000L, 1_000L, SecurityLevel.STANDARD)
        assertEquals(allow, ProtectionAccessState.observeForeground(bank, true, 2_000L, true, levelOf))
        level = SecurityLevel.CRITICAL // a Critical rule started
        assertEquals(challenge, ProtectionAccessState.observeForeground(bank, true, 3_000L, true, levelOf))
        assertFalse(ProtectionAccessState.isAuthorized(bank))
        // Still challenged: no session was revived.
        assertEquals(challenge, ProtectionAccessState.observeForeground(bank, true, 4_000L, true, levelOf))
    }

    @Test
    fun ruleEndCreatesNoAuthorizationAndNoGrace() {
        ProtectionAccessState.setGracePeriod(30_000L)
        var level = SecurityLevel.CRITICAL
        val levelOf: (String) -> SecurityLevel = { level }
        // Unauthorized app: the rule ending never allows it.
        assertEquals(challenge, ProtectionAccessState.observeForeground(bank, true, 1_000L, true, levelOf))
        level = SecurityLevel.STANDARD
        assertEquals(challenge, ProtectionAccessState.observeForeground(bank, true, 2_000L, true, levelOf))
        // A grant made under Critical keeps its Critical floor: leaving removes it.
        level = SecurityLevel.CRITICAL
        ProtectionAccessState.authorize(bank, 120_000L, 3_000L, SecurityLevel.CRITICAL, SecurityLevel.CRITICAL)
        level = SecurityLevel.STANDARD
        assertEquals(allow, ProtectionAccessState.observeForeground(bank, true, 4_000L, true, levelOf))
        assertEquals(allow, ProtectionAccessState.observeForeground(launcher, false, 5_000L, true, levelOf))
        assertFalse(ProtectionAccessState.isAuthorized(bank))
        assertEquals(challenge, ProtectionAccessState.observeForeground(bank, true, 6_000L, true, levelOf))
    }

    @Test
    fun sameLevelKeepsTheH2SlideUnchanged() {
        val levelOf: (String) -> SecurityLevel = { SecurityLevel.SENSITIVE }
        ProtectionAccessState.authorize(bank, 60_000L, 0L, SecurityLevel.SENSITIVE)
        assertEquals(allow, ProtectionAccessState.observeForeground(bank, true, 50_000L, true, levelOf))
        assertEquals(allow, ProtectionAccessState.observeForeground(bank, true, 100_000L, true, levelOf))
        assertEquals(challenge, ProtectionAccessState.observeForeground(bank, true, 200_000L, true, levelOf))
    }

    // -- in-memory SharedPreferences (AOSP failed-commit semantics) ---------------

    private class FakePrefs : SharedPreferences {
        val data = mutableMapOf<String, Any>()
        var failCommit = false
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
        fun restarted(): FakeContext = FakeContext(FakePrefs().also { it.data.putAll(prefs.disk) })
        override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences = prefs
    }
}
