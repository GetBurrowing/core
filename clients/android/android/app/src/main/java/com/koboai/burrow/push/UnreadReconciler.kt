package com.koboai.burrow.push

import com.koboai.burrow.AppApiClient
import org.json.JSONObject
import java.util.concurrent.Callable
import java.util.concurrent.Executors

/**
 * Reconcile on open (task 01a1261e stage 5; iOS `UnreadReconciler`): every
 * signed-in install's `GET /api/app/counts`, each with its OWN bearer
 * ([AppApiClient] looks the bearer up by the request's host), at most
 * [maxConcurrent] at a time. `unread` + `as_of` go into [UnreadStore]
 * (newer wins). A host that fails keeps its last count and is marked
 * stale. An older server that sends no `unread` changes nothing.
 *
 * Blocks: run off the main thread.
 */
class UnreadReconciler(
    private val fetch: (String) -> Counts?,
    private val store: UnreadStore,
    private val maxConcurrent: Int = MAX_CONCURRENT,
) {
    /**
     * One `/api/app/counts` answer: `unread` and `as_of` ([unread] is null on
     * a server that predates it), plus the widgets' `approvals` and `tasks`
     * from the same body, so an open costs ONE request per install.
     */
    data class Counts(
        val unread: Int?,
        val asOfMillis: Long?,
        val approvals: Int? = null,
        val tasks: Int? = null,
    )

    /**
     * Fetches every host in [hosts], writes the answers, and returns the new
     * total. [onAnswer] gets each host that answered (the widget cache).
     */
    fun reconcile(
        hosts: List<String>,
        onAnswer: (String, Counts) -> Unit = { _, _ -> },
    ): Int {
        if (hosts.isEmpty()) return store.total
        val pool = Executors.newFixedThreadPool(maxConcurrent.coerceIn(1, hosts.size))
        try {
            val results =
                pool
                    .invokeAll(
                        hosts.map { host ->
                            Callable {
                                try {
                                    fetch(host)
                                } catch (_: Exception) {
                                    null
                                }
                            }
                        },
                    ).map { it.get() }
            hosts.zip(results).forEach { (host, counts) ->
                when {
                    counts == null -> store.markStale(host)
                    counts.unread != null && counts.asOfMillis != null ->
                        store.write(host, counts.unread, counts.asOfMillis, clearStale = true)
                    else -> Unit
                }
                if (counts != null) onAnswer(host, counts)
            }
        } finally {
            pool.shutdown()
        }
        return store.total
    }

    companion object {
        const val MAX_CONCURRENT = 4
        const val COUNTS_PATH = "/api/app/counts"

        /** [client]'s `/api/app/counts` for a host; throws on any failure. */
        fun fetcher(client: AppApiClient): (String) -> Counts? = { host -> parse(client.getJson(host, COUNTS_PATH)) }

        fun parse(body: String): Counts {
            val json = JSONObject(body)
            val unread = if (json.has("unread") && !json.isNull("unread")) json.getInt("unread").coerceAtLeast(0) else null

            fun optInt(key: String): Int? = if (json.has(key) && !json.isNull(key)) json.getInt(key) else null
            return Counts(unread, UnreadStore.parseAsOf(json.optString("as_of").ifEmpty { null }), optInt("approvals"), optInt("tasks"))
        }
    }
}
