package com.smartapplock.app

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView

/**
 * Opaque touch/key-blocking shield used until Flutter authentication is ready.
 *
 * While protection is configured, a full-size, invisible, non-interactive
 * overlay window stays attached. A protected Accessibility event can then
 * make that already-owned and already-sized window opaque and touch-blocking
 * instead of adding/resizing a window after the protected activity draws.
 */
object ProtectionOverlayController {
    private var windowManager: WindowManager? = null
    private var shield: View? = null
    private var layoutParams: WindowManager.LayoutParams? = null
    private var showing = false

    @Synchronized
    fun arm(context: Context): Boolean {
        if (!Settings.canDrawOverlays(context)) return false
        if (shield != null) return true
        return try {
            val appContext = context.applicationContext
            val manager = appContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val root = FrameLayout(appContext).apply {
                setBackgroundColor(Color.rgb(17, 20, 28))
                isClickable = true
                isFocusable = true
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }
            val message = TextView(appContext).apply {
                text = "Smart App Lock\nPreparing secure unlock…"
                setTextColor(Color.WHITE)
                textSize = 20f
                gravity = Gravity.CENTER
            }
            root.addView(
                message,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT,
                ),
            )
            @Suppress("DEPRECATION")
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                WindowManager.LayoutParams.TYPE_PHONE
            }
            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.MATCH_PARENT,
                type,
                standbyFlags(),
                PixelFormat.OPAQUE,
            ).apply {
                gravity = Gravity.TOP or Gravity.START
                alpha = 0f
                title = "Smart App Lock protection shield"
            }
            root.visibility = View.INVISIBLE
            manager.addView(root, params)
            windowManager = manager
            shield = root
            layoutParams = params
            showing = false
            true
        } catch (_: Exception) {
            shield = null
            windowManager = null
            layoutParams = null
            showing = false
            false
        }
    }

    @Synchronized
    fun show(context: Context): Boolean {
        if (!arm(context)) return false
        if (showing) return true
        val active = shield ?: return false
        val manager = windowManager ?: return false
        val params = layoutParams ?: return false
        return try {
            params.width = WindowManager.LayoutParams.MATCH_PARENT
            params.height = WindowManager.LayoutParams.MATCH_PARENT
            params.flags = shieldFlags()
            params.alpha = 1f
            active.visibility = View.VISIBLE
            manager.updateViewLayout(active, params)
            showing = true
            true
        } catch (_: Exception) {
            disarm()
            false
        }
    }

    /** Makes the shield inert but retains the full-size pre-armed window. */
    @Synchronized
    fun hide(): Boolean {
        val active = shield ?: return true
        val manager = windowManager ?: return false
        val params = layoutParams ?: return false
        return try {
            params.width = WindowManager.LayoutParams.MATCH_PARENT
            params.height = WindowManager.LayoutParams.MATCH_PARENT
            params.flags = standbyFlags()
            params.alpha = 0f
            active.visibility = View.INVISIBLE
            manager.updateViewLayout(active, params)
            showing = false
            true
        } catch (_: Exception) {
            disarm()
            false
        }
    }

    /** Removes the window entirely when protection is disabled. */
    @Synchronized
    fun disarm(): Boolean {
        val active = shield ?: return true
        return try {
            windowManager?.removeViewImmediate(active)
            clearState()
            true
        } catch (_: Exception) {
            clearState()
            false
        }
    }

    @Synchronized
    fun isShowing(): Boolean = showing

    private fun standbyFlags(): Int =
        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
            WindowManager.LayoutParams.FLAG_SECURE

    private fun shieldFlags(): Int =
        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
            WindowManager.LayoutParams.FLAG_SECURE

    private fun clearState() {
        shield = null
        windowManager = null
        layoutParams = null
        showing = false
    }
}
