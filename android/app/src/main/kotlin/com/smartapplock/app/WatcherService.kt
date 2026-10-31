package com.smartapplock.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
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
                    // A new screen cycle supersedes any older Home escape;
                    // its fresh pending generation must remain shielded.
                    abortSafeExit()
                    ProtectionRuntime.invalidateChallengeHandoff()
                    ProtectionAccessState.revokeAll()
                    val observed = ProtectionAccessState.currentForegroundPackage()
                    val wakePackage = WakeReauthTargetPolicy.resolve(
                        observedPackage = observed,
                        rememberedPackage = ProtectionStateStore.wakeReauthPackage(context),
                    ) { ProtectionStateStore.isProtected(context, it) }
                    Log.d(
                        TAG,
                        "SCREEN_OFF observed=$observed wakePackage=$wakePackage",
                    )
                    if (wakePackage != null) {
                        ProtectionStateStore.rememberWakeReauthPackage(
                            context,
                            wakePackage,
                        )
                        resetRecovery(wakePackage)
                        // A fresh generation makes every callback created
                        // before screen-off stale, even for the same package.
                        ProtectionStateStore.replacePendingChallenge(
                            context,
                            wakePackage,
                        )
                        ProtectionOverlayController.show(context)
                    }
                }
                Intent.ACTION_SCREEN_ON -> {
                    val pending = ProtectionStateStore.restoreWakeReauthChallenge(context)
                    Log.d(TAG, "SCREEN_ON pending=$pending")
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
                    val pending = ProtectionStateStore.restoreWakeReauthChallenge(context)
                    Log.d(TAG, "USER_PRESENT pending=$pending")
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
        // F3: a fresh process with no ticket may still have the protected
        // app on screen (death during authorized use, or a screen cycle
        // missed while dead). One fail-closed decision per process.
        restoreAfterProcessRestartIfNeeded(this)
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
        // This is only a bounded launcher/task-transition coordination window.
        // It is never treated as authentication or protected-app authorization.
        private const val SAFE_EXIT_COORDINATION_MS = 1_500L
        const val CHANNEL_ID = "smart_app_lock_watcher"
        const val NOTIFICATION_ID = 7

        @Volatile var running = false
            private set
        @Volatile private var activeInstance: WatcherService? = null
        @Volatile private var lastAccessibilityElapsedMs = 0L
        private val recoveryGate = WakeRecoveryGate(RECOVERY_RETRY_MS)
        private val safeExitGate = SafeExitGate()
        private val safeExitHandler = Handler(Looper.getMainLooper())
        private var safeExitTimeout: Runnable? = null
        // H-1 F1: a possible leave reported while the challenge Activity was
        // still resumed; confirmed only by the matching onPause.
        @Volatile private var abandonCandidate: ChallengeAbandonCandidate? = null
        // F3: the companion is process-scoped, so this latch admits exactly
        // one restart decision per process (sticky restart, a11y rebind, boot
        // or Dart start, whichever reaches onStartCommand first).
        private val restartRecoveryLatch = OneShotLatch()

        /**
         * F3 restart restore. Never authorizes, never replaces an existing
         * ticket (screen-off/wake tickets keep their generation), and only
         * creates a fresh-generation ticket behind an opaque shield; the
         * shield hides only after the exact ready handoff. Errors never
         * escape: a crash loop here would stop Android restarting us.
         */
        private fun restoreAfterProcessRestartIfNeeded(context: Context) {
            if (!restartRecoveryLatch.tryAcquire()) return
            try {
                val nowElapsed = SystemClock.elapsedRealtime()
                val nowWall = System.currentTimeMillis()
                val enabled = ProtectionStateStore.isEnabled(context)
                val pendingExists = ProtectionStateStore.pendingChallenge(context) != null
                val uiResumed = ProtectionRuntime.activityResumed
                val remembered = ProtectionStateStore.rememberedWakeIdentity(context)
                val sameBoot = remembered != null && WakeIdentityBootScope.sameBoot(
                    storedBootCount = remembered.bootCount,
                    currentBootCount = ProtectionStateStore.currentBootCount(context),
                    storedElapsedMs = remembered.stampElapsedMs,
                    storedWallMs = remembered.stampWallMs,
                    nowElapsedMs = nowElapsed,
                    nowWallMs = nowWall,
                )
                val clockConsistent = remembered != null &&
                    WakeIdentityBootScope.wallClockConsistent(
                        storedElapsedMs = remembered.stampElapsedMs,
                        storedWallMs = remembered.stampWallMs,
                        nowElapsedMs = nowElapsed,
                        nowWallMs = nowWall,
                    )
                // UsageEvents is queried only when it can change the outcome.
                val evidence = if (enabled && !pendingExists && !uiResumed) {
                    InstalledAppsChannel.restartForegroundEvidence(
                        context,
                        nowWallMs = nowWall,
                        nowElapsedMs = nowElapsed,
                        imePackage = defaultInputMethodPackage(context),
                    )
                } else {
                    ForegroundEvidence.Unknown
                }
                val result = RestartRecoveryPolicy.decide(
                    RestartRecoveryInput(
                        protectionEnabled = enabled,
                        pendingExists = pendingExists,
                        uiActivityResumed = uiResumed,
                        rememberedPackage = remembered?.packageName,
                        rememberedSameBoot = sameBoot,
                        rememberedStampWallMs = remembered?.stampWallMs,
                        wallClockConsistent = clockConsistent,
                        evidence = evidence,
                    ),
                ) { ProtectionStateStore.isProtected(context, it) }
                // Diagnostics: the decision only, never package names.
                Log.d(TAG, "Restart recovery decision=${result.decision}")
                val target = result.targetPackage ?: return
                val ticket = ProtectionStateStore.createRestartRecoveryChallenge(
                    context,
                    target,
                ) ?: return
                ProtectionStateStore.rememberWakeReauthPackage(context, ticket.packageName)
                ProtectionOverlayController.show(context)
                recoverProtected(context, ticket.packageName, WakeRecoverySignal.RETRY)
            } catch (e: Exception) {
                Log.w(TAG, "Restart recovery failed: ${e.javaClass.simpleName}")
                try {
                    // Fail closed: a persisted ticket keeps the shield and
                    // the bounded recovery retry.
                    if (ProtectionStateStore.pendingChallenge(context) != null) {
                        ProtectionOverlayController.show(context)
                        activeInstance?.scheduleRecoveryRetry()
                    }
                } catch (inner: Exception) {
                    Log.w(TAG, "Restart recovery fallback failed: ${inner.javaClass.simpleName}")
                }
            }
        }

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
            abortSafeExit()
            ProtectionAccessState.revokeAll()
            ProtectionRuntime.invalidateChallengeHandoff()
            ProtectionStateStore.clearPendingChallenge(context)
            ProtectionStateStore.rememberWakeReauthPackage(context, null)
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

        private fun isScreenInteractive(context: Context): Boolean =
            (context.getSystemService(Context.POWER_SERVICE) as? PowerManager)
                ?.isInteractive == true

        fun reportForeground(
            context: Context,
            packageName: String,
            source: ForegroundSource = ForegroundSource.ACCESSIBILITY,
            // F4 P1: Accessibility event class. Native memory only; it is
            // never logged, persisted or forwarded to Dart.
            windowClass: String? = null,
        ) {
            if (!ProtectionStateStore.isEnabled(context) ||
                packageName == context.packageName
            ) {
                return
            }
            if (completeSafeExitIfConfirmed(context, packageName)) return
            if (isSafeExitInProgress()) {
                val request = safeExitGate.request()
                val current = ProtectionStateStore.pendingChallenge(context)
                if (request != null && current == request.challenge) {
                    // Until exact Home confirmation or the bounded fallback,
                    // every non-Home report keeps the opaque shield in place.
                    // In particular, a stale protected-app report cannot
                    // expose content while the user is escaping.
                    if (packageName != request.homePackage) return
                } else {
                    // A newer generation wins over the old escape request.
                    abortSafeExit()
                }
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
            val pending = ProtectionStateStore.pendingChallenge(context)
            val wakeReauthPackage = ProtectionStateStore.wakeReauthPackage(context)
            val screenInteractive = isScreenInteractive(context)
            if (!protected &&
                ScreenOffForegroundPolicy.shouldPreservePending(
                    screenInteractive = screenInteractive,
                    pending = pending,
                    wakeReauthPackage = wakeReauthPackage,
                )
            ) {
                // During the display-off transition, launcher/recents may be
                // reported before ACTION_SCREEN_OFF reaches this service. Do
                // not interpret that report as a completed Home escape: the
                // unresolved protected ticket must survive until the screen
                // receiver replaces it with the fresh wake generation.
                if (pending != null && wakeReauthPackage == null) {
                    ProtectionStateStore.rememberWakeReauthPackage(
                        context,
                        pending.packageName,
                    )
                }
                ProtectionRuntime.invalidateChallengeHandoff()
                ProtectionAccessState.revokeAll()
                return
            }
            if (protected) {
                cancelChallengeAbandonCandidate()
                ProtectionStateStore.rememberWakeReauthPackage(context, packageName)
            } else {
                // H-1: System UI, framework and keyboard windows report a
                // package without the user leaving. They prove nothing.
                val transient = ChallengeAbandonPolicy.isTransientWindow(
                    packageName,
                    defaultInputMethodPackage(context),
                )
                // F4 P1: an overlay, dialog or unresolved window proves no
                // leave either. Only Home, a UsageEvents resume or a resolved
                // Activity of this package is a genuine leave. This affects
                // F1/F2 only; observeForeground below still runs.
                val provesNothing = transient || WindowLeavePolicy.provesNothing(
                    transient = false,
                    kind = foregroundWindowKind(context, packageName, source, windowClass),
                )
                // F2: keep the wake identity across transient windows so
                // SCREEN_OFF still knows which protected app needs re-auth.
                if (ChallengeAbandonPolicy.mayForgetWakeIdentity(
                        protectedTarget = false,
                        transient = provesNothing,
                    )
                ) {
                    ProtectionStateStore.rememberWakeReauthPackage(context, null)
                }
                // F1: Home/Recents may abandon a rendered challenge, but only
                // a confirmed genuine leave clears it; this grants no access.
                ProtectionRuntime.readyChallenge()?.let { ready ->
                    when (
                        ChallengeAbandonPolicy.readyTicketAction(
                            protectedTarget = false,
                            transient = provesNothing,
                            challengeActivityResumed = ProtectionRuntime.activityResumed,
                            screenInteractive = screenInteractive,
                        )
                    ) {
                        ReadyTicketAction.ABANDON -> abandonReadyChallenge(context, ready)
                        ReadyTicketAction.DEFER -> recordChallengeAbandonCandidate(
                            ChallengeAbandonCandidate(ready, packageName, now),
                        )
                        ReadyTicketAction.KEEP -> Unit
                    }
                }
            }
            val decision = ProtectionAccessState.observeForeground(
                packageName = packageName,
                protected = protected,
                nowElapsedMs = now,
            )
            if (!protected || decision == ProtectionAccessState.Decision.ALLOW) {
                resetRecovery()
                // Pending represents unresolved authentication. An
                // unprotected transition may cancel it above; otherwise only
                // exact successful authorization clears it.
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
                ?: return false
            if (pending.packageName != packageName || pending.generation != generation) {
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
            ProtectionStateStore.rememberWakeReauthPackage(context, packageName)
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
            val pending = ProtectionStateStore.ensurePendingChallenge(context, packageName)

            // Duplicate detector events must not re-cover or re-promote an
            // exact rendered challenge. Screen-off invalidates ready state
            // and replaces the generation before reaching recovery.
            if (ProtectionRuntime.activityResumed &&
                ProtectionRuntime.isChallengeReady(pending)
            ) {
                return
            }

            // Security-critical order: shield first, activity hand-off second.
            val shielded = ProtectionOverlayController.show(context)
            val launched = shielded &&
                MainActivity.foregroundForRecovery(context, pending)
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
         * H-1 F1: `MainActivity.onPause`. A leave reported while the challenge
         * Activity was still resumed (event-order race) is confirmed here only
         * for the exact still-ready ticket within the bounded window. Every
         * other outcome keeps the ticket.
         */
        @Synchronized
        fun onChallengeActivityPaused(context: Context) {
            val candidate = abandonCandidate ?: return
            abandonCandidate = null
            if (!ProtectionStateStore.isEnabled(context)) return
            if (!ChallengeAbandonPolicy.confirmsDeferred(
                    candidate = candidate,
                    ready = ProtectionRuntime.readyChallenge(),
                    pending = ProtectionStateStore.pendingChallenge(context),
                    challengeActivityResumed = ProtectionRuntime.activityResumed,
                    screenInteractive = isScreenInteractive(context),
                    nowElapsedMs = SystemClock.elapsedRealtime(),
                )
            ) {
                return
            }
            abandonReadyChallenge(context, candidate.ticket)
            // Same follow-up as an immediate unprotected leave in
            // reportForeground: stop recovery, release only an orphan shield.
            resetRecovery()
            if (ProtectionStateStore.pendingChallenge(context) == null) {
                ProtectionOverlayController.hide()
            }
        }

        /** Exact clear of an abandoned rendered ticket; never an authorization. */
        @Synchronized
        private fun abandonReadyChallenge(
            context: Context,
            ready: ProtectionStateStore.PendingChallenge,
        ) {
            abandonCandidate = null
            if (ProtectionStateStore.clearPendingChallenge(
                    context,
                    ready.packageName,
                    ready.generation,
                )
            ) {
                ProtectionRuntime.invalidateChallengeHandoff()
            }
        }

        @Synchronized
        private fun recordChallengeAbandonCandidate(candidate: ChallengeAbandonCandidate) {
            abandonCandidate = candidate
        }

        @Synchronized
        private fun cancelChallengeAbandonCandidate() {
            abandonCandidate = null
        }

        /** The default Home activity's package: safe exit and F4 P1. */
        private fun resolveHomePackage(context: Context): String? = try {
            val homeIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
            context.packageManager.resolveActivity(homeIntent, 0)
                ?.activityInfo?.packageName
        } catch (_: Exception) {
            null
        }

        /**
         * F4 P1 window kind. Only an Activity declared by the reporting
         * package counts; any failure (including API 30+ package-visibility
         * NameNotFound) is UNCONFIRMED. The class name is never logged.
         */
        private fun foregroundWindowKind(
            context: Context,
            packageName: String,
            source: ForegroundSource,
            windowClass: String?,
        ): ForegroundWindowKind {
            val kind = WindowLeavePolicy.classify(
                packageName = packageName,
                fromUsageEvents = source == ForegroundSource.USAGE_EVENTS,
                homePackage = resolveHomePackage(context),
                windowClass = windowClass.takeIf { source == ForegroundSource.ACCESSIBILITY },
                resolveActivity = { pkg, cls ->
                    @Suppress("DEPRECATION")
                    val info = context.packageManager.getActivityInfo(ComponentName(pkg, cls), 0)
                    ResolvedActivity(info.packageName, info.name)
                },
            )
            Log.d(TAG, "window kind=$kind for $packageName")
            return kind
        }

        private fun defaultInputMethodPackage(context: Context): String? = try {
            ChallengeAbandonPolicy.imePackageFromSetting(
                Settings.Secure.getString(
                    context.contentResolver,
                    Settings.Secure.DEFAULT_INPUT_METHOD,
                ),
            )
        } catch (_: Exception) {
            null
        }

        /**
         * Abandons the current challenge presentation and requests the system
         * launcher without granting the protected package. Detector
         * confirmation completes the normal path; a bounded coordination
         * fallback prevents a missing detector from trapping the user behind
         * the shield.
         */
        @Synchronized
        fun requestSafeExitToHome(context: Context): Boolean {
            val pending = ProtectionStateStore.pendingChallenge(context) ?: return false
            val homeIntent = Intent(Intent.ACTION_MAIN).apply {
                addCategory(Intent.CATEGORY_HOME)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            val homePackage = resolveHomePackage(context) ?: return false
            if (ProtectionStateStore.isProtected(context, homePackage)) return false

            val request = SafeExitRequest(pending, homePackage)
            // Repeated presses for the same ticket do not extend the bounded
            // window. A newer ticket replaces the old request and receives
            // its own exact-generation guard.
            if (!safeExitGate.begin(request)) return true
            cancelSafeExitTimeout()
            activeInstance?.cancelRecoveryRetry()
            return try {
                context.startActivity(homeIntent)
                scheduleSafeExitFallback(context, request)
                true
            } catch (_: Exception) {
                safeExitGate.cancel()
                cancelSafeExitTimeout()
                activeInstance?.scheduleRecoveryRetry()
                false
            }
        }

        private fun isSafeExitInProgress(): Boolean = safeExitGate.isInProgress()

        /** Cancels an old emergency exit when a newer security cycle wins. */
        @Synchronized
        fun abortSafeExit() {
            safeExitGate.cancel()
            cancelSafeExitTimeout()
        }

        @Synchronized
        private fun scheduleSafeExitFallback(
            context: Context,
            request: SafeExitRequest,
        ) {
            cancelSafeExitTimeout()
            val timeout = Runnable {
                completeSafeExitAfterTimeout(context, request)
            }
            safeExitTimeout = timeout
            safeExitHandler.postDelayed(timeout, SAFE_EXIT_COORDINATION_MS)
        }

        @Synchronized
        private fun cancelSafeExitTimeout() {
            safeExitTimeout?.let { safeExitHandler.removeCallbacks(it) }
            safeExitTimeout = null
        }

        @Synchronized
        private fun completeSafeExitAfterTimeout(
            context: Context,
            request: SafeExitRequest,
        ) {
            if (safeExitGate.request() != request) return
            val resolution = safeExitGate.resolveTimeout(
                ProtectionStateStore.pendingChallenge(context),
            )
            when (resolution) {
                SafeExitResolution.FALLBACK -> {
                    // The timeout only abandons the presentation ticket and
                    // releases the UI shield. It is never an auth decision.
                    finishSafeExit(
                        context = context,
                        request = request,
                        homeConfirmed = false,
                    )
                }
                SafeExitResolution.STALE -> {
                    cancelSafeExitTimeout()
                    activeInstance?.scheduleRecoveryRetry()
                }
                else -> Unit
            }
        }

        /** Emergency exit always revokes native authorization; it never grants it. */
        private fun revokeEmergencyExitAuthorization() {
            ProtectionAccessState.revokeAll()
        }

        @Synchronized
        private fun completeSafeExitIfConfirmed(
            context: Context,
            foregroundPackage: String,
        ): Boolean {
            val request = safeExitGate.request() ?: return false
            val resolution = safeExitGate.resolveForeground(
                currentChallenge = ProtectionStateStore.pendingChallenge(context),
                foregroundPackage = foregroundPackage,
            )
            return when (resolution) {
                SafeExitResolution.CONFIRMED -> finishSafeExit(
                    context = context,
                    request = request,
                    homeConfirmed = true,
                )
                SafeExitResolution.STALE -> {
                    cancelSafeExitTimeout()
                    activeInstance?.scheduleRecoveryRetry()
                    false
                }
                else -> false
            }
        }

        /**
         * Clears only the exact abandoned presentation ticket, revokes every
         * native authorization, invalidates the ready handoff, and hides the
         * shield. No Dart session or protection configuration is touched.
         */
        @Synchronized
        private fun finishSafeExit(
            context: Context,
            request: SafeExitRequest,
            homeConfirmed: Boolean,
        ): Boolean {
            val current = ProtectionStateStore.pendingChallenge(context)
            if (current != request.challenge) {
                cancelSafeExitTimeout()
                activeInstance?.scheduleRecoveryRetry()
                return false
            }
            if (!ProtectionStateStore.clearPendingChallenge(
                    context,
                    request.challenge.packageName,
                    request.challenge.generation,
                )
            ) {
                cancelSafeExitTimeout()
                activeInstance?.scheduleRecoveryRetry()
                return false
            }

            ProtectionRuntime.invalidateChallengeHandoff()
            if (homeConfirmed) {
                // Only a detector-confirmed Home transition clears the
                // remembered wake identity. The fallback remains fail-closed
                // for a later screen-off because it cannot prove Home.
                ProtectionStateStore.rememberWakeReauthPackage(context, null)
                ProtectionAccessState.observeForeground(
                    packageName = request.homePackage,
                    protected = false,
                )
            }
            // Emergency exit is not authorization and never starts/extends
            // a grace window, regardless of how the user reached Home.
            revokeEmergencyExitAuthorization()
            recoveryGate.reset()
            activeInstance?.cancelRecoveryRetry()
            cancelSafeExitTimeout()
            if (!ProtectionOverlayController.hide()) {
                ProtectionStateStore.setLastError(
                    context,
                    "Emergency Home exit released state but shield hide failed.",
                )
            }
            return true
        }
    }
}
