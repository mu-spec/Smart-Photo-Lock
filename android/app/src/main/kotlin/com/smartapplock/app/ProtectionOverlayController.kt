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

/** Opaque touch-blocking shield used until Flutter authentication is ready. */
object ProtectionOverlayController {
    private var windowManager: WindowManager? = null
    private var shield: View? = null

    @Synchronized
    fun show(context: Context): Boolean {
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
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_SECURE,
                PixelFormat.OPAQUE,
            ).apply {
                gravity = Gravity.TOP or Gravity.START
                title = "Smart App Lock protection shield"
            }
            manager.addView(root, params)
            windowManager = manager
            shield = root
            true
        } catch (_: Exception) {
            shield = null
            windowManager = null
            false
        }
    }

    @Synchronized
    fun hide(): Boolean {
        val active = shield ?: return true
        return try {
            windowManager?.removeViewImmediate(active)
            shield = null
            windowManager = null
            true
        } catch (_: Exception) {
            shield = null
            windowManager = null
            false
        }
    }

    fun isShowing(): Boolean = shield != null
}
