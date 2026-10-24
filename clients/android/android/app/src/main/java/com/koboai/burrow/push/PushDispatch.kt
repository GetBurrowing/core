package com.koboai.burrow.push

import android.content.Context
import com.koboai.burrow.widgets.WidgetRefresh

/**
 * The ONE handler for a push's data map: it shows the notification
 * ([NotificationPresenter.present]) and runs the briefing widget's hook
 * ([BriefingPush.onMessage]). Both [BurrowMessagingService] (FCM) and the
 * debug build's replay receiver call this and nothing else, so a debug
 * replay behaves as a real push and cannot drift from it.
 */
object PushDispatch {
    /** Test seams; production never sets them. */
    @Volatile
    internal var present: (Context, Map<String, String?>) -> Unit = NotificationPresenter::present

    @Volatile
    internal var refresh: (Context) -> Unit = WidgetRefresh::now

    fun handle(
        context: Context,
        data: Map<String, String?>,
    ) {
        present(context, data)
        BriefingPush.onMessage(context.applicationContext ?: context, PushPayload.from(data), refresh)
    }
}
