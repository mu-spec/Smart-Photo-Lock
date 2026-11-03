package com.smartapplock.app

/**
 * Phase 8 / M2: per-app security level policy for native enforcement.
 *
 * Pure Kotlin (no Android types) so it is covered by JVM tests. The level
 * only ever adds strictness on top of today's enforcement: it shortens or
 * removes the re-lock grace and shortens the H-2 inactivity window. It never
 * authorizes, never creates or extends grace beyond the configured value,
 * never touches tickets or lockout. The protected package set remains the
 * gate; levels exist only for packages in it.
 *
 * Ids and order mirror Dart `AppSecurityLevel` (`standard`, `sensitive`,
 * `critical`).
 */
enum class SecurityLevel(val id: String, val rank: Int) {
    STANDARD("standard", 0),
    SENSITIVE("sensitive", 1),
    CRITICAL("critical", 2);

    fun isStricterThan(other: SecurityLevel): Boolean = rank > other.rank

    companion object {
        /** Exact id → level; anything else → null (caller decides). */
        fun fromId(raw: Any?): SecurityLevel? = values().firstOrNull { it.id == raw }

        fun stricter(a: SecurityLevel, b: SecurityLevel): SecurityLevel =
            if (a.rank >= b.rank) a else b
    }
}

object SecurityLevelPolicy {
    /** Sensitive never keeps more than this much grace after a leave. */
    const val SENSITIVE_GRACE_CAP_MS = 15_000L

    /** H-2 inactivity window cap for Sensitive and Critical. */
    const val STRICT_SESSION_WINDOW_MS = 60_000L

    /** Grace applied when leaving a package of [level]. Never above [configuredMs]. */
    fun graceMs(level: SecurityLevel, configuredMs: Long): Long {
        val configured = configuredMs.coerceAtLeast(0L)
        return when (level) {
            SecurityLevel.STANDARD -> configured
            SecurityLevel.SENSITIVE -> minOf(configured, SENSITIVE_GRACE_CAP_MS)
            SecurityLevel.CRITICAL -> 0L
        }
    }

    /**
     * H-2 window for a new authorization. Standard keeps exactly the
     * requested window (pre-M2 behaviour, no cap); Sensitive and Critical
     * cap it at [STRICT_SESSION_WINDOW_MS]. A level never lengthens it.
     */
    fun sessionWindowMs(level: SecurityLevel, requestedMs: Long): Long {
        val requested = requestedMs.coerceAtLeast(0L)
        return when (level) {
            SecurityLevel.STANDARD -> requested
            SecurityLevel.SENSITIVE, SecurityLevel.CRITICAL ->
                minOf(requested, STRICT_SESSION_WINDOW_MS)
        }
    }

    /**
     * Gate finding 2: optional per-authorization level floor sent by Dart
     * with `authorizePackage` (the level Dart enforced for that grant). It
     * can only make the authorization stricter, never grant one: absent →
     * null (native store level only); present but not an exact level id →
     * Critical (malformed transport is never permissive).
     */
    fun authorizationFloor(present: Boolean, raw: Any?): SecurityLevel? =
        if (!present) null else SecurityLevel.fromId(raw) ?: SecurityLevel.CRITICAL
}

/**
 * Validation of the level part of a `configureProtection` snapshot.
 *
 * Transport (Dart → native), all optional for backward compatibility:
 * `policyVersion` (Int, currently 1), `securityLevels` (Map pkg → id),
 * `snapshotSession` (String), `snapshotRevision` (Number),
 * `authorizedDowngrades` (List of packages whose lower level was confirmed
 * with the CR-2 credential gate in Dart).
 */
object PolicySnapshotResolver {
    const val CURRENT_VERSION = 1

    enum class Status { APPLIED, LEGACY, INVALID }

    data class Resolution(
        val status: Status,
        /** Effective level per protected package (keys == protected set). */
        val levels: Map<String, SecurityLevel>,
        /** Packages whose requested lower level was NOT applied. */
        val heldDowngrades: Set<String>,
        /** Packages whose effective level became stricter than before. */
        val raised: Set<String>,
    )

    /**
     * [packages]: the normalized protected set of this snapshot.
     * [previous]: the effective levels currently in force (from the store).
     *
     * - No version and no map (legacy transport): keep every known level,
     *   new packages are Standard. Never a downgrade.
     * - Version 1 with a map whose keys are exactly [packages] and whose
     *   values are all known ids: candidate levels. A candidate lower than
     *   [previous] is applied only when its package is in
     *   [authorizedDowngrades]; otherwise the previous level is held.
     * - Anything else (unknown version, a map without a version, a version
     *   without a map, wrong types, missing/extra keys, unknown id): INVALID,
     *   every protected package is Critical. A malformed update can only
     *   make protection stricter.
     */
    fun resolve(
        packages: Set<String>,
        version: Any?,
        rawLevels: Any?,
        previous: Map<String, SecurityLevel>,
        authorizedDowngrades: Set<String>,
    ): Resolution {
        if (version == null && rawLevels == null) {
            val levels = packages.associateWith { previous[it] ?: SecurityLevel.STANDARD }
            return Resolution(Status.LEGACY, levels, emptySet(), emptySet())
        }
        val candidate = parse(packages, version, rawLevels)
            ?: return withRaised(
                Status.INVALID,
                packages.associateWith { SecurityLevel.CRITICAL },
                emptySet(),
                previous,
            )
        val held = mutableSetOf<String>()
        val levels = packages.associateWith { pkg ->
            val wanted = candidate.getValue(pkg)
            val before = previous[pkg]
            if (before != null && before.isStricterThan(wanted) && pkg !in authorizedDowngrades) {
                held += pkg
                before
            } else {
                wanted
            }
        }
        return withRaised(Status.APPLIED, levels, held, previous)
    }

    private fun parse(packages: Set<String>, version: Any?, rawLevels: Any?): Map<String, SecurityLevel>? {
        val number = version as? Number ?: return null
        val v = number.toInt()
        if (v != CURRENT_VERSION || number.toDouble() != v.toDouble()) return null
        val map = rawLevels as? Map<*, *> ?: return null
        if (map.size != packages.size) return null
        val out = mutableMapOf<String, SecurityLevel>()
        for ((key, value) in map) {
            val pkg = key as? String ?: return null
            if (pkg !in packages) return null
            out[pkg] = SecurityLevel.fromId(value) ?: return null
        }
        return if (out.keys == packages) out else null
    }

    private fun withRaised(
        status: Status,
        levels: Map<String, SecurityLevel>,
        held: Set<String>,
        previous: Map<String, SecurityLevel>,
    ): Resolution {
        val raised = levels.filter { (pkg, level) ->
            val before = previous[pkg]
            before != null && level.isStricterThan(before)
        }.keys
        return Resolution(status, levels, held, raised)
    }

    /**
     * Gate finding 1: levels to keep when the durable write of [resolved]
     * failed. No package may drop below its last confirmed level in
     * [previous] (an unconfirmed downgrade stays held); a stricter level
     * still applies for this process (fail closed). Packages without a
     * previous level keep [resolved].
     */
    fun unpersisted(
        resolved: Map<String, SecurityLevel>,
        previous: Map<String, SecurityLevel>,
    ): Map<String, SecurityLevel> = resolved.mapValues { (pkg, level) ->
        previous[pkg]?.let { SecurityLevel.stricter(it, level) } ?: level
    }
}

/**
 * Persistent encoding of the effective levels in the native bootstrap store.
 * A version marker distinguishes "no level map yet" (legacy store written
 * before Phase 8 / M2 → Standard, today's behaviour) from "map present but
 * damaged" (→ Critical).
 */
object SecurityLevelStoreCodec {
    const val VERSION = 1
    private const val SEPARATOR = '='

    fun encode(levels: Map<String, SecurityLevel>): Set<String> =
        levels.map { (pkg, level) -> "$pkg$SEPARATOR${level.id}" }.toSet()

    /**
     * [version] and [entries] both null → legacy store (no level map was
     * ever written): every package is Standard.
     * A level map without its version marker is damaged (M2 always writes
     * both in one edit) → every package Critical.
     * Known version → each package's stored level; a missing or unreadable
     * entry is Critical. Unknown version → every package Critical.
     */
    fun decode(version: Int?, entries: Set<String>?, packages: Set<String>): Map<String, SecurityLevel> {
        if (version == null && entries == null) {
            return packages.associateWith { SecurityLevel.STANDARD }
        }
        if (version == null) return packages.associateWith { SecurityLevel.CRITICAL }
        if (version != VERSION) return packages.associateWith { SecurityLevel.CRITICAL }
        val parsed = mutableMapOf<String, SecurityLevel>()
        val damaged = mutableSetOf<String>()
        entries.orEmpty().forEach { entry ->
            val cut = entry.lastIndexOf(SEPARATOR)
            if (cut <= 0) return@forEach
            val pkg = entry.substring(0, cut)
            val level = SecurityLevel.fromId(entry.substring(cut + 1))
            if (level == null) damaged += pkg else parsed[pkg] = level
        }
        return packages.associateWith { pkg ->
            if (pkg in damaged) SecurityLevel.CRITICAL else parsed[pkg] ?: SecurityLevel.CRITICAL
        }
    }
}

/**
 * Per-process ordering of snapshots from one Dart isolate. A snapshot with
 * the same session and a revision not newer than the last accepted one is
 * stale and rejected as a whole (no package, level or enabled change). A new
 * session (Dart restarted) or a snapshot without ordering data (legacy
 * transport) is accepted.
 */
class SnapshotOrderGate {
    private var session: String? = null
    private var revision: Long = Long.MIN_VALUE

    @Synchronized
    fun accept(snapshotSession: String?, snapshotRevision: Long?): Boolean {
        if (snapshotSession == null || snapshotRevision == null) return true
        if (snapshotSession == session && snapshotRevision <= revision) return false
        session = snapshotSession
        revision = snapshotRevision
        return true
    }
}
