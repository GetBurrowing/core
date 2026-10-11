package com.koboai.burrow

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputType
import android.text.TextUtils
import android.text.TextWatcher
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.core.content.res.ResourcesCompat
import androidx.core.view.ViewCompat
import androidx.core.view.isVisible
import java.util.concurrent.Executors

/**
 * The add-your-install state machine (task 01a12787 stage 4, design canvas
 * 01a12787-c69f revision 1): idle, checking, confirm, not found, offline.
 * Mirrors iOS `AddInstallFlowModel`. Plain Kotlin so the JVM tests drive it:
 * [background] runs the probe off the main thread, [main] posts the result
 * back, and [onChange] redraws the view.
 */
class AddInstallFlowModel(
    private val store: InstallStore,
    private val probe: (String) -> InstallCheck,
    /** The picker's Continue: the normal native sign-in runs from here. */
    private val onContinue: (Install) -> Unit,
    private val background: (() -> Unit) -> Unit,
    private val main: (() -> Unit) -> Unit,
) {
    sealed interface State {
        data object Idle : State

        data object Checking : State

        /** The card: the install's own name (manifest, else the host) and host. */
        data class Confirm(
            val host: String,
            val name: String?,
        ) : State {
            val displayName: String get() = name ?: host
            val iconUrl: String get() = Install(host).iconUrl
        }

        data class NotFound(
            val host: String,
        ) : State

        data object Offline : State
    }

    var address: String = ""
    var state: State = State.Idle
        private set(value) {
            field = value
            onChange(value)
        }
    var onChange: (State) -> Unit = {}

    val isChecking: Boolean get() = state == State.Checking
    val canSubmit: Boolean get() = !isChecking && address.isNotBlank()

    /** The primary button's label. */
    val buttonRes: Int get() = if (isChecking) R.string.add_flow_checking else R.string.add_flow_continue

    /** The error line under the field, if any. Not found and offline never share copy. */
    val messageRes: Int?
        get() =
            when (state) {
                is State.NotFound -> R.string.add_flow_not_found
                State.Offline -> R.string.add_flow_offline
                else -> null
            }

    /** Continue: checks the typed address. The field stays editable while it runs. */
    fun submit() {
        if (!canSubmit) return
        val typed = address.trim()
        val host = InstallStore.normalizeHost(typed)
        if (host == null) {
            state = State.NotFound(typed)
            return
        }
        state = State.Checking
        background {
            val result = probe(host)
            main {
                state =
                    when (result) {
                        is InstallCheck.Found -> State.Confirm(host, result.name)
                        InstallCheck.NotFound -> State.NotFound(host)
                        InstallCheck.Offline -> State.Offline
                    }
            }
        }
    }

    /** "Not this one? Change address": back to the field, still filled. */
    fun changeAddress() {
        state = State.Idle
    }

    /** "Continue to sign in": saves, selects and confirms the install, then runs the picker's Continue. */
    fun confirm(): Install? {
        val confirm = state as? State.Confirm ?: return null
        val install = store.add(confirm.host, confirm.name) ?: return null
        store.confirmSelection()
        onContinue(install)
        return install
    }
}

/**
 * The first-launch screen and the switcher's Add install sheet: one field,
 * then a confirmation card with the install's own logo, name and host before
 * any sign-in. Copy is the canvas's, verbatim, in strings.xml. Colours are
 * the semantic slots: surface (base-100), surface_muted plus border
 * (base-200/300) for the field and the card, primary on the two primary
 * buttons only, muted (base-content/60), error on the icon only.
 */
@SuppressLint("ViewConstructor")
class AddInstallFlow(
    context: Context,
    store: InstallStore,
    onContinue: (Install) -> Unit,
) : FrameLayout(context) {
    private val io = Executors.newSingleThreadExecutor()
    private val handler = Handler(Looper.getMainLooper())

    val model =
        AddInstallFlowModel(
            store = store,
            probe = { host -> InstallProbe.check(host) { InstallProbe.networkValidated(context) } },
            onContinue = onContinue,
            background = { io.execute(it) },
            main = { handler.post(it) },
        )

    private val entry = LinearLayout(context)
    private val field = EditText(context)
    private val message = LinearLayout(context)
    private val messageIcon = ImageView(context)
    private val messageText: TextView
    private val continueButton: TextView
    private val card = LinearLayout(context)
    private val cardIcon = FrameLayout(context)
    private val cardName: TextView
    private val cardHost: TextView
    private var icon: Bitmap? = null

    /** True on the confirmation card: back returns to the field. */
    val isConfirming: Boolean get() = model.state is AddInstallFlowModel.State.Confirm

    init {
        setBackgroundColor(color(R.color.burrow_surface))
        isClickable = true
        val scroll = ScrollView(context).apply { isFillViewport = true }
        val content =
            LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(16), dp(24), dp(16), dp(16))
            }
        content.addView(
            ImageView(context).apply {
                setImageResource(R.drawable.splash_arch)
                scaleType = ImageView.ScaleType.FIT_START
                importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
            },
            LinearLayout.LayoutParams(dp(120), dp(120)).apply {
                // The arch fills x 96..192, y 113..174 of its 288 square:
                // crop the square to the arch, about 40 x 25 dp.
                marginStart = -dp(40)
                topMargin = -dp(47)
                bottomMargin = -dp(47) + dp(24)
            },
        )
        content.addView(
            text(context.getString(R.string.add_flow_title), 28f, 800, R.color.burrow_on_surface).apply {
                letterSpacing = -0.01f
                ViewCompat.setAccessibilityHeading(this, true)
            },
            margins(bottom = 8),
        )

        // Step 1: the field
        entry.orientation = LinearLayout.VERTICAL
        entry.addView(text(context.getString(R.string.add_flow_body), 17f, 400, R.color.burrow_on_surface), margins(bottom = 20))
        field.apply {
            typeface = font()
            fontVariationSettings = "'wght' 400"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
            setTextColor(color(R.color.burrow_on_surface))
            setHintTextColor(color(R.color.burrow_muted))
            setHint(R.string.add_flow_placeholder)
            background = box(R.color.burrow_surface_muted, RADIUS_FIELD)
            setPadding(dp(12), 0, dp(12), 0)
            isSingleLine = true
            // A URL keyboard; no suggestions, no autocorrect, no capitals.
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            imeOptions = EditorInfo.IME_ACTION_GO
            contentDescription = context.getString(R.string.add_flow_address_label)
            setOnEditorActionListener { _, action, _ ->
                if (action == EditorInfo.IME_ACTION_GO) {
                    model.submit()
                    true
                } else {
                    false
                }
            }
            addTextChangedListener(
                object : TextWatcher {
                    override fun beforeTextChanged(
                        s: CharSequence?,
                        start: Int,
                        count: Int,
                        after: Int,
                    ) = Unit

                    override fun onTextChanged(
                        s: CharSequence?,
                        start: Int,
                        before: Int,
                        count: Int,
                    ) = Unit

                    override fun afterTextChanged(s: Editable?) {
                        model.address = s?.toString().orEmpty()
                        renderButton()
                    }
                },
            )
        }
        entry.addView(field, LinearLayout.LayoutParams(MATCH, dp(48)))
        message.orientation = LinearLayout.HORIZONTAL
        message.addView(
            messageIcon.apply { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO },
            LinearLayout.LayoutParams(dp(18), dp(18)).apply {
                topMargin = dp(1)
                marginEnd = dp(8)
            },
        )
        messageText = text("", 15f, 400, R.color.burrow_on_surface)
        message.addView(messageText, LinearLayout.LayoutParams(0, WRAP, 1f))
        message.isVisible = false
        entry.addView(message, margins(top = 12))
        continueButton = primaryButton(context.getString(R.string.add_flow_continue)) { model.submit() }
        entry.addView(continueButton, margins(top = 16))
        entry.addView(text(context.getString(R.string.add_flow_help), 15f, 400, R.color.burrow_muted), margins(top = 16, bottom = 16))
        content.addView(entry)

        // Step 2: the confirmation card
        card.orientation = LinearLayout.VERTICAL
        val tile =
            LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(16), dp(16), dp(16), dp(16))
                background = box(R.color.burrow_surface_muted, RADIUS_BOX)
            }
        cardIcon.background = box(R.color.burrow_surface_muted, RADIUS_FIELD)
        cardIcon.clipToOutline = true
        cardIcon.importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        tile.addView(cardIcon, LinearLayout.LayoutParams(dp(40), dp(40)).apply { marginEnd = dp(12) })
        val names = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        cardName = text("", 17f, 600, R.color.burrow_on_surface).apply { maxLines = 2 }
        cardHost =
            text("", 15f, 400, R.color.burrow_muted).apply {
                typeface = android.graphics.Typeface.MONOSPACE
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.MIDDLE
            }
        names.addView(cardName)
        names.addView(cardHost, margins(top = 2))
        tile.addView(names, LinearLayout.LayoutParams(0, WRAP, 1f))
        card.addView(tile, margins(top = 12))
        card.addView(primaryButton(context.getString(R.string.add_flow_continue_to_sign_in)) { model.confirm() }, margins(top = 16))
        card.addView(
            text(context.getString(R.string.add_flow_change_address), 15f, 600, R.color.burrow_on_surface).apply {
                gravity = Gravity.CENTER
                minHeight = dp(48)
                isClickable = true
                isFocusable = true
                setOnClickListener {
                    model.changeAddress()
                    focusField()
                }
            },
            margins(top = 8),
        )
        card.isVisible = false
        content.addView(card)

        scroll.addView(content)
        addView(scroll, LayoutParams(MATCH, MATCH))
        model.onChange = { render() }
        render()
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        focusField()
    }

    override fun onDetachedFromWindow() {
        io.shutdownNow()
        super.onDetachedFromWindow()
    }

    /** Back: from the card to the field. False when there is nothing to undo. */
    fun handleBack(): Boolean {
        if (!isConfirming) return false
        model.changeAddress()
        focusField()
        return true
    }

    private fun focusField() {
        field.requestFocus()
        field.post { context.getSystemService(InputMethodManager::class.java)?.showSoftInput(field, InputMethodManager.SHOW_IMPLICIT) }
    }

    private fun render() {
        val state = model.state
        val confirm = state as? AddInstallFlowModel.State.Confirm
        entry.isVisible = confirm == null
        card.isVisible = confirm != null
        if (confirm != null) {
            context.getSystemService(InputMethodManager::class.java)?.hideSoftInputFromWindow(windowToken, 0)
            cardName.text = confirm.displayName
            cardHost.text = confirm.host
            renderIcon(confirm)
            loadIcon(confirm)
        }
        val messageRes = model.messageRes
        message.isVisible = messageRes != null
        if (messageRes != null) {
            val offline = state == AddInstallFlowModel.State.Offline
            val host = (state as? AddInstallFlowModel.State.NotFound)?.host
            messageText.text = if (host != null) context.getString(messageRes, host) else context.getString(messageRes)
            messageIcon.setImageResource(if (offline) R.drawable.ic_signal_slash else R.drawable.ic_warning)
        }
        renderButton()
        (context as? MainActivity)?.updateBackState()
    }

    private fun renderButton() {
        continueButton.setText(model.buttonRes)
        continueButton.isEnabled = model.canSubmit
        continueButton.alpha = if (model.canSubmit) 1f else 0.4f
    }

    private fun renderIcon(confirm: AddInstallFlowModel.State.Confirm) {
        cardIcon.removeAllViews()
        val bitmap = icon
        if (bitmap != null) {
            cardIcon.addView(
                ImageView(context).apply {
                    setImageBitmap(bitmap)
                    scaleType = ImageView.ScaleType.CENTER_CROP
                },
                LayoutParams(MATCH, MATCH),
            )
        } else {
            cardIcon.addView(
                text(confirm.displayName.take(1).uppercase(), 17f, 800, R.color.burrow_on_surface).apply { gravity = Gravity.CENTER },
                LayoutParams(MATCH, MATCH),
            )
        }
    }

    private fun loadIcon(confirm: AddInstallFlowModel.State.Confirm) {
        icon = null
        io.execute {
            val bitmap = InstallProbe.icon(Install(confirm.host)) ?: return@execute
            handler.post {
                if (model.state != confirm) return@post
                icon = bitmap
                renderIcon(confirm)
            }
        }
    }

    // Building blocks (the picker's, for this screen)

    private fun primaryButton(
        label: String,
        action: () -> Unit,
    ): TextView =
        text(label, 17f, 700, R.color.burrow_on_primary).apply {
            gravity = Gravity.CENTER
            minHeight = dp(48)
            isClickable = true
            isFocusable = true
            background =
                GradientDrawable().apply {
                    cornerRadius = dp(RADIUS_FIELD).toFloat()
                    setColor(color(R.color.burrow_primary))
                }
            setOnClickListener { action() }
        }

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

    private fun font() = ResourcesCompat.getFont(context, R.font.public_sans)

    private fun box(
        fill: Int,
        radius: Int,
    ) = GradientDrawable().apply {
        cornerRadius = dp(radius).toFloat()
        setColor(color(fill))
        setStroke(dp(1), color(R.color.burrow_border))
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
    }
}
