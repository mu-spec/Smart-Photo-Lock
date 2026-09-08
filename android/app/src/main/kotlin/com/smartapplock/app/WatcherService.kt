package com.smartapplock.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Log

enum class ForegroundSource { ACCESSIBILITY, USAGE_EVENTS }

/**
 * Native foreground detector and fail-closed presentation coordinator.
 *
 * Accessibility reports are enforced synchronously even while Dart is
 * healthy. UsageEvents remains a slower recovery fallback. Dart owns the
 * credential challenge and is the only component allowed to grant a native
 * package authorization after explicit authentication success.
 */
class WatcherService : Service() {
    private val handler = Handler(Looper.getMainLooper())

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    ProtectionAccessState.revokeAll()
                    val foreground = ProtectionAccessState.currentForegroundPackage()
                    if (foreground != null &&
                        ProtectionStateStore.isProtected(context, foreground)
                    ) {
                        resetRecovery(foreground)
                        ProtectionStateStore.setPendingChallenge(context, foreground)
                        ProtectionOverlayController.show(context)
                    }
                }
                Intent.ACTION_SCREEN_ON -> {
                    val pending = ProtectionStateStore.pendingChallenge(context)
                    if (pending != null &&
                        ProtectionStateStore.isProtected(context, pending)
                    ) {
                        recoverProtected(context, pending)
                    }
                }
            }
        }
    }

    private val poll = object : Runnable {
        override fun run() {
            if (!ProtectionStateStore.isEnabled(this@WatcherService)) {
                stopSelf()
                return
            }
            InstalledAppsChannel.getForegroundPackage(this@WatcherService)
                ?.let {
                    reportForeground(
                        this@WatcherService,
                        it,
                        ForegroundSource.USAGE_EVENTS,
                    )
                }
            handler.postDelayed(this, POLL_INTERVAL_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = true
        activeInstance = this
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(screenReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(screenReceiver, filter)
        }
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
        // Keep an invisible, full-size overlay attached. Making it opaque on
        // the first Accessibility callback is shorter than adding/resizing a
        // new window after the protected activity is already drawing.
        ProtectionOverlayController.arm(this)
        handler.removeCallbacks(poll)
        handler.post(poll)
        Log.d(TAG, "Native protection watcher started")
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(poll)
        try {
            unregisterReceiver(screenReceiver)
        } catch (_: IllegalArgumentException) {
            // Already unregistered during teardown.
        }
        activeInstance = null
        running = false
        if (!ProtectionStateStore.isEnabled(this)) {
            ProtectionOverlayController.disarm()
        }
        Log.d(TAG, "WatcherService destroyed")
        super.onDestroy()
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
        private const val ACCESSIBILITY_AUTHORITY_MS = 5_000L
        const val CHANNEL_ID = "smart_app_lock_watcher"
        const val NOTIFICATION_ID = 7

        @Volatile var running = false
            private set
        @Volatile private var activeInstance: WatcherService? = null
        @Volatile private var lastAccessibilityElapsedMs = 0L
        @Volatile private var lastLaunchAttemptElapsedMs = 0L
        @Volatile private var lastRecoveryPackage: String? = null

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
            ProtectionAccessState.revokeAll()
            ProtectionOverlayController.disarm()
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

        fun reportForeground(
            context: Context,
            packageName: String,
            source: ForegroundSource = ForegroundSource.ACCESSIBILITY,
        ) {
            if (!ProtectionStateStore.isEnabled(context) ||
                packageName == context.packageName
            ) {
                return
            }
            val now = SystemClock.elapsedRealtime()
            if (source == ForegroundSource.ACCESSIBILITY) {
                lastAccessibilityElapsedMs = now
            } else if (lastAccessibilityElapsedMs > 0L &&
                now - lastAccessibilityElapsedMs < ACCESSIBILITY_AUTHORITY_MS
            ) {
                // A UsageEvents result is historical. It must never override
                // or hide a shield raised by a fresh Accessibility event.
                return
            }

            val protected = ProtectionStateStore.isProtected(context, packageName)
            val decision = ProtectionAccessState.observeForeground(
                packageName = packageName,
                protected = protected,
                nowElapsedMs = now,
            )
            if (!protected || decision == ProtectionAccessState.Decision.ALLOW) {
                resetRecovery()
                // Pending is also the overlay's fail-closed latch. Only the
                // rendered challenge hand-off or explicit authorization may
                // clear it.
                if (ProtectionStateStore.pendingChallenge(context) == null) {
                    ProtectionOverlayController.hide()
                }
            } else {
                // Do not trust a healthy heartbeat for presentation timing:
                // a healthy isolate can still be backgrounded behind the app
                // Android is currently drawing.
                recoverProtected(context, packageName)
            }

            if (!isRunning()) start(context)
        }

        fun setGracePeriod(milliseconds: Long) {
            ProtectionAccessState.setGracePeriod(milliseconds)
        }

        fun authorizePackage(
            context: Context,
            packageName: String,
            sessionWindowMs: Long,
        ): Boolean {
            if (!ProtectionStateStore.isProtected(context, packageName)) return false
            val pending = ProtectionStateStore.pendingChallenge(context)
            if (pending != null && pending != packageName) {
                // A newer protected foreground replaced this challenge. An
                // older route completing successfully must not authorize or
                // launch the package that is no longer being challenged.
                return false
            }
            ProtectionAccessState.authorize(packageName, sessionWindowMs)
            ProtectionStateStore.clearPendingChallenge(context, packageName)
            resetRecovery(packageName)
            return true
        }

        fun revokeAllAuthorizations() {
            ProtectionAccessState.revokeAll()
        }

        @Synchronized
        private fun recoverProtected(context: Context, packageName: String) {
            val now = SystemClock.elapsedRealtime()
            val retryDue = packageName != lastRecoveryPackage ||
                now - lastLaunchAttemptElapsedMs >= RECOVERY_RETRY_MS
            if (!retryDue) return
            lastRecoveryPackage = packageName
            lastLaunchAttemptElapsedMs = now
            ProtectionStateStore.setPendingChallenge(context, packageName)

            // Security-critical order: shield first, activity hand-off second.
            val shielded = ProtectionOverlayController.show(context)
            val launched = shielded && OverlayStatusChannel.launchLockChallenge(context)
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

        @Synchronized
        private fun resetRecovery(packageName: String? = null) {
            if (packageName == null || packageName == lastRecoveryPackage) {
                lastRecoveryPackage = null
                lastLaunchAttemptElapsedMs = 0L
            }
        }
    }
}
