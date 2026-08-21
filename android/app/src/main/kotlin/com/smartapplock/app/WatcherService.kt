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
import android.os.IBinder
import android.util.Log

/**
 * Phase 5 mobile-QA fix: the watcher foreground service.
 *
 * The lock engine (usage-stats polling, the accessibility event
 * listener, the lock trigger and the challenge host) lives in the
 * Flutter isolate. When Smart App Lock is backgrounded, Android freezes
 * or kills that isolate — detection stops and protected apps open with
 * no challenge. This service is the fix: while it runs, the process
 * stays alive, so
 *
 *  * the Dart polling timers keep running,
 *  * the accessibility EventChannel listener stays attached,
 *  * and presenting the challenge (startActivity with
 *    SYSTEM_ALERT_WINDOW granted) is exempt from Android 10+
 *    background-activity-launch restrictions.
 *
 * It performs NO work of its own — it is a lifecycle anchor for the
 * Dart-side pipeline (foregroundServiceType `specialUse` per the
 * capabilities document).
 */
class WatcherService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "WatcherService.onCreate")
        running = true
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
        Log.d(TAG, "WatcherService started in the foreground")
        return START_STICKY
    }

    override fun onDestroy() {
        Log.d(TAG, "WatcherService destroyed")
        running = false
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            val channel = NotificationChannel(
                CHANNEL_ID,
                "App protection",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description =
                    "Keeps detection active while Smart App Lock is in the background."
            }
            manager.createNotificationChannel(channel)
        }

        val launchIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE,
        )

        val builder: Notification.Builder =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }
        return builder
            .setContentTitle("Smart App Lock")
            .setContentText("Protection is active — protected apps are locked.")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(pendingIntent)
            .build()
    }

    companion object {
        private const val TAG = "SmartAppLockWatcher"

        /** Must match the Dart side of the bridge. */
        const val CHANNEL_ID = "smart_app_lock_watcher"
        const val NOTIFICATION_ID = 7

        @Volatile
        var running = false
            private set

        /** Starts the foreground watcher. Total: false when the platform
         * refuses (never crashes the bridge). */
        fun start(context: Context): Boolean {
            return try {
                val intent = Intent(context, WatcherService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                true
            } catch (e: Exception) {
                Log.w(TAG, "Could not start the watcher: ${e.message}")
                false
            }
        }

        /** Stops the foreground watcher. Total. */
        fun stop(context: Context): Boolean {
            return try {
                context.stopService(Intent(context, WatcherService::class.java))
                true
            } catch (e: Exception) {
                Log.w(TAG, "Could not stop the watcher: ${e.message}")
                false
            }
        }

        fun isRunning(): Boolean = running
    }
}
