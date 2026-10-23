package com.koboai.burrow.widgets

import android.content.Context
import android.content.Intent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.net.toUri
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.appWidgetBackground
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.currentState
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.padding
import androidx.glance.semantics.contentDescription
import androidx.glance.semantics.semantics
import androidx.glance.semantics.testTag
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import com.koboai.burrow.MainActivity
import com.koboai.burrow.R
import com.koboai.burrow.push.NotificationPresenter
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Today's briefing (canvas 01a161fa): the third member of the count-widget
 * family (canvas 01a10d91). It uses the same ground, slab and [SlabColors]
 * and has no style of its own. Sizes:
 *
 * - 2x2 ([SIZE_2X2], home default): label, then the slab with the numeral
 *   at 48sp and the caption at 13sp (2 lines max).
 * - 4x2 ([SIZE_4X2]): the cover layout at home type sizes. The date sits
 *   right of the label and "N items · H handled" goes under the slab.
 * - Cover ([SIZE_COVER], Samsung's Flex Window minimum 352x339dp): numeral
 *   72sp, caption 18sp on 1 line, label, date and items line at 16sp.
 *
 * The whole widget is one tap target. It shows counts only, never titles.
 */
object BriefingWidgetSizes {
    val SIZE_2X2 = DpSize(110.dp, 110.dp)
    val SIZE_4X2 = DpSize(250.dp, 110.dp)
    val SIZE_COVER = DpSize(352.dp, 339.dp)
}

/** Which of the three layouts a size gets. */
enum class BriefingLayout(
    val numeralSp: Int,
    val captionSp: Int,
    val captionLines: Int,
    val labelSp: Int,
    val showsSecondary: Boolean,
) {
    HOME_2X2(numeralSp = 48, captionSp = 13, captionLines = 2, labelSp = 13, showsSecondary = false),
    HOME_4X2(numeralSp = 48, captionSp = 13, captionLines = 2, labelSp = 13, showsSecondary = true),
    COVER(numeralSp = 72, captionSp = 18, captionLines = 1, labelSp = 16, showsSecondary = true),
    ;

    companion object {
        fun of(size: DpSize): BriefingLayout =
            when {
                size.width >= BriefingWidgetSizes.SIZE_COVER.width && size.height >= BriefingWidgetSizes.SIZE_COVER.height -> COVER
                size.width >= BriefingWidgetSizes.SIZE_4X2.width -> HOME_4X2
                else -> HOME_2X2
            }
    }
}

class TodaysBriefingWidget : GlanceAppWidget() {
    override val sizeMode =
        SizeMode.Responsive(setOf(BriefingWidgetSizes.SIZE_2X2, BriefingWidgetSizes.SIZE_4X2, BriefingWidgetSizes.SIZE_COVER))

    override suspend fun provideGlance(
        context: Context,
        id: GlanceId,
    ) {
        val initial = BriefingRepository.entry(context)
        provideContent { GlanceTheme { TodaysBriefingContent(liveBriefingEntry(context, initial)) } }
    }
}

/** Home screen (todays_briefing_widget_info: home_screen, 2x2). */
class TodaysBriefingWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = TodaysBriefingWidget()
}

/**
 * Flip 5 cover screen (todays_briefing_cover_widget_info: keyguard,
 * 352x339dp, plus Samsung's sub_screen meta-data). It is a separate receiver
 * so Samsung's minimum does not make the home widget 4+ cells by default.
 */
class TodaysBriefingCoverWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = TodaysBriefingWidget()
}

/** The same [RENDER_VERSION] + produceState reload as the count widgets' liveEntry. */
@Composable
private fun liveBriefingEntry(
    context: Context,
    initial: BriefingEntry,
): BriefingEntry {
    val version = currentState(RENDER_VERSION) ?: 0L
    val entry by produceState(initial, version) { value = BriefingRepository.entry(context) }
    return entry
}

/** Everything the widget shows, worked out away from Glance so it is testable as plain values. */
data class BriefingView(
    val state: BriefingState,
    val label: String,
    /** Right of the label (4x2 and cover, CALLS only): the briefing's date. */
    val date: String?,
    val numeral: Int?,
    val caption: String,
    /** A second line inside the slab: FYI's and All done's. */
    val detail: String?,
    /** Under the slab (4x2 and cover, CALLS only): "12 items · 9 handled". */
    val secondary: String?,
    /** Read aloud for the whole slab, as the count widgets' description(). */
    val description: String,
) {
    companion object {
        /** "Thu 22 Oct", in the person's locale at render time. */
        fun formatDate(date: LocalDate): String = date.format(DateTimeFormatter.ofPattern("EEE d MMM", Locale.getDefault()))

        fun of(
            context: Context,
            entry: BriefingEntry,
            layout: BriefingLayout,
            fontScale: Float,
        ): BriefingView {
            val res = context.resources
            val title = context.getString(R.string.widget_briefing_title)
            val state = entry.state
            val briefing = entry.cached?.briefing
            val large = fontScale > LABEL_FONT_SCALE_LIMIT

            fun items(n: Int) = res.getQuantityString(R.plurals.widget_briefing_items, n, n)

            fun handled(n: Int) = res.getQuantityString(R.plurals.widget_briefing_handled, n, n)
            return when (state) {
                BriefingState.CALLS -> {
                    val b = briefing!!
                    val fullRes = if (b.calls == 1) R.string.widget_briefing_needs_call else R.string.widget_briefing_need_call
                    val full = context.getString(fullRes)
                    val caption = if (large) context.getString(R.string.widget_briefing_your_call) else full
                    val showSecondary = layout.showsSecondary && !large
                    BriefingView(
                        state = state,
                        label = title,
                        date = if (showSecondary) formatDate(b.date) else null,
                        numeral = b.calls,
                        caption = caption,
                        detail = null,
                        secondary =
                            if (showSecondary) {
                                context.getString(R.string.widget_briefing_items_handled, items(b.total), handled(b.handled))
                            } else {
                                null
                            },
                        description = listOf(title, "${b.calls} $full", items(b.total)).joinToString(", "),
                    )
                }
                BriefingState.FYI -> quiet(state, title, context.getString(R.string.widget_briefing_fyi), items(briefing!!.total))
                BriefingState.ALL_DONE -> {
                    val waiting = context.getString(R.string.widget_briefing_nothing_waiting)
                    quiet(state, title, context.getString(R.string.widget_briefing_all_done), waiting)
                }
                BriefingState.NONE -> quiet(state, title, context.getString(R.string.widget_briefing_none), null)
                BriefingState.STALE -> {
                    // A PAST day's count says which day it was, by the BRIEFING's own date (never the
                    // device's). Same day and only older than 30 minutes: still "Today's briefing".
                    val cached = entry.cached
                    val pastDay = cached != null && BriefingState.isPastDay(cached, entry.nowMillis)
                    val label =
                        briefing
                            ?.takeIf { pastDay }
                            ?.let { context.getString(R.string.widget_briefing_stale_label, formatDate(it.date)) }
                            ?: title
                    quiet(state, label, context.getString(R.string.widget_briefing_open_to_refresh), null)
                }
                BriefingState.SIGNED_OUT -> quiet(state, title, context.getString(R.string.widget_briefing_sign_in), null)
            }
        }

        private fun quiet(
            state: BriefingState,
            label: String,
            caption: String,
            detail: String?,
        ) = BriefingView(
            state = state,
            label = label,
            date = null,
            numeral = null,
            caption = caption,
            detail = detail,
            secondary = null,
            description = listOfNotNull(label, caption, detail).joinToString(", "),
        )
    }
}

/** Test tag on the numeral, carrying the size it was actually drawn at (so a size change is visible to tests). */
fun briefingNumeralTag(sp: Int): String = "briefing-numeral-${sp}sp"

@Composable
fun TodaysBriefingContent(entry: BriefingEntry) {
    val context = LocalContext.current
    val layout = BriefingLayout.of(LocalSize.current)
    val view = BriefingView.of(context, entry, layout, context.resources.configuration.fontScale)
    val colors = entry.state.colors
    val content = slabColor(context, colors.content)
    val muted = slabColor(context, R.color.burrow_muted)
    Column(
        modifier =
            GlanceModifier
                .fillMaxSize()
                .appWidgetBackground()
                .background(GlanceTheme.colors.widgetBackground)
                .cornerRadius(16.dp)
                .padding(8.dp)
                .clickable(actionStartActivity(briefingOpenIntent(context, entry))),
    ) {
        Row(modifier = GlanceModifier.fillMaxWidth().padding(start = 4.dp, end = 4.dp, bottom = 4.dp)) {
            Text(
                text = view.label,
                maxLines = 1,
                style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = layout.labelSp.sp, fontWeight = FontWeight.Medium),
                modifier = GlanceModifier.defaultWeight(),
            )
            view.date?.let {
                Text(text = it, maxLines = 1, style = TextStyle(color = muted, fontSize = layout.labelSp.sp))
            }
        }
        Column(
            modifier =
                GlanceModifier
                    .fillMaxWidth()
                    .defaultWeight()
                    .background(slabColor(context, colors.fill))
                    .cornerRadius(12.dp)
                    .padding(if (layout == BriefingLayout.COVER) 16.dp else 10.dp)
                    .semantics { contentDescription = view.description },
            verticalAlignment = Alignment.Bottom,
        ) {
            view.numeral?.let {
                Text(
                    text = it.toString(),
                    maxLines = 1,
                    style = TextStyle(color = content, fontSize = layout.numeralSp.sp, fontWeight = FontWeight.Bold),
                    modifier = GlanceModifier.semantics { testTag = briefingNumeralTag(layout.numeralSp) },
                )
            }
            Text(
                text = view.caption,
                maxLines = layout.captionLines,
                style = TextStyle(color = content, fontSize = layout.captionSp.sp),
            )
            view.detail?.let {
                Text(text = it, maxLines = 1, style = TextStyle(color = content, fontSize = layout.captionSp.sp))
            }
        }
        view.secondary?.let {
            Text(
                text = it,
                maxLines = 1,
                style = TextStyle(color = muted, fontSize = layout.labelSp.sp),
                modifier = GlanceModifier.padding(start = 4.dp, top = 4.dp),
            )
        }
    }
}

/** The page the widget opens: the briefing's own day, or the Inbox when there is none to point at. */
fun briefingPath(entry: BriefingEntry): String {
    val date = entry.cached?.briefing?.date
    return when (entry.state) {
        BriefingState.NONE -> "/inbox"
        else -> if (date == null) "/inbox" else "/inbox/briefing/$date"
    }
}

/**
 * Opens [briefingPath] in the selected install through the same
 * MainActivity path as a notification's Open (as [openIntent]). Signed out
 * or with no install selected, it just opens the app.
 */
fun briefingOpenIntent(
    context: Context,
    entry: BriefingEntry,
): Intent {
    val intent = Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    val host = entry.host
    if (host == null || entry.state == BriefingState.SIGNED_OUT) return intent
    return intent
        .setAction(NotificationPresenter.ACTION_OPEN)
        .setData("burrow-widget://open/briefing".toUri())
        .putExtra(NotificationPresenter.EXTRA_HOST, host)
        .putExtra(NotificationPresenter.EXTRA_PATH, briefingPath(entry))
}
