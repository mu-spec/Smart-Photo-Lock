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

    private val recoveryRetry = object : Runnable {
        override fun run() {
            if (isSafeExitInProgress()) {
                handler.postDelayed(this, RECOVERY_RETRY_MS)
                return
            }
            val pending = ProtectionStateStore.pendingChallenge(this@WatcherService)
            if (pending == null ||
                !ProtectionStateStore.isProtected(
                    this@WatcherService,
                    pending.packageName,
                )
            ) {
                resetRecovery()
                return
            }
            recoverProtected(
                this@WatcherService,
                pending.packageName,
                WakeRecoverySignal.RETRY,
            )
            scheduleRecoveryRetry()
        }
    }

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    recoveryGate.onScreenOff()
                    activeInstance?.cancelRecoveryRetry()
                    ProtectionRuntime.invalidateChallengeHandoff()
                    ProtectionAccessState.revokeAll()
                    val foreground = ProtectionAccessState.currentForegroundPackage()
                    if (foreground != null &&
                        ProtectionStateStore.isProtected(context, foreground)
                    ) {
                        resetRecovery(foreground)
                        // A fresh generation makes every callback created
                        // before screen-off stale, even for the same package.
                        ProtectionStateStore.replacePendingChallenge(
                            context,
                            foreground,
                        )
                        ProtectionOverlayController.show(context)
                    }
                }
                Intent.ACTION_SCREEN_ON -> {
                    val pending = ProtectionStateStore.pendingChallenge(context)
                    if (pending != null &&
                        ProtectionStateStore.isProtected(context, pending.packageName)
                    ) {
                        recoverProtected(
                            context,
                            pending.packageName,
                            WakeRecoverySignal.SCREEN_ON,
                        )
                    }
                }
                Intent.ACTION_USER_PRESENT -> {
                    val pending = ProtectionStateStore.pendingChallenge(context)
                    if (pending != null &&
                        ProtectionStateStore.isProtected(context, pending.packageName)
                    ) {
                        // SCREEN_ON usually occurs behind keyguard. This is a
                        // distinct forced attempt after the user unlocks it.
                        recoverProtected(
                            context,
                            pending.packageName,
                            WakeRecoverySignal.USER_PRESENT,
                        )
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
            addAction(Intent.ACTION_USER_PRESENT)
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
        ProtectionStateStore.pendingChallenge(this)?.let { pending ->
            ProtectionOverlayController.show(this)
            recoverProtected(
                this,
                pending.packageName,
                WakeRecoverySignal.RETRY,
            )
        }
        handler.removeCallbacks(poll)
        handler.post(poll)
        Log.d(TAG, "Native protection watcher started")
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(poll)
        handler.removeCallbacks(recoveryRetry)
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

    private fun scheduleRecoveryRetry() {
        handler.removeCallbacks(recoveryRetry)
        if (ProtectionStateStore.pendingChallenge(this) != null) {
            handler.postDelayed(recoveryRetry, RECOVERY_RETRY_MS)
        }
    }

    private fun cancelRecoveryRetry() {
        handler.removeCallbacks(recoveryRetry)
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
        private val recoveryGate = WakeRecoveryGate(RECOVERY_RETRY_MS)
        @Volatile private var safeExitChallenge: ProtectionStateStore.PendingChallenge? = null
        @Volatile private var safeExitHomePackage: String? = null

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
            ProtectionRuntime.invalidateChallengeHandoff()
            ProtectionStateStore.clearPendingChallenge(context)
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
            if (completeSafeExitIfConfirmed(context, packageName)) return
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
                if (isSafeExitInProgress()) return
                // Do not trust a healthy heartbeat for presentation timing:
                // a healthy isolate can still be backgrounded behind the app
                // Android is currently drawing.
                recoverProtected(
                    context,
                    packageName,
                    WakeRecoverySignal.FOREGROUND,
                )
            }

            if (!isRunning()) start(context)
        }

        fun setGracePeriod(milliseconds: Long) {
            ProtectionAccessState.setGracePeriod(milliseconds)
        }

        fun authorizePackage(
            context: Context,
            packageName: String,
            generation: Long,
            sessionWindowMs: Long,
        ): Boolean {
            if (!ProtectionStateStore.isProtected(context, packageName)) return false
            val pending = ProtectionStateStore.pendingChallenge(context)
            if (pending != null &&
                (pending.packageName != packageName || pending.generation != generation)
            ) {
                // A newer protected foreground replaced this challenge. An
                // older route completing successfully must not authorize or
                // launch the package that is no longer being challenged.
                return false
            }
            if (!ProtectionRuntime.consumeChallengeHandoff(packageName, generation)) {
                // Authentication from a route that was never handed visible
                // coverage, or was invalidated by screen-off, cannot grant.
                return false
            }
            ProtectionAccessState.authorize(packageName, sessionWindowMs)
            ProtectionStateStore.clearPendingChallenge(
                context,
                packageName,
                generation,
            )
            resetRecovery(packageName)
            return true
        }

        fun revokeAllAuthorizations() {
            ProtectionAccessState.revokeAll()
        }

        @Synchronized
        private fun recoverProtected(
            context: Context,
            packageName: String,
            signal: WakeRecoverySignal,
        ) {
            val now = SystemClock.elapsedRealtime()
            if (!recoveryGate.shouldAttempt(packageName, signal, now)) {
                activeInstance?.scheduleRecoveryRetry()
                return
            }
            ProtectionStateStore.ensurePendingChallenge(context, packageName)

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
            activeInstance?.scheduleRecoveryRetry()
        }

        @Synchronized
        private fun resetRecovery(packageName: String? = null) {
            recoveryGate.reset(packageName)
            if (ProtectionStateStore.pendingChallenge(
                    activeInstance ?: return,
                ) == null
            ) {
                activeInstance?.cancelRecoveryRetry()
            }
        }

        fun onChallengeHandoffComplete() {
            recoveryGate.reset()
            activeInstance?.cancelRecoveryRetry()
        }

        fun onChallengeHandoffFailed(context: Context, packageName: String) {
            ProtectionRuntime.invalidateChallengeHandoff()
            ProtectionStateStore.replacePendingChallenge(context, packageName)
            recoveryGate.reset(packageName)
            recoverProtected(
                context,
                packageName,
                WakeRecoverySignal.FOREGROUND,
            )
        }

        fun onChallengeActivityAvailable(context: Context) {
            val pending = ProtectionStateStore.pendingChallenge(context) ?: return
            if (!ProtectionStateStore.isProtected(context, pending.packageName)) return
            ProtectionOverlayController.show(context)
            activeInstance?.scheduleRecoveryRetry()
        }

        /**
         * Leaves a recovery shield for the system launcher without granting
         * the protected package. The shield is removed only after a detector
         * confirms that the requested Home package is actually foreground.
         */
        @Synchronized
        fun requestSafeExitToHome(context: Context): Boolean {
            val pending = ProtectionStateStore.pendingChallenge(context) ?: return false
            val homeIntent = Intent(Intent.ACTION_MAIN).apply {
                addCategory(Intent.CATEGORY_HOME)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            val homePackage = try {
                context.packageManager.resolveActivity(homeIntent, 0)
                    ?.activityInfo?.packageName
            } catch (_: Exception) {
                null
            } ?: return false
            if (ProtectionStateStore.isProtected(context, homePackage)) return false

            safeExitChallenge = pending
            safeExitHomePackage = homePackage
            activeInstance?.cancelRecoveryRetry()
            return try {
                context.startActivity(homeIntent)
                true
            } catch (_: Exception) {
                safeExitChallenge = null
                safeExitHomePackage = null
                activeInstance?.scheduleRecoveryRetry()
                false
            }
        }

        private fun isSafeExitInProgress(): Boolean = safeExitChallenge != null

        @Synchronized
        private fun completeSafeExitIfConfirmed(
            context: Context,
            foregroundPackage: String,
        ): Boolean {
            val pending = safeExitChallenge ?: return false
            if (safeExitHomePackage != foregroundPackage) return false
            val cleared = ProtectionStateStore.clearPendingChallenge(
                context,
                pending.packageName,
                pending.generation,
            )
            if (!cleared) {
                safeExitChallenge = null
                safeExitHomePackage = null
                return false
            }
            safeExitChallenge = null
            safeExitHomePackage = null
            ProtectionRuntime.invalidateChallengeHandoff()
            recoveryGate.reset()
            activeInstance?.cancelRecoveryRetry()
            ProtectionOverlayController.hide()
            return true
        }
    }
}
