package com.smartapplock.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * MethodChannel bridge for the accessibility capability (Phase 4C) and
 * the foreground-event channel for detection (Phase 5A).
 *
 *  * `isAccessibilityEnabled` — true when Smart App Lock's service is
 *    listed in the system's ENABLED_ACCESSIBILITY_SERVICES setting.
 *  * `requestAccessibilityEnable` — opens the system Accessibility
 *    settings screen (the only place the user can enable the service)
 *    and reports whether the intent resolved.
 *  * `EVENTS_CHANNEL` (EventChannel) — foreground package names reported
 *    by the detection-only accessibility service on
 *    TYPE_WINDOW_STATE_CHANGED events (Phase 5A fallback detection).
 *
 * The bridge performs NO accessibility work itself — it only surfaces
 * capability state, routes the user to the system settings, and relays
 * window-state package names. Content capture stays disabled.
 */
object AccessibilityStatusChannel {

    /** Must match the Dart side of the bridge. */
    const val CHANNEL = "smart_app_lock/accessibility"

    /** Phase 5A: foreground window-state events (fallback detection). */
    const val EVENTS_CHANNEL = "smart_app_lock/accessibility_events"

    fun register(engine: FlutterEngine, activity: MainActivity) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isAccessibilityEnabled" -> {
                    try {
                        result.success(isAccessibilityEnabled(activity))
                    } catch (e: Exception) {
                        result.error(
                            "accessibility_error",
                            "Failed to check accessibility state: ${e.message}",
                            null,
                        )
                    }
                }
                "requestAccessibilityEnable" -> {
                    try {
                        result.success(openAccessibilitySettings(activity))
                    } catch (e: Exception) {
                        result.error(
                            "accessibility_error",
                            "Failed to open accessibility settings: ${e.message}",
                            null,
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Phase 5A: relays TYPE_WINDOW_STATE_CHANGED foreground packages
        // from the detection-only service to Dart listeners. Package names
        // only — no content is ever captured or transmitted.
        val eventChannel =
            EventChannel(engine.dartExecutor.binaryMessenger, EVENTS_CHANNEL)
        eventChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    AccessibilityLockService.eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    AccessibilityLockService.eventSink = null
                }
            },
        )
    }

    fun isAccessibilityEnabled(context: Context): Boolean {
        val expected = ComponentName(context, AccessibilityLockService::class.java)
        val enabledServices = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return false
        val parts = enabledServices.split(':')
        for (part in parts) {
            val component = ComponentName.unflattenFromString(part)
            if (component == expected) {
                return true
            }
        }
        return false
    }

    fun openAccessibilitySettings(context: Context): Boolean {
        return try {
            val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }
}
