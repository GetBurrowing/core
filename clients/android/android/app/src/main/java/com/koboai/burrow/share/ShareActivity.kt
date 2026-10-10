package com.koboai.burrow.share

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.TextUtils
import android.text.TextWatcher
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.content.res.ResourcesCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isNotEmpty
import androidx.core.view.isVisible
import androidx.core.view.updatePadding
import com.koboai.burrow.MainActivity
import com.koboai.burrow.R
import com.koboai.burrow.push.BurrowPush
import com.koboai.burrow.shortcuts.ConversationShortcuts
import java.util.concurrent.Executors

/**
 * The share target (canvas 01a10d91, "Share target"): a bottom sheet over
 * the SENDING app. It is its own translucent activity (taskAffinity "",
 * excludeFromRecents) rather than an intent filter on MainActivity, which
 * would bring the WebView task forward instead of sitting over the sender.
 *
 * The sheet opens at about 60% height and goes full height when the message
 * field takes focus. State lives in [ShareSheetModel]; this only renders it.
 */
class ShareActivity : AppCompatActivity() {
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var model: ShareSheetModel? = null

    private lateinit var sheet: LinearLayout
    private lateinit var title: TextView
    private lateinit var sendButton: FrameLayout
    private lateinit var sendLabel: TextView
    private lateinit var sendSpinner: ProgressBar
    private lateinit var body: LinearLayout
    private lateinit var preview: LinearLayout
    private lateinit var notice: LinearLayout
    private lateinit var noticeText: TextView
    private lateinit var bannerText: TextView
    private lateinit var spaceValue: TextView
    private lateinit var agents: LinearLayout
    private lateinit var messageField: EditText
    private lateinit var signedOut: LinearLayout
    private lateinit var loading: ProgressBar

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(layout())
        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    close()
                }
            },
        )
        val selected = BurrowPush.installs(this).selectedInstall?.host
        val client = AppShareClient(BurrowPush.client(this))
        val shareIntent = intent
        val app = applicationContext
        io.execute {
            val shared = ShareIntents.parse(contentResolver, shareIntent)
            // A direct-share target (conversation shortcut) names its install and space.
            val (host, preselect) =
                ShareSheetModel.target(
                    shareIntent.getStringExtra(ShortcutManagerCompat.EXTRA_SHORTCUT_ID),
                    selected,
                    client::isSignedIn,
                )
            val m =
                ShareSheetModel(
                    host,
                    client,
                    shared.files,
                    shared.text,
                    preselect,
                    onSent = { h, space -> noteShared(app, h, space) },
                    // Large files (task 01a120be): copied into app storage while
                    // the share grant is live, then uploaded by WorkManager.
                    enqueuer = WorkManagerLargeUploadEnqueuer(app),
                )
            m.start()
            main.post {
                model = m
                render()
            }
        }
    }

    /** A share that was sent: its conversation was used. */
    private fun noteShared(
        app: Context,
        host: String,
        space: ShareSpace,
    ) {
        ConversationShortcuts.forContext(app).noteUsed(
            host = host,
            spaceId = space.id,
            name = space.name,
            path = "/chat/${space.pathSegment ?: space.id}",
            persons = emptyList(),
            isGroup = space.kind != "dm",
        )
    }

    override fun onDestroy() {
        io.shutdown()
        super.onDestroy()
    }

    /** Back, the X and a tap outside: close, unless something is typed. */
    private fun close() {
        val m = model
        val done = m?.phase == ShareSheetModel.Phase.SENT || m?.phase == ShareSheetModel.Phase.HANDED_OFF
        if (m != null && m.hasTypedText && !done) {
            AlertDialog
                .Builder(this)
                .setMessage(R.string.share_discard_title)
                .setPositiveButton(R.string.share_discard) { _, _ -> finish() }
                .setNegativeButton(R.string.share_keep_editing, null)
                .show()
        } else {
            finish()
        }
    }

    private fun send() {
        val m = model ?: return
        m.message = messageField.text.toString()
        if (!m.canSend) return
        io.execute {
            // SENDING is set synchronously inside send(); show it first.
            main.post { renderSending() }
            val ok = m.send()
            main.post {
                render()
                if (ok) main.postDelayed({ finish() }, SENT_DWELL_MS)
            }
        }
    }

    private fun pickSpace() {
        val m = model ?: return
        if (m.spaces.isEmpty()) return
        val names = m.spaces.map { it.name }.toTypedArray()
        val checked = m.spaces.indexOfFirst { it.id == m.selectedSpaceId }
        AlertDialog
            .Builder(this)
            .setTitle(R.string.share_space)
            .setSingleChoiceItems(names, checked) { dialog, which ->
                m.selectedSpaceId = m.spaces[which].id
                dialog.dismiss()
                render()
            }.show()
    }

    private fun renderSending() {
        sendSpinner.isVisible = true
        sendLabel.isVisible = false
        sendButton.isEnabled = false
        messageField.isEnabled = false
    }

    private fun render() {
        val m = model ?: return
        loading.isVisible = m.phase == ShareSheetModel.Phase.LOADING_SPACES
        val notSignedIn = m.phase == ShareSheetModel.Phase.NOT_SIGNED_IN
        signedOut.isVisible = notSignedIn
        body.isVisible = !notSignedIn && m.phase != ShareSheetModel.Phase.LOADING_SPACES
        sendButton.isVisible = !notSignedIn
        title.text =
            when (m.phase) {
                ShareSheetModel.Phase.SENT -> getString(R.string.share_sent_to, m.selectedSpace?.name.orEmpty())
                // The sheet closes at once; the upload carries on in WorkManager.
                ShareSheetModel.Phase.HANDED_OFF -> getString(R.string.share_handed_off)
                else -> getString(R.string.share_title)
            }

        val size = m.size
        preview.removeAllViews()
        for (file in m.files) {
            val over = file in size.oversized
            preview.addView(fileRow(file, over))
        }
        m.sharedText?.let { shared ->
            preview.addView(text(shared, 15f, 400, R.color.burrow_on_surface).apply { maxLines = 4 })
        }
        notice.isVisible = size.notice != null
        noticeText.text = size.notice
        bannerText.isVisible = m.banner != null
        bannerText.text = m.banner?.text

        spaceValue.text = m.selectedSpace?.name ?: getString(R.string.share_choose_space)
        agents.removeAllViews()
        m.selectedSpace?.agents?.forEach { agent ->
            val selected = agent.id == m.selectedAgentId
            agents.addView(
                chip(agent.name, selected) {
                    m.selectedAgentId = if (selected) null else agent.id
                    render()
                },
                LinearLayout.LayoutParams(WRAP, WRAP).apply { marginEnd = dp(8) },
            )
        }
        agents.isVisible = agents.isNotEmpty()

        val locked =
            m.phase == ShareSheetModel.Phase.SENDING ||
                m.phase == ShareSheetModel.Phase.SENT ||
                m.phase == ShareSheetModel.Phase.HANDED_OFF
        messageField.isEnabled = !locked
        sendLabel.text = m.sendLabel
        sendLabel.isVisible = m.phase != ShareSheetModel.Phase.SENDING
        sendSpinner.isVisible = m.phase == ShareSheetModel.Phase.SENDING
        m.message = messageField.text.toString()
        val enabled = m.canSend
        sendButton.isEnabled = enabled
        sendButton.alpha = if (enabled) 1f else 0.4f
        sendButton.contentDescription = m.sendLabel
    }

    // Layout

    private fun layout(): View {
        val root = FrameLayout(this)
        root.setOnClickListener { close() }
        sheet =
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                isClickable = true // a tap inside never reaches the scrim
                background =
                    GradientDrawable().apply {
                        val r = dp(16).toFloat()
                        cornerRadii = floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
                        setColor(color(R.color.burrow_surface))
                    }
            }
        ViewCompat.setOnApplyWindowInsetsListener(sheet) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.ime())
            // Full height (message focused) reaches under the status bar.
            val top = if (view.layoutParams?.height == MATCH) bars.top else 0
            view.updatePadding(top = top, bottom = bars.bottom)
            insets
        }
        val height = (resources.displayMetrics.heightPixels * 0.6f).toInt()
        root.addView(sheet, FrameLayout.LayoutParams(MATCH, height, Gravity.BOTTOM))

        // Header: close, title, Send.
        val header =
            LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(4), dp(8), dp(12), dp(8))
            }
        header.addView(
            ImageView(this).apply {
                setImageResource(R.drawable.ic_close)
                contentDescription = getString(R.string.share_close)
                setPadding(dp(12), dp(12), dp(12), dp(12))
                setOnClickListener { close() }
            },
            LinearLayout.LayoutParams(dp(48), dp(48)),
        )
        title = text(getString(R.string.share_title), 17f, 700, R.color.burrow_on_surface).apply { singleLine() }
        header.addView(title, LinearLayout.LayoutParams(0, WRAP, 1f))
        sendLabel = text(getString(R.string.share_send), 15f, 700, R.color.burrow_on_primary).apply { gravity = Gravity.CENTER }
        sendSpinner = ProgressBar(this).apply { isVisible = false }
        sendButton =
            FrameLayout(this).apply {
                minimumHeight = dp(36)
                minimumWidth = dp(64)
                isClickable = true
                isFocusable = true
                background =
                    GradientDrawable().apply {
                        cornerRadius = dp(RADIUS_FIELD).toFloat()
                        setColor(color(R.color.burrow_primary))
                    }
                setPadding(dp(16), 0, dp(16), 0)
                setOnClickListener { send() }
                addView(sendLabel, FrameLayout.LayoutParams(WRAP, dp(36), Gravity.CENTER))
                addView(sendSpinner, FrameLayout.LayoutParams(dp(20), dp(20), Gravity.CENTER))
            }
        header.addView(sendButton, LinearLayout.LayoutParams(WRAP, dp(36)))
        sheet.addView(header, LinearLayout.LayoutParams(MATCH, WRAP))

        loading = ProgressBar(this)
        sheet.addView(loading, LinearLayout.LayoutParams(WRAP, WRAP).apply { gravity = Gravity.CENTER_HORIZONTAL })

        // Not signed in.
        signedOut =
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(16), dp(16), dp(16), dp(16))
                isVisible = false
            }
        signedOut.addView(text(ShareSheetModel.NOT_SIGNED_IN_TEXT, 17f, 400, R.color.burrow_on_surface), margins(bottom = 16))
        signedOut.addView(
            primaryButton(getString(R.string.share_open_burrow)) {
                startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                finish()
            },
        )
        sheet.addView(signedOut, LinearLayout.LayoutParams(MATCH, WRAP))

        // The form.
        val scroll = ScrollView(this)
        body =
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(16), 0, dp(16), dp(16))
                isVisible = false
            }
        preview =
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(12), dp(12), dp(12), dp(12))
                background = box(R.color.burrow_surface_muted)
            }
        body.addView(preview, margins(bottom = 8))
        noticeText = text("", 15f, 400, R.color.burrow_on_surface)
        notice = iconLine(noticeText)
        body.addView(notice, margins(bottom = 8))
        bannerText = text("", 15f, 400, R.color.burrow_on_surface).apply { isVisible = false }
        body.addView(bannerText, margins(bottom = 8))

        val spaceRow =
            LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                minimumHeight = dp(48)
                isClickable = true
                isFocusable = true
                setOnClickListener { pickSpace() }
            }
        spaceRow.addView(text(getString(R.string.share_space), 17f, 400, R.color.burrow_muted), LinearLayout.LayoutParams(0, WRAP, 1f))
        spaceValue = text(getString(R.string.share_choose_space), 17f, 600, R.color.burrow_on_surface).apply { singleLine() }
        spaceRow.addView(spaceValue, LinearLayout.LayoutParams(WRAP, WRAP))
        body.addView(spaceRow, margins())
        agents = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        body.addView(agents, margins(bottom = 8))

        messageField =
            EditText(this).apply {
                hint = getString(R.string.share_message_hint)
                typeface = font()
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
                setTextColor(color(R.color.burrow_on_surface))
                setHintTextColor(color(R.color.burrow_muted))
                minLines = 2
                gravity = Gravity.TOP or Gravity.START
                background = box(R.color.burrow_surface)
                setPadding(dp(12), dp(12), dp(12), dp(12))
                setOnFocusChangeListener { _, focused -> if (focused) expandSheet() }
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
                            render()
                        }
                    },
                )
            }
        body.addView(messageField, margins())
        scroll.addView(body)
        sheet.addView(scroll, LinearLayout.LayoutParams(MATCH, 0, 1f))
        return root
    }

    private fun expandSheet() {
        sheet.layoutParams = (sheet.layoutParams as FrameLayout.LayoutParams).apply { height = MATCH }
        ViewCompat.requestApplyInsets(sheet)
        sheet.requestLayout()
    }

    private fun fileRow(
        file: SharedFile,
        over: Boolean,
    ): View {
        val line =
            text(
                "${file.name} · ${ByteLabel.format(file.size)}",
                15f,
                400,
                R.color.burrow_on_surface,
            ).apply { singleLine() }
        if (!over) return line.apply { setPadding(0, dp(2), 0, dp(2)) }
        return iconLine(line)
    }

    /** An error-tone icon beside base-content text (canvas: never red text). */
    private fun iconLine(label: TextView): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(2), 0, dp(2))
            addView(
                ImageView(this@ShareActivity).apply {
                    setImageResource(R.drawable.ic_warning)
                    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                },
                LinearLayout.LayoutParams(dp(20), dp(20)).apply { marginEnd = dp(8) },
            )
            addView(label, LinearLayout.LayoutParams(0, WRAP, 1f))
        }

    private fun chip(
        label: String,
        selected: Boolean,
        action: () -> Unit,
    ): TextView =
        text(label, 15f, 600, if (selected) R.color.burrow_on_primary else R.color.burrow_on_surface).apply {
            setPadding(dp(12), dp(6), dp(12), dp(6))
            background =
                GradientDrawable().apply {
                    cornerRadius = dp(16).toFloat()
                    setColor(if (selected) color(R.color.burrow_primary) else Color.TRANSPARENT)
                    if (!selected) setStroke(dp(1), color(R.color.burrow_border))
                }
            isClickable = true
            setOnClickListener { action() }
        }

    private fun primaryButton(
        label: String,
        action: () -> Unit,
    ): TextView =
        text(label, 17f, 700, R.color.burrow_on_primary).apply {
            gravity = Gravity.CENTER
            minHeight = dp(48)
            background =
                GradientDrawable().apply {
                    cornerRadius = dp(RADIUS_FIELD).toFloat()
                    setColor(color(R.color.burrow_primary))
                }
            isClickable = true
            setOnClickListener { action() }
        }

    private fun text(
        value: String,
        sp: Float,
        weight: Int,
        colour: Int,
    ): TextView =
        TextView(this).apply {
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

    private fun box(fill: Int) =
        GradientDrawable().apply {
            cornerRadius = dp(RADIUS_FIELD).toFloat()
            setColor(color(fill))
            setStroke(dp(1), color(R.color.burrow_border))
        }

    private fun margins(bottom: Int = 0) = LinearLayout.LayoutParams(MATCH, WRAP).apply { bottomMargin = dp(bottom) }

    private fun font() = ResourcesCompat.getFont(this, R.font.public_sans)

    private fun color(res: Int) = ContextCompat.getColor(this, res)

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    companion object {
        private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        private const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT
        private const val RADIUS_FIELD = 10
        private const val SENT_DWELL_MS = 1_000L
    }
}
