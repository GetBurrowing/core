package com.koboai.burrow.widgets

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.TimeZone

class BriefingStateTest {
    private val zone = "America/Chicago"

    // 2026-10-23T15:00Z = 10:00 in Chicago (CDT), so today there is 2026-10-23.
    private val now = Instant.parse("2026-10-23T15:00:00Z").toEpochMilli()
    private val today = LocalDate.parse("2026-10-23")
    private val min = 60_000L

    private fun briefing(
        calls: Int,
        open: Int,
        date: LocalDate = today,
    ) = Briefing(date, total = calls + open + 2, open = open, calls = calls, handled = 2)

    private fun cached(
        briefing: Briefing?,
        fetchedAt: Long = now,
        serverToday: LocalDate = today,
    ) = CachedBriefing(serverToday, zone, briefing, fetchedAt)

    @Test
    fun `signed out wins over everything`() {
        assertEquals(BriefingState.SIGNED_OUT, BriefingState.of(cached(briefing(3, 4)), now, signedIn = false))
        assertEquals(BriefingState.SIGNED_OUT, BriefingState.of(null, now, signedIn = false))
    }

    @Test
    fun `nothing cached is stale`() {
        assertEquals(BriefingState.STALE, BriefingState.of(null, now, signedIn = true))
    }

    @Test
    fun `calls, fyi, all done and none`() {
        assertEquals(BriefingState.CALLS, BriefingState.of(cached(briefing(calls = 2, open = 5)), now, true))
        assertEquals(BriefingState.CALLS, BriefingState.of(cached(briefing(calls = 1, open = 0)), now, true))
        assertEquals(BriefingState.FYI, BriefingState.of(cached(briefing(calls = 0, open = 3)), now, true))
        assertEquals(BriefingState.ALL_DONE, BriefingState.of(cached(briefing(calls = 0, open = 0)), now, true))
        assertEquals(BriefingState.NONE, BriefingState.of(cached(null), now, true))
    }

    @Test
    fun `exactly 30 minutes old is fresh, one millisecond more is stale`() {
        assertEquals(BriefingState.FYI, BriefingState.of(cached(briefing(0, 3), fetchedAt = now - 30 * min), now, true))
        assertEquals(BriefingState.STALE, BriefingState.of(cached(briefing(0, 3), fetchedAt = now - 30 * min - 1), now, true))
        assertEquals(BriefingState.NONE, BriefingState.of(cached(null, fetchedAt = now - 30 * min), now, true))
        assertEquals(BriefingState.STALE, BriefingState.of(cached(null, fetchedAt = now - 30 * min - 1), now, true))
    }

    @Test
    fun `yesterday's briefing is stale even when just fetched`() {
        val yesterday = today.minusDays(1)
        assertEquals(BriefingState.STALE, BriefingState.of(cached(briefing(2, 1, date = yesterday)), now, true))
        // No briefing: the server's own today is the applies-to date.
        assertEquals(BriefingState.STALE, BriefingState.of(cached(null, serverToday = yesterday), now, true))
    }

    @Test
    fun `today is the SERVER zone's today, not the device's`() {
        val saved = TimeZone.getDefault()
        try {
            TimeZone.setDefault(TimeZone.getTimeZone("UTC"))
            // 04:30Z on the 23rd is 23:30 on the 22nd in Chicago.
            val at = Instant.parse("2026-10-23T04:30:00Z").toEpochMilli()
            val the22nd = LocalDate.parse("2026-10-22")
            val c = CachedBriefing(the22nd, zone, Briefing(the22nd, 3, 1, 0, 2), at)
            assertEquals(BriefingState.FYI, BriefingState.of(c, at, signedIn = true))
        } finally {
            TimeZone.setDefault(saved)
        }
    }

    @Test
    fun `isPastDay separates a past day from a same-day answer that is only old`() {
        // Same day, 31 minutes old: STALE by age alone, not a past day.
        val aged = cached(briefing(3, 1), fetchedAt = now - 31 * min)
        assertEquals(BriefingState.STALE, BriefingState.of(aged, now, true))
        assertFalse(BriefingState.isPastDay(aged, now))
        // Yesterday's, just fetched: a past day.
        val yesterday = cached(briefing(3, 1, date = today.minusDays(1)), fetchedAt = now)
        assertTrue(BriefingState.isPastDay(yesterday, now))
        // The SERVER zone decides: 04:30Z on the 23rd is still the 22nd in Chicago.
        val at = Instant.parse("2026-10-23T04:30:00Z").toEpochMilli()
        val the22nd = LocalDate.parse("2026-10-22")
        assertFalse(BriefingState.isPastDay(CachedBriefing(the22nd, zone, Briefing(the22nd, 3, 1, 0, 2), at - 31 * min), at))
        // No zone: today cannot be proven.
        assertTrue(BriefingState.isPastDay(CachedBriefing(today, "Not/AZone", briefing(1, 1), now), now))
    }

    @Test
    fun `an unreadable zone cannot be fresh`() {
        val c = CachedBriefing(today, "Not/AZone", briefing(1, 1), now)
        assertEquals(BriefingState.STALE, BriefingState.of(c, now, signedIn = true))
    }

    @Test
    fun `only CALLS uses the live fill, through the unchanged slab colours`() {
        assertEquals(listOf(BriefingState.CALLS), BriefingState.entries.filter { it.usesLiveFill })
        for (state in BriefingState.entries) {
            assertEquals(state.usesLiveFill, state.slabState.usesLiveFill)
            assertEquals(SlabColors.of(state.slabState), state.colors)
        }
        assertTrue(BriefingState.CALLS.colors == SlabColors.of(SlabState.LIVE))
        assertFalse(BriefingState.FYI.colors == SlabColors.of(SlabState.LIVE))
    }

    @Test
    fun `the entry decides through the same rule`() {
        assertEquals(BriefingState.CALLS, BriefingEntry(now, "burrow.example.com", true, cached(briefing(1, 0))).state)
        assertEquals(BriefingState.SIGNED_OUT, BriefingEntry(now, null, false, null).state)
    }

    @Test
    fun `the stale render is the earlier of the 30-minute boundary and the server zone's midnight`() {
        // 10:00 Chicago: the 30-minute boundary comes first.
        val c = cached(briefing(1, 0))
        assertEquals(now + 30 * min + 1_000, BriefingState.staleRenderAt(c, now))
        // 23:50 Chicago: midnight (05:00Z next day in CDT) comes first.
        val late = Instant.parse("2026-10-24T04:50:00Z").toEpochMilli()
        val lateCached = cached(briefing(1, 0), fetchedAt = late)
        val midnight =
            LocalDate
                .parse("2026-10-24")
                .atStartOfDay(ZoneId.of(zone))
                .toInstant()
                .toEpochMilli()
        assertEquals(midnight + 1_000, BriefingState.staleRenderAt(lateCached, late))
        assertEquals(BriefingState.STALE, BriefingState.of(lateCached, midnight + 1_000, true))
    }
}
