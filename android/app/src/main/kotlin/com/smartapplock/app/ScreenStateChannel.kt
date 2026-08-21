package com.smartapplock.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

/**
 * Phase 5K: screen-state bridge — re-lock when the screen turns off.
 *
 * Relays `ACTION_SCREEN_OFF` / `ACTION_SCREEN_ON` to Dart through an
 * EventChannel. The receiver is registered at RUNTIME while a Dart
 * listener is attached (these broadcasts cannot be received through a
 * manifest-registered receiver) and unregistered on cancel.
 *
 * Why not lifecycle pauses? When Smart App Lock launches a protected
 * app after a successful unlock, the activity itself is paused — a
 * lifecycle-based "re-lock on pause" would revoke every fresh session
 * instantly. The screen-state broadcast distinguishes a real screen-off
 * from the app simply being covered.
 */
object ScreenStateChannel {

    /** Must match the Dart side of the bridge. */
    const val CHANNEL = "smart_app_lock/screen_state"

    fun register(engine: FlutterEngine, activity: MainActivity) {
        val channel = EventChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setStreamHandler(
            object : EventChannel.StreamHandler {
                private var receiver: BroadcastReceiver? = null

                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    if (receiver != null) {
                        return // already listening
                    }
                    val newReceiver = object : BroadcastReceiver() {
                        override fun onReceive(context: Context?, intent: Intent?) {
                            when (intent?.action) {
                                Intent.ACTION_SCREEN_OFF -> events?.success("screen_off")
                                Intent.ACTION_SCREEN_ON -> events?.success("screen_on")
                            }
                        }
                    }
                    val filter = IntentFilter().apply {
                        addAction(Intent.ACTION_SCREEN_OFF)
                        addAction(Intent.ACTION_SCREEN_ON)
                    }
                    receiver = newReceiver
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        activity.registerReceiver(
                            newReceiver,
                            filter,
                            Context.RECEIVER_NOT_EXPORTED,
                        )
                    } else {
                        @Suppress("UnspecifiedRegisterReceiverFlag")
                        activity.registerReceiver(newReceiver, filter)
                    }
                }

                override fun onCancel(arguments: Any?) {
                    val active = receiver
                    receiver = null
                    if (active != null) {
                        try {
                            activity.unregisterReceiver(active)
                        } catch (e: IllegalArgumentException) {
                            // Already unregistered (e.g. activity teardown).
                        }
                    }
                }
            },
        )
    }
}
