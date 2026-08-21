package com.smartapplock.app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * MethodChannel bridge for the watcher foreground service
 * (Phase 5 mobile-QA fix).
 *
 *  * `start` — requests POST_NOTIFICATIONS on API 33+ (the system shows
 *    the watcher notification only with it; the service itself runs
 *    either way), then starts the foreground watcher;
 *  * `stop` — stops the watcher;
 *  * `isRunning` — the watcher's running state.
 */
object WatcherChannel {

    /** Must match the Dart side of the bridge. */
    const val CHANNEL = "smart_app_lock/watcher"

    private const val NOTIFICATION_PERMISSION_REQUEST = 1001

    fun register(engine: FlutterEngine, activity: MainActivity) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    try {
                        requestNotificationPermission(activity)
                        result.success(WatcherService.start(activity))
                    } catch (e: Exception) {
                        result.error(
                            "watcher_error",
                            "Failed to start the watcher: ${e.message}",
                            null,
                        )
                    }
                }
                "stop" -> {
                    try {
                        result.success(WatcherService.stop(activity))
                    } catch (e: Exception) {
                        result.error(
                            "watcher_error",
                            "Failed to stop the watcher: ${e.message}",
                            null,
                        )
                    }
                }
                "isRunning" -> {
                    result.success(WatcherService.isRunning())
                }
                else -> result.notImplemented()
            }
        }
    }

    /** The foreground service runs without POST_NOTIFICATIONS (its
     * notification is simply hidden); request it once so the protection
     * indicator is visible on API 33+. */
    private fun requestNotificationPermission(activity: MainActivity) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return
        }
        val granted = activity.checkSelfPermission(
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            activity.requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST,
            )
        }
    }
}
