package com.koboai.burrow

import android.view.View
import android.widget.FrameLayout
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * The picker counts the keyboard once (task 01a12787 review finding 1).
 * Frames are the reviewer's API 35 measurement: window 2400 tall, content
 * from y=136, keyboard 883 px, adjustResize shrinking the picker to end at
 * the keyboard top (y=1517).
 */
@RunWith(RobolectricTestRunner::class)
class PickerInsetsTest {
    private val ime = 883
    private val navBar = 63

    @Test
    fun `the arithmetic pads only for what still overlaps`() {
        // Resized above the keyboard: nothing left to pad.
        assertEquals(0, PickerInsets.bottomPadding(ime, rootHeight = 2400, viewTop = 136, viewHeight = 1381))
        // Not resized (adjustNothing): pad the whole keyboard.
        assertEquals(ime, PickerInsets.bottomPadding(ime, rootHeight = 2400, viewTop = 136, viewHeight = 2264))
        // No keyboard, edge to edge: the navigation bar.
        assertEquals(navBar, PickerInsets.bottomPadding(navBar, rootHeight = 2400, viewTop = 136, viewHeight = 2264))
        // A partial resize pads the rest, never a negative.
        assertEquals(100, PickerInsets.bottomPadding(ime, rootHeight = 2400, viewTop = 136, viewHeight = 1481))
        assertEquals(0, PickerInsets.bottomPadding(0, rootHeight = 2400, viewTop = 136, viewHeight = 1000))
    }

    /** The real picker in a 1080 x 2400 window, laid out at [top] for [height] px, then handed insets. */
    private fun pickerPadding(
        top: Int,
        height: Int,
        imeBottom: Int,
    ): Int {
        val context = RuntimeEnvironment.getApplication()
        val store = InstallStore(InMemoryKeyValueStore(), InMemoryKeyValueStore())
        val picker = InstallPickerView(context, store, {}) {}
        val root = FrameLayout(context)
        root.addView(picker, FrameLayout.LayoutParams(1080, height).apply { topMargin = top })
        val exactly = View.MeasureSpec.EXACTLY
        root.measure(View.MeasureSpec.makeMeasureSpec(1080, exactly), View.MeasureSpec.makeMeasureSpec(2400, exactly))
        root.layout(0, 0, 1080, 2400)
        val insets =
            WindowInsetsCompat
                .Builder()
                .setInsets(WindowInsetsCompat.Type.systemBars(), Insets.of(0, top, 0, navBar))
                .setInsets(WindowInsetsCompat.Type.ime(), Insets.of(0, 0, 0, imeBottom))
                .build()
        ViewCompat.dispatchApplyWindowInsets(picker, insets)
        return picker.paddingBottom
    }

    @Test
    fun `with the window resized above the keyboard, the picker does not pad for it again`() {
        assertEquals(0, pickerPadding(top = 136, height = 1381, imeBottom = ime))
    }

    @Test
    fun `with the window not resized, the picker pads for the keyboard`() {
        assertEquals(ime, pickerPadding(top = 136, height = 2264, imeBottom = ime))
        assertEquals(navBar, pickerPadding(top = 136, height = 2264, imeBottom = 0))
    }
}
