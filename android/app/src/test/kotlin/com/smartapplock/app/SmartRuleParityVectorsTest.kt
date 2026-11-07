package com.smartapplock.app

import android.content.Context
import android.content.SharedPreferences
import java.io.File
import java.util.Calendar
import java.util.TimeZone
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Phase 10 / M3 (PRD 10J, 10L): Kotlin side of the Dart/Kotlin parity
 * vectors.
 *
 * Executes `test/fixtures/smart_rules/conflict_vectors.json`, the SAME file
 * the Dart test `smart_rule_parity_vectors_m3_test.dart` executes. The Dart
 * test proves the fixture's `transport` is exactly what Dart sends for the
 * fixture's rules; here that transport goes through the production native
 * path: [SmartRuleTransport.parse] → [SmartRulePolicy], and
 * [ProtectionStateStore.configure] → [ProtectionStateStore.effectiveLevel]
 * (including a simulated restart over the durable copy). Expected values
 * come from an independent reference model (generate_conflict_vectors.py).
 *
 * JVM, SIMULATED Android inputs (in-memory SharedPreferences); not device
 * evidence.
 */
class SmartRuleParityVectorsTest {
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
        val rel = "test/fixtures/smart_rules/conflict_vectors.json"
        System.getProperty("smartRuleVectors")?.let { return File(it) }
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val f = File(dir, rel)
            if (f.isFile) return f
            dir = dir.parentFile
        }
        throw IllegalStateException("conflict_vectors.json not found above ${System.getProperty("user.dir")}")
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
        else -> '-'
    }

    private fun specs(transport: Any?): Set<SmartRuleSpec> {
        val parsed = SmartRuleTransport.parse(1, transport)
        assertNotNull("fixture transport must parse natively", parsed)
        return parsed!!
    }

    private fun input(levels: Map<String, Any?>, rules: Any?, rev: Long = 1, session: String = "parity-${counter++}") =
        ProtectionStateStore.PolicyInput(
            version = 1,
            rawLevels = levels,
            session = session,
            revision = rev,
            rulesPresent = true,
            rulesVersion = 1,
            rawRules = rules,
            authorizedRuleRelaxation = false,
        )

    /** Wall-clock millis of a local date/time in the CURRENT default zone. */
    private fun wall(local: String): Long {
        // yyyy-MM-ddTHH:mm:ss
        val (date, time) = local.split('T')
        val (y, mo, d) = date.split('-').map { it.toInt() }
        val (h, mi, s) = time.split(':').map { it.toInt() }
        return Calendar.getInstance().apply {
            clear()
            set(y, mo - 1, d, h, mi, s)
        }.timeInMillis
    }

    private fun wall(day: Int, minute: Int, second: Int = 0): Long = Calendar.getInstance().apply {
        clear()
        set(2026, Calendar.NOVEMBER, 1 + day, minute / 60, minute % 60, second)
    }.timeInMillis

    private fun sets() = list(v["ruleSets"]).map { obj(it) }

    // -- 11–13. matching, conflict and effective level ------------------------------

    @Test
    fun fixtureShape() {
        assertEquals(1L, (v["version"] as Number).toLong())
        assertEquals(11, sets().size)
        assertEquals(57, sets().sumOf { list(it["cases"]).size })
    }

    @Test
    fun handWrittenCasesPureNativePolicy() {
        var checked = 0
        for (s in sets()) {
            val specs = specs(s["transport"])
            val baselines = obj(s["baselines"])
            for (raw in list(s["cases"])) {
                val c = obj(raw)
                val why = "${s["id"]}: ${c["name"]}"
                val app = c["app"] as String
                val day = (c["day"] as Number).toInt()
                val minute = (c["minute"] as Number).toInt()
                val ruleLevel = SmartRulePolicy.ruleLevel(specs, app, day, minute)
                assertEquals(why, level(c["ruleLevel"]), ruleLevel)
                val base = level(baselines[app])
                if (base != null) {
                    assertEquals(why, level(c["effective"]), SmartRulePolicy.effectiveLevel(base, ruleLevel))
                } else {
                    assertNull(why, c["effective"])
                }
                checked++
            }
        }
        assertEquals(57, checked)
    }

    @Test
    fun handWrittenCasesThroughTheNativeStoreAndRestart() {
        for (s in sets()) {
            val baselines = obj(s["baselines"])
            val ctx = FakeContext()
            val out = ProtectionStateStore.configure(ctx, true, baselines.keys, input(baselines, s["transport"]))
            assertTrue("${s["id"]} persisted", out.persisted)
            assertEquals("${s["id"]} rule status", "applied", out.ruleStatus)
            val restarted = ctx.restarted()
            for (raw in list(s["cases"])) {
                val c = obj(raw)
                val app = c["app"] as String
                if (app !in baselines) continue
                val why = "${s["id"]}: ${c["name"]}"
                val at = wall(c["local"] as String)
                assertEquals(why, level(c["effective"]), ProtectionStateStore.effectiveLevel(ctx, app, at))
                assertEquals("$why (restart)", level(c["effective"]), ProtectionStateStore.effectiveLevel(restarted, app, at))
                // The saved level is never rewritten by a rule.
                assertEquals(why, level(baselines[app]), ProtectionStateStore.securityLevel(ctx, app))
            }
        }
    }

    // -- 14. boundary parity ----------------------------------------------------------

    @Test
    fun denseBoundaryGridPureAndStore() {
        var points = 0
        for (s in sets()) {
            val specs = specs(s["transport"])
            val baselines = obj(s["baselines"])
            val ctx = FakeContext()
            ProtectionStateStore.configure(ctx, true, baselines.keys, input(baselines, s["transport"]))
            val minutes = list(s["gridMinutes"]).map { (it as Number).toInt() }
            for ((pkg, rowsRaw) in obj(s["grid"])) {
                val rows = list(rowsRaw).map { it as String }
                val base = level(baselines[pkg])
                for (day in 1..7) {
                    val pure = minutes.map { char(SmartRulePolicy.ruleLevel(specs, pkg, day, it)) }.joinToString("")
                    assertEquals("${s["id"]} $pkg day $day", rows[day - 1], pure)
                    if (base != null) {
                        for ((i, m) in minutes.withIndex()) {
                            val expected = SecurityLevel.stricter(
                                base,
                                when (rows[day - 1][i]) {
                                    'C' -> SecurityLevel.CRITICAL
                                    'S' -> SecurityLevel.SENSITIVE
                                    else -> base
                                },
                            )
                            // :59 seconds: boundaries are whole minutes.
                            assertEquals(
                                "${s["id"]} $pkg day $day minute $m (store)",
                                expected,
                                ProtectionStateStore.effectiveLevel(ctx, pkg, wall(day, m, 59)),
                            )
                            points++
                        }
                    }
                }
            }
        }
        assertTrue("grid points checked through the store: $points", points > 1000)
    }

    // -- 4. order independence ---------------------------------------------------------

    @Test
    fun transportOrderNeverChangesTheOutcome() {
        for (s in sets()) {
            val transport = list(s["transport"])
            if (transport.size < 2) continue
            val expectedSpecs = specs(transport)
            val orders = listOf(transport.reversed()) +
                (1 until transport.size).map { k -> transport.drop(k) + transport.take(k) }
            val minutes = list(s["gridMinutes"]).map { (it as Number).toInt() }
            for (order in orders) {
                val permuted = specs(order)
                assertEquals(expectedSpecs, permuted)
                for ((pkg, rowsRaw) in obj(s["grid"])) {
                    val rows = list(rowsRaw).map { it as String }
                    for (day in 1..7) {
                        val row = minutes.map { char(SmartRulePolicy.ruleLevel(permuted.toList().reversed(), pkg, day, it)) }
                            .joinToString("")
                        assertEquals("${s["id"]} $pkg day $day permuted", rows[day - 1], row)
                    }
                }
            }
        }
    }

    // -- DST / time zone ------------------------------------------------------------------

    @Test
    fun dstAndTimeZoneInstantsUseTheLocalWallClockAtEachDecision() {
        val dst = obj(v["dst"])
        val baselines = obj(dst["baselines"])
        for (raw in list(dst["instants"])) {
            val i = obj(raw)
            val why = i["name"] as String
            TimeZone.setDefault(TimeZone.getTimeZone(i["zone"] as String))
            val epoch = (i["epochMillis"] as Number).toLong()
            val cal = Calendar.getInstance().apply { timeInMillis = epoch }
            assertEquals(why, (i["localDay"] as Number).toInt(), SmartRulePolicy.isoDayFromCalendar(cal.get(Calendar.DAY_OF_WEEK)))
            assertEquals(why, (i["localMinute"] as Number).toInt(), cal.get(Calendar.HOUR_OF_DAY) * 60 + cal.get(Calendar.MINUTE))
            val ctx = FakeContext()
            ProtectionStateStore.configure(ctx, true, baselines.keys, input(baselines, dst["transport"]))
            assertEquals(why, level(i["effective"]), ProtectionStateStore.effectiveLevel(ctx, "com.example.bank", epoch))
            assertEquals(
                why,
                level(i["ruleLevel"]),
                SmartRulePolicy.ruleLevel(specs(dst["transport"]), "com.example.bank", (i["localDay"] as Number).toInt(), (i["localMinute"] as Number).toInt()),
            )
        }
    }

    // -- 15. invalid input ---------------------------------------------------------------

    @Test
    fun invalidTransportIsRejectedAndKeepsThePreviousRules() {
        val first = sets().first { it["id"] == "two_rules_same_app" }
        val baselines = obj(first["baselines"])
        for (raw in list(v["invalidTransport"])) {
            val c = obj(raw)
            val why = c["name"] as String
            assertNull(why, SmartRuleTransport.parse(1, listOf(c["entry"])))
            // One bad entry invalidates the whole list.
            assertNull(why, SmartRuleTransport.parse(1, list(first["transport"]) + listOf(c["entry"])))
            val ctx = FakeContext()
            val session = "invalid-${counter++}"
            ProtectionStateStore.configure(ctx, true, baselines.keys, input(baselines, first["transport"], 1, session))
            val out = ProtectionStateStore.configure(ctx, true, baselines.keys, input(baselines, listOf(c["entry"]), 2, session))
            assertEquals(why, "invalid", out.ruleStatus)
            // The Critical lunch rule still applies (previous rules kept).
            assertEquals(why, SecurityLevel.CRITICAL, ProtectionStateStore.effectiveLevel(ctx, "com.example.bank", wall(1, 12 * 60 + 30)))
        }
    }

    @Test
    fun invalidQueriesNeverMatch() {
        val q = obj(v["invalidQueries"])
        val specs = specs(q["transport"])
        for (raw in list(q["queries"])) {
            val c = obj(raw)
            assertNull(
                c["name"] as String,
                SmartRulePolicy.ruleLevel(specs, c["app"] as String, (c["day"] as Number).toInt(), (c["minute"] as Number).toInt()),
            )
        }
    }

    // -- CR-2 / held boundary ------------------------------------------------------

    /**
     * The same reduction decision as Dart `SmartRulePolicy.relaxedPackages`:
     * pure [SmartRulePolicy.relaxes], then through the native store — a
     * reduction without `authorizedRuleRelaxation` is HELD as the stricter
     * union of old and new rules; with it (CR-2 confirmed in Dart) APPLIED.
     */
    @Test
    fun relaxationVectorsDecideHeldExactlyAsDart() {
        val pairs = list(v["relaxation"]).map { obj(it) }
        assertEquals(21, pairs.size)
        val baselines = mapOf<String, Any?>(
            "com.example.bank" to "standard",
            "com.example.chat" to "standard",
        )
        var points = 0
        for (c in pairs) {
            val why = c["name"] as String
            val before = specs(c["beforeTransport"])
            val after = specs(c["afterTransport"])
            val relaxes = c["relaxes"] as Boolean
            assertEquals(why, relaxes, SmartRulePolicy.relaxes(before, after))
            assertEquals(why, relaxes, SmartRulePolicy.relaxes(before.reversed(), after.reversed()))

            val minutes = sortedSetOf(0, 1439)
            for (r in before + after) {
                if (!r.allDay) for (m in listOf(r.start, r.end)) for (d in -1..1) minutes += (m + d + 1440) % 1440
            }

            // Without the CR-2 flag.
            val ctx = FakeContext()
            val session = "relax-${counter++}"
            ProtectionStateStore.configure(ctx, true, baselines.keys, input(baselines, c["beforeTransport"], 1, session))
            val out = ProtectionStateStore.configure(ctx, true, baselines.keys, input(baselines, c["afterTransport"], 2, session))
            assertEquals(why, if (relaxes) "held" else "applied", out.ruleStatus)
            val restarted = ctx.restarted()
            for (pkg in baselines.keys) for (day in 1..7) for (minute in minutes) {
                val was = SmartRulePolicy.ruleLevel(before, pkg, day, minute)
                val now = SmartRulePolicy.ruleLevel(after, pkg, day, minute)
                val enforcedRule = if (relaxes) {
                    if (was == null) now else if (now == null) was else SecurityLevel.stricter(was, now)
                } else {
                    now
                }
                val expected = SmartRulePolicy.effectiveLevel(SecurityLevel.STANDARD, enforcedRule)
                assertEquals("$why $pkg d$day m$minute", expected, ProtectionStateStore.effectiveLevel(ctx, pkg, wall(day, minute)))
                assertEquals("$why restart $pkg d$day m$minute", expected, ProtectionStateStore.effectiveLevel(restarted, pkg, wall(day, minute)))
                points++
            }

            // With the CR-2 flag: applied exactly as sent.
            val ctx2 = FakeContext()
            val session2 = "relax-${counter++}"
            ProtectionStateStore.configure(ctx2, true, baselines.keys, input(baselines, c["beforeTransport"], 1, session2))
            val authorized = input(baselines, c["afterTransport"], 2, session2).copy(authorizedRuleRelaxation = true)
            assertEquals(why, "applied", ProtectionStateStore.configure(ctx2, true, baselines.keys, authorized).ruleStatus)
            for (pkg in baselines.keys) for (day in 1..7) for (minute in minutes) {
                val expected = SmartRulePolicy.effectiveLevel(SecurityLevel.STANDARD, SmartRulePolicy.ruleLevel(after, pkg, day, minute))
                assertEquals("$why authorized $pkg d$day m$minute", expected, ProtectionStateStore.effectiveLevel(ctx2, pkg, wall(day, minute)))
            }
        }
        assertTrue("relaxation store points: $points", points > 1000)
    }

    // -- tiny JSON reader (test only; no dependency) ----------------------------------

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
