package com.smartapplock.app

/**
 * Phase 12 / M2: pure (Android-free) decisions for intruder evidence and the
 * alarm, so they are JVM-unit-testable. Nothing here can grant access; it
 * only decides whether a camera still or a tone MAY start.
 */
object IntruderDefensePolicy {

    const val MAX_WIDTH = 1280
    const val MIN_ALARM_MS = 1_000L
    const val MAX_ALARM_MS = 30_000L
    const val MIN_MAX_BYTES = 16 * 1024
    const val MAX_MAX_BYTES = 256 * 1024
    const val OPEN_TIMEOUT_MS = 4_000L
    const val CAPTURE_TIMEOUT_MS = 4_000L
    const val AE_SETTLE_MS = 700L

    /** JPEG re-encode qualities, tried in order until the image fits. */
    val QUALITY_LADDER = intArrayOf(80, 65, 50, 35)

    /**
     * Null when a capture may start, otherwise the failure code returned to
     * Dart. The camera is only ever used while the challenge Activity is in
     * the foreground (resumed) and the screen is on — never in background.
     */
    fun captureBlockReason(
        permissionGranted: Boolean,
        hasFrontCamera: Boolean,
        activityResumed: Boolean,
        interactive: Boolean,
        captureInFlight: Boolean,
    ): String? = when {
        !permissionGranted -> "permission"
        !hasFrontCamera -> "no_front_camera"
        !activityResumed -> "not_foreground"
        !interactive -> "screen_off"
        captureInFlight -> "busy"
        else -> null
    }

    /**
     * Null when the alarm may sound, otherwise the suppression reason
     * (names match Dart's AlarmStartResult). Do Not Disturb (any filter
     * other than ALL) and silent/vibrate ringer modes always win; the app
     * never changes volume, ringer or DND.
     */
    fun alarmBlockReason(
        alreadyPlaying: Boolean,
        activityResumed: Boolean,
        interruptionFilterAll: Boolean,
        ringerNormal: Boolean,
    ): String? = when {
        alreadyPlaying -> "alreadyPlaying"
        !activityResumed -> "notForeground"
        !interruptionFilterAll -> "suppressedByDnd"
        !ringerNormal -> "suppressedByRinger"
        else -> null
    }

    fun clampAlarmMs(ms: Long): Long = ms.coerceIn(MIN_ALARM_MS, MAX_ALARM_MS)

    fun clampMaxBytes(n: Int): Int = n.coerceIn(MIN_MAX_BYTES, MAX_MAX_BYTES)

    /**
     * The JPEG output size: the largest width <= [maxWidth]; when every size
     * is wider, the smallest available. Null when there are no sizes.
     */
    fun chooseSize(sizes: List<Pair<Int, Int>>, maxWidth: Int = MAX_WIDTH): Pair<Int, Int>? {
        val valid = sizes.filter { it.first > 0 && it.second > 0 }
        if (valid.isEmpty()) return null
        val fitting = valid.filter { it.first <= maxWidth }
        return if (fitting.isNotEmpty()) {
            fitting.maxWithOrNull(compareBy<Pair<Int, Int>> { it.first }.thenBy { it.second })
        } else {
            valid.minWithOrNull(compareBy<Pair<Int, Int>> { it.first }.thenBy { it.second })
        }
    }

    /**
     * Clockwise rotation to apply to sensor pixels so the stored image is
     * upright (Camera2 JPEG_ORIENTATION formula; front lens mirrors the
     * device rotation). Inputs are normalised to multiples of 90.
     */
    fun rotationDegrees(sensorOrientation: Int, deviceRotation: Int, frontFacing: Boolean): Int {
        val device = ((deviceRotation % 360 + 360) % 360 / 90) * 90
        val signed = if (frontFacing) -device else device
        return ((sensorOrientation + signed) % 360 + 360) % 360
    }

    /** Index of the first ladder quality whose size fits, or -1. */
    fun firstFitting(sizesByQuality: List<Int>, maxBytes: Int): Int =
        sizesByQuality.indexOfFirst { it in 1..maxBytes }
}
