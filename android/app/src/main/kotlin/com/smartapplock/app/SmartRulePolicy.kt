package com.smartapplock.app

/**
 * Phase 10 / M2 (PRD 10F): native, raise-only Smart Rule enforcement.
 *
 * Pure Kotlin (no Android types) so it is covered by JVM tests. Mirrors Dart
 * `SmartRulePolicy` / `SmartRuleEvaluator` (M1 semantics):
 *  - local wall-clock minute 0..1439, start inclusive, end exclusive;
 *  - ISO weekdays Monday = 1 … Sunday = 7;
 *  - an overnight window's after-midnight part belongs to the PREVIOUS day;
 *  - an explicit all-day flag (a window never has start == end);
 *  - exact package match.
 *
 * Only raising actions reach native (Sensitive, Critical). The effective
 * level is `stricter(baseline, rule level)`, so a rule can never lower a
 * saved level, remove protection, create grace or authorize access. Several
 * matching rules → the strictest (Phase 10 / M3 owns conflict diagnostics).
 */
data class SmartRuleSpec(
    val level: SecurityLevel,
    val days: Set<Int>,
    val allDay: Boolean,
    val start: Int,
    val end: Int,
    val targets: Set<String>,
) {
    fun matches(packageName: String, isoDay: Int, minute: Int): Boolean {
        if (packageName !in targets) return false
        if (isoDay !in 1..7 || minute !in 0 until SmartRulePolicy.MINUTES_PER_DAY) return false
        if (allDay) return isoDay in days
        if (start < end) return minute >= start && minute < end && isoDay in days
        if (minute >= start) return isoDay in days
        if (minute < end) return SmartRulePolicy.previousDay(isoDay) in days
        return false
    }
}

object SmartRulePolicy {
    const val MINUTES_PER_DAY = 24 * 60

    fun previousDay(isoDay: Int): Int = if (isoDay == 1) 7 else isoDay - 1

    /** `java.util.Calendar.DAY_OF_WEEK` (Sunday = 1 … Saturday = 7) → ISO. */
    fun isoDayFromCalendar(calendarDayOfWeek: Int): Int = ((calendarDayOfWeek + 5) % 7) + 1

    /** Strictest level the rules raise [packageName] to at that local time, or null. */
    fun ruleLevel(
        rules: Collection<SmartRuleSpec>,
        packageName: String,
        isoDay: Int,
        minute: Int,
    ): SecurityLevel? {
        var best: SecurityLevel? = null
        for (rule in rules) {
            if (best != null && !rule.level.isStricterThan(best)) continue
            if (rule.matches(packageName, isoDay, minute)) best = rule.level
        }
        return best
    }

    /** Baseline floor: never below [baseline]. */
    fun effectiveLevel(baseline: SecurityLevel, ruleLevel: SecurityLevel?): SecurityLevel =
        ruleLevel?.let { SecurityLevel.stricter(baseline, it) } ?: baseline

    /**
     * True when [after] gives less rule strictness than [before] for some
     * package, weekday and minute (a removed, narrowed or lowered rule).
     * Exact: the level is constant between consecutive boundaries (minute 0
     * and every window start/end), so each boundary of each day is checked.
     */
    fun relaxes(before: Collection<SmartRuleSpec>, after: Collection<SmartRuleSpec>): Boolean {
        if (before.isEmpty()) return false
        val boundaries = sortedSetOf(0)
        (before + after).filter { !it.allDay }.forEach {
            boundaries += it.start
            boundaries += it.end
        }
        val packages = before.flatMap { it.targets }.toSet()
        for (pkg in packages) {
            for (day in 1..7) {
                for (minute in boundaries) {
                    val was = ruleLevel(before, pkg, day, minute) ?: continue
                    val now = ruleLevel(after, pkg, day, minute)
                    if (now == null || was.isStricterThan(now)) return true
                }
            }
        }
        return false
    }
}

/**
 * Parser of the `smartRules` transport sent by Dart with
 * `configureProtection` (`smartRulesVersion` = 1). Each entry: `level`
 * ("sensitive" | "critical"), `days` (non-empty ints 1..7), `allDay` (Bool),
 * `start`/`end` (ints 0..1439, different, ignored when all-day), `targets`
 * (non-empty package names). Anything else makes the whole list malformed.
 */
object SmartRuleTransport {
    const val VERSION = 1

    fun parse(version: Any?, raw: Any?): Set<SmartRuleSpec>? {
        val number = version as? Number ?: return null
        if (number.toDouble() != VERSION.toDouble()) return null
        val list = raw as? List<*> ?: return null
        val out = mutableSetOf<SmartRuleSpec>()
        for (entry in list) {
            out += parseOne(entry as? Map<*, *> ?: return null) ?: return null
        }
        return out
    }

    private fun parseOne(map: Map<*, *>): SmartRuleSpec? {
        val level = when (map["level"]) {
            SecurityLevel.SENSITIVE.id -> SecurityLevel.SENSITIVE
            SecurityLevel.CRITICAL.id -> SecurityLevel.CRITICAL
            else -> return null
        }
        val days = (map["days"] as? List<*>)?.map { exactInt(it) ?: return null }?.toSet()
            ?: return null
        if (days.isEmpty() || days.any { it !in 1..7 }) return null
        val allDay = map["allDay"] as? Boolean ?: return null
        val start = exactInt(map["start"]) ?: return null
        val end = exactInt(map["end"]) ?: return null
        if (!allDay) {
            if (start !in 0 until SmartRulePolicy.MINUTES_PER_DAY) return null
            if (end !in 0 until SmartRulePolicy.MINUTES_PER_DAY) return null
            if (start == end) return null
        }
        val targets = (map["targets"] as? List<*>)?.map { it as? String ?: return null }?.toSet()
            ?: return null
        if (targets.isEmpty() || targets.any { !SmartRuleStoreCodec.isSafePackage(it) }) return null
        return SmartRuleSpec(
            level = level,
            days = days,
            allDay = allDay,
            start = if (allDay) 0 else start,
            end = if (allDay) 0 else end,
            targets = targets,
        )
    }

    private fun exactInt(raw: Any?): Int? {
        val n = raw as? Number ?: return null
        if (n is Double || n is Float) return null
        val v = n.toLong()
        return if (v in Int.MIN_VALUE..Int.MAX_VALUE) v.toInt() else null
    }
}

/**
 * Resolution of the rule part of one snapshot against the rules in force.
 *  - not sent → KEPT (Dart could not read its rules; nothing is relaxed);
 *  - malformed → INVALID, previous rules kept;
 *  - a set that [SmartRulePolicy.relaxes] the previous one without
 *    `authorizedRuleRelaxation` (CR-2 confirmed in Dart) → HELD: the union of
 *    previous and new rules (the new strictness applies, nothing relaxes);
 *  - otherwise APPLIED.
 * A damaged stored rule set ([previousDamaged]) can only be replaced by an
 * authorized snapshot; otherwise it stays (every protected app Critical).
 */
object SmartRuleSnapshotResolver {
    enum class Status { APPLIED, HELD, KEPT, INVALID }

    data class Resolution(
        val status: Status,
        /** Rules to persist; null = leave the stored rules untouched. */
        val rules: Set<SmartRuleSpec>?,
    )

    fun resolve(
        present: Boolean,
        version: Any?,
        raw: Any?,
        previous: Set<SmartRuleSpec>,
        previousDamaged: Boolean,
        authorizedRelaxation: Boolean,
    ): Resolution {
        if (!present) return Resolution(Status.KEPT, null)
        val candidate = SmartRuleTransport.parse(version, raw)
            ?: return Resolution(Status.INVALID, null)
        if (previousDamaged) {
            return if (authorizedRelaxation) {
                Resolution(Status.APPLIED, candidate)
            } else {
                Resolution(Status.HELD, null)
            }
        }
        if (!authorizedRelaxation && SmartRulePolicy.relaxes(previous, candidate)) {
            return Resolution(Status.HELD, previous + candidate)
        }
        return Resolution(Status.APPLIED, candidate)
    }

    /** Rules to keep when the durable write of [resolved] failed: never weaker. */
    fun unpersisted(resolved: Set<SmartRuleSpec>, previous: Set<SmartRuleSpec>): Set<SmartRuleSpec> =
        previous + resolved
}

/**
 * Persistent encoding of the rules in the native bootstrap store, one string
 * per rule: `level|days|time|targets`, e.g. `critical|1,2,3|540-1020|com.a.b`
 * or `sensitive|6,7|all|com.a.b,com.c.d`. The version key is the presence
 * marker: version and entries both absent → no rules (legacy store);
 * anything unreadable → damaged (every protected app Critical).
 */
object SmartRuleStoreCodec {
    const val VERSION = 1
    private val PACKAGE = Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$")

    data class Decoded(val rules: Set<SmartRuleSpec>, val damaged: Boolean)

    fun isSafePackage(value: String): Boolean = value.length <= 255 && PACKAGE.matches(value)

    fun encode(rules: Set<SmartRuleSpec>): Set<String> = rules.map { r ->
        val time = if (r.allDay) "all" else "${r.start}-${r.end}"
        "${r.level.id}|${r.days.sorted().joinToString(",")}|$time|${r.targets.sorted().joinToString(",")}"
    }.toSet()

    fun decode(version: Int?, entries: Set<String>?): Decoded {
        if (version == null && entries == null) return Decoded(emptySet(), false)
        if (version != VERSION || entries == null) return Decoded(emptySet(), true)
        val out = mutableSetOf<SmartRuleSpec>()
        for (entry in entries) {
            out += decodeOne(entry) ?: return Decoded(emptySet(), true)
        }
        return Decoded(out, false)
    }

    private fun decodeOne(entry: String): SmartRuleSpec? {
        val parts = entry.split('|')
        if (parts.size != 4) return null
        val level = when (parts[0]) {
            SecurityLevel.SENSITIVE.id -> SecurityLevel.SENSITIVE
            SecurityLevel.CRITICAL.id -> SecurityLevel.CRITICAL
            else -> return null
        }
        val days = parts[1].split(',').map { it.toIntOrNull() ?: return null }.toSet()
        if (days.isEmpty() || days.any { it !in 1..7 }) return null
        val allDay = parts[2] == "all"
        var start = 0
        var end = 0
        if (!allDay) {
            val window = parts[2].split('-')
            if (window.size != 2) return null
            start = window[0].toIntOrNull() ?: return null
            end = window[1].toIntOrNull() ?: return null
            if (start !in 0 until SmartRulePolicy.MINUTES_PER_DAY) return null
            if (end !in 0 until SmartRulePolicy.MINUTES_PER_DAY || start == end) return null
        }
        val targets = parts[3].split(',').toSet()
        if (targets.isEmpty() || targets.any { !isSafePackage(it) }) return null
        return SmartRuleSpec(level, days, allDay, start, end, targets)
    }
}
