package com.smartapplock.app

import android.app.AppOpsManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Build
import android.provider.Settings
import android.util.Base64
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

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
 *
 * Implementation note: the query pipeline is written as explicit loops
 * with fully-typed locals on purpose — no chained lambda forms — so the
 * file compiles cleanly across Kotlin compiler versions.
 */
object InstalledAppsChannel {

    /** Must match the Dart side of the bridge. */
    const val CHANNEL = "smart_app_lock/apps"

    /**
     * Phase 5A: how far back the usage-stats probe looks for the most
     * recently used app. Generous enough to survive polling gaps and OEM
     * throttling, short enough that stale entries cannot outlive a real
     * foreground switch.
     */
    const val FOREGROUND_LOOKBACK_WINDOW_MS = 60_000L

    fun register(engine: FlutterEngine, activity: MainActivity) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInstalledApps" -> {
                    try {
                        val includeSystemApps =
                            call.argument<Boolean>("includeSystemApps") ?: false
                        val apps = queryInstalledApps(
                            activity.packageManager,
                            activity.packageName,
                            includeSystemApps,
                        )
                        result.success(apps)
                    } catch (e: Exception) {
                        result.error(
                            "installed_apps_error",
                            "Failed to list installed apps: ${e.message}",
                            null,
                        )
                    }
                }
                "getAppIcon" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName == null) {
                        result.success(null)
                    } else {
                        try {
                            result.success(
                                loadAppIconPng(activity.packageManager, packageName),
                            )
                        } catch (e: Exception) {
                            result.success(null)
                        }
                    }
                }
                "hasUsageAccess" -> {
                    // Usage-access capability state (Phase 4B): answers
                    // true/false for the normal granted/not-granted states.
                    // The check itself is total — a platform quirk resolves
                    // to false (not granted) instead of failing the bridge.
                    try {
                        result.success(hasUsageAccess(activity))
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "requestUsageAccess" -> {
                    // Routes the user to the system Usage Access settings
                    // (the ONLY place the grant can be made). The helper
                    // already resolves to false when the intent cannot be
                    // started, so the Dart side never sees a crash here.
                    result.success(openUsageAccessSettings(activity))
                }
                "getForegroundPackage" -> {
                    // Phase 5A: the currently-foreground app resolved from
                    // the usage-stats backend. Total: returns null (unknown)
                    // when usage access is missing or the backend fails —
                    // detection is fail-closed, never fabricated.
                    try {
                        result.success(getForegroundPackage(activity))
                    } catch (e: Exception) {
                        result.success(null)
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
        val results = mutableListOf<Map<String, Any?>>()
        val packages: List<PackageInfo> = packageManager.getInstalledPackages(0)

        for (packageInfo in packages) {
            if (packageInfo.packageName == ownPackageName) {
                continue
            }
            // Launchable only: an app you can actually open (and lock).
            if (packageManager.getLaunchIntentForPackage(packageInfo.packageName) == null) {
                continue
            }
            // The SDK types this as nullable: a package with no resolvable
            // ApplicationInfo cannot be labeled or classified — skip it
            // safely instead of risking a null crash.
            val applicationInfo: ApplicationInfo? = packageInfo.applicationInfo
            if (applicationInfo == null) {
                continue
            }
            val isSystemApp: Boolean =
                (applicationInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0
            if (isSystemApp && !includeSystemApps) {
                continue
            }
            val label: String = applicationInfo.loadLabel(packageManager).toString()
            val versionName: String? = packageInfo.versionName
            results.add(
                mapOf(
                    "packageName" to packageInfo.packageName,
                    "label" to label,
                    "isSystemApp" to isSystemApp,
                    "versionName" to versionName,
                ),
            )
        }

        results.sortBy { entry ->
            val label = entry["label"] as String
            label.lowercase()
        }
        return results
    }

    /**
     * Renders the app's launcher icon into a 96x96 ARGB bitmap and returns
     * it as a base64-encoded PNG (NO_WRAP), or null when the system cannot
     * provide an icon.
     */
    fun loadAppIconPng(packageManager: PackageManager, packageName: String): String? {
        return try {
            val drawable = packageManager.getApplicationIcon(packageName)
            val bitmap = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            drawable.setBounds(0, 0, 96, 96)
            drawable.draw(canvas)
            val stream = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
            Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
        } catch (e: Exception) {
            null
        }
    }

    /**
     * True when the user has granted Usage Access to this app.
     *
     * The authoritative check is the AppOps state for OPSTR_GET_USAGE_STATS
     * — the OS grants it exclusively through the Usage Access settings
     * screen, and no manifest declaration can force it. The method is
     * TOTAL: a denied grant returns false (not an error), and any
     * platform quirk (OEM AppOps behavior, unexpected service state)
     * also resolves to false — the bridge never throws for a normal
     * not-granted state, and never uses an unsafe null assertion.
     */
    fun hasUsageAccess(context: Context): Boolean {
        return try {
            val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val uid = context.applicationInfo.uid
            val packageName = context.packageName
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                appOps.unsafeCheckOpNoThrow(
                    AppOpsManager.OPSTR_GET_USAGE_STATS,
                    uid,
                    packageName,
                )
            } else {
                @Suppress("DEPRECATION")
                appOps.checkOpNoThrow(
                    AppOpsManager.OPSTR_GET_USAGE_STATS,
                    uid,
                    packageName,
                )
            }
            mode == AppOpsManager.MODE_ALLOWED
        } catch (e: Exception) {
            false // fail-safe: treat as not granted; never crash the bridge
        }
    }

    /**
     * Phase 5A: the currently-foreground app, resolved from the
     * usage-stats backend (UsageStatsManager).
     *
     * The selected Play-compliant architecture polls the most recently
     * used launchable app over a short lookback window. The method is
     * TOTAL and fail-closed:
     *  * no Usage Access grant      -> null (the caller simply detects
     *    nothing; it must never fabricate a foreground app);
     *  * backend failure / empty    -> null;
     *  * this app's own package is never reported.
     *
     * The platform types queryUsageStats as a non-null list, but the
     * loop still guards defensively so OEM variants cannot crash it.
     */
    fun getForegroundPackage(context: Context): String? {
        if (!hasUsageAccess(context)) {
            return null
        }
        return try {
            val usageStats =
                context.getSystemService(Context.USAGE_STATS_SERVICE)
                    as UsageStatsManager
            val end = System.currentTimeMillis()
            val begin = end - FOREGROUND_LOOKBACK_WINDOW_MS
            val stats = usageStats.queryUsageStats(
                UsageStatsManager.INTERVAL_DAILY,
                begin,
                end,
            )
            var bestPackage: String? = null
            var bestTime = 0L
            for (stat in stats) {
                if (stat.packageName == context.packageName) {
                    continue
                }
                if (stat.lastTimeUsed <= 0L) {
                    continue
                }
                if (stat.lastTimeUsed > bestTime) {
                    bestTime = stat.lastTimeUsed
                    bestPackage = stat.packageName
                }
            }
            bestPackage
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Opens the system Usage Access settings screen (the ONLY place the
     * user can grant this special capability). Returns true when the
     * intent resolved and was started, false otherwise.
     */
    fun openUsageAccessSettings(context: Context): Boolean {
        return try {
            val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }
}
