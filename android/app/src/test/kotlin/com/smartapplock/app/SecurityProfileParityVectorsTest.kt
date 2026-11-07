package com.smartapplock.app

import android.content.Context
import android.content.SharedPreferences
import java.io.File
import java.util.Calendar
import java.util.TimeZone
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Phase 11 / M1: Kotlin side of the Dart/Kotlin Security Profile parity
 * vectors.
 *
 * Executes `test/fixtures/security_profiles/profile_vectors.json`, the SAME
 * file the Dart test `security_profile_parity_vectors_test.dart` executes.
 * The Dart test proves the fixture's `transport` is exactly what Dart sends
 * (saved rules + the active profile's raise-only overlay as all-day
 * entries); here that transport goes through the UNCHANGED production native
 * path: [SmartRuleTransport.parse] → [SmartRulePolicy], and
 * [ProtectionStateStore.configure] → [ProtectionStateStore.effectiveLevel]
 * (including a simulated restart, HELD vs APPLIED profile switches and a
 * failed durable write). Expected values come from an independent reference
 * model (generate_profile_vectors.py).
 *
 * JVM, SIMULATED Android inputs (in-memory SharedPreferences with AOSP
 * failed-commit semantics); not device evidence.
 */
class SecurityProfileParityVectorsTest {
    private lateinit var savedZone: TimeZone
    private lateinit var v: Map<String, Any?>
    private var counter = 0

    @Before
    fun setUp() {
        savedZone = TimeZone.getDefault()
        TimeZone.setDefault(TimeZone.getTimeZone("UTC"))
        ProtectionAccessState.revokeAll()
        ProtectionRuntime.invalidateChallengeHandoff()
        ProtectionAccessState.setGracePeriod(0L)
        @Suppress("UNCHECKED_CAST")
        v = MiniJson.parse(fixture().readText()) as Map<String, Any?>
    }

    @After
    fun tearDown() {
        TimeZone.setDefault(savedZone)
    }

    // -- helpers ---------------------------------------------------------------

    private fun fixture(): File {
        val rel = "test/fixtures/security_profiles/profile_vectors.json"
        System.getProperty("securityProfileVectors")?.let { return File(it) }
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val f = File(dir, rel)
            if (f.isFile) return f
            dir = dir.parentFile
        }
        throw IllegalStateException("profile_vectors.json not found above ${System.getProperty("user.dir")}")
    }

    @Suppress("UNCHECKED_CAST")
    private fun obj(raw: Any?) = raw as Map<String, Any?>

    @Suppress("UNCHECKED_CAST")
    private fun list(raw: Any?) = raw as List<Any?>

    private fun level(raw: Any?): SecurityLevel? = when (raw) {
        null -> null
        "standard" -> SecurityLevel.STANDARD
        "sensitive" -> SecurityLevel.SENSITIVE
        "critical" -> SecurityLevel.CRITICAL
        else -> throw IllegalArgumentException("level $raw")
    }

    private fun char(l: SecurityLevel?) = when (l) {
        SecurityLevel.CRITICAL -> 'C'
        SecurityLevel.SENSITIVE -> 'S'
        SecurityLevel.STANDARD -> 'T'
        else -> '-'
    }

    private fun specs(transport: Any?): Set<SmartRuleSpec> {
        val parsed = SmartRuleTransport.parse(1, transport)
        assertNotNull("fixture transport must parse natively", parsed)
        return parsed!!
    }

    /** Unique per test instance: native's snapshot-order gate is process-wide. */
    private val session = "profile-parity-${java.util.UUID.randomUUID()}"

    private fun input(levels: Map<String, Any?>, rules: Any?, authorized: Boolean = false) =
        ProtectionStateStore.PolicyInput(
            version = 1,
            rawLevels = levels,
            session = session,
            revision = (++counter).toLong(),
            rulesPresent = true,
            rulesVersion = 1,
            rawRules = rules,
            authorizedRuleRelaxation = authorized,
        )

    /** Wall-clock millis of `yyyy-MM-ddTHH:mm:ss` in the default zone (UTC). */
    private fun wall(local: String): Long {
        val (date, time) = local.split('T')
        val (y, mo, d) = date.split('-').map { it.toInt() }
        val (h, mi, s) = time.split(':').map { it.toInt() }
        return Calendar.getInstance().apply {
            clear()
            set(y, mo - 1, d, h, mi, s)
        }.timeInMillis
    }

    /** Reference week: Monday = 2026-11-02. */
    private fun wall(day: Int, minute: Int, second: Int = 0): Long = Calendar.getInstance().apply {
        clear()
        set(2026, Calendar.NOVEMBER, 1 + day, minute / 60, minute % 60, second)
    }.timeInMillis

    private fun scenarios() = list(v["scenarios"]).map { obj(it) }
    private fun switches() = list(v["switches"]).map { obj(it) }

    // -- tests -----------------------------------------------------------------

    @Test
    fun fixtureShape() {
        assertEquals(1, (v["version"] as Number).toInt())
        assertEquals(7, scenarios().size)
        assertEquals(23, scenarios().sumOf { list(it["cases"]).size })
        assertEquals(11, switches().size)
    }

    @Test
    fun normalProfileSendsExactlyTheRulesTransport() {
        var normal = 0
        for (s in scenarios()) {
            if (list(s["overlayTransport"]).isNotEmpty()) continue
            assertEquals("${s["id"]}", specs(s["rulesTransport"]), specs(s["transport"]))
            normal++
        }
        assertEquals(3, normal)
    }

    @Test
    fun handWrittenCasesPurePolicyStoreAndRestart() {
        var checked = 0
        for (s in scenarios()) {
            val baselines = obj(s["baselines"])
            val specs = specs(s["transport"])
            val ctx = FakeContext()
            val out = ProtectionStateStore.configure(ctx, true, baselines.keys, input(baselines, s["transport"]))
            assertTrue("${s["id"]} persisted", out.persisted)
            assertEquals("${s["id"]} rule status", "applied", out.ruleStatus)
            val restarted = ctx.restarted()
            for (raw in list(s["cases"])) {
                val c = obj(raw)
                val why = "${s["id"]}: ${c["name"]}"
                val app = c["app"] as String
                if (app !in baselines) {
                    assertFalse("$why: not protected", ProtectionStateStore.isProtected(ctx, app))
                    checked++
                    continue
                }
                val day = (c["day"] as Number).toInt()
                val minute = (c["minute"] as Number).toInt()
                assertEquals(why, level(c["extraLevel"]), SmartRulePolicy.ruleLevel(specs, app, day, minute))
                val at = wall(c["local"] as String)
                assertEquals(why, level(c["effective"]), ProtectionStateStore.effectiveLevel(ctx, app, at))
                assertEquals("$why (restart)", level(c["effective"]), ProtectionStateStore.effectiveLevel(restarted, app, at))
                // The saved level is never rewritten by a profile.
                assertEquals(why, level(baselines[app]), ProtectionStateStore.securityLevel(ctx, app))
                checked++
            }
        }
        assertEquals(23, checked)
    }

    @Test
    fun denseGridPurePolicyAndStore() {
        var points = 0
        for (s in scenarios()) {
            val baselines = obj(s["baselines"])
            val specs = specs(s["transport"])
            val ctx = FakeContext()
            ProtectionStateStore.configure(ctx, true, baselines.keys, input(baselines, s["transport"]))
            val minutes = list(s["gridMinutes"]).map { (it as Number).toInt() }
            val grid = obj(s["grid"])
            val tgrid = obj(s["transportGrid"])
            for ((pkg, rowsRaw) in tgrid) {
                val rows = list(rowsRaw).map { it as String }
                val effRows = list(grid[pkg]).map { it as String }
                val protected = pkg in baselines
                for (day in 1..7) {
                    val pure = minutes.map { char(SmartRulePolicy.ruleLevel(specs, pkg, day, it)) }.joinToString("")
                    assertEquals("${s["id"]} $pkg day $day engine", rows[day - 1], pure)
                    if (!protected) continue
                    for ((i, m) in minutes.withIndex()) {
                        for (sec in intArrayOf(0, 59)) {
                            val got = char(ProtectionStateStore.effectiveLevel(ctx, pkg, wall(day, m, sec)))
                            assertEquals("${s["id"]} $pkg day $day min $m:$sec", effRows[day - 1][i], got)
                        }
                    }
                    points += minutes.size
                }
            }
        }
        assertTrue("grid points checked: $points", points > 500)
    }

    @Test
    fun switchesRelaxesHeldAndAuthorized() {
        for (s in switches()) {
            val why = s["name"] as String
            val baselines = obj(s["baselines"])
            val before = specs(s["beforeTransport"])
            val after = specs(s["afterTransport"])
            val relaxes = s["relaxes"] as Boolean
            assertEquals(why, relaxes, SmartRulePolicy.relaxes(before, after))

            // Unauthorized switch: a relaxation is HELD (stricter union), else applied.
            val ctx = FakeContext()
            assertEquals(why, "applied", ProtectionStateStore.configure(ctx, true, baselines.keys, input(baselines, s["beforeTransport"])).ruleStatus)
            val out = ProtectionStateStore.configure(ctx, true, baselines.keys, input(baselines, s["afterTransport"]))
            assertEquals(why, if (relaxes) "held" else "applied", out.ruleStatus)
            val expectedSpecs = if (relaxes) before + after else after
            val restarted = ctx.restarted()
            for (pkg in baselines.keys) {
                val base = level(baselines[pkg])!!
                for (day in 1..7) {
                    for (m in intArrayOf(0, 539, 540, 1019, 1020, 1439)) {
                        val want = SmartRulePolicy.effectiveLevel(base, SmartRulePolicy.ruleLevel(expectedSpecs, pkg, day, m))
                        assertEquals("$why $pkg $day $m", want, ProtectionStateStore.effectiveLevel(ctx, pkg, wall(day, m)))
                        assertEquals("$why $pkg $day $m (restart)", want, ProtectionStateStore.effectiveLevel(restarted, pkg, wall(day, m)))
                    }
                }
            }

            // Authorized (CR-2 proof in Dart, wired in M2): applied exactly.
            val ctx2 = FakeContext()
            ProtectionStateStore.configure(ctx2, true, baselines.keys, input(baselines, s["beforeTransport"]))
            assertEquals(why, "applied", ProtectionStateStore.configure(ctx2, true, baselines.keys, input(baselines, s["afterTransport"], authorized = true)).ruleStatus)
            for (pkg in baselines.keys) {
                val base = level(baselines[pkg])!!
                for (day in 1..7) {
                    val want = SmartRulePolicy.effectiveLevel(base, SmartRulePolicy.ruleLevel(after, pkg, day, 600))
                    assertEquals("$why $pkg $day authorized", want, ProtectionStateStore.effectiveLevel(ctx2, pkg, wall(day, 600)))
                }
            }
        }
    }

    @Test
    fun failedDurableWriteOfAProfileSwitchNeverWeakensAndIsNotReportedPersisted() {
        var relaxing = 0
        for (s in switches()) {
            if (s["relaxes"] != true) continue
            relaxing++
            val why = s["name"] as String
            val baselines = obj(s["baselines"])
            val before = specs(s["beforeTransport"])
            val prefs = FakePrefs()
            val ctx = FakeContext(prefs)
            ProtectionStateStore.configure(ctx, true, baselines.keys, input(baselines, s["beforeTransport"]))
            prefs.failCommit = true
            // Even an AUTHORIZED relaxation must not weaken when the write fails.
            val out = ProtectionStateStore.configure(ctx, true, baselines.keys, input(baselines, s["afterTransport"], authorized = true))
            assertFalse("$why: not reported persisted", out.persisted)
            prefs.failCommit = false
            val restarted = ctx.restarted()
            for (pkg in baselines.keys) {
                val base = level(baselines[pkg])!!
                for (day in 1..7) {
                    for (m in intArrayOf(0, 600, 1439)) {
                        val floor = SmartRulePolicy.effectiveLevel(base, SmartRulePolicy.ruleLevel(before, pkg, day, m))
                        val now = ProtectionStateStore.effectiveLevel(ctx, pkg, wall(day, m))
                        val after = ProtectionStateStore.effectiveLevel(restarted, pkg, wall(day, m))
                        assertFalse("$why $pkg $day $m live weaker", floor.isStricterThan(now))
                        assertFalse("$why $pkg $day $m restart weaker", floor.isStricterThan(after))
                    }
                }
            }
        }
        assertEquals(5, relaxing)
    }

    // -- JSON reader and in-memory SharedPreferences (copied from
    //    SmartRuleParityVectorsTest; test infrastructure only) ------------------

    private object MiniJson {
        fun parse(text: String): Any? {
            val p = P(text)
            val value = p.value()
            p.ws()
            check(p.i == text.length) { "trailing data at ${p.i}" }
            return value
        }

        private class P(val s: String) {
            var i = 0
            fun ws() {
                while (i < s.length && s[i].isWhitespace()) i++
            }

            fun value(): Any? {
                ws()
                return when (val c = s[i]) {
                    '{' -> obj()
                    '[' -> arr()
                    '"' -> str()
                    't' -> lit("true", true)
                    'f' -> lit("false", false)
                    'n' -> lit("null", null)
                    else -> if (c == '-' || c.isDigit()) num() else error("unexpected '$c' at $i")
                }
            }

            private fun lit(word: String, v: Any?): Any? {
                check(s.startsWith(word, i)) { "bad literal at $i" }
                i += word.length
                return v
            }

            private fun obj(): Map<String, Any?> {
                val out = LinkedHashMap<String, Any?>()
                i++
                ws()
                if (s[i] == '}') { i++; return out }
                while (true) {
                    ws()
                    val k = str()
                    ws(); check(s[i] == ':'); i++
                    out[k] = value()
                    ws()
                    if (s[i] == ',') { i++; continue }
                    check(s[i] == '}') { "expected } at $i" }
                    i++
                    return out
                }
            }

            private fun arr(): List<Any?> {
                val out = ArrayList<Any?>()
                i++
                ws()
                if (s[i] == ']') { i++; return out }
                while (true) {
                    out += value()
                    ws()
                    if (s[i] == ',') { i++; continue }
                    check(s[i] == ']') { "expected ] at $i" }
                    i++
                    return out
                }
            }

            private fun str(): String {
                check(s[i] == '"') { "expected string at $i" }
                i++
                val b = StringBuilder()
                while (s[i] != '"') {
                    if (s[i] == '\\') {
                        i++
                        when (val e = s[i]) {
                            'n' -> b.append('\n'); 't' -> b.append('\t'); 'r' -> b.append('\r')
                            'b' -> b.append('\b'); 'f' -> b.append('\u000c')
                            'u' -> { b.append(s.substring(i + 1, i + 5).toInt(16).toChar()); i += 4 }
                            else -> b.append(e)
                        }
                    } else {
                        b.append(s[i])
                    }
                    i++
                }
                i++
                return b.toString()
            }

            /** Integer literals → Int (or Long); anything with . or e → Double. */
            private fun num(): Number {
                val start = i
                if (s[i] == '-') i++
                while (i < s.length && (s[i].isDigit() || s[i] in ".eE+-")) i++
                val t = s.substring(start, i)
                if (t.any { it in ".eE" }) return t.toDouble()
                val l = t.toLong()
                return if (l in Int.MIN_VALUE..Int.MAX_VALUE) l.toInt() else l
            }
        }
    }

    // -- in-memory SharedPreferences (AOSP failed-commit semantics) -------------------

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
