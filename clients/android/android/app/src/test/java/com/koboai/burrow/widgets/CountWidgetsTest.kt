package com.koboai.burrow.widgets

import androidx.glance.appwidget.testing.unit.runGlanceAppWidgetUnitTest
import androidx.glance.testing.unit.hasText
import androidx.glance.testing.unit.hasTextEqualTo
import com.koboai.burrow.push.NotificationPresenter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/** Glance layouts per size, through glance-appwidget-testing (Robolectric for resources). */
@RunWith(RobolectricTestRunner::class)
class CountWidgetsTest {
    private val now = 1_800_000_000_000L
    private val host = "suite.example.com"
    private val live = CountsEntry(now, host, signedIn = true, counts = Counts(3, 12, now))
    private val signedOut = CountsEntry(now, host, signedIn = false, counts = null)
    private val stale = CountsEntry(now, host, signedIn = true, counts = Counts(3, 12, now - 31 * 60_000L))

    @Test
    fun `2x1 approvals - one slab, label, numeral, caption`() =
        runGlanceAppWidgetUnitTest {
            setAppWidgetSize(CountWidgetSizes.SIZE_2X1)
            setContext(RuntimeEnvironment.getApplication())
            provideComposable { CountWidgetContent(live, SlabKind.APPROVALS) }
            onNode(hasTextEqualTo("My approvals")).assertExists()
            onNode(hasTextEqualTo("3")).assertExists()
            onNode(hasTextEqualTo("waiting on you")).assertExists()
            onNode(hasTextEqualTo("My tasks")).assertDoesNotExist()
        }

    @Test
    fun `2x1 above 1_3x font scale drops the label`() {
        RuntimeEnvironment.setFontScale(1.5f)
        runGlanceAppWidgetUnitTest {
            setAppWidgetSize(CountWidgetSizes.SIZE_2X1)
            setContext(RuntimeEnvironment.getApplication())
            provideComposable { CountWidgetContent(live, SlabKind.APPROVALS) }
            onNode(hasTextEqualTo("My approvals")).assertDoesNotExist()
            onNode(hasTextEqualTo("3")).assertExists()
            onNode(hasTextEqualTo("waiting on you")).assertExists()
        }
    }

    @Test
    fun `2x2 - label above the slab, numeral and caption`() =
        runGlanceAppWidgetUnitTest {
            setAppWidgetSize(CountWidgetSizes.SIZE_2X2)
            setContext(RuntimeEnvironment.getApplication())
            provideComposable { CountWidgetContent(live, SlabKind.TASKS) }
            onNode(hasTextEqualTo("My tasks")).assertExists()
            onNode(hasTextEqualTo("12")).assertExists()
            onNode(hasTextEqualTo("open")).assertExists()
            onNode(hasTextEqualTo("My approvals")).assertDoesNotExist()
        }

    @Test
    fun `4x2 - approvals and tasks side by side`() =
        runGlanceAppWidgetUnitTest {
            setAppWidgetSize(CountWidgetSizes.SIZE_4X2)
            setContext(RuntimeEnvironment.getApplication())
            provideComposable { CountWidgetContent(live, SlabKind.APPROVALS) }
            onNode(hasTextEqualTo("My approvals")).assertExists()
            onNode(hasTextEqualTo("My tasks")).assertExists()
            onNode(hasTextEqualTo("3")).assertExists()
            onNode(hasTextEqualTo("12")).assertExists()
        }

    @Test
    fun `signed out shows no numeral and the sign-in copy`() =
        runGlanceAppWidgetUnitTest {
            setAppWidgetSize(CountWidgetSizes.SIZE_2X2)
            setContext(RuntimeEnvironment.getApplication())
            provideComposable { CountWidgetContent(signedOut, SlabKind.APPROVALS) }
            onNode(hasTextEqualTo("Sign in to see approvals")).assertExists()
            onNode(hasTextEqualTo("3")).assertDoesNotExist()
        }

    @Test
    fun `stale keeps the last numeral with As of`() =
        runGlanceAppWidgetUnitTest {
            setAppWidgetSize(CountWidgetSizes.SIZE_2X2)
            setContext(RuntimeEnvironment.getApplication())
            provideComposable { CountWidgetContent(stale, SlabKind.APPROVALS) }
            onNode(hasTextEqualTo("3")).assertExists()
            onNode(hasText("As of")).assertExists()
        }

    @Test
    fun `each slab deep-links to its own page through the notification Open path`() {
        val app = RuntimeEnvironment.getApplication()
        val approvals = openIntent(app, host, SlabKind.APPROVALS)
        val tasks = openIntent(app, host, SlabKind.TASKS)
        assertEquals(NotificationPresenter.ACTION_OPEN, approvals.action)
        assertEquals("/inbox", approvals.getStringExtra(NotificationPresenter.EXTRA_PATH))
        assertEquals("/tasks", tasks.getStringExtra(NotificationPresenter.EXTRA_PATH))
        assertEquals(host, tasks.getStringExtra(NotificationPresenter.EXTRA_HOST))
        // Distinct data, so the two PendingIntents never overwrite each other.
        assertEquals(false, approvals.filterEquals(tasks))
        assertNull(openIntent(app, null, SlabKind.APPROVALS).action)
    }
}
