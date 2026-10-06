package com.koboai.burrow.push

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.OnBackPressedCallback
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.content.res.ResourcesCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import com.koboai.burrow.R

/**
 * The notification permission explainer (canvas 01a10d91, "Permission
 * explainer" wireframe and States; copy verbatim in strings.xml). Android
 * 13+ only, shown before the system prompt so that prompt only reaches
 * someone who has said yes.
 *
 * - [VARIANT_ASK]: "Turn on notifications" shows the system prompt; "Not now"
 *   continues into the app.
 * - [VARIANT_DENIED_PERMANENTLY]: Android will not prompt again, so the
 *   button opens Burrow's notification settings instead.
 *
 * The result code is one of [RESULT_GRANTED], [RESULT_DENIED],
 * [RESULT_NOT_NOW], [RESULT_SETTINGS]. Back is "Not now".
 */
class PermissionExplainerActivity : AppCompatActivity() {
    private lateinit var prefs: PushPrefs

    private val request =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            finishWith(if (granted) RESULT_GRANTED else RESULT_DENIED)
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        prefs = BurrowPush.prefs(this)
        val deniedPermanently = intent.getStringExtra(EXTRA_VARIANT) == VARIANT_DENIED_PERMANENTLY
        setContentView(layout(deniedPermanently))
        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    finishWith(RESULT_NOT_NOW)
                }
            },
        )
    }

    private fun turnOn() {
        // Only ever shown on Android 13+ (PushPermission.nextStep).
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            finishWith(RESULT_DENIED)
            return
        }
        prefs.systemAsked = true
        request.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    private fun openSettings() {
        val intent =
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        try {
            startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            // No settings screen to open; the person stays in the app.
        }
        finishWith(RESULT_SETTINGS)
    }

    private fun finishWith(code: Int) {
        setResult(code)
        finish()
    }

    private fun layout(deniedPermanently: Boolean): View {
        val root =
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setBackgroundColor(color(R.color.burrow_surface))
                setPadding(dp(24), dp(16), dp(24), dp(16))
            }
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            view.updatePadding(
                left = bars.left + dp(24),
                top = bars.top + dp(16),
                right = bars.right + dp(24),
                bottom =
                    bars.bottom + dp(16),
            )
            insets
        }
        root.addView(View(this), LinearLayout.LayoutParams(MATCH, 0, 1f))
        root.addView(
            ImageView(this).apply {
                setImageResource(R.drawable.splash_arch)
                scaleType = ImageView.ScaleType.CENTER_CROP
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            },
            // splash_arch is the arch inside a 288 square at 1/3 width: a
            // 192dp view shows it 64dp wide.
            LinearLayout.LayoutParams(dp(192), dp(128)).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                bottomMargin = dp(8)
            },
        )
        root.addView(
            text(getString(R.string.explainer_title), 28f, 800, R.color.burrow_on_surface).apply {
                letterSpacing = -0.01f
                ViewCompat.setAccessibilityHeading(this, true)
            },
            LinearLayout.LayoutParams(MATCH, WRAP).apply { bottomMargin = dp(12) },
        )
        val body = if (deniedPermanently) R.string.explainer_denied_body else R.string.explainer_body
        root.addView(text(getString(body), 17f, 400, R.color.burrow_muted), LinearLayout.LayoutParams(MATCH, WRAP))
        root.addView(View(this), LinearLayout.LayoutParams(MATCH, 0, 1.4f))
        if (deniedPermanently) {
            root.addView(button(R.string.explainer_open_settings, primary = true) { openSettings() }, margins(bottom = 8))
        } else {
            root.addView(button(R.string.explainer_turn_on, primary = true) { turnOn() }, margins(bottom = 8))
        }
        root.addView(button(R.string.explainer_not_now, primary = false) { finishWith(RESULT_NOT_NOW) }, margins())
        return root
    }

    private fun button(
        label: Int,
        primary: Boolean,
        action: () -> Unit,
    ): FrameLayout {
        val button =
            FrameLayout(this).apply {
                minimumHeight = dp(48)
                isClickable = true
                isFocusable = true
                contentDescription = getString(label)
                background =
                    GradientDrawable().apply {
                        cornerRadius = dp(RADIUS_FIELD).toFloat()
                        if (primary) {
                            setColor(color(R.color.burrow_primary))
                        } else {
                            setColor(color(R.color.burrow_surface))
                            setStroke(dp(1), color(R.color.burrow_border))
                        }
                    }
                setOnClickListener { action() }
            }
        val text = text(getString(label), 17f, 700, if (primary) R.color.burrow_on_primary else R.color.burrow_on_surface)
        text.gravity = Gravity.CENTER
        text.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        button.addView(text, FrameLayout.LayoutParams(MATCH, dp(48), Gravity.CENTER))
        return button
    }

    private fun text(
        value: String,
        sp: Float,
        weight: Int,
        colour: Int,
    ): TextView =
        TextView(this).apply {
            text = value
            typeface = ResourcesCompat.getFont(this@PermissionExplainerActivity, R.font.public_sans)
            fontVariationSettings = "'wght' $weight"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
            setTextColor(color(colour))
        }

    private fun margins(bottom: Int = 0) = LinearLayout.LayoutParams(MATCH, WRAP).apply { bottomMargin = dp(bottom) }

    private fun color(res: Int) = ContextCompat.getColor(this, res)

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    companion object {
        const val EXTRA_VARIANT = "com.koboai.burrow.push.VARIANT"
        const val VARIANT_ASK = "ask"
        const val VARIANT_DENIED_PERMANENTLY = "denied_permanently"

        const val RESULT_GRANTED = 10
        const val RESULT_DENIED = 11
        const val RESULT_NOT_NOW = 12
        const val RESULT_SETTINGS = 13

        private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        private const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT
        private const val RADIUS_FIELD = 10
    }
}
