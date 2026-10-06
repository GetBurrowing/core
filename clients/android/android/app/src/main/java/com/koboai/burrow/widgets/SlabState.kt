package com.koboai.burrow.widgets

import java.text.DateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * What a widget's count slab shows. Mirrors
 * `clients/ios/ios/Shared/SlabState.swift` exactly.
 *
 * The rule that makes the slab worth having: CYAN MEANS LIVE AND NON-ZERO.
 * Only [LIVE] gets the cyan fill ([SlabColors]). Zero, stale and
 * signed out drop to the fixed `burrow_surface_muted`, so a cyan slab on the
 * home screen is never an out-of-date number.
 */
enum class SlabState {
    /** Fresh and above zero: the cyan fill, the numeral, `waiting on you` / `open`. */
    LIVE,

    /** Fresh and zero: `Nothing waiting` / `Nothing open`. */
    ZERO,

    /** The last good count is OLDER than [STALE_AFTER_MILLIS]: the last numeral kept, `As of {time}`. */
    STALE,

    /** No bearer for the selected install: no numeral, `Sign in to see approvals`. */
    SIGNED_OUT,
    ;

    val usesLiveFill: Boolean get() = this == LIVE

    companion object {
        /**
         * A count is stale once it is OLDER than 30 minutes. Exactly 30
         * minutes is still fresh. WorkManager refreshes every 30 minutes, so
         * a healthy widget re-fetches around the boundary; one that cannot
         * reach the server crosses it and must stop looking live.
         */
        const val STALE_AFTER_MILLIS: Long = 30L * 60 * 1000

        /** The one place the slab rule is decided. [fetchedAtMillis] is when this device received the count. */
        fun of(
            count: Int,
            fetchedAtMillis: Long,
            nowMillis: Long,
            signedIn: Boolean,
        ): SlabState {
            if (!signedIn) return SIGNED_OUT
            if (nowMillis - fetchedAtMillis > STALE_AFTER_MILLIS) return STALE
            return if (count > 0) LIVE else ZERO
        }
    }
}

/** Which of the two counts a slab shows. */
enum class SlabKind(
    val title: String,
    /** The web route the slab opens (router.ex `/inbox`, `/tasks`). */
    val path: String,
) {
    APPROVALS("My approvals", "/inbox"),
    TASKS("My tasks", "/tasks"),
    ;

    /** The caption under the numeral. `As of` uses the short time style in the person's locale and zone. */
    fun caption(
        state: SlabState,
        fetchedAtMillis: Long?,
        zone: TimeZone = TimeZone.getDefault(),
        locale: Locale = Locale.getDefault(),
    ): String =
        when (state) {
            SlabState.LIVE -> if (this == APPROVALS) "waiting on you" else "open"
            SlabState.ZERO -> if (this == APPROVALS) "Nothing waiting" else "Nothing open"
            SlabState.SIGNED_OUT -> if (this == APPROVALS) "Sign in to see approvals" else "Sign in to see tasks"
            SlabState.STALE -> {
                if (fetchedAtMillis == null) {
                    "Not loaded yet"
                } else {
                    val format = DateFormat.getTimeInstance(DateFormat.SHORT, locale)
                    format.timeZone = zone
                    "As of ${format.format(Date(fetchedAtMillis))}"
                }
            }
        }
}

/** The counts this device last received for one install. */
data class Counts(
    val approvals: Int,
    val tasks: Int,
    /** When THIS device received them (its own clock, so a skewed server cannot make an old count fresh). */
    val fetchedAtMillis: Long,
) {
    fun count(kind: SlabKind): Int = if (kind == SlabKind.APPROVALS) approvals else tasks
}

/** One rendered moment: the selected install, whether it has a bearer, and its last counts. Mirrors `CountsEntry.swift`. */
data class CountsEntry(
    val nowMillis: Long,
    val host: String?,
    val signedIn: Boolean,
    val counts: Counts?,
) {
    fun state(kind: SlabKind): SlabState {
        if (!signedIn) return SlabState.SIGNED_OUT
        // Signed in with nothing ever fetched: nothing to be live about.
        val counts = counts ?: return SlabState.STALE
        return SlabState.of(counts.count(kind), counts.fetchedAtMillis, nowMillis, signedIn)
    }

    /** The numeral, or null when there is none to show (signed out, never loaded). */
    fun count(kind: SlabKind): Int? = if (state(kind) == SlabState.SIGNED_OUT) null else counts?.count(kind)

    fun caption(kind: SlabKind): String = kind.caption(state(kind), counts?.fetchedAtMillis)
}
