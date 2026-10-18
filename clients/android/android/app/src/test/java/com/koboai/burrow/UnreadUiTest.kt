package com.koboai.burrow

import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import androidx.core.view.children
import com.koboai.burrow.push.InstallUnread
import com.koboai.burrow.push.PushKeyStore
import com.koboai.burrow.push.UnreadStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.shadows.ShadowLooper
import java.io.File

/** The switcher pills, the switch banner and their resources (task 01a1261e stage 5). */
@RunWith(RobolectricTestRunner::class)
class UnreadUiTest {
    private val a = "burrow-a.localhost"
    private val b = "burrow-b.localhost"

    @Test
    fun `pill text is none at 0, the number at 7, and 99+ at 100`() {
        assertNull(UnreadPill.text(0))
        assertEquals("7", UnreadPill.text(7))
        assertEquals("99+", UnreadPill.text(100))
        assertEquals("99", UnreadPill.text(99))
        assertNull(UnreadPill.text(-1))
    }

    @Test
    fun `the banner shows only for a switch to ANOTHER install`() {
        assertTrue(SwitchBanner.shouldShow(a, b))
        assertFalse(SwitchBanner.shouldShow(b, b))
        assertFalse(SwitchBanner.shouldShow("BURROW-B.localhost", b))
        // Nothing was showing (cold start from a notification): no "switched".
        assertFalse(SwitchBanner.shouldShow(null, b))
    }

    private fun texts(view: View): List<TextView> =
        when (view) {
            is TextView -> listOf(view)
            is ViewGroup -> view.children.flatMap { texts(it) }.toList()
            else -> emptyList()
        }

    private fun picker(counts: () -> Map<String, InstallUnread>): InstallPickerView {
        val context = RuntimeEnvironment.getApplication()
        val store = InstallStore(InMemoryKeyValueStore(), InMemoryKeyValueStore())
        store.add(a, "A")
        store.add(b, "B")
        store.select(a)
        return InstallPickerView(context, store, {}, counts) {}.also { it.refreshUnread() }
    }

    // The first match is the icon tile's monogram (the row's letter), whose
    // parent's parent is the row, as is the name label's. Lists below start
    // with that monogram.
    private fun row(
        view: InstallPickerView,
        name: String,
    ): ViewGroup {
        val label = view.findViewsWithTextRecursive(name).first()
        return label.parent.parent as ViewGroup
    }

    private fun View.findViewsWithTextRecursive(text: String): List<TextView> = texts(this).filter { it.text.toString() == text }

    @Test
    fun `B with 3 shows a 3 pill, A with none shows no pill and keeps its check`() {
        val view = picker { mapOf(b to InstallUnread(3, 1, false)) }
        val bTexts = texts(row(view, "B")).map { it.text.toString() }
        val aTexts = texts(row(view, "A")).map { it.text.toString() }
        assertEquals(listOf("B", "B", b, "3"), bTexts)
        assertEquals(listOf("A", "A", a), aTexts)
        assertFalse(aTexts.contains("0"))
        assertTrue(row(view, "A").contentDescription.toString().endsWith("Selected"))
        assertEquals("B, 3 unread", row(view, "B").contentDescription.toString())
    }

    @Test
    fun `the current install shows its own count, and a big count caps at 99+`() {
        val view = picker { mapOf(a to InstallUnread(2, 1, false), b to InstallUnread(120, 1, false)) }
        assertEquals(listOf("A", "A", a, "2"), texts(row(view, "A")).map { it.text.toString() })
        assertEquals(listOf("B", "B", b, "99+"), texts(row(view, "B")).map { it.text.toString() })
    }

    @Test
    fun `a stale row keeps its count dimmed and reads Could not update`() {
        val view = picker { mapOf(b to InstallUnread(2, 1, true)) }
        val bRow = row(view, "B")
        val labels = texts(bRow)
        assertEquals(listOf("B", "B", "Could not update", "2"), labels.map { it.text.toString() })
        assertEquals(0.5f, labels.last().alpha)
    }

    @Test
    fun `a stale install that is also unreachable reads Could not update, with the red dot, not Can't reach`() {
        InstallProbe.probeOverride = { null }
        try {
            val view = picker { mapOf(b to InstallUnread(2, 1, true)) }
            view.reload()

            fun dotted(label: TextView): Boolean {
                val parent = label.parent as ViewGroup
                return parent.childCount == 2 && parent.getChildAt(0) !is TextView
            }

            fun bStatus() = texts(row(view, "B")).first { it.text.toString() == "Could not update" }
            for (i in 0 until 100) {
                ShadowLooper.idleMainLooper()
                if (texts(view).any { it.text.toString() == "Can't reach. Tap to retry." } && dotted(bStatus())) break
                Thread.sleep(20)
            }
            // Both probes failed: B's status line carries the red reachability dot.
            assertTrue(dotted(bStatus()))
            // A has no cached count: today's unreachable copy.
            assertEquals(listOf("A", "A", "Can't reach. Tap to retry."), texts(row(view, "A")).map { it.text.toString() })
            // B is stale with a cached count: the plan's copy, its last count dimmed.
            assertEquals(listOf("B", "B", "Could not update", "2"), texts(row(view, "B")).map { it.text.toString() })
        } finally {
            InstallProbe.probeOverride = null
        }
    }

    @Test
    fun `a refresh keeps the last counts and the row order`() {
        var counts = mapOf(b to InstallUnread(3, 1, false))
        val view = picker { counts }
        val before = texts(view).map { it.text.toString() }.filter { it == "A" || it == "B" }
        counts = mapOf(a to InstallUnread(5, 2, false), b to InstallUnread(3, 1, false))
        view.refreshUnread()
        val after = texts(view).map { it.text.toString() }.filter { it == "A" || it == "B" }
        assertEquals(before, after)
        assertEquals(listOf("A", "A", a, "5"), texts(row(view, "A")).map { it.text.toString() })
    }

    @Test
    fun `the banner reads Switched to and leaves after 2 seconds`() {
        val context = RuntimeEnvironment.getApplication()
        val parent = FrameLayout(context)
        val banner = SwitchBanner.show(parent, context.getString(R.string.switched_to, "B"))
        assertEquals(listOf("Switched to B"), texts(banner).map { it.text.toString() })
        assertEquals(1, parent.childCount)
        ShadowLooper.idleMainLooper(SwitchBanner.DURATION_MS + 500, java.util.concurrent.TimeUnit.MILLISECONDS)
        assertEquals(0, parent.childCount)
    }

    @Test
    fun `the push key and unread files are excluded from backup`() {
        for (path in listOf("src/main/res/xml/data_extraction_rules.xml", "src/main/res/xml/backup_rules.xml")) {
            val xml = File(path).readText()
            for (file in listOf(PushKeyStore.PREFS_FILE, UnreadStore.FILE)) {
                val count = Regex("path=\"$file\\.xml\"").findAll(xml).count()
                assertEquals("$path must exclude $file in every section", if (path.contains("extraction")) 2 else 1, count)
            }
        }
    }
}
