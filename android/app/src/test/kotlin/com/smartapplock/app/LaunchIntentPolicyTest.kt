package com.smartapplock.app

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Phase 6 / M1 pre-commit review: launch-extra hardening of the exported
 * MainActivity.
 *
 * Flutter's embedding reads caller-controlled extras during
 * `super.onCreate`, and malformed values throw there. Examples are an unknown
 * `cached_engine_id` or `cached_engine_group_id`, a `background_mode` that is
 * not an enum name, a non-List `dart_entrypoint_args`, or a disallowed
 * `dart-flags` value (FATAL in the engine). MainActivity therefore
 * rebuilds the Intent through [LaunchIntentPolicy] before calling super.
 *
 * JVM policy tests plus one static source-order contract. Nothing here runs
 * Android or the Flutter embedding, and nothing here is device evidence.
 */
class LaunchIntentPolicyTest {
    private val recover = "com.smartapplock.app.action.RECOVER_CHALLENGE"

    private fun neverRead(): () -> Nothing = {
        throw AssertionError("extras of a non-recovery intent must not be read")
    }

    @Test
    fun nonRecoveryIntentsKeepOnlyTheActionAndNeverTouchExtras() {
        val actions = listOf(
            null,
            "android.intent.action.MAIN",
            "android.intent.action.VIEW",
            "android.intent.action.SEND",
            "android.intent.action.RUN",
            "attacker.defined.ACTION",
        )
        for (action in actions) {
            val retained = LaunchIntentPolicy.retain(
                action = action,
                recoveryAction = recover,
                readRecoveryPackage = neverRead(),
                readRecoveryGeneration = neverRead(),
            )
            assertEquals(action, retained.action)
            assertNull(retained.recoveryPackage)
            assertNull(retained.recoveryGeneration)
        }
    }

    @Test
    fun wellFormedRecoveryHintIsKeptForTheExactMatchGate() {
        val retained = LaunchIntentPolicy.retain(
            action = recover,
            recoveryAction = recover,
            readRecoveryPackage = { "com.whatsapp" },
            readRecoveryGeneration = { 42L },
        )
        assertEquals(recover, retained.action)
        assertEquals("com.whatsapp", retained.recoveryPackage)
        assertEquals(42L, retained.recoveryGeneration)
        // A kept hint is still only a hint: it re-raises the shield solely
        // when it equals the native pending ticket, and never authorizes.
        val pending = ProtectionStateStore.PendingChallenge("com.whatsapp", 42L)
        assertTrue(
            RecoveryIntentPolicy.matches(
                pending,
                retained.recoveryPackage,
                retained.recoveryGeneration!!,
            ),
        )
        assertFalse(RecoveryIntentPolicy.matches(pending, retained.recoveryPackage, 41L))
    }

    @Test
    fun malformedRecoveryHintIsDropped() {
        val cases = listOf<Pair<String?, Long>>(
            null to 42L,
            "" to 42L,
            "   " to 42L,
            "com.whatsapp" to -1L,
        )
        for ((packageName, generation) in cases) {
            val retained = LaunchIntentPolicy.retain(
                action = recover,
                recoveryAction = recover,
                readRecoveryPackage = { packageName },
                readRecoveryGeneration = { generation },
            )
            assertEquals(recover, retained.action)
            assertNull(retained.recoveryPackage)
            assertNull(retained.recoveryGeneration)
        }
    }

    @Test
    fun hostileExtrasBundleCannotCrashTheProcess() {
        // Stand-ins for BadParcelableException / ClassCastException thrown by
        // the first extras access on a crafted bundle.
        val failures = listOf<() -> RuntimeException>(
            { IllegalStateException("bad parcelable") },
            { ClassCastException("wrong extra type") },
            { IllegalArgumentException("bad bundle") },
        )
        for (failure in failures) {
            val onPackage = LaunchIntentPolicy.retain(
                action = recover,
                recoveryAction = recover,
                readRecoveryPackage = { throw failure() },
                readRecoveryGeneration = { 1L },
            )
            val onGeneration = LaunchIntentPolicy.retain(
                action = recover,
                recoveryAction = recover,
                readRecoveryPackage = { "com.whatsapp" },
                readRecoveryGeneration = { throw failure() },
            )
            for (retained in listOf(onPackage, onGeneration)) {
                assertEquals(recover, retained.action)
                assertNull(retained.recoveryPackage)
                assertNull(retained.recoveryGeneration)
            }
        }
    }

    /**
     * STATIC SOURCE CONTRACT. MainActivity itself cannot run on this JVM
     * harness. This pins the wiring that makes the policy effective: the
     * sanitized Intent replaces getIntent() BEFORE super.onCreate, where
     * the Flutter embedding reads extras, and onNewIntent forwards only the
     * sanitized Intent.
     */
    @Test
    fun mainActivitySanitizesBeforeTheEmbeddingReadsTheIntent() {
        val relative = "src/main/kotlin/com/smartapplock/app/MainActivity.kt"
        val source = listOf(
            File(relative),
            File("android/app/$relative"),
        ).firstOrNull { it.isFile }
        assertNotNull("MainActivity.kt not found from ${File(".").absolutePath}", source)
        val text = source!!.readText()

        val onCreate = text.substringAfter("override fun onCreate(", "")
            .substringBefore("override fun ")
        val sanitize = onCreate.indexOf("setIntent(sanitizedLaunchIntent(intent))")
        val superCreate = onCreate.indexOf("super.onCreate(")
        assertTrue("onCreate must sanitize the intent", sanitize >= 0)
        assertTrue("sanitize must precede super.onCreate", sanitize in 0 until superCreate)

        val onNewIntent = text.substringAfter("override fun onNewIntent(", "")
            .substringBefore("override fun ")
        assertTrue(onNewIntent.contains("val launch = sanitizedLaunchIntent(intent)"))
        assertTrue(onNewIntent.contains("super.onNewIntent(launch)"))
        assertTrue(onNewIntent.contains("setIntent(launch)"))
        assertFalse(onNewIntent.contains("super.onNewIntent(intent)"))
        assertFalse(onNewIntent.contains("setIntent(intent)"))

        val builder = text.substringAfter("private fun sanitizedLaunchIntent(", "")
            .substringBefore("override fun ")
        assertTrue(builder.contains("LaunchIntentPolicy.retain("))
        assertTrue(builder.contains("recoveryAction = ACTION_RECOVER_CHALLENGE"))
        assertTrue(builder.contains("Intent(this, MainActivity::class.java)"))
        // The rebuilt Intent never copies caller data or the whole bundle.
        for (forbidden in listOf("putExtras(", "replaceExtras(", "setData", "data =", "Intent(source")) {
            assertFalse("sanitizer must not use $forbidden", builder.contains(forbidden))
        }
    }
}
