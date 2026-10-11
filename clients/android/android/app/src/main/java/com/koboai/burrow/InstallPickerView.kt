package com.koboai.burrow

import android.annotation.SuppressLint
import android.app.AlertDialog
import android.content.Context
import android.graphics.Bitmap
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.core.content.res.ResourcesCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import androidx.core.view.updatePadding
import com.koboai.burrow.push.InstallUnread
import java.util.concurrent.Executors

/**
 * The install picker: Android Views laid out as the iOS picker (canvas
 * 01a10887, Layout intent + Wireframes + States, as amended for Android by
 * canvas 01a10d91). Copy is the canvas's, verbatim, in strings.xml.
 *
 * Primary buttons are `burrow_primary` (orange): cyan is reserved for the
 * live widget slab, so no button is cyan (README, "Colour slots").
 */
@SuppressLint("ViewConstructor")
class InstallPickerView(
    context: Context,
    private val store: InstallStore,
    /** Removes the host's conversation shortcuts (ConversationShortcuts.removeForHost). */
    private val removeShortcuts: (String) -> Unit,
    /** Per-install unread for the signed-in installs (UnreadStore.entries), read on [refreshUnread]. */
    private val unread: () -> Map<String, InstallUnread> = { emptyMap() },
    private val onContinue: (Install) -> Unit,
) : FrameLayout(context) {
    private enum class Reachability { UNKNOWN, REACHABLE, UNREACHABLE }

    private val io = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())
    private val reachability = mutableMapOf<String, Reachability>()
    private val icons = mutableMapOf<String, Bitmap>()

    private val listScreen = LinearLayout(context)
    private val rows = LinearLayout(context)
    private val continueButton: FrameLayout
    private val continueSpinner = ProgressBar(context)
    private val cantReach = LinearLayout(context)
    private val cantReachTitle = text("", 28f, 800, R.color.burrow_on_surface)
    private val addScreen = LinearLayout(context)
    private val addressField = EditText(context)
    private val addError = LinearLayout(context)
    private val addButton: FrameLayout
    private val addButtonLabel: TextView
    private val addSpinner = ProgressBar(context)

    private var checking = false
    private var continuing = false

    /**
     * The last unread counts read. Replaced whole on [refreshUnread], never
     * cleared first, so a refresh never flashes the pills empty.
     */
    private var counts: Map<String, InstallUnread> = emptyMap()

    init {
        setBackgroundColor(color(R.color.burrow_surface))
        isClickable = true // nothing under the picker takes a tap
        ViewCompat.setOnApplyWindowInsetsListener(this) { view, insets ->
            val bars =
                insets.getInsets(
                    WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout() or WindowInsetsCompat.Type.ime(),
                )
            view.updatePadding(left = bars.left, top = bars.top, right = bars.right, bottom = bars.bottom)
            insets
        }

        // List screen
        listScreen.orientation = LinearLayout.VERTICAL
        val scroll = ScrollView(context)
        val content =
            LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(16), dp(16), dp(16), dp(16))
            }
        content.addView(text(R.string.picker_title, 28f, 800, R.color.burrow_on_surface).apply { letterSpacing = -0.01f })
        content.addView(
            text(R.string.picker_subtitle, 15f, 400, R.color.burrow_muted),
            margins(top = 4, bottom = 24),
        )
        rows.orientation = LinearLayout.VERTICAL
        rows.background = box(R.color.burrow_surface, RADIUS_BOX)
        rows.clipToOutline = true
        content.addView(rows, LinearLayout.LayoutParams(MATCH, WRAP))
        scroll.addView(content)
        listScreen.addView(scroll, LinearLayout.LayoutParams(MATCH, 0, 1f))

        val buttons =
            LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(16), dp(8), dp(16), dp(16))
            }
        buttons.addView(button(R.string.picker_add, primary = false) { showAdd() }, margins(bottom = 8))
        continueButton = button(R.string.picker_continue, primary = true) { continueWithSelection() }
        continueButton.addView(continueSpinner.apply { isVisible = false }, LayoutParams(dp(24), dp(24), Gravity.CENTER))
        buttons.addView(continueButton)
        listScreen.addView(buttons)
        addView(listScreen, LayoutParams(MATCH, MATCH))

        // Can't reach screen
        cantReach.orientation = LinearLayout.VERTICAL
        cantReach.setPadding(dp(16), 0, dp(16), dp(16))
        cantReach.addView(View(context), LinearLayout.LayoutParams(MATCH, 0, 1f))
        cantReach.addView(
            ImageView(context).apply {
                setImageResource(R.drawable.ic_signal_slash)
                importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
            },
            LinearLayout.LayoutParams(dp(40), dp(40)).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                bottomMargin = dp(16)
            },
        )
        cantReachTitle.gravity = Gravity.CENTER
        cantReach.addView(cantReachTitle, LinearLayout.LayoutParams(MATCH, WRAP))
        cantReach.addView(View(context), LinearLayout.LayoutParams(MATCH, 0, 1f))
        cantReach.addView(button(R.string.try_again, primary = true) { continueWithSelection() }, margins(bottom = 8))
        cantReach.addView(button(R.string.choose_another, primary = false) { showList() })
        cantReach.isVisible = false
        addView(cantReach, LayoutParams(MATCH, MATCH))

        // Add screen
        addScreen.orientation = LinearLayout.VERTICAL
        addScreen.setPadding(dp(16), dp(32), dp(16), dp(16))
        addScreen.setBackgroundColor(color(R.color.burrow_surface))
        addScreen.isClickable = true
        addScreen.addView(text(R.string.add_title, 28f, 800, R.color.burrow_on_surface))
        addScreen.addView(text(R.string.add_subtitle, 15f, 400, R.color.burrow_muted), margins(top = 4, bottom = 12))
        addScreen.addView(text(R.string.add_address_label, 13f, 400, R.color.burrow_muted), margins(top = 12, bottom = 6))
        val field =
            LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(12), 0, dp(12), 0)
                background = box(R.color.burrow_surface, RADIUS_FIELD)
            }
        field.addView(text("https://", 17f, 400, R.color.burrow_muted).apply { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO })
        addressField.apply {
            typeface = font()
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
            setTextColor(color(R.color.burrow_on_surface))
            setHintTextColor(color(R.color.burrow_muted))
            setHint(R.string.add_address_hint)
            background = null
            setPadding(dp(2), 0, 0, 0)
            isSingleLine = true
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            imeOptions = EditorInfo.IME_ACTION_GO
            contentDescription = context.getString(R.string.add_address_label)
            setOnEditorActionListener { _, action, _ ->
                if (action == EditorInfo.IME_ACTION_GO) {
                    checkAndAdd()
                    true
                } else {
                    false
                }
            }
        }
        field.addView(addressField, LinearLayout.LayoutParams(0, MATCH, 1f))
        addScreen.addView(field, LinearLayout.LayoutParams(MATCH, dp(48)))
        addError.orientation = LinearLayout.HORIZONTAL
        addError.addView(
            ImageView(context).apply {
                setImageResource(R.drawable.ic_warning)
                importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
            },
            LinearLayout.LayoutParams(dp(16), dp(16)).apply {
                topMargin = dp(2)
                marginEnd = dp(6)
            },
        )
        addError.addView(text(R.string.add_not_burrow, 13f, 400, R.color.burrow_on_surface), LinearLayout.LayoutParams(0, WRAP, 1f))
        addError.isVisible = false
        addScreen.addView(addError, margins(top = 8))
        addScreen.addView(View(context), LinearLayout.LayoutParams(MATCH, 0, 1f))
        addButton = button(R.string.add_check, primary = true) { checkAndAdd() }
        addButtonLabel = addButton.getChildAt(0) as TextView
        addButton.addView(addSpinner.apply { isVisible = false }, LayoutParams(dp(24), dp(24), Gravity.CENTER))
        addScreen.addView(addButton)
        addScreen.isVisible = false
        addView(addScreen, LayoutParams(MATCH, MATCH))
    }

    override fun onDetachedFromWindow() {
        io.shutdownNow()
        super.onDetachedFromWindow()
    }

    /** True while a sub-screen (add, can't reach) is up: back closes it. */
    val hasSubScreen: Boolean get() = addScreen.isVisible || cantReach.isVisible

    /** Back: close a sub-screen. False when there is none. */
    fun handleBack(): Boolean {
        if (!hasSubScreen) return false
        showList()
        return true
    }

    fun reload() {
        counts = unread()
        renderRows()
        store.installs.forEach { refresh(it.host) }
    }

    /** Re-reads the unread counts (after a reconcile or a push) and redraws the rows in place. */
    fun refreshUnread() {
        counts = unread()
        renderRows()
    }

    // Rows

    private fun renderRows() {
        rows.removeAllViews()
        val list = store.installs
        val selected = store.selectedHost
        list.forEachIndexed { index, install ->
            if (index > 0) {
                rows.addView(
                    View(context).apply { setBackgroundColor(color(R.color.burrow_border)) },
                    LinearLayout.LayoutParams(MATCH, dp(1)).apply { marginStart = dp(16) },
                )
            }
            rows.addView(row(install, install.host == selected), LinearLayout.LayoutParams(MATCH, dp(64)))
        }
        continueButton.isEnabled = selected != null
        continueButton.alpha = if (selected != null) 1f else 0.4f
    }

    private fun row(
        install: Install,
        selected: Boolean,
    ): View {
        val row =
            LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(16), 0, dp(16), 0)
                isClickable = true
                isFocusable = true
                background = ContextCompat.getDrawable(context, android.R.drawable.list_selector_background)
                setOnClickListener {
                    store.select(install.host)
                    if (reachability[install.host] == Reachability.UNREACHABLE) refresh(install.host)
                    renderRows()
                }
                setOnLongClickListener {
                    confirmRemove(install)
                    true
                }
            }
        row.addView(iconTile(install), LinearLayout.LayoutParams(dp(40), dp(40)).apply { marginEnd = dp(12) })

        val texts = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        texts.addView(text(install.displayName, 17f, 600, R.color.burrow_on_surface).apply { singleLine() })
        val entry = counts[install.host]
        val stale = entry?.stale == true
        if (reachability[install.host] == Reachability.UNREACHABLE) {
            // The status replaces the host line so it never takes width from
            // the name (canvas self-critique).
            val status = LinearLayout(context).apply { gravity = Gravity.CENTER_VERTICAL }
            status.addView(
                View(context).apply { background = circle(R.color.burrow_error) },
                LinearLayout.LayoutParams(dp(8), dp(8)).apply { marginEnd = dp(6) },
            )
            // An install whose cached count is stale reads the plan's
            // "Could not update" (the count beside it is the last known);
            // without a cached count it is today's "Can't reach. Tap to
            // retry." Either way the dot is red and a tap retries.
            val label = if (stale) R.string.row_could_not_update else R.string.row_unreachable
            status.addView(text(label, 13f, 400, R.color.burrow_on_surface).apply { singleLine() })
            texts.addView(status, margins(top = 2))
        } else if (stale) {
            // The last refresh of this install's counts failed: its count
            // stays, dimmed, and the host line says so.
            texts.addView(text(R.string.row_could_not_update, 13f, 400, R.color.burrow_muted).apply { singleLine() }, margins(top = 2))
        } else {
            texts.addView(
                text(install.host, 13f, 400, R.color.burrow_muted).apply {
                    singleLine()
                    ellipsize = TextUtils.TruncateAt.MIDDLE
                },
                margins(top = 2),
            )
        }
        row.addView(texts, LinearLayout.LayoutParams(0, WRAP, 1f))
        val pillText = UnreadPill.text(entry?.count ?: 0, context.getString(R.string.unread_pill_cap))
        if (pillText != null) {
            row.addView(
                pill(pillText).apply { if (stale) alpha = STALE_ALPHA },
                LinearLayout.LayoutParams(WRAP, dp(20)).apply { marginStart = dp(8) },
            )
        }
        if (stale) texts.alpha = STALE_ALPHA
        row.addView(selectionMark(selected), LinearLayout.LayoutParams(dp(24), dp(24)).apply { marginStart = dp(8) })
        row.contentDescription =
            listOfNotNull(
                install.displayName,
                entry?.count?.takeIf { it > 0 }?.let { resources.getQuantityString(R.plurals.unread_pill_description, it, it) },
                if (stale) context.getString(R.string.row_could_not_update) else null,
                if (selected) context.getString(R.string.selected) else null,
            ).joinToString(", ")
        return row
    }

    private fun iconTile(install: Install): View {
        val tile = FrameLayout(context)
        tile.background = box(R.color.burrow_surface_muted, RADIUS_FIELD)
        tile.clipToOutline = true
        tile.importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        val bitmap = icons[install.host]
        if (bitmap != null) {
            tile.addView(
                ImageView(context).apply {
                    setImageBitmap(bitmap)
                    scaleType = ImageView.ScaleType.CENTER_CROP
                },
                LayoutParams(MATCH, MATCH),
            )
        } else {
            tile.addView(
                text(install.displayName.take(1).uppercase(), 17f, 800, R.color.burrow_on_surface).apply { gravity = Gravity.CENTER },
                LayoutParams(MATCH, MATCH),
            )
        }
        return tile
    }

    /** The count pill: burrow_primary fill, on-primary 12sp tabular digits (the chat rail's unread pill). */
    private fun pill(value: String): TextView =
        text(value, 12f, 700, R.color.burrow_on_primary).apply {
            fontFeatureSettings = "tnum"
            gravity = Gravity.CENTER
            minWidth = dp(20)
            setPadding(dp(6), 0, dp(6), 0)
            background =
                GradientDrawable().apply {
                    cornerRadius = dp(10).toFloat()
                    setColor(color(R.color.burrow_primary))
                }
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        }

    private fun selectionMark(selected: Boolean): View {
        val mark = FrameLayout(context)
        if (selected) {
            mark.background = circle(R.color.burrow_primary)
            mark.addView(ImageView(context).apply { setImageResource(R.drawable.ic_check) }, LayoutParams(dp(14), dp(14), Gravity.CENTER))
        } else {
            mark.background =
                GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setStroke(dp(2), color(R.color.burrow_border))
                }
        }
        mark.importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        return mark
    }

    private fun confirmRemove(install: Install) {
        AlertDialog
            .Builder(context)
            .setMessage(context.getString(R.string.remove_confirm, install.displayName))
            .setPositiveButton(R.string.remove) { _, _ ->
                store.remove(install.host)
                removeShortcuts(install.host)
                renderRows()
            }.setNegativeButton(R.string.cancel, null)
            .show()
    }

    private fun refresh(host: String) {
        reachability[host] = Reachability.UNKNOWN
        io.execute {
            val result = InstallProbe.probe(host)
            val icon = if (icons[host] == null) InstallProbe.icon(Install(host)) else null
            main.post {
                reachability[host] = if (result == null) Reachability.UNREACHABLE else Reachability.REACHABLE
                result?.name?.let { store.updateName(it, host) }
                icon?.let { icons[host] = it }
                renderRows()
            }
        }
    }

    // Continue

    private fun continueWithSelection() {
        if (continuing) return
        val install = store.selectedInstall ?: return
        continuing = true
        setBusy(continueButton, continueSpinner, true)
        io.execute {
            val ok = InstallProbe.reachable(install.host)
            main.post {
                continuing = false
                setBusy(continueButton, continueSpinner, false)
                if (ok) {
                    reachability[install.host] = Reachability.REACHABLE
                    showList()
                    onContinue(install)
                } else {
                    reachability[install.host] = Reachability.UNREACHABLE
                    cantReachTitle.text = context.getString(R.string.cant_reach, install.host)
                    listScreen.isVisible = false
                    cantReach.isVisible = true
                    renderRows()
                }
            }
        }
    }

    // Add

    private fun showAdd() {
        addressField.setText("")
        addError.isVisible = false
        addScreen.isVisible = true
        addressField.requestFocus()
        context.getSystemService(InputMethodManager::class.java)?.showSoftInput(addressField, InputMethodManager.SHOW_IMPLICIT)
        (context as? MainActivity)?.updateBackState()
    }

    private fun showList() {
        addScreen.isVisible = false
        cantReach.isVisible = false
        listScreen.isVisible = true
        context.getSystemService(InputMethodManager::class.java)?.hideSoftInputFromWindow(windowToken, 0)
        (context as? MainActivity)?.updateBackState()
    }

    private fun checkAndAdd() {
        if (checking) return
        val typed = addressField.text.toString()
        val host = InstallStore.normalizeHost(typed)
        if (host == null) {
            addError.isVisible = true
            return
        }
        checking = true
        addError.isVisible = false
        addButtonLabel.setText(R.string.add_checking)
        setBusy(addButton, addSpinner, true)
        io.execute {
            val result = InstallProbe.probe(host)
            main.post {
                checking = false
                addButtonLabel.setText(R.string.add_check)
                setBusy(addButton, addSpinner, false)
                if (result == null) {
                    addError.isVisible = true
                } else {
                    store.add(host, result.name)
                    reachability[host] = Reachability.REACHABLE
                    showList()
                    reload()
                }
            }
        }
    }

    // Building blocks

    private fun setBusy(
        button: FrameLayout,
        spinner: ProgressBar,
        busy: Boolean,
    ) {
        button.getChildAt(0).isVisible = !busy
        spinner.isVisible = busy
        button.isEnabled = !busy
    }

    private fun button(
        label: Int,
        primary: Boolean,
        action: () -> Unit,
    ): FrameLayout {
        val button =
            FrameLayout(context).apply {
                minimumHeight = dp(48)
                isClickable = true
                isFocusable = true
                background =
                    if (primary) {
                        GradientDrawable().apply {
                            cornerRadius = dp(RADIUS_FIELD).toFloat()
                            setColor(color(R.color.burrow_primary))
                        }
                    } else {
                        box(R.color.burrow_surface, RADIUS_FIELD)
                    }
                setOnClickListener { action() }
            }
        val text = text(label, 17f, 700, if (primary) R.color.burrow_on_primary else R.color.burrow_on_surface)
        text.gravity = Gravity.CENTER
        button.addView(text, LayoutParams(MATCH, dp(48)))
        button.layoutParams = LinearLayout.LayoutParams(MATCH, WRAP)
        return button
    }

    private fun text(
        res: Int,
        sp: Float,
        weight: Int,
        colour: Int,
    ) = text(context.getString(res), sp, weight, colour)

    private fun text(
        value: String,
        sp: Float,
        weight: Int,
        colour: Int,
    ): TextView =
        TextView(context).apply {
            text = value
            typeface = font()
            fontVariationSettings = "'wght' $weight"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
            setTextColor(color(colour))
        }

    private fun TextView.singleLine() {
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
    }

    private fun font() = ResourcesCompat.getFont(context, R.font.public_sans)

    private fun box(
        fill: Int,
        radius: Int,
    ) = GradientDrawable().apply {
        cornerRadius = dp(radius).toFloat()
        setColor(color(fill))
        setStroke(dp(1), color(R.color.burrow_border))
    }

    private fun circle(fill: Int) =
        GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(color(fill))
        }

    private fun margins(
        top: Int = 0,
        bottom: Int = 0,
    ) = LinearLayout.LayoutParams(MATCH, WRAP).apply {
        topMargin = dp(top)
        bottomMargin = dp(bottom)
    }

    private fun color(res: Int) = ContextCompat.getColor(context, res)

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    companion object {
        private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        private const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT
        private const val RADIUS_FIELD = 10
        private const val RADIUS_BOX = 14
        private const val STALE_ALPHA = 0.5f
    }
}
