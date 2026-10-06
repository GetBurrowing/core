package com.koboai.burrow.widgets

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.koboai.burrow.ApiException
import com.koboai.burrow.AppApiClient
import com.koboai.burrow.push.BurrowPush
import kotlinx.coroutines.flow.first
import org.json.JSONException
import org.json.JSONObject

/** The last counts per install host. Counts are not secrets; the bearer never touches this store. */
interface CountsStore {
    suspend fun read(host: String): Counts?

    suspend fun write(
        host: String,
        counts: Counts,
    )

    suspend fun remove(host: String)
}

private val Context.countsDataStore: DataStore<Preferences> by preferencesDataStore(name = "burrow_widget_counts")

/** [CountsStore] in DataStore (`burrow_widget_counts`), keyed by host. */
class DataStoreCountsStore(
    context: Context,
) : CountsStore {
    private val store = context.applicationContext.countsDataStore

    private fun approvals(host: String) = intPreferencesKey("approvals.v1.$host")

    private fun tasks(host: String) = intPreferencesKey("tasks.v1.$host")

    private fun fetchedAt(host: String) = longPreferencesKey("fetched_at.v1.$host")

    override suspend fun read(host: String): Counts? {
        val prefs = store.data.first()
        val a = prefs[approvals(host)] ?: return null
        val t = prefs[tasks(host)] ?: return null
        val at = prefs[fetchedAt(host)] ?: return null
        return Counts(a, t, at)
    }

    override suspend fun write(
        host: String,
        counts: Counts,
    ) {
        store.edit {
            it[approvals(host)] = counts.approvals
            it[tasks(host)] = counts.tasks
            it[fetchedAt(host)] = counts.fetchedAtMillis
        }
    }

    override suspend fun remove(host: String) {
        store.edit {
            it.remove(approvals(host))
            it.remove(tasks(host))
            it.remove(fetchedAt(host))
        }
    }
}

/**
 * `GET /api/app/counts` -> `{approvals, tasks, as_of}`, cached with the
 * device's own fetch time. A failed refresh keeps the last good counts, so
 * the widget shows them as STALE once they are over 30 minutes old rather
 * than dropping to nothing.
 */
class CountsRepository(
    private val api: AppApiClient,
    private val store: CountsStore,
    private val now: () -> Long = System::currentTimeMillis,
) {
    /** The fresh counts, or null when the fetch failed (the cache is left as it was). Blocks on the network. */
    suspend fun refresh(host: String): Counts? {
        val counts =
            try {
                parse(api.getJson(host, COUNTS_PATH), now())
            } catch (_: ApiException) {
                return null
            }
        store.write(host, counts)
        return counts
    }

    suspend fun cached(host: String): Counts? = store.read(host)

    /** Sign-out: the old account's numbers must not survive under the next sign-in. */
    suspend fun forget(host: String) = store.remove(host)

    companion object {
        const val COUNTS_PATH = "/api/app/counts"

        fun parse(
            body: String,
            fetchedAtMillis: Long,
        ): Counts =
            try {
                val json = JSONObject(body)
                Counts(json.getInt("approvals"), json.getInt("tasks"), fetchedAtMillis)
            } catch (_: JSONException) {
                throw ApiException(ApiException.Kind.BAD_RESPONSE, route = COUNTS_PATH)
            }

        fun forContext(context: Context): CountsRepository = CountsRepository(BurrowPush.client(context), DataStoreCountsStore(context))

        /** What the widgets render now: the selected install, its bearer, its cached counts. */
        suspend fun entry(
            context: Context,
            nowMillis: Long = System.currentTimeMillis(),
        ): CountsEntry {
            val host = BurrowPush.installs(context).selectedInstall?.host
            val signedIn = host != null && BurrowPush.tokens(context).token(host) != null
            val counts = host?.let { DataStoreCountsStore(context).read(it) }
            return CountsEntry(nowMillis, host, signedIn, counts)
        }
    }
}
