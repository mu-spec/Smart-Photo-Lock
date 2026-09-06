package com.smartapplock.app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Flutter bridge for protection bootstrap, liveness, and native health. */
object WatcherChannel {
    const val CHANNEL = "smart_app_lock/watcher"

    fun register(engine: FlutterEngine, activity: MainActivity) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start" -> result.success(WatcherService.start(activity))
                        "stop" -> result.success(WatcherService.stop(activity))
                        "isRunning" -> result.success(WatcherService.isRunning())
                        "configureProtection" -> {
                            val enabled = call.argument<Boolean>("enabled") ?: false
                            val packages = call.argument<List<String>>("protectedPackages")
                                ?.toSet() ?: emptySet()
                            ProtectionStateStore.configure(activity, enabled, packages)
                            if (!enabled) {
                                ProtectionStateStore.clearPendingChallenge(activity)
                                ProtectionOverlayController.hide()
                            }
                            result.success(true)
                        }
                        "heartbeat" -> {
                            WatcherService.heartbeat()
                            result.success(true)
                        }
                        "markEngineUnavailable" -> {
                            WatcherService.markEngineUnavailable()
                            result.success(true)
                        }
                        "takePendingChallenge" -> result.success(
                            ProtectionStateStore.takePendingChallenge(activity),
                        )
                        "getHealth" -> result.success(health(activity))
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    ProtectionStateStore.setLastError(activity, e.message)
                    result.error("watcher_error", e.message, null)
                }
            }
    }

    private fun health(activity: MainActivity): Map<String, Any?> {
        val configured = ProtectionStateStore.isEnabled(activity)
        val engineState = when {
            !configured -> "inactive"
            ProtectionRuntime.isEngineHealthy() -> "healthy"
            WatcherService.isRunning() -> "recovering"
            else -> "unavailable"
        }
        val notificationGranted = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        return mapOf(
            "protectionConfigured" to configured,
            "serviceRunning" to WatcherService.isRunning(),
            "engineState" to engineState,
            "notificationPermissionGranted" to notificationGranted,
            "lastError" to ProtectionStateStore.lastError(activity),
        )
    }
}
