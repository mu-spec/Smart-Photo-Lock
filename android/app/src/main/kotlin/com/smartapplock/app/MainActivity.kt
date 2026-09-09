package com.smartapplock.app

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import java.lang.ref.WeakReference

/**
 * Entry Activity of the Smart App Lock application.
 *
 * Extends [FlutterFragmentActivity] (instead of FlutterActivity) because
 * the biometric integration (Phase 2J, `local_auth`) requires a
 * FragmentActivity host for the AndroidX BiometricPrompt on a range of
 * API levels — the prompt is attached via a Fragment. This is the
 * officially recommended host for apps using local_auth.
 *
 * Native bridges (Phase 3A: the installed-apps PackageManager channel) are
 * registered in [configureFlutterEngine].
 *
 * Later phases will add sibling Android components (e.g.
 * [android.app.admin.DeviceAdminReceiver] and
 * [android.accessibilityservice.AccessibilityService] subclasses) for the
 * app-lock enforcement features.
 */
class MainActivity : FlutterFragmentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        currentActivity = WeakReference(this)
        acceptRecoveryIntent(intent, "onCreate")
    }

    override fun onResume() {
        // Set this before Flutter receives the resumed lifecycle. A Dart
        // post-frame ready acknowledgement issued from that callback must
        // never be rejected because native state was one callback behind.
        ProtectionRuntime.activityResumed = true
        super.onResume()
        currentActivity = WeakReference(this)
        acceptRecoveryIntent(intent, "onResume")
        WatcherService.onChallengeActivityAvailable(this)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        acceptRecoveryIntent(intent, "onNewIntent")
        // singleTop/reorder-to-front may deliver a new intent without
        // recreating Flutter. Keep the native retry path armed while the
        // existing host pulls and reconstructs its pending challenge.
        WatcherService.onChallengeActivityAvailable(this)
    }

    override fun onPause() {
        ProtectionRuntime.activityResumed = false
        super.onPause()
    }

    override fun onDestroy() {
        ProtectionRuntime.activityResumed = false
        if (currentActivity?.get() === this) {
            currentActivity = null
        }
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        InstalledAppsChannel.register(flutterEngine, this)
        AccessibilityStatusChannel.register(flutterEngine, this)
        OverlayStatusChannel.register(flutterEngine, this)
        ScreenStateChannel.register(flutterEngine, this)
        WatcherChannel.register(flutterEngine, this)
    }

    private fun acceptRecoveryIntent(intent: Intent?, callback: String) {
        if (intent?.action != ACTION_RECOVER_CHALLENGE) return
        val packageName = intent.getStringExtra(EXTRA_PACKAGE_NAME) ?: return
        val generation = intent.getLongExtra(EXTRA_GENERATION, -1L)
        val pending = ProtectionStateStore.pendingChallenge(this)
        val exact = RecoveryIntentPolicy.matches(pending, packageName, generation)
        Log.d(
            TAG,
            "$callback recovery package=$packageName generation=$generation exact=$exact",
        )
        if (exact) {
            WatcherService.onChallengeActivityAvailable(this)
        }
    }

    companion object {
        private const val TAG = "SmartAppLockActivity"
        const val ACTION_RECOVER_CHALLENGE =
            "com.smartapplock.app.action.RECOVER_CHALLENGE"
        const val EXTRA_PACKAGE_NAME = "protectedPackageName"
        const val EXTRA_GENERATION = "challengeGeneration"

        @Volatile private var currentActivity: WeakReference<MainActivity>? = null

        fun recoveryIntent(
            context: Context,
            challenge: ProtectionStateStore.PendingChallenge,
        ): Intent = Intent(context, MainActivity::class.java).apply {
            action = ACTION_RECOVER_CHALLENGE
            putExtra(EXTRA_PACKAGE_NAME, challenge.packageName)
            putExtra(EXTRA_GENERATION, challenge.generation)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
        }

        /**
         * Raises the exact existing Flutter task when it is still alive.
         * MainActivity has an empty task affinity as task-hijacking hardening,
         * so a plain NEW_TASK launch cannot be relied on to find that task.
         * If no live Activity exists, the explicit recovery intent cold-starts
         * one. Neither path clears the pending shield latch.
         */
        fun foregroundForRecovery(
            context: Context,
            challenge: ProtectionStateStore.PendingChallenge,
        ): Boolean {
            val recoveryIntent = recoveryIntent(context, challenge)
            val activity = currentActivity?.get()?.takeUnless {
                it.isFinishing || it.isDestroyed
            }
            if (activity != null) {
                return try {
                    // Deliver the generation even when Android elects not to
                    // call onNewIntent for a task promotion. Flutter consumes
                    // it only after the Activity actually resumes.
                    activity.setIntent(recoveryIntent)
                    activity.acceptRecoveryIntent(recoveryIntent, "existingTask")
                    val manager = activity.getSystemService(ActivityManager::class.java)
                    manager.moveTaskToFront(
                        activity.taskId,
                        ActivityManager.MOVE_TASK_WITH_HOME,
                    )
                    Log.d(
                        TAG,
                        "moveTaskToFront taskId=${activity.taskId} " +
                            "package=${challenge.packageName} " +
                            "generation=${challenge.generation}",
                    )
                    true
                } catch (e: Exception) {
                    Log.w(TAG, "Existing task promotion failed", e)
                    launchCold(context, recoveryIntent, challenge)
                }
            }
            return launchCold(context, recoveryIntent, challenge)
        }

        private fun launchCold(
            context: Context,
            intent: Intent,
            challenge: ProtectionStateStore.PendingChallenge,
        ): Boolean = try {
            context.startActivity(intent)
            Log.d(
                TAG,
                "startActivity package=${challenge.packageName} " +
                    "generation=${challenge.generation}",
            )
            true
        } catch (e: Exception) {
            Log.w(TAG, "Recovery Activity launch failed", e)
            false
        }
    }
}
