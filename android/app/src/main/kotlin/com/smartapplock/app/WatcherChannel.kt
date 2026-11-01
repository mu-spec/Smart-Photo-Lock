package com.smartapplock.app

import android.Manifest
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
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
                            if (enabled) {
                                ProtectionOverlayController.arm(activity)
                            } else {
                                ProtectionStateStore.clearPendingChallenge(activity)
                                ProtectionOverlayController.disarm()
                            }
                            result.success(true)
                        }
                        "setGracePeriod" -> {
                            val milliseconds =
                                call.argument<Number>("milliseconds")?.toLong() ?: 0L
                            WatcherService.setGracePeriod(milliseconds)
                            result.success(true)
                        }
                        "authorizePackage" -> {
                            val packageName = call.argument<String>("packageName") ?: ""
                            val generation =
                                call.argument<Number>("generation")?.toLong() ?: -1L
                            val sessionWindowMs =
                                call.argument<Number>("sessionWindowMilliseconds")
                                    ?.toLong() ?: 0L
                            result.success(
                                WatcherService.authorizePackage(
                                    activity,
                                    packageName,
                                    generation,
                                    sessionWindowMs,
                                ),
                            )
                        }
                        "revokeAllAuthorizations" -> {
                            WatcherService.revokeAllAuthorizations()
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
                            ProtectionStateStore.takePendingChallenge(activity)?.toMap(),
                        )
                        "getHealth" -> result.success(health(activity))
                        "openProtectionSettings" -> result.success(
                            openProtectionSettings(activity, call.argument<String>("target")),
                        )
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    ProtectionStateStore.setLastError(activity, e.message)
                    result.error("watcher_error", e.message, null)
                }
            }
    }

    /**
     * Phase 7 / M2: user-initiated repair link. Opens one allowlisted
     * Settings screen ([ProtectionSettingsTargets]) and reports whether it
     * started. Never changes protection state, tickets or permissions.
     */
    private fun openProtectionSettings(activity: MainActivity, target: String?): Boolean {
        var spec = ProtectionSettingsTargets.spec(target, Build.VERSION.SDK_INT)
        while (spec != null) {
            try {
                val intent = Intent(spec.action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (spec.packageExtra) {
                    intent.putExtra(ProtectionSettingsTargets.EXTRA_APP_PACKAGE, activity.packageName)
                }
                if (spec.packageData) {
                    intent.data = Uri.fromParts("package", activity.packageName, null)
                }
                activity.startActivity(intent)
                return true
            } catch (e: Exception) {
                spec = spec.fallback
            }
        }
        return false
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
        ) + healthSignals(activity)
    }

    /**
     * Phase 7 / M1: additive, read-only Protection Health signals. Each
     * platform read that can fail or is unsupported reports null (UNKNOWN).
     */
    private fun healthSignals(activity: MainActivity): Map<String, Any?> {
        val sdk = Build.VERSION.SDK_INT
        val activityManager =
            activity.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        val powerManager =
            activity.getSystemService(Context.POWER_SERVICE) as? PowerManager
        return ProtectionHealthSignals.signals(
            accessibilityConnected = AccessibilityConnection.connected,
            shieldArmed = ProtectionHealthSignals.probe {
                ProtectionOverlayController.isArmed()
            },
            challengePending = ProtectionHealthSignals.probe {
                ProtectionStateStore.pendingChallenge(activity) != null
            },
            backgroundRestricted = ProtectionHealthSignals.backgroundRestricted(sdk) {
                if (sdk >= Build.VERSION_CODES.P) {
                    activityManager!!.isBackgroundRestricted
                } else {
                    throw IllegalStateException("unsupported")
                }
            },
            powerSaveMode = ProtectionHealthSignals.probe { powerManager!!.isPowerSaveMode },
            ignoringBatteryOptimizations = ProtectionHealthSignals.probe {
                powerManager!!.isIgnoringBatteryOptimizations(activity.packageName)
            },
            sdkInt = sdk,
        )
    }
}
