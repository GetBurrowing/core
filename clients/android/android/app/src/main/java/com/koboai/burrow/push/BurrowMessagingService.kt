package com.koboai.burrow.push

import android.content.Context
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * FCM's entry points. Every Burrow push is data-only, so this runs for each
 * one, foreground or not, and the app builds the notification.
 *
 * Nothing here logs: not the token, not the data, not an exception.
 */
class BurrowMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        NotificationPresenter.present(this, message.data)
    }

    /**
     * FCM rotated the token: store the new one on every signed-in install,
     * silently, if notifications are allowed. Called on a background thread.
     *
     * firebase-messaging 25 deprecates the getToken/onNewToken pair in
     * favour of register()/onRegistered; the pair still works and is what
     * the task spec names. Moving to register() is a follow-up.
     */
    @Suppress("OVERRIDE_DEPRECATION")
    override fun onNewToken(token: String) {
        reregister(this, token)
    }

    companion object {
        fun reregister(
            context: Context,
            token: String,
        ) {
            if (!BurrowPush.notificationsEnabled(context)) return
            val registrar = BurrowPush.registrar(context, FixedTokenSource(token))
            for (host in BurrowPush.signedInHosts(context)) {
                try {
                    registrar.register(host)
                } catch (_: PushError) {
                    // Silent by design: the next enablePush (every page
                    // mount with "granted") registers again.
                }
            }
        }
    }
}
