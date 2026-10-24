package com.koboai.burrow.widgets

import androidx.glance.appwidget.testing.unit.runGlanceAppWidgetUnitTest
import androidx.glance.testing.unit.hasContentDescriptionEqualTo
import androidx.glance.testing.unit.hasTestTag
import androidx.glance.testing.unit.hasTextEqualTo
import com.koboai.burrow.push.NotificationPresenter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import java.time.Instant
import java.time.LocalDate

/** Today's briefing layouts per state and size (canvas 01a161fa), through glance-appwidget-testing. */
@RunWith(RobolectricTestRunner::class)
class TodaysBriefingWidgetTest {
    private val host = "burrow.example.com"
    private val zone = "UTC"

    /**
     * Thursday 2026-10-22, noon UTC, so the device and the server agree on the day. The canvas's
     * example "Wed 22 Oct" has the wrong weekday for 2026; the format (EEE d MMM) is the canvas's.
     */
    private val today = LocalDate.parse("2026-10-22")
    private val now = Instant.parse("2026-10-22T12:00:00Z").toEpochMilli()

    private fun entry(
        briefing: Briefing?,
        today: LocalDate = this.today,
        fetchedAt: Long = now - 60_000L,
        signedIn: Boolean = true,
        cached: Boolean = true,
    ) = BriefingEntry(now, host, signedIn, if (cached) CachedBriefing(today, zone, briefing, fetchedAt) else null)

    private val calls = entry(Briefing(today, total = 12, open = 5, calls = 3, handled = 9))
    private val oneCall = entry(Briefing(today, total = 12, open = 1, calls = 1, handled = 11))
    private val fyi = entry(Briefing(today, total = 12, open = 3, calls = 0, handled = 9))
    private val allDone = entry(Briefing(today, total = 12, open = 0, calls = 0, handled = 12))
    private val none = entry(null)
    private val yesterday = LocalDate.parse("2026-10-21")
    private val stale = entry(Briefing(yesterday, total = 8, open = 4, calls = 4, handled = 4), today = yesterday)
    private val signedOut = entry(null, signedIn = false, cached = false)

    private val numeral48 = hasTestTag(briefingNumeralTag(48))
    private val numeral72 = hasTestTag(briefingNumeralTag(72))

    @Test
    fun `fixture states are the ones named`() {
        assertEquals(BriefingState.CALLS, calls.state)
        assertEquals(BriefingState.FYI, fyi.state)
        assertEquals(BriefingState.ALL_DONE, allDone.state)
        assertEquals(BriefingState.NONE, none.state)
        assertEquals(BriefingState.STALE, stale.state)
        assertEquals(BriefingState.SIGNED_OUT, signedOut.state)
    }

    @Test
    fun `2x2 calls - label, numeral at 48sp, caption, no secondary line`() =
        runGlanceAppWidgetUnitTest {
            setAppWidgetSize(BriefingWidgetSizes.SIZE_2X2)
            setContext(RuntimeEnvironment.getApplication())
            provideComposable { TodaysBriefingContent(calls) }
            onNode(hasTextEqualTo("Today's briefing")).assertExists()
            onNode(hasTextEqualTo("3")).assertExists()
            onNode(numeral48).assertExists()
            onNode(hasTextEqualTo("need your call")).assertExists()
            onNode(hasTextEqualTo("12 items · 9 handled")).assertDoesNotExist()
            onNode(hasTextEqualTo("Thu 22 Oct")).assertDoesNotExist()
        }

    @Test
    fun `2x2 one call - needs your call`() =
        runGlanceAppWidgetUnitTest {
            setAppWidgetSize(BriefingWidgetSizes.SIZE_2X2)
            setContext(RuntimeEnvironment.getApplication())
            provideComposable { TodaysBriefingContent(oneCall) }
            onNode(hasTextEqualTo("1")).assertExists()
            onNode(hasTextEqualTo("needs your call")).assertExists()
            onNode(hasTextEqualTo("need your call")).assertDoesNotExist()
        }

    @Test
    fun `2x2 FYI - FYI only and item count, no numeral`() =
        runGlanceAppWidgetUnitTest {
            setAppWidgetSize(BriefingWidgetSizes.SIZE_2X2)
            setContext(RuntimeEnvironment.getApplication())
            provideComposable { TodaysBriefingContent(fyi) }
            onNode(hasTextEqualTo("FYI only")).assertExists()
            onNode(hasTextEqualTo("12 items")).assertExists()
            onNode(numeral48).assertDoesNotExist()
            onNode(hasTextEqualTo("0")).assertDoesNotExist()
            onNode(hasTextEqualTo("3")).assertDoesNotExist()
        }

    @Test
    fun `2x2 all done - never a 0`() =
        runGlanceAppWidgetUnitTest {
            setAppWidgetSize(BriefingWidgetSizes.SIZE_2X2)
            setContext(RuntimeEnvironment.getApplication())
            provideComposable { TodaysBriefingContent(allDone) }
            onNode(hasTextEqualTo("All done")).assertExists()
            onNode(hasTextEqualTo("Nothing waiting")).assertExists()
            onNode(hasTextEqualTo("0")).assertDoesNotExist()
            onNode(numeral48).assertDoesNotExist()
        }

    @Test
    fun `2x2 no briefing today`() =
        runGlanceAppWidgetUnitTest {
            setAppWidgetSize(BriefingWidgetSizes.SIZE_2X2)
            setContext(RuntimeEnvironment.getApplication())
            provideComposable { TodaysBriefingContent(none) }
            onNode(hasTextEqualTo("Today's briefing")).assertExists()
            onNode(hasTextEqualTo("No briefing today")).assertExists()
            onNode(numeral48).assertDoesNotExist()
        }

    @Test
    fun `2x2 stale - the briefing's own date in the label, no numeral`() =
        runGlanceAppWidgetUnitTest {
            setAppWidgetSize(BriefingWidgetSizes.SIZE_2X2)
            setContext(RuntimeEnvironment.getApplication())
            provideComposable { TodaysBriefingContent(stale) }
            onNode(hasTextEqualTo("Briefing · Wed 21 Oct")).assertExists()
            onNode(hasTextEqualTo("Briefing · Thu 22 Oct")).assertDoesNotExist()
            onNode(hasTextEqualTo("Open to refresh")).assertExists()
            onNode(hasTextEqualTo("4")).assertDoesNotExist()
            onNode(numeral48).assertDoesNotExist()
        }

    /** Same day, last fetched 31 minutes ago: STALE by fetch age only (declared deviation 1). */
    private val agedToday = entry(Briefing(today, total = 12, open = 5, calls = 3, handled = 9), fetchedAt = now - 31 * 60_000L)

    @Test
    fun `same-day stale by age - label stays Today's briefing, Open to refresh, no numeral`() =
        runGlanceAppWidgetUnitTest {
            assertEquals(BriefingState.STALE, agedToday.state)
            setAppWidgetSize(BriefingWidgetSizes.SIZE_2X2)
            setContext(RuntimeEnvironment.getApplication())
            provideComposable { TodaysBriefingContent(agedToday) }
            onNode(hasTextEqualTo("Today's briefing")).assertExists()
            onNode(hasTextEqualTo("Briefing · Thu 22 Oct")).assertDoesNotExist()
            onNode(hasTextEqualTo("Open to refresh")).assertExists()
            onNode(hasTextEqualTo("3")).assertDoesNotExist()
            onNode(numeral48).assertDoesNotExist()
        }

    @Test
    fun `cover same-day stale by age - label stays Today's briefing, no numeral`() =
        runGlanceAppWidgetUnitTest {
            setAppWidgetSize(BriefingWidgetSizes.SIZE_COVER)
            setContext(RuntimeEnvironment.getApplication())
            provideComposable { TodaysBriefingContent(agedToday) }
            onNode(hasTextEqualTo("Today's briefing")).assertExists()
            onNode(hasTextEqualTo("Briefing · Thu 22 Oct")).assertDoesNotExist()
            onNode(hasTextEqualTo("Open to refresh")).assertExists()
            onNode(numeral72).assertDoesNotExist()
        }

    @Test
    fun `2x2 signed out`() =
        runGlanceAppWidgetUnitTest {
            setAppWidgetSize(BriefingWidgetSizes.SIZE_2X2)
            setContext(RuntimeEnvironment.getApplication())
            provideComposable { TodaysBriefingContent(signedOut) }
            onNode(hasTextEqualTo("Open Burrow to sign in")).assertExists()
            onNode(numeral48).assertDoesNotExist()
        }

    @Test
    fun `4x2 calls - date and secondary line, numeral at 48sp`() =
        runGlanceAppWidgetUnitTest {
            setAppWidgetSize(BriefingWidgetSizes.SIZE_4X2)
            setContext(RuntimeEnvironment.getApplication())
            provideComposable { TodaysBriefingContent(calls) }
            onNode(hasTextEqualTo("Today's briefing")).assertExists()
            onNode(hasTextEqualTo("Thu 22 Oct")).assertExists()
            onNode(numeral48).assertExists()
            onNode(hasTextEqualTo("need your call")).assertExists()
            onNode(hasTextEqualTo("12 items · 9 handled")).assertExists()
        }

    @Test
    fun `cover calls - numeral at 72sp, date and secondary line`() =
        runGlanceAppWidgetUnitTest {
            setAppWidgetSize(BriefingWidgetSizes.SIZE_COVER)
            setContext(RuntimeEnvironment.getApplication())
            provideComposable { TodaysBriefingContent(calls) }
            onNode(hasTextEqualTo("3")).assertExists()
            onNode(numeral72).assertExists()
            onNode(numeral48).assertDoesNotExist()
            onNode(hasTextEqualTo("Thu 22 Oct")).assertExists()
            onNode(hasTextEqualTo("need your call")).assertExists()
            onNode(hasTextEqualTo("12 items · 9 handled")).assertExists()
        }

    @Test
    fun `font scale 1_5 drops the secondary line and keeps the numeral`() {
        RuntimeEnvironment.setFontScale(1.5f)
        runGlanceAppWidgetUnitTest {
            setAppWidgetSize(BriefingWidgetSizes.SIZE_COVER)
            setContext(RuntimeEnvironment.getApplication())
            provideComposable { TodaysBriefingContent(calls) }
            onNode(hasTextEqualTo("12 items · 9 handled")).assertDoesNotExist()
            onNode(hasTextEqualTo("Thu 22 Oct")).assertDoesNotExist()
            onNode(hasTextEqualTo("3")).assertExists()
            onNode(numeral72).assertExists()
            onNode(hasTextEqualTo("your call")).assertExists()
        }
    }

    @Test
    fun `accessible description in the count widgets' format`() {
        val app = RuntimeEnvironment.getApplication()
        assertEquals(
            "Today's briefing, 3 need your call, 12 items",
            BriefingView.of(app, calls, BriefingLayout.HOME_2X2, 1f).description,
        )
        // Shortening the caption for large fonts never shortens what is read aloud.
        assertEquals(
            "Today's briefing, 3 need your call, 12 items",
            BriefingView.of(app, calls, BriefingLayout.COVER, 1.5f).description,
        )
        assertEquals("Today's briefing, FYI only, 12 items", BriefingView.of(app, fyi, BriefingLayout.HOME_2X2, 1f).description)
        runGlanceAppWidgetUnitTest {
            setAppWidgetSize(BriefingWidgetSizes.SIZE_2X2)
            setContext(app)
            provideComposable { TodaysBriefingContent(calls) }
            onNode(hasContentDescriptionEqualTo("Today's briefing, 3 need your call, 12 items")).assertExists()
        }
    }

    @Test
    fun `layout by size`() {
        assertEquals(BriefingLayout.HOME_2X2, BriefingLayout.of(BriefingWidgetSizes.SIZE_2X2))
        assertEquals(BriefingLayout.HOME_4X2, BriefingLayout.of(BriefingWidgetSizes.SIZE_4X2))
        assertEquals(BriefingLayout.COVER, BriefingLayout.of(BriefingWidgetSizes.SIZE_COVER))
    }

    @Test
    fun `opens the briefing's own day through the notification Open path`() {
        val app = RuntimeEnvironment.getApplication()
        val open = briefingOpenIntent(app, calls)
        assertEquals(NotificationPresenter.ACTION_OPEN, open.action)
        assertEquals("/inbox/briefing/2026-10-22", open.getStringExtra(NotificationPresenter.EXTRA_PATH))
        assertEquals(host, open.getStringExtra(NotificationPresenter.EXTRA_HOST))
        assertEquals("burrow-widget://open/briefing", open.dataString)
        // Distinct from the count widgets' data, so the PendingIntents never overwrite each other.
        assertEquals(false, open.filterEquals(openIntent(app, host, SlabKind.APPROVALS)))
        assertEquals("/inbox", briefingOpenIntent(app, none).getStringExtra(NotificationPresenter.EXTRA_PATH))
        // Stale with nothing cached has no date to point at.
        assertEquals("/inbox", briefingOpenIntent(app, entry(null, cached = false)).getStringExtra(NotificationPresenter.EXTRA_PATH))
        assertEquals("/inbox/briefing/2026-10-21", briefingOpenIntent(app, stale).getStringExtra(NotificationPresenter.EXTRA_PATH))
        // Signed out or no install: just the app.
        assertNull(briefingOpenIntent(app, signedOut).action)
        assertNull(briefingOpenIntent(app, BriefingEntry(now, null, false, null)).action)
    }

    @Test
    fun `both receivers render the briefing widget and render() re-renders it`() {
        assertTrue(TodaysBriefingWidgetReceiver().glanceAppWidget is TodaysBriefingWidget)
        assertTrue(TodaysBriefingCoverWidgetReceiver().glanceAppWidget is TodaysBriefingWidget)
        val rendered = WidgetRefresh.renderedWidgets().map { it.javaClass.name }
        assertTrue(rendered.toString(), TodaysBriefingWidget::class.java.name in rendered)
        assertTrue(rendered.toString(), MyApprovalsWidget::class.java.name in rendered)
        assertTrue(rendered.toString(), MyTasksWidget::class.java.name in rendered)
    }
}
