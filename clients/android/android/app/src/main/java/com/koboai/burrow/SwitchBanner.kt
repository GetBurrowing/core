package com.koboai.burrow

import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.core.content.res.ResourcesCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

/**
 * "Switched to <install>" (task 01a1261e stage 5; iOS `SwitchBanner`): a
 * 2-second top banner after a notification's Open or a conversation
 * shortcut moved the app to ANOTHER install, so the person knows which
 * sign-in they are now looking at. None when the target is the install
 * already showing.
 */
object SwitchBanner {
    const val DURATION_MS = 2_000L

    fun shouldShow(
        currentHost: String?,
        targetHost: String,
    ): Boolean = currentHost != null && !currentHost.equals(targetHost, ignoreCase = true)

    /**
     * Shows [text] over [parent]'s top system-bar inset (surface fill,
     * on-surface text, border edge) and removes it after [DURATION_MS]. A
     * newer banner replaces one still showing. Returns the banner view.
     */
    fun show(
        parent: ViewGroup,
        text: String,
    ): View {
        val context = parent.context
        parent.findViewWithTag<View>(TAG)?.let { parent.removeView(it) }
        val density = context.resources.displayMetrics.density

        fun dp(value: Int) = (value * density).toInt()
        val label =
            TextView(context).apply {
                this.text = text
                typeface = ResourcesCompat.getFont(context, R.font.public_sans)
                fontVariationSettings = "'wght' 600"
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
                setTextColor(ContextCompat.getColor(context, R.color.burrow_on_surface))
                maxLines = 1
                setPadding(dp(16), dp(10), dp(16), dp(10))
                background =
                    GradientDrawable().apply {
                        cornerRadius = dp(20).toFloat()
                        setColor(ContextCompat.getColor(context, R.color.burrow_surface))
                        setStroke(dp(1), ContextCompat.getColor(context, R.color.burrow_border))
                    }
                elevation = dp(4).toFloat()
                accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
            }
        val banner =
            FrameLayout(context).apply {
                tag = TAG
                isClickable = false
                addView(
                    label,
                    FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.WRAP_CONTENT,
                        ViewGroup.LayoutParams.WRAP_CONTENT,
                        Gravity.CENTER_HORIZONTAL,
                    ),
                )
            }
        val top =
            ViewCompat
                .getRootWindowInsets(parent)
                ?.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
                ?.top ?: 0
        parent.addView(
            banner,
            FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP).apply {
                topMargin = top + dp(8)
                leftMargin = dp(16)
                rightMargin = dp(16)
            },
        )
        banner.alpha = 0f
        banner
            .animate()
            .alpha(1f)
            .setDuration(FADE_MS)
            .start()
        Handler(Looper.getMainLooper()).postDelayed({
            banner
                .animate()
                .alpha(0f)
                .setDuration(FADE_MS)
                .withEndAction { (banner.parent as? ViewGroup)?.removeView(banner) }
                .start()
        }, DURATION_MS)
        return banner
    }

    private const val TAG = "burrow-switch-banner"
    private const val FADE_MS = 200L
}

/** The switcher's count pill text (task 01a1261e): none at zero, capped at 99+. */
object UnreadPill {
    const val CAP = 99

    fun text(
        count: Int,
        cap: String = "99+",
    ): String? =
        when {
            count <= 0 -> null
            count > CAP -> cap
            else -> count.toString()
        }
}
