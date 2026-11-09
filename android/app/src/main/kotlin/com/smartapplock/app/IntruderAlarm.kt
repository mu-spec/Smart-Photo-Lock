package com.smartapplock.app

import android.app.NotificationManager
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.Looper

/**
 * Phase 12 / M2: the optional intruder alarm. A bounded ToneGenerator tone
 * on the NOTIFICATION stream, only while the challenge Activity is in the
 * foreground. It never changes volume, ringer mode or DND, holds transient
 * audio focus (and stops when focus is lost — e.g. an incoming call), and
 * stops on timeout, owner success, Activity pause/destroy, or process death
 * (no service, no persistence, no repeat). Main thread only.
 */
object IntruderAlarm {

    private val main = Handler(Looper.getMainLooper())
    private var tone: ToneGenerator? = null
    private var audioManager: AudioManager? = null
    private var focusRequest: AudioFocusRequest? = null
    private val stopRunnable = Runnable { stop() }

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change == AudioManager.AUDIOFOCUS_LOSS ||
            change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT ||
            change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK
        ) {
            main.post { stop() }
        }
    }

    val isPlaying: Boolean get() = tone != null

    fun start(context: Context, requestedMs: Long): String {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            ?: return "error"
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        val filterAll = nm == null ||
            nm.currentInterruptionFilter == NotificationManager.INTERRUPTION_FILTER_ALL
        val blocked = IntruderDefensePolicy.alarmBlockReason(
            alreadyPlaying = tone != null,
            activityResumed = ProtectionRuntime.activityResumed,
            interruptionFilterAll = filterAll,
            ringerNormal = am.ringerMode == AudioManager.RINGER_MODE_NORMAL,
        )
        if (blocked != null) return blocked
        if (!requestFocus(am)) return "focusDenied"
        val durationMs = IntruderDefensePolicy.clampAlarmMs(requestedMs)
        return try {
            // Volume 100 is RELATIVE to the user's current notification volume.
            val generator = ToneGenerator(AudioManager.STREAM_NOTIFICATION, 100)
            tone = generator
            audioManager = am
            if (!generator.startTone(ToneGenerator.TONE_CDMA_EMERGENCY_RINGBACK, durationMs.toInt())) {
                stop()
                return "error"
            }
            main.removeCallbacks(stopRunnable)
            main.postDelayed(stopRunnable, durationMs)
            "started"
        } catch (_: Exception) {
            stop()
            abandonFocus(am)
            "error"
        }
    }

    /** Idempotent. */
    fun stop() {
        main.removeCallbacks(stopRunnable)
        val generator = tone
        tone = null
        if (generator != null) {
            try {
                generator.stopTone()
            } catch (_: Exception) {
            }
            try {
                generator.release()
            } catch (_: Exception) {
            }
        }
        audioManager?.let { abandonFocus(it) }
        audioManager = null
    }

    private fun requestFocus(am: AudioManager): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_EVENT)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                .setOnAudioFocusChangeListener(focusListener, main)
                .build()
            focusRequest = request
            am.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            @Suppress("DEPRECATION")
            am.requestAudioFocus(
                focusListener,
                AudioManager.STREAM_NOTIFICATION,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT,
            ) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
    } catch (_: Exception) {
        false
    }

    private fun abandonFocus(am: AudioManager) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                focusRequest?.let { am.abandonAudioFocusRequest(it) }
                focusRequest = null
            } else {
                @Suppress("DEPRECATION")
                am.abandonAudioFocus(focusListener)
            }
        } catch (_: Exception) {
        }
    }
}
