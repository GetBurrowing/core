package com.koboai.burrow.push

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.view.View
import android.widget.FrameLayout
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.core.graphics.createBitmap
import androidx.glance.ExperimentalGlanceApi
import androidx.glance.appwidget.compose
import com.koboai.burrow.widgets.Briefing
import com.koboai.burrow.widgets.CachedBriefing
import com.koboai.burrow.widgets.Counts
import com.koboai.burrow.widgets.DataStoreBriefingStore
import com.koboai.burrow.widgets.DataStoreCountsStore
import com.koboai.burrow.widgets.TodaysBriefingWidget
import com.koboai.burrow.widgets.WidgetRefresh
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.time.LocalDate
import java.time.ZoneId

/**
 * DEBUG BUILDS ONLY. Puts the widgets in a state without a server, for
 * screenshots on an emulator that cannot sign in (the IdP is passkey-first):
 *
 *   am broadcast -a com.koboai.burrow.debug.WIDGET \
 *     -n com.koboai.burrow.debug/com.koboai.burrow.push.DebugWidgetReceiver \
 *     --ez signed_in true --ei approvals 3 --ei tasks 0 --ei age_minutes 0
 *
 * `signed_in true` stores a stand-in bearer for the selected install
 * (false removes it); the counts are written with `fetched_at = now -
 * age_minutes`; `--ez never_loaded true` clears them. DUMP-protected like
 * DebugPushReceiver.
 *
 * `--es briefing calls|one_call|fyi|all_done|none|stale|never_loaded` puts
 * Today's briefing in that state instead of touching the counts: counts
 * 12 items, 9 handled, 3 calls (fyi: 3 open, no calls), dated today in the
 * device's zone; `stale` is yesterday's briefing.
 *
 * `--es install <host>` first adds and selects that install, for an
 * emulator with none (use a host that never resolves, such as
 * burrow.example.com, so the stand-in bearer never reaches a real server).
 *
 * `--es render_cover light|dark` then also renders the briefing widget's
 * RemoteViews as the Flip 5 cover screen would size them, 720x748 px at
 * 320 dpi (360x374dp, so the cover layout), into
 * files/cover-<state>-<theme>.png under the app's external files dir.
 * No Flip emulator exists; this is Glance's own composition, applied and
 * drawn off-screen, not a launcher.
 */
class DebugWidgetReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent,
    ) {
        if (intent.action != ACTION) return
        val app = context.applicationContext
        intent.getStringExtra("install")?.let { BurrowPush.installs(app).add(it) }
        val host = BurrowPush.installs(app).selectedInstall?.host ?: return
        val tokens = BurrowPush.tokens(app)
        if (intent.getBooleanExtra("signed_in", true)) tokens.store(host, "debug-widget-stub") else tokens.remove(host)
        val pending = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val briefing = intent.getStringExtra("briefing")
                val store = DataStoreCountsStore(app)
                if (briefing != null) {
                    writeBriefing(app, host, briefing)
                } else if (intent.getBooleanExtra("never_loaded", false)) {
                    store.remove(host)
                } else {
                    val age = intent.getIntExtra("age_minutes", 0) * 60_000L
                    store.write(
                        host,
                        Counts(intent.getIntExtra("approvals", 3), intent.getIntExtra("tasks", 0), System.currentTimeMillis() - age),
                    )
                }
                WidgetRefresh.render(app)
                intent.getStringExtra("render_cover")?.let { renderCover(app, briefing ?: "counts", it == "dark") }
            } finally {
                pending.finish()
            }
        }
    }

    private suspend fun writeBriefing(
        context: Context,
        host: String,
        state: String,
    ) {
        val store = DataStoreBriefingStore(context)
        val zone = ZoneId.systemDefault()
        val today = LocalDate.now(zone)
        val now = System.currentTimeMillis()

        fun at(
            date: LocalDate,
            b: Briefing?,
        ) = CachedBriefing(date, zone.id, b, now)
        when (state) {
            "calls" -> store.write(host, at(today, Briefing(today, 12, 5, 3, 9)))
            "one_call" -> store.write(host, at(today, Briefing(today, 12, 1, 1, 11)))
            "fyi" -> store.write(host, at(today, Briefing(today, 12, 3, 0, 9)))
            "all_done" -> store.write(host, at(today, Briefing(today, 12, 0, 0, 12)))
            "none" -> store.write(host, at(today, null))
            "stale" -> today.minusDays(1).let { store.write(host, at(it, Briefing(it, 8, 4, 4, 4))) }
            "never_loaded" -> store.remove(host)
        }
    }

    @OptIn(ExperimentalGlanceApi::class)
    private suspend fun renderCover(
        context: Context,
        state: String,
        dark: Boolean,
    ) {
        val config = Configuration(context.resources.configuration)
        config.densityDpi = COVER_DPI
        config.uiMode = (config.uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
            (if (dark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO)
        val cover = context.createConfigurationContext(config)
        val density = COVER_DPI / 160f
        val size = DpSize((COVER_WIDTH_PX / density).dp, (COVER_HEIGHT_PX / density).dp)
        val views = TodaysBriefingWidget().compose(cover, size = size)
        val bitmap =
            withContext(Dispatchers.Main) {
                val parent = FrameLayout(cover)
                val view = views.apply(cover, parent)
                parent.addView(view, FrameLayout.LayoutParams(COVER_WIDTH_PX, COVER_HEIGHT_PX))
                val exact = { px: Int -> View.MeasureSpec.makeMeasureSpec(px, View.MeasureSpec.EXACTLY) }
                parent.measure(exact(COVER_WIDTH_PX), exact(COVER_HEIGHT_PX))
                parent.layout(0, 0, COVER_WIDTH_PX, COVER_HEIGHT_PX)
                createBitmap(COVER_WIDTH_PX, COVER_HEIGHT_PX).also {
                    val canvas = android.graphics.Canvas(it)
                    // The cover screen around the widget is black in both themes.
                    canvas.drawColor(0xFF000000.toInt())
                    parent.draw(canvas)
                }
            }
        val out = File(context.getExternalFilesDir(null), "cover-$state-${if (dark) "dark" else "light"}.png")
        out.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    companion object {
        private const val COVER_WIDTH_PX = 720
        private const val COVER_HEIGHT_PX = 748
        private const val COVER_DPI = 320
        const val ACTION = "com.koboai.burrow.debug.WIDGET"
    }
}
