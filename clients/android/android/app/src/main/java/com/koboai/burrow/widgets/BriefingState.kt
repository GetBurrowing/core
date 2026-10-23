package com.koboai.burrow.widgets

import java.time.Instant
import java.time.ZoneId

/**
 * What the Today's briefing widget shows. Same family rule as [SlabState]:
 * only [CALLS] (fresh, with calls waiting on the person) is live and gets
 * the live fill, through [slabState] and the unchanged [SlabColors.of].
 */
enum class BriefingState {
    /** Fresh, today's, and at least one call waiting on the person. */
    CALLS,

    /** Fresh, today's, no calls but items still open. */
    FYI,

    /** Fresh, today's, everything handled. */
    ALL_DONE,

    /** Fresh, and the server has no briefing for today. */
    NONE,

    /** Never loaded, a different day's answer, or older than [SlabState.STALE_AFTER_MILLIS]. */
    STALE,

    /** No bearer for the selected install. */
    SIGNED_OUT,
    ;

    val usesLiveFill: Boolean get() = this == CALLS

    /** The slab state whose colours this state wears: only CALLS maps to LIVE. */
    val slabState: SlabState
        get() =
            when (this) {
                CALLS -> SlabState.LIVE
                FYI, ALL_DONE, NONE -> SlabState.ZERO
                STALE -> SlabState.STALE
                SIGNED_OUT -> SlabState.SIGNED_OUT
            }

    val colors: SlabColors get() = SlabColors.of(slabState)

    companion object {
        /**
         * The one place the briefing widget's state is decided, in this order:
         * signed out; nothing cached; a cached date that is not today in the
         * SERVER's [zone] (never the device's); older than the family's
         * 30-minute rule; no briefing; calls; open; all done.
         */
        fun of(
            cached: CachedBriefing?,
            nowMillis: Long,
            signedIn: Boolean,
            zone: ZoneId? = cached?.zoneId,
        ): BriefingState {
            if (!signedIn) return SIGNED_OUT
            if (cached == null) return STALE
            if (isPastDay(cached, nowMillis, zone)) return STALE
            if (nowMillis - cached.fetchedAtMillis > SlabState.STALE_AFTER_MILLIS) return STALE
            val briefing = cached.briefing ?: return NONE
            if (briefing.calls > 0) return CALLS
            if (briefing.open > 0) return FYI
            return ALL_DONE
        }

        /**
         * Why a cached answer is STALE, when the reason is its DAY: true when
         * [cached]'s applies-to date is not today in the SERVER's [zone]
         * (never the device's), or when the zone is unreadable (today cannot
         * be proven). False for a same-day answer, which is STALE only by
         * fetch age. The widget's label reads this: a past day's count says
         * which day it was ("Briefing · Wed 21 Oct"); a same-day one that is
         * merely older than 30 minutes keeps "Today's briefing".
         */
        fun isPastDay(
            cached: CachedBriefing,
            nowMillis: Long,
            zone: ZoneId? = cached.zoneId,
        ): Boolean {
            if (zone == null) return true
            val today = Instant.ofEpochMilli(nowMillis).atZone(zone).toLocalDate()
            return cached.appliesTo != today
        }

        /**
         * When a widget showing [cached] must next re-render without a fetch:
         * the earlier of just past the 30-minute stale boundary and the next
         * midnight in the server's zone (when today's answer stops being today's).
         */
        fun staleRenderAt(
            cached: CachedBriefing,
            nowMillis: Long,
        ): Long {
            val staleAt = cached.fetchedAtMillis + SlabState.STALE_AFTER_MILLIS + 1_000
            val zone = cached.zoneId ?: return staleAt
            val midnight =
                Instant
                    .ofEpochMilli(nowMillis)
                    .atZone(zone)
                    .toLocalDate()
                    .plusDays(1)
                    .atStartOfDay(zone)
                    .toInstant()
                    .toEpochMilli() + 1_000
            return minOf(staleAt, midnight)
        }
    }
}
