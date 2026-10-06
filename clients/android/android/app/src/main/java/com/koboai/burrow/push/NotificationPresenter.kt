package com.koboai.burrow.push

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.app.RemoteInput
import androidx.core.content.ContextCompat
import com.koboai.burrow.MainActivity
import com.koboai.burrow.R

/**
 * Builds and posts every Burrow notification from a data-only FCM payload
 * (canvas 01a10d91, "Notifications"):
 *
 * - `chat_mention`: MessagingStyle (conversation = the space, sender = the
 *   author) in Mentions, grouped per install and space, with Reply (inline
 *   RemoteInput) and Open;
 * - `task_plan_review`, `review_request_pending`: the standard layout in
 *   Approvals, grouped per install, Open only;
 * - anything else: a tap opens it.
 *
 * The notification colour is never set: Android tints the app name and the
 * action labels with it, and cyan on white is about 1.8:1. Every
 * PendingIntent is FLAG_IMMUTABLE except Reply's, which RemoteInput has to
 * fill in. Each notification is posted under its own tag ([PushPayload.tag]),
 * so a reply updates that one notification in place, and every
 * PendingIntent carries a per-notification data URI and request code.
 */
object NotificationPresenter {
    const val NOTIFICATION_ID = 1
    const val SUMMARY_ID = 2
    const val KEY_REPLY = "reply_text"
    const val EXTRA_DATA = "com.koboai.burrow.push.DATA"
    const val ACTION_OPEN = "com.koboai.burrow.push.OPEN"
    const val ACTION_REPLY = "com.koboai.burrow.push.REPLY"
    const val EXTRA_HOST = "com.koboai.burrow.push.HOST"
    const val EXTRA_PATH = "com.koboai.burrow.push.PATH"
    const val EXTRA_TAG = "com.koboai.burrow.push.TAG"

    /** Entry point for FCM and the debug replay receiver. */
    fun present(
        context: Context,
        data: Map<String, String?>,
    ) {
        val payload = PushPayload.from(data)
        if (payload.installHost == null) {
            NotificationChannels.ensure(context, listOf(null))
        } else {
            BurrowPush.ensureChannels(context, payload.installHost)
        }
        post(context, payload.tag, build(context, payload))
        payload.groupKey?.let { postSummary(context, payload, it) }
    }

    /** After a Reply: `You: {reply}` appended to the conversation, alerting nobody. */
    fun showReplySent(
        context: Context,
        payload: PushPayload,
        reply: String,
    ) {
        val previous = active(context, payload.tag)?.let { NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(it) }
        post(context, payload.tag, build(context, payload, history = previous, sent = reply))
    }

    /**
     * After a failed Reply: `Couldn't send. Tap to open.` beside an error
     * icon, with the reply still on the notification (the web composer has
     * no prefill parameter, so the text stays here). The notification is not
     * auto-cancelled by the tap, so the reply survives opening the space.
     */
    fun showReplyFailed(
        context: Context,
        payload: PushPayload,
        reply: String,
    ) {
        val text = context.getString(R.string.reply_failed)
        val builder =
            base(context, payload)
                .setSmallIcon(R.drawable.ic_stat_error)
                .setContentTitle(payload.spaceName ?: payload.title ?: context.getString(R.string.app_name))
                .setContentText(text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(context.getString(R.string.reply_you, reply) + "\n" + text))
                .setAutoCancel(false)
                .setContentIntent(openIntent(context, payload))
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .addAction(0, context.getString(R.string.action_open), openIntent(context, payload))
        post(context, payload.tag, builder.build())
    }

    /** Re-posts the original (an empty reply), so Android stops the reply spinner. */
    fun restore(
        context: Context,
        payload: PushPayload,
    ) {
        val previous = active(context, payload.tag)?.let { NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(it) }
        post(context, payload.tag, build(context, payload, history = previous, alert = false))
    }

    internal fun build(
        context: Context,
        payload: PushPayload,
        history: NotificationCompat.MessagingStyle? = null,
        sent: String? = null,
        alert: Boolean = sent == null,
    ): Notification {
        val builder = base(context, payload).setContentIntent(openIntent(context, payload))
        if (!alert) builder.setOnlyAlertOnce(true).setSilent(true)
        when {
            payload.isMention -> {
                val style = history ?: mentionStyle(context, payload)
                if (sent != null) style.addMessage(sent, System.currentTimeMillis(), null as Person?)
                builder
                    .setStyle(style)
                    .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                    .setContentTitle(payload.spaceName ?: payload.title)
                    .setContentText(sent?.let { context.getString(R.string.reply_you, it) } ?: payload.body)
                if (payload.canReply) builder.addAction(replyAction(context, payload))
                builder.addAction(0, context.getString(R.string.action_open), openIntent(context, payload))
            }
            payload.isApproval -> {
                builder
                    .setContentTitle(payload.title)
                    .setContentText(payload.body)
                    .setStyle(NotificationCompat.BigTextStyle().bigText(payload.body))
                    .addAction(0, context.getString(R.string.action_open), openIntent(context, payload))
            }
            else -> {
                builder.setContentTitle(payload.title).setContentText(payload.body)
                payload.body?.let { builder.setStyle(NotificationCompat.BigTextStyle().bigText(it)) }
            }
        }
        return builder.build()
    }

    /** The group summary: "3 approvals", "4 new in {space}". */
    internal fun buildSummary(
        context: Context,
        payload: PushPayload,
        groupKey: String,
        count: Int,
    ): Notification {
        val text = PushPayload.summaryText(payload, count)
        return NotificationCompat
            .Builder(context, NotificationChannels.channelFor(payload))
            .setSmallIcon(R.drawable.ic_stat_burrow)
            .setContentTitle(text)
            .setContentText(text)
            .setStyle(NotificationCompat.InboxStyle().setSummaryText(text))
            .setGroup(groupKey)
            .setGroupSummary(true)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
            .setAutoCancel(true)
            .setContentIntent(openIntent(context, if (payload.isApproval) payload.copy(url = "/inbox") else payload, "summary"))
            .build()
    }

    private fun base(
        context: Context,
        payload: PushPayload,
    ): NotificationCompat.Builder {
        val builder =
            NotificationCompat
                .Builder(context, NotificationChannels.channelFor(payload))
                .setSmallIcon(R.drawable.ic_stat_burrow)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
        // No setColor: see the class comment.
        payload.groupKey?.let { builder.setGroup(it) }
        return builder
    }

    private fun mentionStyle(
        context: Context,
        payload: PushPayload,
    ): NotificationCompat.MessagingStyle {
        val you = Person.Builder().setName(context.getString(R.string.reply_you_name)).build()
        val author = Person.Builder().setName(payload.authorName ?: context.getString(R.string.someone)).build()
        return NotificationCompat
            .MessagingStyle(you)
            .setConversationTitle(payload.spaceName)
            .setGroupConversation(true)
            .addMessage(payload.body ?: payload.title.orEmpty(), System.currentTimeMillis(), author)
    }

    private fun replyAction(
        context: Context,
        payload: PushPayload,
    ): NotificationCompat.Action {
        val input =
            RemoteInput
                .Builder(KEY_REPLY)
                .setLabel(context.getString(R.string.reply_hint, payload.spaceName ?: context.getString(R.string.app_name)))
                .build()
        val intent =
            Intent(context, ReplyReceiver::class.java)
                .setAction(ACTION_REPLY)
                .setData(uri(payload.tag, "reply"))
                .putExtra(EXTRA_DATA, bundle(payload))
        // FLAG_MUTABLE: RemoteInput writes the typed text into this intent.
        // The intent is explicit (component set), as Android 14 requires.
        val pending =
            PendingIntent.getBroadcast(
                context,
                requestCode(payload.tag, "reply"),
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
            )
        return NotificationCompat.Action
            .Builder(0, context.getString(R.string.action_reply), pending)
            .addRemoteInput(input)
            .setAllowGeneratedReplies(false)
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_REPLY)
            .setShowsUserInterface(false)
            .build()
    }

    /** Opens [payload]'s install at its (guarded) path, through MainActivity. */
    internal fun openIntent(
        context: Context,
        payload: PushPayload,
        purpose: String = "open",
    ): PendingIntent {
        val intent =
            Intent(context, MainActivity::class.java)
                .setAction(ACTION_OPEN)
                .setData(uri(payload.tag, purpose))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(EXTRA_HOST, payload.installHost)
                .putExtra(EXTRA_PATH, payload.openPath)
                .putExtra(EXTRA_TAG, payload.tag)
        return PendingIntent.getActivity(
            context,
            requestCode(payload.tag, purpose),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun bundle(payload: PushPayload): Bundle = Bundle().apply { payload.toData().forEach { (k, v) -> putString(k, v) } }

    fun payloadFrom(bundle: Bundle?): PushPayload? {
        if (bundle == null) return null
        return PushPayload.from(bundle.keySet().associateWith { bundle.getString(it) })
    }

    /** Distinct per notification and action, so no two PendingIntents overwrite each other. */
    internal fun requestCode(
        tag: String,
        purpose: String,
    ): Int = "$tag#$purpose".hashCode()

    private fun uri(
        tag: String,
        purpose: String,
    ): Uri =
        Uri
            .Builder()
            .scheme("burrow-notification")
            .authority(purpose)
            .appendPath(tag)
            .build()

    /**
     * The group's size including the notification just posted. `notify` is
     * asynchronous: on a device the new child is usually NOT yet in
     * `activeNotifications` when this runs (measured on the API 35 emulator:
     * three approvals summarised as "2 approvals"), while it may be there
     * already. Counting every OTHER child and adding one is right either way.
     */
    internal fun groupCount(
        activeChildTags: List<String?>,
        postedTag: String,
    ): Int = activeChildTags.count { it != postedTag } + 1

    private fun postSummary(
        context: Context,
        payload: PushPayload,
        groupKey: String,
    ) {
        val children =
            manager(context)
                .activeNotifications
                .filter { it.notification.group == groupKey && (it.notification.flags and Notification.FLAG_GROUP_SUMMARY) == 0 }
                .map { it.tag }
        val count = groupCount(children, payload.tag)
        if (count < 2) return
        post(context, "summary:$groupKey", buildSummary(context, payload, groupKey, count), SUMMARY_ID)
    }

    private fun active(
        context: Context,
        tag: String,
    ): Notification? = manager(context).activeNotifications.firstOrNull { it.tag == tag && it.id == NOTIFICATION_ID }?.notification

    /** Posts only when allowed; Android 13+ drops it anyway without the permission. */
    private fun post(
        context: Context,
        tag: String,
        notification: Notification,
        id: Int = NOTIFICATION_ID,
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        NotificationManagerCompat.from(context).notify(tag, id, notification)
    }

    private fun manager(context: Context): NotificationManager = context.getSystemService(NotificationManager::class.java)
}
