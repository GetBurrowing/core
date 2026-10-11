package com.koboai.burrow

/**
 * The install picker's bottom padding (task 01a12787). The bridge's window
 * resizes above the keyboard (adjustResize), and the inset the picker
 * receives still reports the whole keyboard. Pad only for the part of the
 * keyboard or navigation bar that still overlaps the view, so the keyboard is
 * never counted twice: measured on API 35, counting it twice left the
 * first-launch flow 498 px of a 1381 px picker and put Continue under the
 * keyboard.
 */
object PickerInsets {
    /**
     * [insetBottom] is the largest of the system bar, cutout and IME bottom
     * insets; [rootHeight] the window's height; [viewTop] and [viewHeight] the
     * picker's frame in the window.
     */
    fun bottomPadding(
        insetBottom: Int,
        rootHeight: Int,
        viewTop: Int,
        viewHeight: Int,
    ): Int {
        val belowView = (rootHeight - viewTop - viewHeight).coerceAtLeast(0)
        return (insetBottom - belowView).coerceAtLeast(0)
    }
}
