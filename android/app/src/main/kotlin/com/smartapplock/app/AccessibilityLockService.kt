package com.smartapplock.app

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent

/**
 * Detection-only accessibility service for Smart App Lock (Phase 4C).
 *
 * The service exists so the user can enable the fallback detection path.
 * Its config (`res/xml/accessibility_service_config.xml`) restricts it to
 * TYPE_WINDOW_STATE_CHANGED events with content capture DISABLED — the
 * service never reads screen content, never performs actions on the
 * user's behalf, and never stores or transmits anything.
 *
 * The actual foreground-app reporting is wired in the lock-engine phase;
 * until then the service is deliberately inert.
 */
class AccessibilityLockService : AccessibilityService() {

    override fun onServiceConnected() {
        super.onServiceConnected()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Lock-engine wiring lands in a later phase. Nothing is read,
        // stored, or transmitted.
    }

    override fun onInterrupt() {
        // No-op: no work to interrupt.
    }
}
