package com.smartapplock.app

import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * MethodChannel bridge to the Android [PackageManager] (Phase 3A).
 *
 * Answers `getInstalledApps` with the apps that are **appropriate for App
 * Lock selection**:
 *
 *  * only *launchable* apps (they have a MAIN/LAUNCHER intent) — shell
 *    packages, widgets, and background services are excluded;
 *  * this app's own package is never returned;
 *  * system apps are included only when `includeSystemApps` is true;
 *  * each entry carries `packageName`, a user-facing `label`,
 *    `isSystemApp`, and `versionName`.
 *
 * The list is sorted by label (case-insensitive) before returning.
 */
object InstalledAppsChannel {

    /** Must match the Dart side of the bridge. */
    const val CHANNEL = "smart_app_lock/apps"

    fun register(engine: FlutterEngine, activity: MainActivity) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInstalledApps" -> {
                        try {
                            val includeSystemApps =
                                call.argument<Boolean>("includeSystemApps") ?: false
                            result.success(
                                queryInstalledApps(
                                    activity.packageManager,
                                    activity.packageName,
                                    includeSystemApps,
                                )
                            )
                        } catch (e: Exception) {
                            result.error(
                                "installed_apps_error",
                                "Failed to list installed apps: ${e.message}",
                                null,
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    fun queryInstalledApps(
        packageManager: PackageManager,
        ownPackageName: String,
        includeSystemApps: Boolean,
    ): List<Map<String, Any?>> {
        return packageManager.getInstalledPackages(0)
            .asSequence()
            .filter { it.packageName != ownPackageName }
            .filter { package ->
                // Launchable only: an app you can actually open (and lock).
                packageManager.getLaunchIntentForPackage(package.packageName) != null
            }
            .filter { package ->
                val isSystem =
                    (package.applicationInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0
                includeSystemApps || !isSystem
            }
            .map { package ->
                val appInfo = package.applicationInfo
                val isSystem =
                    (appInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0
                mapOf(
                    "packageName" to package.packageName,
                    "label" to appInfo.loadLabel(packageManager).toString(),
                    "isSystemApp" to isSystem,
                    "versionName" to package.versionName,
                )
            }
            .sortedBy { (it["label"] as String).lowercase() }
            .toList()
    }
}
