package com.koboai.burrow.widgets

import com.koboai.burrow.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.Locale
import java.util.TimeZone

class SlabStateTest {
    private val now = 1_800_000_000_000L
    private val min = 60_000L

    @Test
    fun `the four states, with the 30-minute boundary exactly as iOS`() {
        assertEquals(SlabState.LIVE, SlabState.of(3, now, now, signedIn = true))
        assertEquals(SlabState.ZERO, SlabState.of(0, now, now, signedIn = true))
        // Exactly 30 minutes old is still fresh; one millisecond more is stale.
        assertEquals(SlabState.LIVE, SlabState.of(3, now - 30 * min, now, signedIn = true))
        assertEquals(SlabState.STALE, SlabState.of(3, now - 30 * min - 1, now, signedIn = true))
        assertEquals(SlabState.STALE, SlabState.of(0, now - 31 * min, now, signedIn = true))
        // Signed out wins over everything.
        assertEquals(SlabState.SIGNED_OUT, SlabState.of(3, now, now, signedIn = false))
        assertEquals(30 * min, SlabState.STALE_AFTER_MILLIS)
    }

    @Test
    fun `entries - signed in with nothing ever fetched is stale, not live`() {
        val never = CountsEntry(now, "h", signedIn = true, counts = null)
        assertEquals(SlabState.STALE, never.state(SlabKind.APPROVALS))
        assertEquals("Not loaded yet", never.caption(SlabKind.APPROVALS))
        assertNull(never.count(SlabKind.APPROVALS))

        val out = CountsEntry(now, "h", signedIn = false, counts = Counts(3, 1, now))
        assertEquals(SlabState.SIGNED_OUT, out.state(SlabKind.TASKS))
        assertNull(out.count(SlabKind.APPROVALS))

        val live = CountsEntry(now, "h", signedIn = true, counts = Counts(3, 0, now))
        assertEquals(SlabState.LIVE, live.state(SlabKind.APPROVALS))
        assertEquals(SlabState.ZERO, live.state(SlabKind.TASKS))
        assertEquals(3, live.count(SlabKind.APPROVALS))
    }

    @Test
    fun `captions follow the iOS copy`() {
        assertEquals("waiting on you", SlabKind.APPROVALS.caption(SlabState.LIVE, now))
        assertEquals("open", SlabKind.TASKS.caption(SlabState.LIVE, now))
        assertEquals("Nothing waiting", SlabKind.APPROVALS.caption(SlabState.ZERO, now))
        assertEquals("Nothing open", SlabKind.TASKS.caption(SlabState.ZERO, now))
        assertEquals("Sign in to see approvals", SlabKind.APPROVALS.caption(SlabState.SIGNED_OUT, null))
        assertEquals("Sign in to see tasks", SlabKind.TASKS.caption(SlabState.SIGNED_OUT, null))
        // 2027-01-14 14:14:00 UTC
        val at = 1_799_936_040_000L
        val stale = SlabKind.TASKS.caption(SlabState.STALE, at, TimeZone.getTimeZone("UTC"), Locale.US)
        assertEquals("As of 2:14 PM", stale.replace(" PM", " PM"))
        assertEquals("/inbox", SlabKind.APPROVALS.path)
        assertEquals("/tasks", SlabKind.TASKS.path)
    }

    @Test
    fun `cyan is the LIVE fill and nothing else`() {
        for (state in SlabState.entries) {
            val colors = SlabColors.of(state)
            if (state == SlabState.LIVE) {
                assertEquals(SlabColors(R.color.burrow_info, R.color.burrow_on_info), colors)
            } else {
                assertEquals("$state", SlabColors(R.color.burrow_surface_muted, R.color.burrow_on_surface), colors)
            }
        }
    }
}
