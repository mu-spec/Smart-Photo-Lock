package com.smartapplock.app

import android.content.Context
import android.content.SharedPreferences
import android.os.SystemClock
import android.provider.Settings
import java.util.Calendar

/** Minimal non-secret state required to recover enforcement without Dart. */
object ProtectionStateStore {
    data class PendingChallenge(
        val packageName: String,
        val generation: Long,
    ) {
        fun toMap(): Map<String, Any> = mapOf(
            "packageName" to packageName,
            "generation" to generation,
        )
    }

    private const val PREFS = "smart_app_lock_protection_bootstrap"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_PACKAGES = "protected_packages"
    private const val KEY_PENDING = "pending_challenge"
    private const val KEY_PENDING_GENERATION = "pending_challenge_generation"
    private const val KEY_NEXT_GENERATION = "next_challenge_generation"
    private const val KEY_WAKE_REAUTH_PACKAGE = "wake_reauth_package"
    // F3 boot scope of the wake identity (non-secret device counters only).
    private const val KEY_WAKE_REAUTH_BOOT_COUNT = "wake_reauth_boot_count"
    private const val KEY_WAKE_REAUTH_STAMP_ELAPSED = "wake_reauth_stamp_elapsed"
    private const val KEY_WAKE_REAUTH_STAMP_WALL = "wake_reauth_stamp_wall"
    private const val KEY_LAST_ERROR = "last_error"
    // Phase 8 / M2: effective per-package levels, written in the SAME edit
    // as the protected set. The version key is the presence marker: absent
    // = legacy store (pre-M2, every app Standard); present = map in force.
    private const val KEY_LEVELS = "security_levels"
    private const val KEY_LEVELS_VERSION = "security_levels_version"
    const val ERROR_LEVELS_INVALID = "security_levels_invalid"
    // Phase 10 / M2: raise-only Smart Rule specs, written in the SAME edit
    // as the protected set and levels (see SmartRuleStoreCodec).
    private const val KEY_RULES = "smart_rules"
    private const val KEY_RULES_VERSION = "smart_rules_version"

    private val snapshotOrder = SnapshotOrderGate()

    /** Level part of a `configureProtection` call (all optional). */
    data class PolicyInput(
        val version: Any? = null,
        val rawLevels: Any? = null,
        val session: String? = null,
        val revision: Long? = null,
        val authorizedDowngrades: Set<String> = emptySet(),
        /** Phase 10 / M2: whether `smartRules` was sent at all. */
        val rulesPresent: Boolean = false,
        val rulesVersion: Any? = null,
        val rawRules: Any? = null,
        /** Phase 10 / M2: a rule relaxation confirmed through CR-2 in Dart. */
        val authorizedRuleRelaxation: Boolean = false,
    )

    /** What native applied; returned to Dart for reconciliation. */
    data class ConfigureOutcome(
        val applied: Boolean,
        val status: String,
        val levels: Map<String, SecurityLevel>,
        val heldDowngrades: Set<String>,
        /** False when the durable write failed (reported, never as applied). */
        val persisted: Boolean = true,
        /** Phase 10 / M2: applied | held | kept | invalid. */
        val ruleStatus: String = "kept",
    ) {
        fun toMap(): Map<String, Any> = mapOf(
            "applied" to applied,
            "persisted" to persisted,
            "policyStatus" to status,
            "effectiveLevels" to levels.mapValues { it.value.id },
            "heldDowngrades" to heldDowngrades.toList(),
            "ruleStatus" to ruleStatus,
        )
    }

    /**
     * Applies one protection snapshot. Phase 8 / M2: a stale snapshot (same
     * Dart session, revision not newer) changes nothing. Otherwise the level
     * map is resolved by [PolicySnapshotResolver] (legacy → keep / Standard,
     * invalid → Critical, unacknowledged downgrade → held) and persisted
     * atomically with the protected set, durably (`commit`) before the reply
     * so a process kill cannot lose an upgrade the app was told is active.
     *
     * Gate finding 1: `SharedPreferences.commit()` applies the edit to the
     * in-memory map BEFORE the disk write and does not roll it back when the
     * write fails, and any later write of another key flushes that map to
     * disk. So on a failed write the level map is immediately rewritten to
     * [PolicySnapshotResolver.unpersisted] (never below the last confirmed
     * level; an unconfirmed downgrade is reported as held) and the reply says
     * `persisted = false`. Both edits run under [levelsLock], which readers
     * also take, so no enforcement read can observe the unconfirmed level.
     * A failed upgrade stays enforced in memory for this process; after a
     * process death native falls back to the last durable level until the
     * next Dart sync (Dart was told the upgrade is not confirmed). Packages whose level became
     * stricter lose any existing authorization or grace. Pending tickets of
     * still-protected packages, lockout and grace settings are untouched.
     */
    @Synchronized
    fun configure(
        context: Context,
        enabled: Boolean,
        packages: Set<String>,
        policy: PolicyInput = PolicyInput(),
    ): ConfigureOutcome {
        val normalized = packages.filter { it.isNotBlank() }.toSet()
        if (!snapshotOrder.accept(policy.session, policy.revision)) {
            return ConfigureOutcome(false, "stale", securityLevels(context), emptySet())
        }
        val resolution = PolicySnapshotResolver.resolve(
            packages = normalized,
            version = policy.version,
            rawLevels = policy.rawLevels,
            previous = securityLevels(context),
            authorizedDowngrades = policy.authorizedDowngrades,
        )
        ProtectionAccessState.retainProtectedPackages(normalized)
        ProtectionAccessState.revoke(resolution.raised)
        if (!enabled || normalized.isEmpty()) {
            ProtectionAccessState.revokeAll()
        }
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        var ruleStatus = SmartRuleSnapshotResolver.Status.KEPT
        val (persisted, levels) = synchronized(levelsLock) {
            val previous = securityLevelsLocked(preferences)
            // Phase 10 / M2: rules resolved and written with the levels.
            val previousRulesVersion = rulesVersionLocked(preferences)
            val previousRuleEntries = preferences.getStringSet(KEY_RULES, null)?.toSet()
            val previousRules = SmartRuleStoreCodec.decode(previousRulesVersion, previousRuleEntries)
            val rules = SmartRuleSnapshotResolver.resolve(
                present = policy.rulesPresent,
                version = policy.rulesVersion,
                raw = policy.rawRules,
                previous = previousRules.rules,
                previousDamaged = previousRules.damaged,
                authorizedRelaxation = policy.authorizedRuleRelaxation,
            )
            ruleStatus = rules.status
            val edit = preferences.edit()
                .putBoolean(KEY_ENABLED, enabled && normalized.isNotEmpty())
                .putStringSet(KEY_PACKAGES, normalized)
                .putInt(KEY_LEVELS_VERSION, SecurityLevelStoreCodec.VERSION)
                .putStringSet(KEY_LEVELS, SecurityLevelStoreCodec.encode(resolution.levels))
            rules.rules?.let {
                edit.putInt(KEY_RULES_VERSION, SmartRuleStoreCodec.VERSION)
                    .putStringSet(KEY_RULES, SmartRuleStoreCodec.encode(it))
            }
            val written = edit.commit()
            if (written) {
                true to resolution.levels
            } else {
                val safe = PolicySnapshotResolver.unpersisted(resolution.levels, previous)
                // Restores memory whatever the disk result; best effort on disk.
                val restore = preferences.edit()
                    .putInt(KEY_LEVELS_VERSION, SecurityLevelStoreCodec.VERSION)
                    .putStringSet(KEY_LEVELS, SecurityLevelStoreCodec.encode(safe))
                val resolvedRules = rules.rules
                if (resolvedRules != null) {
                    if (previousRules.damaged) {
                        // Keep the damaged marker (Critical) exactly as it was.
                        if (previousRulesVersion == null) {
                            restore.remove(KEY_RULES_VERSION)
                        } else {
                            restore.putInt(KEY_RULES_VERSION, previousRulesVersion)
                        }
                        if (previousRuleEntries == null) {
                            restore.remove(KEY_RULES)
                        } else {
                            restore.putStringSet(KEY_RULES, previousRuleEntries)
                        }
                    } else {
                        // Never weaker than the last confirmed rules.
                        restore.putInt(KEY_RULES_VERSION, SmartRuleStoreCodec.VERSION)
                            .putStringSet(
                                KEY_RULES,
                                SmartRuleStoreCodec.encode(
                                    SmartRuleSnapshotResolver.unpersisted(
                                        resolvedRules,
                                        previousRules.rules,
                                    ),
                                ),
                            )
                    }
                }
                restore.commit()
                false to safe
            }
        }
        if (resolution.status == PolicySnapshotResolver.Status.INVALID) {
            setLastError(context, ERROR_LEVELS_INVALID)
        }
        val pending = pendingChallenge(context)
        if (!enabled || (pending != null && pending.packageName !in normalized)) {
            clearPendingChallenge(context)
            ProtectionRuntime.invalidateChallengeHandoff()
        }
        val wakePackage = rememberedWakeReauthPackage(context)
        if (!enabled || (wakePackage != null && wakePackage !in normalized)) {
            rememberWakeReauthPackage(context, null)
        }
        return ConfigureOutcome(
            applied = true,
            status = resolution.status.name.lowercase(),
            levels = levels,
            heldDowngrades = resolution.heldDowngrades +
                levels.filter { (pkg, level) -> resolution.levels[pkg] != level }.keys,
            persisted = persisted,
            ruleStatus = ruleStatus.name.lowercase(),
        )
    }

    /**
     * Phase 10 / M2: the level native ENFORCES for [packageName] at the
     * wall-clock instant [nowWallMs] (device default time zone, read at the
     * call): the stricter of its saved level ([securityLevel]) and the
     * strictest persisted Smart Rule matching it then. Never below the saved
     * level. A damaged rule store → Critical. Called at every foreground
     * decision and at authorization; no timer or alarm is involved, so a
     * rule start takes effect at the next observed foreground event.
     */
    fun effectiveLevel(
        context: Context,
        packageName: String,
        nowWallMs: Long = System.currentTimeMillis(),
    ): SecurityLevel {
        val baseline = securityLevel(context, packageName)
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val decoded = synchronized(levelsLock) {
            SmartRuleStoreCodec.decode(
                rulesVersionLocked(preferences),
                preferences.getStringSet(KEY_RULES, null)?.toSet(),
            )
        }
        if (decoded.damaged) return SecurityLevel.CRITICAL
        if (decoded.rules.isEmpty()) return baseline
        val calendar = Calendar.getInstance().apply { timeInMillis = nowWallMs }
        val ruleLevel = SmartRulePolicy.ruleLevel(
            decoded.rules,
            packageName,
            SmartRulePolicy.isoDayFromCalendar(calendar.get(Calendar.DAY_OF_WEEK)),
            calendar.get(Calendar.HOUR_OF_DAY) * 60 + calendar.get(Calendar.MINUTE),
        )
        return SmartRulePolicy.effectiveLevel(baseline, ruleLevel)
    }

    private fun rulesVersionLocked(preferences: SharedPreferences): Int? =
        if (preferences.contains(KEY_RULES_VERSION)) {
            preferences.getInt(KEY_RULES_VERSION, -1)
        } else {
            null
        }

    /**
     * Phase 8 / M2: effective level of every protected package (see
     * [SecurityLevelStoreCodec.decode]: legacy store → Standard, damaged
     * map → Critical).
     */
    fun securityLevels(context: Context): Map<String, SecurityLevel> {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return synchronized(levelsLock) { securityLevelsLocked(preferences) }
    }

    /**
     * Leaf lock for the level entries (gate finding 1). Never acquire another
     * lock while holding it: [ProtectionAccessState.observeForeground] reads
     * levels under its own monitor while [configure] (this object's monitor)
     * calls into [ProtectionAccessState].
     */
    private val levelsLock = Any()

    private fun securityLevelsLocked(preferences: SharedPreferences): Map<String, SecurityLevel> {
        val version = if (preferences.contains(KEY_LEVELS_VERSION)) {
            preferences.getInt(KEY_LEVELS_VERSION, -1)
        } else {
            null
        }
        return SecurityLevelStoreCodec.decode(
            version,
            preferences.getStringSet(KEY_LEVELS, null),
            preferences.getStringSet(KEY_PACKAGES, emptySet())?.toSet() ?: emptySet(),
        )
    }

    /**
     * Effective level for [packageName]. A package outside the protected set
     * never holds an authorization; it reads as Critical (strict) anyway.
     */
    fun securityLevel(context: Context, packageName: String): SecurityLevel =
        securityLevels(context)[packageName] ?: SecurityLevel.CRITICAL

    fun isEnabled(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_ENABLED, false)

    fun protectedPackages(context: Context): Set<String> =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getStringSet(KEY_PACKAGES, emptySet())?.toSet() ?: emptySet()

    fun isProtected(context: Context, packageName: String): Boolean =
        isEnabled(context) && protectedPackages(context).contains(packageName)

    /**
     * Returns the current ticket for [packageName], creating one when needed.
     * Repeated detector/retry events for the same package keep one generation.
     */
    @Synchronized
    fun ensurePendingChallenge(
        context: Context,
        packageName: String,
    ): PendingChallenge {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val current = readPendingChallenge(preferences)
        if (current?.packageName == packageName) return current
        return replacePendingChallenge(context, packageName)
    }

    /**
     * Creates a new ticket even when the package is unchanged. Screen-off uses
     * this to invalidate every pre-sleep ready/authentication callback.
     */
    @Synchronized
    fun replacePendingChallenge(
        context: Context,
        packageName: String,
    ): PendingChallenge {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val generation = preferences.getLong(KEY_NEXT_GENERATION, 0L) + 1L
        val pending = PendingChallenge(packageName, generation)
        // commit() is intentional: the fail-closed recovery ticket must reach
        // disk before Android can kill the process during screen-off/wake.
        preferences.edit()
            .putString(KEY_PENDING, packageName)
            .putLong(KEY_PENDING_GENERATION, generation)
            .putLong(KEY_NEXT_GENERATION, generation)
            .commit()
        ProtectionRuntime.invalidateChallengeHandoff()
        return pending
    }

    fun takePendingChallenge(context: Context): PendingChallenge? {
        // Pending represents unresolved authentication, not merely an overlay
        // transition. Reading it during Flutter reconstruction and rendering
        // the route must not clear it. It is cleared only by exact successful
        // authorization, confirmed safe exit, or exact bounded emergency
        // abandonment of the current presentation.
        return pendingChallenge(context)
    }

    fun pendingChallenge(context: Context): PendingChallenge? =
        readPendingChallenge(
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE),
        )

    /**
     * Persists only the non-secret package identity needed to reconstruct a
     * screen-off challenge after native/Flutter process recreation. This is
     * deliberately separate from the pending presentation latch: a rendered
     * challenge clears the latch, but the active protected package must still
     * be known if the screen turns off a moment later.
     */
    @Synchronized
    fun rememberWakeReauthPackage(context: Context, packageName: String?) {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val normalized = packageName?.takeIf { it.isNotBlank() }
        val editor = preferences.edit()
        if (normalized == null) {
            if (preferences.getString(KEY_WAKE_REAUTH_PACKAGE, null) == null &&
                !preferences.contains(KEY_WAKE_REAUTH_STAMP_ELAPSED)
            ) {
                return
            }
            editor.remove(KEY_WAKE_REAUTH_PACKAGE)
                .remove(KEY_WAKE_REAUTH_BOOT_COUNT)
                .remove(KEY_WAKE_REAUTH_STAMP_ELAPSED)
                .remove(KEY_WAKE_REAUTH_STAMP_WALL)
        } else {
            // F3: the identity is boot-scoped. An unchanged package is
            // re-stamped when its stamp is missing or from another boot, so
            // an identity carried over a reboot becomes usable again as soon
            // as the same app is reported in this boot.
            val nowElapsed = SystemClock.elapsedRealtime()
            val nowWall = System.currentTimeMillis()
            val bootCount = currentBootCount(context)
            val stored = readRememberedWakeIdentity(preferences)
            if (stored?.packageName == normalized &&
                WakeIdentityBootScope.sameBoot(
                    storedBootCount = stored.bootCount,
                    currentBootCount = bootCount,
                    storedElapsedMs = stored.stampElapsedMs,
                    storedWallMs = stored.stampWallMs,
                    nowElapsedMs = nowElapsed,
                    nowWallMs = nowWall,
                )
            ) {
                return
            }
            editor.putString(KEY_WAKE_REAUTH_PACKAGE, normalized)
                .putInt(KEY_WAKE_REAUTH_BOOT_COUNT, bootCount)
                .putLong(KEY_WAKE_REAUTH_STAMP_ELAPSED, nowElapsed)
                .putLong(KEY_WAKE_REAUTH_STAMP_WALL, nowWall)
        }
        // This state is written on foreground transitions, not every poll.
        // Synchronous persistence ensures SCREEN_OFF/process death cannot
        // leave authorization revoked without the package identity.
        editor.commit()
    }

    fun wakeReauthPackage(context: Context): String? =
        rememberedWakeReauthPackage(context)
            ?.takeIf { it.isNotBlank() && isProtected(context, it) }

    private fun rememberedWakeReauthPackage(context: Context): String? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_WAKE_REAUTH_PACKAGE, null)

    /** The persisted wake identity with its F3 boot-scope stamp. */
    data class RememberedWakeIdentity(
        val packageName: String,
        val bootCount: Int?,
        val stampElapsedMs: Long?,
        val stampWallMs: Long?,
    )

    /**
     * Raw remembered identity (protection is checked by the caller's
     * policy). Missing stamp fields stay null: a legacy identity written
     * before F3 can never be proven to belong to this boot.
     */
    fun rememberedWakeIdentity(context: Context): RememberedWakeIdentity? =
        readRememberedWakeIdentity(
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE),
        )

    private fun readRememberedWakeIdentity(
        preferences: android.content.SharedPreferences,
    ): RememberedWakeIdentity? {
        val packageName = preferences.getString(KEY_WAKE_REAUTH_PACKAGE, null)
            ?.takeIf { it.isNotBlank() } ?: return null
        return RememberedWakeIdentity(
            packageName = packageName,
            bootCount = if (preferences.contains(KEY_WAKE_REAUTH_BOOT_COUNT)) {
                preferences.getInt(KEY_WAKE_REAUTH_BOOT_COUNT, -1)
            } else {
                null
            },
            stampElapsedMs = if (preferences.contains(KEY_WAKE_REAUTH_STAMP_ELAPSED)) {
                preferences.getLong(KEY_WAKE_REAUTH_STAMP_ELAPSED, 0L)
            } else {
                null
            },
            stampWallMs = if (preferences.contains(KEY_WAKE_REAUTH_STAMP_WALL)) {
                preferences.getLong(KEY_WAKE_REAUTH_STAMP_WALL, 0L)
            } else {
                null
            },
        )
    }

    // A process never outlives a boot, so a known boot count is cached.
    @Volatile private var cachedBootCount: Int? = null

    /** `Settings.Global.BOOT_COUNT` (API 24), or -1 when unavailable. */
    fun currentBootCount(context: Context): Int {
        cachedBootCount?.let { return it }
        val value = try {
            Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, -1)
        } catch (e: Exception) {
            -1
        }
        if (value >= 0) cachedBootCount = value
        return value
    }

    /**
     * F3: creates a fresh-generation ticket for [packageName] only when no
     * ticket exists. An existing ticket (including a screen-off/wake ticket)
     * is never replaced and is returned as null, so the caller does nothing.
     */
    @Synchronized
    fun createRestartRecoveryChallenge(
        context: Context,
        packageName: String,
    ): PendingChallenge? {
        if (pendingChallenge(context) != null) return null
        return replacePendingChallenge(context, packageName)
    }

    /** Restores a pending ticket from the separate wake identity if needed. */
    @Synchronized
    fun restoreWakeReauthChallenge(context: Context): PendingChallenge? {
        pendingChallenge(context)?.let { return it }
        val packageName = wakeReauthPackage(context) ?: return null
        return replacePendingChallenge(context, packageName)
    }

    @Synchronized
    fun clearPendingChallenge(
        context: Context,
        expectedPackage: String? = null,
        expectedGeneration: Long? = null,
    ): Boolean {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val pending = readPendingChallenge(preferences)
        if (expectedPackage != null && pending?.packageName != expectedPackage) {
            return false
        }
        if (expectedGeneration != null && pending?.generation != expectedGeneration) {
            return false
        }
        preferences.edit()
            .remove(KEY_PENDING)
            .remove(KEY_PENDING_GENERATION)
            .apply()
        return true
    }

    private fun readPendingChallenge(
        preferences: android.content.SharedPreferences,
    ): PendingChallenge? {
        val packageName = preferences.getString(KEY_PENDING, null)
            ?.takeIf { it.isNotBlank() } ?: return null
        val generation = preferences.getLong(KEY_PENDING_GENERATION, 0L)
        // Legacy state from an older build is still fail-closed. Upgrade it
        // to generation zero; the next replacement gets a fresh generation.
        return PendingChallenge(packageName, generation)
    }

    fun setLastError(context: Context, message: String?) {
        val editor = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
        if (message == null) {
            editor.remove(KEY_LAST_ERROR)
        } else {
            editor.putString(KEY_LAST_ERROR, message)
        }
        editor.apply()
    }

    fun lastError(context: Context): String? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_LAST_ERROR, null)
}

/** Process-local liveness. It intentionally resets after genuine process death. */
object ProtectionRuntime {
    private const val HEARTBEAT_LEASE_MS = 6_000L

    @Volatile private var lastHeartbeatElapsedMs = 0L
    @Volatile var activityResumed = false

    /**
     * Phase 6 / M2: `Activity.isInMultiWindowMode` of MainActivity, set in
     * onResume / onMultiWindowModeChanged and cleared in onDestroy.
     */
    @Volatile var activityInMultiWindow = false

    @Volatile private var readyChallenge: ProtectionStateStore.PendingChallenge? = null

    fun heartbeat() {
        lastHeartbeatElapsedMs = SystemClock.elapsedRealtime()
    }

    fun markEngineUnavailable() {
        lastHeartbeatElapsedMs = 0L
    }

    @Synchronized
    fun markChallengeReady(challenge: ProtectionStateStore.PendingChallenge) {
        readyChallenge = challenge
    }

    @Synchronized
    fun isChallengeReady(challenge: ProtectionStateStore.PendingChallenge): Boolean =
        readyChallenge == challenge

    @Synchronized
    fun readyChallenge(): ProtectionStateStore.PendingChallenge? = readyChallenge

    @Synchronized
    fun consumeChallengeHandoff(
        packageName: String,
        generation: Long,
    ): Boolean {
        val ready = readyChallenge
        if (ready?.packageName != packageName || ready.generation != generation) {
            return false
        }
        readyChallenge = null
        return true
    }

    @Synchronized
    fun invalidateChallengeHandoff() {
        readyChallenge = null
    }

    fun isEngineHealthy(nowElapsedMs: Long = SystemClock.elapsedRealtime()): Boolean =
        lastHeartbeatElapsedMs > 0L &&
            nowElapsedMs - lastHeartbeatElapsedMs <= HEARTBEAT_LEASE_MS
}
