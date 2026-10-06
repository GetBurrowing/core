package com.koboai.burrow.push

import android.app.NotificationChannel
import android.app.NotificationChannelGroup
import android.app.NotificationManager
import android.content.Context
import com.koboai.burrow.R

/**
 * The two channels (canvas 01a10d91, "Channels"): Mentions and Approvals,
 * both high importance. Android never lets an app remove a channel quietly,
 * so there is no third ("Other") until a third kind ships; anything that is
 * neither a mention nor an approval posts to Mentions.
 *
 * Channels are per install host (`mentions:<host>`), so each install's
 * switches are its own. With one install they show as two plain channels;
 * once two or more installs are in use each pair moves under a group named
 * for its install (Android lets an existing channel take a group once).
 * "In use" means signed in: the picker pre-lists three installs, and three
 * empty groups on a phone that uses one would be noise.
 */
object NotificationChannels {
    const val MENTIONS = "mentions"
    const val APPROVALS = "approvals"

    fun channelId(
        base: String,
        host: String?,
    ): String = if (host == null) base else "$base:$host"

    fun groupId(host: String): String = "install:$host"

    /** The channel a payload posts to. */
    fun channelFor(payload: PushPayload): String = channelId(if (payload.isApproval) APPROVALS else MENTIONS, payload.installHost)

    /**
     * Creates (or updates) both channels for every host in [hosts] (null: a
     * payload with no install, posted to the un-suffixed pair), each
     * labelled by [names] when grouped. Safe to call on every launch:
     * re-creating a channel keeps the person's settings.
     */
    fun ensure(
        context: Context,
        hosts: List<String?>,
        names: Map<String, String> = emptyMap(),
    ) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val grouped = hosts.filterNotNull().distinct().size > 1
        for (host in hosts.distinct()) {
            if (grouped &&
                host != null
            ) {
                manager.createNotificationChannelGroup(NotificationChannelGroup(groupId(host), names[host] ?: host))
            }
            for ((base, name, description) in channels(context)) {
                val channel = NotificationChannel(channelId(base, host), name, NotificationManager.IMPORTANCE_HIGH)
                channel.description = description
                if (grouped && host != null) channel.group = groupId(host)
                manager.createNotificationChannel(channel)
            }
        }
    }

    private fun channels(context: Context) =
        listOf(
            Triple(MENTIONS, context.getString(R.string.channel_mentions), context.getString(R.string.channel_mentions_description)),
            Triple(APPROVALS, context.getString(R.string.channel_approvals), context.getString(R.string.channel_approvals_description)),
        )
}
