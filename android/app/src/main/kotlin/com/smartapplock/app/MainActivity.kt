package com.smartapplock.app

import android.content.Intent
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

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

    override fun onResume() {
        // Set this before Flutter receives the resumed lifecycle. A Dart
        // post-frame ready acknowledgement issued from that callback must
        // never be rejected because native state was one callback behind.
        ProtectionRuntime.activityResumed = true
        super.onResume()
        WatcherService.onChallengeActivityAvailable(this)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
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
}
