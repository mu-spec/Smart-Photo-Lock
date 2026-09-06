package com.smartapplock.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/** Restarts only previously configured protection after an unlocked boot. */
class ProtectionBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Intent.ACTION_BOOT_COMPLETED) return
        if (!ProtectionStateStore.isEnabled(context)) return
        if (!WatcherService.start(context)) {
            ProtectionStateStore.setLastError(
                context,
                "Protection service could not restart after boot.",
            )
            Log.w(TAG, "Boot recovery could not start WatcherService")
        }
    }

    companion object {
        private const val TAG = "SmartAppLockBoot"
    }
}
