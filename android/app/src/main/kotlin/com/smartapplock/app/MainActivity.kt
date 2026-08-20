package com.smartapplock.app

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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        InstalledAppsChannel.register(flutterEngine, this)
        AccessibilityStatusChannel.register(flutterEngine, this)
    }
}
