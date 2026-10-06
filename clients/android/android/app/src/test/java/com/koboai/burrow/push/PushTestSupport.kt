package com.koboai.burrow.push

import android.Manifest
import android.app.Application
import android.app.Notification
import android.app.NotificationManager
import com.koboai.burrow.FakeTokenCipher
import com.koboai.burrow.HttpTransport
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf

/** Shared Robolectric setup for the push tests. */
object PushTestSupport {
    const val HOST = "suite.example.com"
    const val BEARER = "tok_live_bearer_9f8e7d"

    val mention =
        mapOf(
            "kind" to "chat_mention",
            "title" to "Harper in Internal Fabrikam SXI",
            "body" to "@Marlowe can you check the banner copy",
            "url" to "/chat/internal-fabrikam-sxi?message=0192-m",
            "space_id" to "0192-s",
            "message_id" to "0192-m",
            "install_host" to HOST,
            "author_name" to "Harper",
            "space_name" to "Internal Fabrikam SXI",
        )

    fun approval(
        n: Int,
        kind: String = "review_request_pending",
    ) = mapOf(
        "kind" to kind,
        "title" to "Review requested",
        "body" to "Task $n",
        "url" to "/tasks/t$n",
        "task_id" to "t$n",
        "inbox_item_id" to "i$n",
        "install_host" to HOST,
    )

    fun app(): Application {
        val app = RuntimeEnvironment.getApplication()
        shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        BurrowPush.cipherOverride = FakeTokenCipher()
        return app
    }

    fun signIn(
        app: Application,
        host: String = HOST,
    ) {
        BurrowPush.installs(app).add(host)
        BurrowPush.tokens(app).store(host, BEARER)
    }

    fun reset() {
        BurrowPush.cipherOverride = null
        BurrowPush.transportOverride = null
        BurrowPush.tokenSourceOverride = null
    }

    fun withTransport(transport: HttpTransport) {
        BurrowPush.transportOverride = transport
    }

    fun active(app: Application): List<android.service.notification.StatusBarNotification> =
        app.getSystemService(NotificationManager::class.java).activeNotifications.toList()

    fun posted(
        app: Application,
        tag: String,
    ): Notification = active(app).single { it.tag == tag }.notification

    fun text(n: Notification): String =
        listOf(Notification.EXTRA_TITLE, Notification.EXTRA_TEXT, Notification.EXTRA_BIG_TEXT, Notification.EXTRA_SUMMARY_TEXT)
            .mapNotNull { n.extras.getCharSequence(it)?.toString() }
            .joinToString("\n")
}
