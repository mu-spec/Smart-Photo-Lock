package com.smartapplock.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
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
 * The bridge only surfaces capability state and routes the user to the
 * system settings — the overlay lock window itself lands with the
 * lock-screen phase.
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
}
