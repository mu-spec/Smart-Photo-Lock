package com.smartapplock.app

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent
import io.flutter.plugin.common.EventChannel

/**
 * Detection-only accessibility service for Smart App Lock (Phase 4C
 * declaration; Phase 5A reporting).
 *
 * The service exists as the FALLBACK foreground-detection path. Its
 * config (`res/xml/accessibility_service_config.xml`) restricts it to
 * TYPE_WINDOW_STATE_CHANGED events with content capture DISABLED — the
 * service never reads screen content, never performs actions on the
 * user's behalf, and never stores anything.
 *
 * Phase 5A: on a window-state change the service reports ONLY the
 * foreground package name to the Dart side through the EventChannel
 * registered in [AccessibilityStatusChannel]. The sink lives in the
 * companion so the service (a separate component instance) can reach it.
 */
class AccessibilityLockService : AccessibilityService() {

    override fun onServiceConnected() {
        super.onServiceConnected()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val type = event?.eventType ?: return
        if (type != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            return
        }
        val packageName = event.packageName?.toString() ?: return
        if (packageName == applicationContext.packageName) {
            return // never report our own app
        }
        val sink = eventSink ?: return
        try {
            sink.success(packageName)
        } catch (e: Exception) {
            // The Dart listener went away; nothing to do.
        }
    }

    override fun onInterrupt() {
        // No work to interrupt.
    }

    companion object {
        /**
         * The Dart-side event sink, installed by
         * [AccessibilityStatusChannel] while a listener is attached.
         * Volatile: the service and the engine run on different threads.
         */
        @Volatile
        var eventSink: EventChannel.EventSink? = null
    }
}
