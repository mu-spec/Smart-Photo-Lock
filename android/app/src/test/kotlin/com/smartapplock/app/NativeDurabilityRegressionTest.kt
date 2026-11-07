package com.smartapplock.app

import android.content.Context
import android.content.SharedPreferences
import java.util.Calendar
import java.util.TimeZone
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Native rule-persistence durability regression (Phase 10 / M2 gate, kept
 * in the repository as permanent evidence by Phase 10 / M3). JVM,
 * SIMULATED storage faults. Drives the PRODUCTION
 * ProtectionStateStore.configure / effectiveLevel through a scripted
 * SharedPreferences:
 *  - OK: memory + disk updated, true;
 *  - FAIL_BEFORE_DISK: memory updated (AOSP commitToMemory), disk unchanged,
 *    false (AOSP: backup rename / write error with cleanup);
 *  - FAIL_AFTER_DISK: memory + disk updated, false (a write that landed but
 *    is reported as failed: non-AOSP partial write, or a concurrent writer
 *    flushing the in-memory map before the failure was observed).
 * A restart loads ONLY the disk copy.
 *
 * Old rule R_old: bank Critical Mon–Fri 09:00–17:00 (baseline Standard).
 * Relaxation: the rule removed (empty set). Probe: bank at Mon 10:00.
 *
 * The `*_records*` / `*withoutOptionA*` / `*withoutRA*` cases document the
 * native-only residual (native alone relies on Dart's Option A restore and
 * R-A floor); they assert today's behaviour and must be revisited if R-B is
 * ever approved. They are not failures.
 */
class NativeDurabilityRegressionTest {
    private val bank = "com.example.bank"
    private val notes = "com.example.notes"
    private val pk = setOf(bank, notes)
    private val levels = mapOf(bank to "standard", notes to "standard")
    private val old = listOf(rule("critical", bank))
    private val raise = old + rule("sensitive", notes)
    private val relaxed = emptyList<Map<String, Any>>()
    private lateinit var savedZone: TimeZone
    private var counter = 0

    enum class Mode { OK, FAIL_BEFORE_DISK, FAIL_AFTER_DISK }

    @Before
    fun setUp() {
        savedZone = TimeZone.getDefault()
        TimeZone.setDefault(TimeZone.getTimeZone("UTC"))
        ProtectionAccessState.revokeAll()
        ProtectionRuntime.invalidateChallengeHandoff()
    }

    @After
    fun tearDown() = TimeZone.setDefault(savedZone)

    private fun rule(level: String, target: String) = mapOf(
        "level" to level, "days" to listOf(1, 2, 3, 4, 5), "allDay" to false,
        "start" to 540, "end" to 1020, "targets" to listOf(target),
    )

    private val mon10 = Calendar.getInstance().apply { clear(); set(2026, 10, 2, 10, 0) }.timeInMillis

    private fun input(rules: List<Map<String, Any>>, authorized: Boolean, s: String, rev: Long) =
        ProtectionStateStore.PolicyInput(
            version = 1, rawLevels = levels, session = s, revision = rev,
            rulesPresent = true, rulesVersion = 1, rawRules = rules,
            authorizedRuleRelaxation = authorized,
        )

    private class Setup(val ctx: Ctx, val s: String)

    /** R_old confirmed and durable. */
    private fun confirmedOld(): Setup {
        val ctx = Ctx()
        val s = "gate-${System.nanoTime()}-${counter++}"
        val out = ProtectionStateStore.configure(ctx, true, pk, input(old, false, s, 1))
        assertTrue(out.persisted)
        assertEquals("applied", out.ruleStatus)
        assertEquals(SecurityLevel.CRITICAL, level(ctx, bank))
        assertEquals(SecurityLevel.CRITICAL, level(ctx.restarted(), bank))
        return Setup(ctx, s)
    }

    private fun level(ctx: Context, pkg: String) = ProtectionStateStore.effectiveLevel(ctx, pkg, mon10)

    /** Dart's normal sync after a restart: its document (relaxed set), NO CR-2 flag. */
    private fun dartResyncAfterRestart(restarted: Ctx): ProtectionStateStore.ConfigureOutcome =
        ProtectionStateStore.configure(restarted, true, pk, input(relaxed, false, "dart-after-restart-${counter++}", 1))

    // 1. success -------------------------------------------------------------

    @Test
    fun s1_authorizedRelaxationPersisted_isDurableAndAcked() {
        val g = confirmedOld()
        val out = ProtectionStateStore.configure(g.ctx, true, pk, input(relaxed, true, g.s, 2))
        assertTrue(out.persisted)
        assertEquals("applied", out.ruleStatus)
        assertEquals(SecurityLevel.STANDARD, level(g.ctx, bank))
        assertEquals(SecurityLevel.STANDARD, level(g.ctx.restarted(), bank))
    }

    @Test
    fun s1_unauthorizedRelaxationPersisted_isHeldDurably() {
        val g = confirmedOld()
        val out = ProtectionStateStore.configure(g.ctx, true, pk, input(relaxed, false, g.s, 2))
        assertTrue(out.persisted)
        assertEquals("held", out.ruleStatus)
        assertEquals(SecurityLevel.CRITICAL, level(g.ctx, bank))
        assertEquals(SecurityLevel.CRITICAL, level(g.ctx.restarted(), bank))
    }

    // 2./4. write fails before persistence; rollback succeeds -------------------

    @Test
    fun s2_authorizedRelaxationFailsBeforeDisk_rollbackOk_neverWeakerAfterRestart() {
        val g = confirmedOld()
        g.ctx.prefs.plan(Mode.FAIL_BEFORE_DISK, Mode.OK)
        val out = ProtectionStateStore.configure(g.ctx, true, pk, input(relaxed, true, g.s, 2))
        assertFalse(out.persisted) // Dart: Result.failure → "Saved, but … not confirmed"
        assertEquals(SecurityLevel.CRITICAL, level(g.ctx, bank))
        val restarted = g.ctx.restarted()
        assertEquals(SecurityLevel.CRITICAL, level(restarted, bank))
        val resync = dartResyncAfterRestart(restarted)
        assertEquals("held", resync.ruleStatus) // needs a new CR-2 confirmation
        assertEquals(SecurityLevel.CRITICAL, level(restarted, bank))
    }

    @Test
    fun s2_failedRaise_neverWeakerInMemoryOrAfterRestart() {
        val g = confirmedOld()
        g.ctx.prefs.plan(Mode.FAIL_BEFORE_DISK, Mode.OK)
        val out = ProtectionStateStore.configure(g.ctx, true, pk, input(raise, false, g.s, 2))
        assertFalse(out.persisted)
        assertEquals(SecurityLevel.SENSITIVE, level(g.ctx, notes))
        assertEquals(SecurityLevel.CRITICAL, level(g.ctx.restarted(), bank))
    }

    // 3./4. write lands but reports failure; rollback succeeds ------------------

    @Test
    fun s3_authorizedRelaxationLandsButReportsFailure_rollbackOk_neverWeakerAfterRestart() {
        val g = confirmedOld()
        g.ctx.prefs.plan(Mode.FAIL_AFTER_DISK, Mode.OK)
        val out = ProtectionStateStore.configure(g.ctx, true, pk, input(relaxed, true, g.s, 2))
        assertFalse(out.persisted)
        assertEquals(SecurityLevel.CRITICAL, level(g.ctx, bank))
        val restarted = g.ctx.restarted()
        assertEquals(SecurityLevel.CRITICAL, level(restarted, bank))
        assertEquals("held", dartResyncAfterRestart(restarted).ruleStatus)
    }

    // 5. relaxation fails and rollback also fails --------------------------------

    @Test
    fun s5a_authorizedRelaxationFailsBeforeDisk_rollbackFails_neverWeakerAfterRestart() {
        val g = confirmedOld()
        g.ctx.prefs.plan(Mode.FAIL_BEFORE_DISK, Mode.FAIL_BEFORE_DISK)
        val out = ProtectionStateStore.configure(g.ctx, true, pk, input(relaxed, true, g.s, 2))
        assertFalse(out.persisted)
        assertEquals(SecurityLevel.CRITICAL, level(g.ctx, bank)) // memory = union
        val restarted = g.ctx.restarted()
        assertEquals(SecurityLevel.CRITICAL, level(restarted, bank)) // disk = R_old
        assertEquals("held", dartResyncAfterRestart(restarted).ruleStatus)
    }

    @Test
    fun s5_unauthorizedRelaxation_everyFailureCombination_neverWeaker() {
        for (first in Mode.values()) for (second in Mode.values()) {
            val g = confirmedOld()
            g.ctx.prefs.plan(first, second)
            val out = ProtectionStateStore.configure(g.ctx, true, pk, input(relaxed, false, g.s, 2))
            assertEquals("$first/$second", "held", out.ruleStatus)
            assertEquals("$first/$second memory", SecurityLevel.CRITICAL, level(g.ctx, bank))
            assertEquals("$first/$second restart", SecurityLevel.CRITICAL, level(g.ctx.restarted(), bank))
        }
    }

    @Test
    fun s5_inMemoryIsNeverWeakerThanDisk_everyCombination() {
        for (authorized in listOf(false, true)) for (first in Mode.values()) for (second in Mode.values()) {
            val g = confirmedOld()
            g.ctx.prefs.plan(first, second)
            ProtectionStateStore.configure(g.ctx, true, pk, input(relaxed, authorized, g.s, 2))
            val mem = level(g.ctx, bank)
            val disk = level(g.ctx.restarted(), bank)
            assertFalse("auth=$authorized $first/$second", disk.isStricterThan(mem))
        }
    }

    /**
     * 5b + 6, WITHOUT Option A (the pre-fix app re-sent its reduced document
     * after a restart): records the original defect. Native durable state
     * and the unflagged re-sync both end weaker; asserted as observed.
     */
    @Test
    fun s5b_withoutOptionA_recordsTheOriginalDefect() {
        val g = confirmedOld()
        g.ctx.prefs.plan(Mode.FAIL_AFTER_DISK, Mode.FAIL_BEFORE_DISK)
        val out = ProtectionStateStore.configure(g.ctx, true, pk, input(relaxed, true, g.s, 2))
        assertFalse(out.persisted)
        assertEquals(SecurityLevel.CRITICAL, level(g.ctx, bank)) // this process: union
        val restarted = g.ctx.restarted()
        assertEquals(SecurityLevel.STANDARD, level(restarted, bank))
        assertEquals("applied", dartResyncAfterRestart(restarted).ruleStatus)
        assertEquals(SecurityLevel.STANDARD, level(restarted, bank))
    }

    /**
     * 5b + 6 WITH Option A: the app restored the previous rules, so its
     * start-up sync sends the stricter set; native treats it as a raise from
     * the weaker disk and enforces (and, when the write works, persists) it.
     */
    @Test
    fun s5b_withOptionA_restartedNativeIsRestoredAtTheFirstDartSync() {
        val g = confirmedOld()
        g.ctx.prefs.plan(Mode.FAIL_AFTER_DISK, Mode.FAIL_BEFORE_DISK)
        assertFalse(ProtectionStateStore.configure(g.ctx, true, pk, input(relaxed, true, g.s, 2)).persisted)
        val restarted = g.ctx.restarted()
        val out = ProtectionStateStore.configure(restarted, true, pk, input(old, false, "dart-restored-${counter++}", 1))
        assertTrue(out.persisted)
        assertEquals("applied", out.ruleStatus)
        assertEquals(SecurityLevel.CRITICAL, level(restarted, bank))
        assertEquals(SecurityLevel.CRITICAL, level(restarted.restarted(), bank))
    }

    // -- G. startup gap: foreground decisions after the 5b restart --------------
    //
    // State: native disk holds the WEAKER set (5b); Option A restored the
    // stricter rules in app storage. The process died (all native grants are
    // in memory, so none survive). Native restarts before Dart has synced.

    private val launcher = "com.example.launcher"
    private val grace = 30_000L
    private val window = 120_000L

    private fun gapState(): Ctx {
        val g = confirmedOld()
        g.ctx.prefs.plan(Mode.FAIL_AFTER_DISK, Mode.FAIL_BEFORE_DISK)
        assertFalse(ProtectionStateStore.configure(g.ctx, true, pk, input(relaxed, true, g.s, 2)).persisted)
        val restarted = g.ctx.restarted()
        ProtectionAccessState.revokeAll() // process death
        ProtectionAccessState.setGracePeriod(grace)
        ProtectionAccessState.observeForeground(launcher, false, 0L)
        assertEquals(SecurityLevel.STANDARD, level(restarted, bank)) // weaker disk loaded
        return restarted
    }

    private fun observe(ctx: Ctx, pkg: String, t: Long) =
        ProtectionAccessState.observeForeground(pkg, pkg != launcher, t, true) { level(ctx, it) }

    /** Dart's start-up sync of the restored (stricter) rules, no CR-2 flag. */
    private fun dartSyncsRestoredRules(ctx: Ctx) =
        ProtectionStateStore.configure(ctx, true, pk, input(old, false, "dart-restored-${counter++}", 1))

    @Test
    fun g1_nativeOnlyGap_everyProtectedAccessIsChallenged() {
        val ctx = gapState()
        // No Flutter: native has no way to grant; grants died with the process.
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, observe(ctx, bank, 1_000L))
        observe(ctx, launcher, 2_000L)
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, observe(ctx, bank, 3_000L))
        assertFalse(ProtectionAccessState.isAuthorized(bank))
    }

    @Test
    fun g2_pinGrantWithDartRuleFloorLoaded_noWeakerGrace() {
        val ctx = gapState()
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, observe(ctx, bank, 1_000L))
        // WatcherService.authorizePackage: level = native effective (Standard,
        // weaker disk), floor = Dart's grant level (rule cache loaded: Critical).
        ProtectionAccessState.authorize(bank, window, 2_000L, level(ctx, bank), SecurityLevel.CRITICAL)
        assertEquals(ProtectionAccessState.Decision.ALLOW, observe(ctx, bank, 2_500L))
        observe(ctx, launcher, 3_000L)
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, observe(ctx, bank, 5_000L))
    }

    /**
     * MANDATORY startup-gap invariant (R-A): a PIN grant made before Dart's
     * Smart Rules are known (cold-start race) or after a failed rule read
     * now carries the CRITICAL floor (DefaultAccessController R-A; proven
     * through the real lock host in smart_rules_startup_floor_m2_test.dart
     * RA-7/RA-8 via `authorizeLevelFloors`). Native's own effective level is
     * still the weaker disk set, so the floor is what decides.
     */
    @Test
    fun g3_INVARIANT_pinGrantBeforeDartRulesKnown_RA_mustNotGetWeakerGrace() {
        for (case in listOf("cold-start race", "failed rule read")) {
            val ctx = gapState()
            assertEquals(case, ProtectionAccessState.Decision.CHALLENGE, observe(ctx, bank, 1_000L))
            // R-A: floor = CRITICAL while the rules are not known.
            ProtectionAccessState.authorize(bank, window, 2_000L, level(ctx, bank), SecurityLevel.CRITICAL)
            assertEquals(case, ProtectionAccessState.Decision.ALLOW, observe(ctx, bank, 2_500L))
            observe(ctx, launcher, 3_000L)
            val reentry = observe(ctx, bank, 5_000L) // 2 s later, inside 30 s grace
            assertEquals(
                "$case: re-entry 2 s after leaving during the startup gap (restored rule = Critical, no grace)",
                ProtectionAccessState.Decision.CHALLENGE,
                reentry,
            )
            assertFalse(case, ProtectionAccessState.isAuthorized(bank))
            // Critical window: the grant does not outlive 60 s even in place.
            ProtectionAccessState.authorize(bank, window, 10_000L, level(ctx, bank), SecurityLevel.CRITICAL)
            assertEquals(case, ProtectionAccessState.Decision.CHALLENGE, observe(ctx, bank, 10_000L + 60_000L))
        }
    }

    /**
     * Record (pre-R-A Dart floor = saved Standard): native alone does not
     * close the gap; it relies on the floor Dart sends. Asserted as observed.
     */
    @Test
    fun g3_withoutRA_recordsNativeReliesOnTheDartFloor() {
        val ctx = gapState()
        ProtectionAccessState.authorize(bank, window, 2_000L, level(ctx, bank), SecurityLevel.STANDARD)
        observe(ctx, launcher, 3_000L)
        assertEquals(ProtectionAccessState.Decision.ALLOW, observe(ctx, bank, 5_000L))
    }

    @Test
    fun g4_gapClosesAtDartSync_strictRulesInMemoryEvenIfTheWriteFailsAgain() {
        for (mode in Mode.values()) {
            val ctx = gapState()
            ProtectionAccessState.authorize(bank, window, 2_000L, level(ctx, bank), SecurityLevel.STANDARD)
            observe(ctx, launcher, 3_000L)
            ctx.prefs.plan(mode, Mode.FAIL_BEFORE_DISK)
            val out = dartSyncsRestoredRules(ctx)
            assertEquals("$mode", "applied", out.ruleStatus) // a raise from the weaker disk
            assertEquals("$mode", SecurityLevel.CRITICAL, level(ctx, bank))
            // The weaker grant is revoked at the next decision.
            assertEquals("$mode", ProtectionAccessState.Decision.CHALLENGE, observe(ctx, bank, 5_000L))
            val durable = level(ctx.restarted(), bank)
            if (mode == Mode.FAIL_BEFORE_DISK) {
                // Disk may stay weaker until a later successful sync (next gap).
                assertEquals("$mode", SecurityLevel.STANDARD, durable)
            } else {
                assertEquals("$mode", SecurityLevel.CRITICAL, durable)
            }
        }
    }

    @Test
    fun g5_userStillInsideTheAppWhenDartSyncs_weakerGrantRevokedAtNextDecision() {
        val ctx = gapState()
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, observe(ctx, bank, 1_000L))
        ProtectionAccessState.authorize(bank, window, 2_000L, level(ctx, bank), SecurityLevel.STANDARD)
        assertEquals(ProtectionAccessState.Decision.ALLOW, observe(ctx, bank, 2_500L))
        assertEquals("applied", dartSyncsRestoredRules(ctx).ruleStatus)
        // Same package, window still valid: only the rise-revoke rule stops it.
        assertEquals(ProtectionAccessState.Decision.CHALLENGE, observe(ctx, bank, 3_000L))
        assertFalse(ProtectionAccessState.isAuthorized(bank))
    }

    // -- scripted SharedPreferences ------------------------------------------------

    class Prefs : SharedPreferences {
        val data = mutableMapOf<String, Any>()
        val disk = mutableMapOf<String, Any>()
        private val script = ArrayDeque<Mode>()
        fun plan(vararg modes: Mode) { script.clear(); script.addAll(modes) }
        fun next(): Mode = script.removeFirstOrNull() ?: Mode.OK
        override fun getBoolean(key: String?, defValue: Boolean) = data[key] as? Boolean ?: defValue
        override fun getLong(key: String?, defValue: Long) = data[key] as? Long ?: defValue
        override fun getInt(key: String?, defValue: Int) = data[key] as? Int ?: defValue
        override fun getString(key: String?, defValue: String?) = data[key] as? String ?: defValue
        @Suppress("UNCHECKED_CAST")
        override fun getStringSet(key: String?, defValues: Set<String>?): Set<String>? =
            (data[key] as? Set<String>)?.toSet() ?: defValues
        override fun contains(key: String?) = data.containsKey(key)
        override fun edit(): SharedPreferences.Editor = Editor(this)
    }

    class Editor(private val prefs: Prefs) : SharedPreferences.Editor {
        private val puts = mutableMapOf<String, Any>()
        private val removes = mutableSetOf<String>()
        private fun put(key: String?, value: Any): SharedPreferences.Editor { puts[key!!] = value; return this }
        override fun putBoolean(key: String?, value: Boolean) = put(key, value)
        override fun putLong(key: String?, value: Long) = put(key, value)
        override fun putInt(key: String?, value: Int) = put(key, value)
        override fun putString(key: String?, value: String?) = put(key, value!!)
        override fun putStringSet(key: String?, values: Set<String>?) = put(key, values!!.toSet())
        override fun remove(key: String?): SharedPreferences.Editor { removes += key!!; return this }
        override fun clear(): SharedPreferences.Editor { prefs.data.clear(); return this }
        override fun apply() { commit() }
        override fun commit(): Boolean {
            removes.forEach { prefs.data.remove(it) }
            prefs.data.putAll(puts) // AOSP commitToMemory: never rolled back
            val mode = prefs.next()
            if (mode != Mode.FAIL_BEFORE_DISK) {
                prefs.disk.clear()
                prefs.disk.putAll(prefs.data) // the whole map is written
            }
            return mode == Mode.OK
        }
    }

    class Ctx(val prefs: Prefs = Prefs()) : Context() {
        fun restarted(): Ctx = Ctx(Prefs().also { it.data.putAll(prefs.disk); it.disk.putAll(prefs.disk) })
        override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences = prefs
    }
}
