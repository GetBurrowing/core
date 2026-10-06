package com.koboai.burrow.widgets

import android.content.Context
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.state.updateAppWidgetState
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.koboai.burrow.push.BurrowPush
import java.util.concurrent.TimeUnit

/**
 * When the widgets refresh: every 30 minutes (WorkManager periodic), when
 * the app comes to the foreground, and on sign-in and sign-out. Each
 * refresh also schedules a render-only run just past the stale boundary of
 * the counts it fetched, so a widget whose next refresh never comes still
 * drops its cyan on time (the Android form of iOS's second timeline entry).
 */
object WidgetRefresh {
    private const val PERIODIC = "burrow-widgets-periodic"
    private const val NOW = "burrow-widgets-now"
    private const val STALE_RENDER = "burrow-widgets-stale-render"
    const val KEY_RENDER_ONLY = "render_only"

    fun schedule(context: Context) {
        val request =
            PeriodicWorkRequestBuilder<CountsRefreshWorker>(30, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.KEEP, request)
    }

    /** Foreground, sign-in, sign-out: refresh (or just re-render, signed out) right away. */
    fun now(context: Context) {
        WorkManager
            .getInstance(context)
            .enqueueUniqueWork(NOW, ExistingWorkPolicy.REPLACE, OneTimeWorkRequestBuilder<CountsRefreshWorker>().build())
    }

    internal fun scheduleStaleRender(
        context: Context,
        delayMillis: Long,
    ) {
        val request =
            OneTimeWorkRequestBuilder<CountsRefreshWorker>()
                .setInitialDelay(delayMillis.coerceAtLeast(0), TimeUnit.MILLISECONDS)
                .setInputData(workDataOf(KEY_RENDER_ONLY to true))
                .build()
        WorkManager.getInstance(context).enqueueUniqueWork(STALE_RENDER, ExistingWorkPolicy.REPLACE, request)
    }

    /** Re-renders every placed widget with what is in the cache now. */
    suspend fun render(context: Context) {
        val manager = GlanceAppWidgetManager(context)
        val version = System.currentTimeMillis()
        for (widget in listOf(MyApprovalsWidget(), MyTasksWidget())) {
            for (id in manager.getGlanceIds(widget.javaClass)) {
                updateAppWidgetState(context, id) { it[RENDER_VERSION] = version }
                widget.update(context, id)
            }
        }
    }
}

class CountsRefreshWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val context = applicationContext
        if (!inputData.getBoolean(WidgetRefresh.KEY_RENDER_ONLY, false)) {
            val host = BurrowPush.installs(context).selectedInstall?.host
            if (host != null && BurrowPush.tokens(context).token(host) != null) {
                val counts = CountsRepository.forContext(context).refresh(host)
                if (counts != null) {
                    val staleAt = counts.fetchedAtMillis + SlabState.STALE_AFTER_MILLIS + 1_000
                    WidgetRefresh.scheduleStaleRender(context, staleAt - System.currentTimeMillis())
                }
            }
        }
        WidgetRefresh.render(context)
        return Result.success()
    }
}
