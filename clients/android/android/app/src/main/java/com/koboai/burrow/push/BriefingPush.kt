package com.koboai.burrow.push

import android.content.Context
import com.koboai.burrow.widgets.WidgetRefresh

/**
 * The briefing widget's push hook: an `insight_briefing` push (what the
 * Disseminator sends) refreshes the widgets as well as showing the
 * notification. A pure seam, so it is testable without booting FCM.
 */
object BriefingPush {
    const val KIND = "insight_briefing"

    fun shouldRefresh(payload: PushPayload): Boolean = payload.kind == KIND

    fun onMessage(
        context: Context,
        payload: PushPayload,
        refresh: (Context) -> Unit = WidgetRefresh::now,
    ) {
        if (shouldRefresh(payload)) refresh(context)
    }
}
