package com.koboai.burrow.push

import com.koboai.burrow.widgets.Counts
import com.koboai.burrow.widgets.CountsStore
import kotlinx.coroutines.runBlocking

/**
 * What every app open refreshes (task 01a1261e): each signed-in install's
 * `GET /api/app/counts`, ONCE. The answer feeds both consumers:
 *
 * - the per-install unread counts ([UnreadReconciler] -> [UnreadStore]);
 * - the widgets' cache for the selected install (`approvals` and `tasks`
 *   from the same body, written to [widgetCache] with this device's time,
 *   as `CountsRepository.refresh` would).
 *
 * The widgets therefore do NOT fetch on resume (MainActivity only asks them
 * to re-render); before this, an open sent two counts requests to the
 * selected install.
 *
 * Blocks: run off the main thread.
 */
class ResumeRefresh(
    private val reconciler: UnreadReconciler,
    private val widgetCache: CountsStore,
    private val now: () -> Long = System::currentTimeMillis,
) {
    /** The outcome: the new unread total, and the widget counts written for the selected install (null if none). */
    data class Outcome(
        val total: Int,
        val widgetCounts: Counts?,
    )

    fun run(
        hosts: List<String>,
        selectedHost: String?,
    ): Outcome {
        var written: Counts? = null
        val total =
            reconciler.reconcile(hosts) { host, answer ->
                if (host == selectedHost && answer.approvals != null && answer.tasks != null) {
                    val counts = Counts(answer.approvals, answer.tasks, now())
                    runBlocking { widgetCache.write(host, counts) }
                    written = counts
                }
            }
        return Outcome(total, written)
    }
}
