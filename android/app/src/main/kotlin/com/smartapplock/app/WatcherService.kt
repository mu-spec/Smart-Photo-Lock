package com.smartapplock.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Log

/**
 * Native lifecycle/recovery watcher.
 *
 * Dart remains authoritative while its heartbeat is healthy. After process
 * death, isolate failure, or reboot, this service polls UsageEvents and also
 * accepts accessibility reports. A protected foreground package is covered
 * by the native shield before MainActivity rebuilds Flutter authentication.
 */
class WatcherService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var lastLaunchAttemptElapsedMs = 0L
    private var lastRecoveryPackage: String? = null

    private val poll = object : Runnable {
        override fun run() {
            if (!ProtectionStateStore.isEnabled(this@WatcherService)) {
                stopSelf()
                return
            }
            InstalledAppsChannel.getForegroundPackage(this@WatcherService)
                ?.let { handleForegroundPackage(it) }
            handler.postDelayed(this, POLL_INTERVAL_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = true
        activeInstance = this
        Log.d(TAG, "WatcherService.onCreate")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        handler.removeCallbacks(poll)
        handler.post(poll)
        Log.d(TAG, "Native protection watcher started")
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(poll)
        activeInstance = null
        running = false
        if (!ProtectionStateStore.isEnabled(this)) {
            ProtectionOverlayController.hide()
        }
        Log.d(TAG, "WatcherService destroyed")
        super.onDestroy()
    }

    private fun handleForegroundPackage(packageName: String) {
        if (packageName == applicationContext.packageName) return
        if (!ProtectionStateStore.isProtected(this, packageName)) {
            lastRecoveryPackage = null
            ProtectionStateStore.clearPendingChallenge(this)
            if (!ProtectionRuntime.isEngineHealthy()) {
                ProtectionOverlayController.hide()
            }
            return
        }
        if (ProtectionRuntime.isEngineHealthy()) return

        val now = SystemClock.elapsedRealtime()
        val retryDue = packageName != lastRecoveryPackage ||
            now - lastLaunchAttemptElapsedMs >= RECOVERY_RETRY_MS
        if (!retryDue) return
        lastRecoveryPackage = packageName
        lastLaunchAttemptElapsedMs = now
        ProtectionStateStore.setPendingChallenge(this, packageName)

        val shielded = ProtectionOverlayController.show(this)
        val launched = OverlayStatusChannel.launchLockChallenge(this)
        when {
            !shielded -> ProtectionStateStore.setLastError(
                this,
                "Overlay permission is unavailable; lock presentation is unavailable.",
            )
            !launched -> ProtectionStateStore.setLastError(
                this,
                "Android blocked the challenge activity; recovery shield remains active.",
            )
            else -> ProtectionStateStore.setLastError(this, null)
        }
    }

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "App protection",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Shows whether Smart App Lock protection is running."
                },
            )
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val text = if (ProtectionRuntime.isEngineHealthy()) {
            "Protection engine active"
        } else {
            "Protection recovery active"
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Smart App Lock")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .build()
    }

    private fun refreshNotification() {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, buildNotification())
    }

    companion object {
        private const val TAG = "SmartAppLockWatcher"
        private const val POLL_INTERVAL_MS = 1_000L
        private const val RECOVERY_RETRY_MS = 3_000L
        const val CHANNEL_ID = "smart_app_lock_watcher"
        const val NOTIFICATION_ID = 7

        @Volatile var running = false
            private set
        @Volatile private var activeInstance: WatcherService? = null

        fun start(context: Context): Boolean = try {
            val intent = Intent(context, WatcherService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
            true
        } catch (e: Exception) {
            ProtectionStateStore.setLastError(context, "Watcher start failed: ${e.message}")
            Log.w(TAG, "Could not start watcher", e)
            false
        }

        fun stop(context: Context): Boolean = try {
            ProtectionOverlayController.hide()
            context.stopService(Intent(context, WatcherService::class.java))
            true
        } catch (e: Exception) {
            Log.w(TAG, "Could not stop watcher", e)
            false
        }

        fun isRunning(): Boolean = running

        fun heartbeat() {
            ProtectionRuntime.heartbeat()
            activeInstance?.refreshNotification()
        }

        fun markEngineUnavailable() {
            ProtectionRuntime.markEngineUnavailable()
            activeInstance?.refreshNotification()
        }

        fun reportForeground(context: Context, packageName: String) {
            val instance = activeInstance
            if (instance != null) {
                instance.handleForegroundPackage(packageName)
            } else if (ProtectionStateStore.isEnabled(context)) {
                // Accessibility may be the only enabled detector. Do not drop
                // its first event while the sticky service is being recreated:
                // cover a protected app synchronously, persist the hand-off,
                // and then start the watcher for retries and health reporting.
                if (ProtectionStateStore.isProtected(context, packageName) &&
                    !ProtectionRuntime.isEngineHealthy()
                ) {
                    ProtectionStateStore.setPendingChallenge(context, packageName)
                    val shielded = ProtectionOverlayController.show(context)
                    val launched = OverlayStatusChannel.launchLockChallenge(context)
                    when {
                        !shielded -> ProtectionStateStore.setLastError(
                            context,
                            "Overlay permission is unavailable; lock presentation is unavailable.",
                        )
                        !launched -> ProtectionStateStore.setLastError(
                            context,
                            "Android blocked the challenge activity; recovery shield remains active.",
                        )
                        else -> ProtectionStateStore.setLastError(context, null)
                    }
                }
                start(context)
            }
        }
    }
}
