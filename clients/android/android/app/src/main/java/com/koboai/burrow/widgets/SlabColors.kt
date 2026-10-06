package com.koboai.burrow.widgets

import androidx.annotation.ColorRes
import com.koboai.burrow.R

/**
 * The slab's fill and content colours: THE ONLY place outside colors.xml
 * that may name `burrow_info` (WidgetColourGuardTest fails on any other
 * reference). Both pairs are FIXED resources, never a dynamic Material You
 * colour: a teal wallpaper turns dynamic surface-variant teal, which a
 * glance would read as live (canvas 01a10d91, "Signature element").
 */
data class SlabColors(
    @param:ColorRes val fill: Int,
    @param:ColorRes val content: Int,
) {
    companion object {
        fun of(state: SlabState): SlabColors =
            if (state.usesLiveFill) {
                SlabColors(R.color.burrow_info, R.color.burrow_on_info)
            } else {
                SlabColors(R.color.burrow_surface_muted, R.color.burrow_on_surface)
            }
    }
}
