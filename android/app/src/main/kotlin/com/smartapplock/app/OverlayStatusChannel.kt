package com.smartapplock.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * MethodChannel bridge for the overlay ("draw over other apps")
 * capability (Phase 4D).
 *
 *  * `isOverlayGranted` — the authoritative [Settings.canDrawOverlays]
 *    probe.
 *  * `requestOverlayPermission` — opens the system overlay-permission
 *    settings screen, scoped to this app's package where the platform
 *    supports it, and reports whether the intent resolved.
 *
 * It also coordinates the native touch-blocking recovery shield and the
 * hand-off to MainActivity. Credential input remains in Flutter.
 */
object OverlayStatusChannel {

    /** Must match the Dart side of the bridge. */
    const val CHANNEL = "smart_app_lock/overlay"

    fun register(engine: FlutterEngine, activity: MainActivity) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isOverlayGranted" -> {
                    try {
                        result.success(Settings.canDrawOverlays(activity))
                    } catch (e: Exception) {
                        result.error(
                            "overlay_error",
                            "Failed to check overlay state: ${e.message}",
                            null,
                        )
                    }
                }
                "requestOverlayPermission" -> {
                    try {
                        result.success(openOverlaySettings(activity))
                    } catch (e: Exception) {
                        result.error(
                            "overlay_error",
                            "Failed to open overlay settings: ${e.message}",
                            null,
                        )
                    }
                }
                "showLockChallenge" -> {
                    try {
                        val packageName = call.argument<String>("packageName")
                        if (!packageName.isNullOrBlank()) {
                            ProtectionStateStore.setPendingChallenge(
                                activity,
                                packageName,
                            )
                        }
                        // Cover first, then launch: a blocked/delayed
                        // background activity start can never expose the
                        // protected app as usable content.
                        val shielded = ProtectionOverlayController.show(activity)
                        val launched = shielded &&
                            (ProtectionRuntime.activityResumed ||
                                launchLockChallenge(activity))
                        result.success(shielded && launched)
                    } catch (e: Exception) {
                        result.error(
                            "overlay_error",
                            "Failed to show the lock challenge: ${e.message}",
                            null,
                        )
                    }
                }
                "hideLockChallenge" -> {
                    result.success(ProtectionOverlayController.hide())
                }
                "markChallengeReady" -> {
                    // Never drop the hand-off shield for an off-screen
                    // Flutter route, or clear a newer package's latch with a
                    // stale post-frame callback from an older challenge.
                    val packageName = call.argument<String>("packageName")
                    if (ProtectionRuntime.activityResumed &&
                        !packageName.isNullOrBlank()
                    ) {
                        // Clear only this package. If a newer package replaced
                        // the latch, its pending recovery survives; the
                        // already-rendered Flutter challenge is nevertheless
                        // a safe opaque hand-off surface for the shield.
                        ProtectionStateStore.clearPendingChallenge(
                            activity,
                            packageName,
                        )
                        result.success(ProtectionOverlayController.hide())
                    } else {
                        result.success(false)
                    }
                }
                "setSecureWindow" -> {
                    // Phase 5O (recents hardening): FLAG_SECURE keeps the
                    // recents snapshot and screenshots blank while the
                    // lock challenge (or any sensitive state) is on
                    // screen. Total: false when the toggle cannot be
                    // applied (never crashes the bridge).
                    val secure = call.argument<Boolean>("secure") ?: false
                    try {
                        result.success(setSecureWindow(activity, secure))
                    } catch (e: Exception) {
                        result.error(
                            "overlay_error",
                            "Failed to toggle the secure window: ${e.message}",
                            null,
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun openOverlaySettings(context: Context): Boolean {
        return try {
            val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                intent.data = Uri.parse("package:${context.packageName}")
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Phase 5O: toggles FLAG_SECURE on the activity window — while set,
     * the recents snapshot and screenshots render blank, so a challenge
     * (or any sensitive state) never leaks through task switching.
     * Window flags must change on the UI thread.
     */
    fun setSecureWindow(activity: MainActivity, secure: Boolean): Boolean {
        return try {
            activity.runOnUiThread {
                if (secure) {
                    activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                } else {
                    activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Phase 5D: brings Smart App Lock's activity to the foreground so the
     * Flutter side can present the unlock challenge. Total: returns false
     * when the launch cannot be performed (never crashes the bridge).
     */
    fun launchLockChallenge(context: Context): Boolean {
        return try {
            val intent = Intent(context, MainActivity::class.java)
            intent.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT,
            )
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }
}
