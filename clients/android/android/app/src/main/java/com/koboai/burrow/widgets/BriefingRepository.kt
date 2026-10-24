package com.koboai.burrow.widgets

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.koboai.burrow.ApiException
import com.koboai.burrow.AppApiClient
import com.koboai.burrow.push.BurrowPush
import kotlinx.coroutines.flow.first
import org.json.JSONException
import org.json.JSONObject
import java.time.DateTimeException
import java.time.LocalDate
import java.time.ZoneId

/** Today's briefing as counts: the date it applies to and its four numbers. Never its summary text or items. */
data class Briefing(
    val date: LocalDate,
    val total: Int,
    val open: Int,
    val calls: Int,
    val handled: Int,
)

/** One `GET /api/app/briefing` answer as this device cached it. */
data class CachedBriefing(
    /** Today in the SERVER's zone when it answered; the applies-to date when [briefing] is null. */
    val today: LocalDate,
    /** The server's zone (`Disseminator.timezone/0`), the zone a briefing's date is written in. */
    val zone: String,
    /** Null when there is no briefing for [today]. */
    val briefing: Briefing?,
    /** When THIS device received it (its own clock, as [Counts.fetchedAtMillis]). */
    val fetchedAtMillis: Long,
) {
    /** The date this answer is about: the briefing's own date, or the server's today when there was none. */
    val appliesTo: LocalDate get() = briefing?.date ?: today

    /** [zone] as a ZoneId, or null if it does not name one. */
    val zoneId: ZoneId? get() =
        try {
            ZoneId.of(zone)
        } catch (_: DateTimeException) {
            null
        }
}

/** The last briefing per install host. Counts only; the bearer never touches this store. */
interface BriefingStore {
    suspend fun read(host: String): CachedBriefing?

    suspend fun write(
        host: String,
        cached: CachedBriefing,
    )

    suspend fun remove(host: String)
}

private val Context.briefingDataStore: DataStore<Preferences> by preferencesDataStore(name = "burrow_widget_briefing")

/** [BriefingStore] in DataStore (`burrow_widget_briefing`), keyed by host. */
class DataStoreBriefingStore(
    context: Context,
) : BriefingStore {
    private val store = context.applicationContext.briefingDataStore

    private fun date(host: String) = stringPreferencesKey("date.v1.$host")

    private fun total(host: String) = intPreferencesKey("total.v1.$host")

    private fun open(host: String) = intPreferencesKey("open.v1.$host")

    private fun calls(host: String) = intPreferencesKey("calls.v1.$host")

    private fun handled(host: String) = intPreferencesKey("handled.v1.$host")

    private fun today(host: String) = stringPreferencesKey("today.v1.$host")

    private fun zone(host: String) = stringPreferencesKey("zone.v1.$host")

    private fun fetchedAt(host: String) = longPreferencesKey("fetched_at.v1.$host")

    override suspend fun read(host: String): CachedBriefing? {
        val prefs = store.data.first()
        val today = prefs[today(host)]?.let(::parseDate) ?: return null
        val zone = prefs[zone(host)] ?: return null
        val at = prefs[fetchedAt(host)] ?: return null
        val briefing =
            prefs[date(host)]?.let(::parseDate)?.let { d ->
                Briefing(
                    d,
                    prefs[total(host)] ?: return null,
                    prefs[open(host)] ?: return null,
                    prefs[calls(host)] ?: return null,
                    prefs[handled(host)] ?: return null,
                )
            }
        return CachedBriefing(today, zone, briefing, at)
    }

    override suspend fun write(
        host: String,
        cached: CachedBriefing,
    ) {
        store.edit {
            it[today(host)] = cached.today.toString()
            it[zone(host)] = cached.zone
            it[fetchedAt(host)] = cached.fetchedAtMillis
            val b = cached.briefing
            if (b == null) {
                for (key in listOf(total(host), open(host), calls(host), handled(host))) it.remove(key)
                it.remove(date(host))
            } else {
                it[date(host)] = b.date.toString()
                it[total(host)] = b.total
                it[open(host)] = b.open
                it[calls(host)] = b.calls
                it[handled(host)] = b.handled
            }
        }
    }

    override suspend fun remove(host: String) {
        store.edit {
            it.remove(date(host))
            it.remove(total(host))
            it.remove(open(host))
            it.remove(calls(host))
            it.remove(handled(host))
            it.remove(today(host))
            it.remove(zone(host))
            it.remove(fetchedAt(host))
        }
    }

    /** Every key name in the store, for tests that must see what is really on disk. */
    internal suspend fun storedKeyNames(): Set<String> =
        store.data
            .first()
            .asMap()
            .keys
            .map { it.name }
            .toSet()

    private fun parseDate(s: String): LocalDate? =
        try {
            LocalDate.parse(s)
        } catch (_: DateTimeException) {
            null
        }
}

/**
 * `GET /api/app/briefing` -> `{today, zone, briefing: null | {date, total,
 * open, calls, handled, summary, url}}`, cached with the device's own fetch
 * time. Only the counts, the dates and the zone are kept: never the summary
 * line, the url or anything else the server adds. A failed refresh keeps
 * the last good answer, which [BriefingState] then shows as STALE.
 */
class BriefingRepository(
    private val api: AppApiClient,
    private val store: BriefingStore,
    private val now: () -> Long = System::currentTimeMillis,
) {
    /** The fresh briefing, or null when the fetch failed (the cache is left as it was). Blocks on the network. */
    suspend fun refresh(host: String): CachedBriefing? {
        val cached =
            try {
                parse(api.getJson(host, PATH), now())
            } catch (_: ApiException) {
                return null
            }
        store.write(host, cached)
        return cached
    }

    suspend fun cached(host: String): CachedBriefing? = store.read(host)

    /** Sign-out: the old account's briefing must not survive under the next sign-in. */
    suspend fun forget(host: String) = store.remove(host)

    companion object {
        const val PATH = "/api/app/briefing"

        fun parse(
            body: String,
            fetchedAtMillis: Long,
        ): CachedBriefing =
            try {
                val json = JSONObject(body)
                val zone = json.getString("zone")
                ZoneId.of(zone)
                val briefing =
                    if (json.isNull("briefing")) {
                        null
                    } else {
                        val b = json.getJSONObject("briefing")
                        Briefing(
                            LocalDate.parse(b.getString("date")),
                            b.getInt("total"),
                            b.getInt("open"),
                            b.getInt("calls"),
                            b.getInt("handled"),
                        )
                    }
                CachedBriefing(LocalDate.parse(json.getString("today")), zone, briefing, fetchedAtMillis)
            } catch (_: JSONException) {
                throw ApiException(ApiException.Kind.BAD_RESPONSE, route = PATH)
            } catch (_: DateTimeException) {
                throw ApiException(ApiException.Kind.BAD_RESPONSE, route = PATH)
            }

        fun forContext(context: Context): BriefingRepository =
            BriefingRepository(BurrowPush.client(context), DataStoreBriefingStore(context))

        /** What the briefing widget renders now: the selected install, its bearer, its cached briefing. */
        suspend fun entry(
            context: Context,
            nowMillis: Long = System.currentTimeMillis(),
        ): BriefingEntry {
            val host = BurrowPush.installs(context).selectedInstall?.host
            val signedIn = host != null && BurrowPush.tokens(context).token(host) != null
            val cached = host?.let { DataStoreBriefingStore(context).read(it) }
            return BriefingEntry(nowMillis, host, signedIn, cached)
        }
    }
}

/** One rendered moment of the briefing widget. */
data class BriefingEntry(
    val nowMillis: Long,
    val host: String?,
    val signedIn: Boolean,
    val cached: CachedBriefing?,
) {
    val state: BriefingState get() = BriefingState.of(cached, nowMillis, signedIn)
}
