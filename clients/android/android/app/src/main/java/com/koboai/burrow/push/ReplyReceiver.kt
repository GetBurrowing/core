package com.koboai.burrow.push

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.RemoteInput
import com.koboai.burrow.ApiException
import com.koboai.burrow.AppApiClient
import java.util.concurrent.Executors

/**
 * The notification Reply action. The post runs off the main thread under
 * `goAsync()` and ALWAYS ends by updating the notification (sent: `You:
 * {reply}` appended; failed: `Couldn't send. Tap to open.`), because Android
 * leaves the reply field spinning until the app re-posts it.
 *
 * Timeouts are short (4 s connect + 4 s read) so the whole post fits in the
 * ~10 s a `goAsync()` receiver is given.
 */
class ReplyReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent,
    ) {
        val payload = NotificationPresenter.payloadFrom(intent.getBundleExtra(NotificationPresenter.EXTRA_DATA)) ?: return
        val text =
            RemoteInput
                .getResultsFromIntent(intent)
                ?.getCharSequence(NotificationPresenter.KEY_REPLY)
                ?.toString()
        val app = context.applicationContext
        val pending = goAsync()
        executor.execute {
            try {
                ReplyHandler(BurrowPush.client(app, REPLY_TIMEOUT_MILLIS)).handle(app, payload, text)
            } finally {
                pending.finish()
            }
        }
    }

    companion object {
        const val REPLY_TIMEOUT_MILLIS = 4_000
        private val executor = Executors.newSingleThreadExecutor()
    }
}

/** What a Reply does, synchronously (so the tests drive it directly). */
class ReplyHandler(
    private val client: AppApiClient,
    /** After a 2xx: re-publish the conversation and report the use (stage 2, task 01a116c4). */
    private val noteUsed: (Context, PushPayload) -> Unit = { c, p -> NotificationPresenter.noteConversationUsed(c, p) },
) {
    /** True when the server took the reply. */
    fun handle(
        context: Context,
        payload: PushPayload,
        rawText: String?,
    ): Boolean {
        val text = rawText?.trim().orEmpty()
        if (text.isEmpty()) {
            NotificationPresenter.restore(context, payload)
            return false
        }
        val sent = send(payload, text)
        if (sent) {
            noteUsed(context, payload)
            NotificationPresenter.showReplySent(context, payload, text)
        } else {
            NotificationPresenter.showReplyFailed(context, payload, text)
        }
        return sent
    }

    /**
     * `POST /api/app/spaces/<space_id>/messages` with `reply_to` = the
     * mentioned message, on the bearer of the payload's own install.
     */
    fun send(
        payload: PushPayload,
        text: String,
    ): Boolean {
        val host = payload.installHost ?: return false
        val spaceId = payload.spaceId ?: return false
        val messageId = payload.messageId ?: return false
        return try {
            client.postReply(host, spaceId, text, messageId)
            true
        } catch (_: ApiException) {
            false
        }
    }
}
