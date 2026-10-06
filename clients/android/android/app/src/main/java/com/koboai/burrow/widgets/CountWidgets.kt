package com.koboai.burrow.widgets

import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import androidx.annotation.ColorRes
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.net.toUri
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.action.Action
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.appWidgetBackground
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.color.ColorProvider
import androidx.glance.currentState
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxHeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.semantics.contentDescription
import androidx.glance.semantics.semantics
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import com.koboai.burrow.MainActivity
import com.koboai.burrow.push.NotificationPresenter
import androidx.glance.unit.ColorProvider as GlanceColor

/**
 * The count widgets (canvas 01a10d91, "Glance widgets"), sizes:
 *
 * - 2x1 ([SIZE_2X1], My approvals only): one slab across the widget, label
 *   left 13sp, numeral right 28sp; above 1.3x font scale the label goes.
 * - 2x2 ([SIZE_2X2], the default): label top-left 13sp, the slab below,
 *   numeral 48sp bottom-left.
 * - 4x2 ([SIZE_4X2]): My approvals and My tasks side by side, each its own
 *   deep link.
 *
 * The widget background and label follow the system (GlanceTheme, dynamic
 * colour on Android 12+). The slab does NOT: [SlabColors] holds it to fixed
 * resources. Numerals are the system sans at Bold (Glance cannot load
 * Public Sans, and has no tabular-figures setting).
 */
object CountWidgetSizes {
    val SIZE_2X1 = DpSize(110.dp, 40.dp)
    val SIZE_2X2 = DpSize(110.dp, 110.dp)
    val SIZE_4X2 = DpSize(250.dp, 110.dp)
}

class MyApprovalsWidget : GlanceAppWidget() {
    override val sizeMode =
        SizeMode.Responsive(setOf(CountWidgetSizes.SIZE_2X1, CountWidgetSizes.SIZE_2X2, CountWidgetSizes.SIZE_4X2))

    override suspend fun provideGlance(
        context: Context,
        id: GlanceId,
    ) {
        val initial = CountsRepository.entry(context)
        provideContent { GlanceTheme { CountWidgetContent(liveEntry(context, initial), SlabKind.APPROVALS) } }
    }
}

class MyTasksWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Responsive(setOf(CountWidgetSizes.SIZE_2X2, CountWidgetSizes.SIZE_4X2))

    override suspend fun provideGlance(
        context: Context,
        id: GlanceId,
    ) {
        val initial = CountsRepository.entry(context)
        provideContent { GlanceTheme { CountWidgetContent(liveEntry(context, initial), SlabKind.TASKS) } }
    }
}

class MyApprovalsWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = MyApprovalsWidget()
}

class MyTasksWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = MyTasksWidget()
}

/**
 * The entry, re-read whenever [WidgetRefresh.render] bumps the widget's
 * [RENDER_VERSION]. A running Glance session does NOT call provideGlance
 * again on update (measured on the API 35 emulator: a widget kept showing
 * "3 waiting on you" after the counts went to zero), so the data has to be
 * loaded inside the composition, keyed on state the update changes.
 */
@Composable
private fun liveEntry(
    context: Context,
    initial: CountsEntry,
): CountsEntry {
    val version = currentState(RENDER_VERSION) ?: 0L
    val entry by produceState(initial, version) { value = CountsRepository.entry(context) }
    return entry
}

/** Bumped by [WidgetRefresh.render] for every widget id, so each recomposes with fresh data. */
val RENDER_VERSION = longPreferencesKey("render_version")

/** Font scale above which the 2x1 drops its label. */
const val LABEL_FONT_SCALE_LIMIT = 1.3f

@Composable
fun CountWidgetContent(
    entry: CountsEntry,
    kind: SlabKind,
) {
    val size = LocalSize.current
    val fontScale = LocalContext.current.resources.configuration.fontScale
    val root =
        GlanceModifier
            .fillMaxSize()
            .appWidgetBackground()
            .background(GlanceTheme.colors.widgetBackground)
            .cornerRadius(16.dp)
            .padding(8.dp)
    when {
        size.width >= CountWidgetSizes.SIZE_4X2.width ->
            Row(modifier = root) {
                LabelledSlab(entry, SlabKind.APPROVALS, GlanceModifier.defaultWeight().fillMaxHeight())
                Spacer(GlanceModifier.width(8.dp))
                LabelledSlab(entry, SlabKind.TASKS, GlanceModifier.defaultWeight().fillMaxHeight())
            }
        size.height < CountWidgetSizes.SIZE_2X2.height && kind == SlabKind.APPROVALS ->
            Box(modifier = root) { WideSlab(entry, kind, showLabel = fontScale <= LABEL_FONT_SCALE_LIMIT) }
        else -> Box(modifier = root) { LabelledSlab(entry, kind, GlanceModifier.fillMaxSize()) }
    }
}

/** Label above, slab below (2x2, and each half of 4x2). */
@Composable
private fun LabelledSlab(
    entry: CountsEntry,
    kind: SlabKind,
    modifier: GlanceModifier,
) {
    Column(modifier = modifier.clickable(openAction(entry, kind))) {
        Text(
            text = kind.title,
            maxLines = 1,
            style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 13.sp, fontWeight = FontWeight.Medium),
            modifier = GlanceModifier.padding(start = 4.dp, bottom = 4.dp),
        )
        val state = entry.state(kind)
        val colors = SlabColors.of(state)
        val content = slabColor(LocalContext.current, colors.content)
        Column(
            modifier =
                GlanceModifier
                    .fillMaxSize()
                    .background(slabColor(LocalContext.current, colors.fill))
                    .cornerRadius(12.dp)
                    .padding(10.dp)
                    .semantics { contentDescription = description(entry, kind) },
            verticalAlignment = Alignment.Bottom,
        ) {
            entry.count(kind)?.let {
                Text(
                    text = it.toString(),
                    maxLines = 1,
                    style = TextStyle(color = content, fontSize = 48.sp, fontWeight = FontWeight.Bold),
                )
            }
            Text(text = entry.caption(kind), maxLines = 2, style = TextStyle(color = content, fontSize = 13.sp))
        }
    }
}

/** 2x1: one slab, label left, numeral right. */
@Composable
private fun WideSlab(
    entry: CountsEntry,
    kind: SlabKind,
    showLabel: Boolean,
) {
    val state = entry.state(kind)
    val colors = SlabColors.of(state)
    val content = slabColor(LocalContext.current, colors.content)
    Row(
        modifier =
            GlanceModifier
                .fillMaxSize()
                .background(slabColor(LocalContext.current, colors.fill))
                .cornerRadius(12.dp)
                .padding(horizontal = 12.dp)
                .clickable(openAction(entry, kind))
                .semantics { contentDescription = description(entry, kind) },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = GlanceModifier.defaultWeight()) {
            if (showLabel) {
                Text(text = kind.title, maxLines = 1, style = TextStyle(color = content, fontSize = 13.sp, fontWeight = FontWeight.Medium))
            }
            Text(text = entry.caption(kind), maxLines = 1, style = TextStyle(color = content, fontSize = 13.sp))
        }
        entry.count(kind)?.let {
            Text(text = it.toString(), maxLines = 1, style = TextStyle(color = content, fontSize = 28.sp, fontWeight = FontWeight.Bold))
        }
    }
}

private fun description(
    entry: CountsEntry,
    kind: SlabKind,
): String = listOfNotNull(kind.title, entry.count(kind)?.toString(), entry.caption(kind)).joinToString(", ")

/**
 * Opens [kind]'s page in the selected install through the same
 * MainActivity path as a notification's Open (install switch, handoff,
 * path guard). With no install selected, just the app.
 */
fun openIntent(
    context: Context,
    host: String?,
    kind: SlabKind,
): Intent {
    val intent = Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    if (host == null) return intent
    return intent
        .setAction(NotificationPresenter.ACTION_OPEN)
        .setData("burrow-widget://open/${kind.name.lowercase()}".toUri())
        .putExtra(NotificationPresenter.EXTRA_HOST, host)
        .putExtra(NotificationPresenter.EXTRA_PATH, kind.path)
}

@Composable
private fun openAction(
    entry: CountsEntry,
    kind: SlabKind,
): Action = actionStartActivity(openIntent(LocalContext.current, entry.host, kind))

/**
 * A FIXED colour resource as a Glance colour: its light value by day and its
 * values-night value by night, read from colors.xml (never a dynamic
 * Material You colour; see [SlabColors]).
 */
fun slabColor(
    context: Context,
    @ColorRes res: Int,
): GlanceColor {
    fun at(night: Boolean): Color {
        val config = Configuration(context.resources.configuration)
        config.uiMode =
            (config.uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
            (if (night) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO)
        return Color(context.createConfigurationContext(config).getColor(res))
    }
    return ColorProvider(day = at(false), night = at(true))
}
