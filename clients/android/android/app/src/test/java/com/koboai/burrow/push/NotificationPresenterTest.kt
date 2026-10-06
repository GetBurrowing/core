package com.koboai.burrow.push

import android.app.Application
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import androidx.core.app.NotificationCompat
import com.koboai.burrow.R
import com.koboai.burrow.push.PushTestSupport.HOST
import com.koboai.burrow.push.PushTestSupport.active
import com.koboai.burrow.push.PushTestSupport.approval
import com.koboai.burrow.push.PushTestSupport.mention
import com.koboai.burrow.push.PushTestSupport.posted
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

@RunWith(RobolectricTestRunner::class)
class NotificationPresenterTest {
    private lateinit var app: Application
    private lateinit var manager: NotificationManager

    @Before
    fun setUp() {
        app = PushTestSupport.app()
        manager = app.getSystemService(NotificationManager::class.java)
    }

    @After
    fun tearDown() = PushTestSupport.reset()

    private fun mentionTag() = PushPayload.from(mention).tag

    @Test
    fun `a mention is a MessagingStyle conversation in Mentions with Reply and Open`() {
        NotificationPresenter.present(app, mention)
        val n = posted(app, mentionTag())

        assertEquals("mentions:$HOST", n.channelId)
        assertEquals("mentions:$HOST:0192-s", n.group)
        val style = NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n)!!
        assertEquals("Internal Fabrikam SXI", style.conversationTitle)
        val message = style.messages.single()
        assertEquals("Harper", message.person!!.name)
        assertEquals("@Marlowe can you check the banner copy", message.text)

        val actions = n.actions.map { it.title.toString() }
        assertEquals(listOf("Reply", "Open"), actions)
        val reply = n.actions[0]
        assertEquals("Message Internal Fabrikam SXI", reply.remoteInputs.single().label)
        assertEquals(NotificationPresenter.KEY_REPLY, reply.remoteInputs.single().resultKey)
    }

    @Test
    fun `Reply is the only mutable PendingIntent and the colour is unset`() {
        NotificationPresenter.present(app, mention)
        val n = posted(app, mentionTag())
        val reply = n.actions[0].actionIntent
        val open = n.actions[1].actionIntent
        assertFalse(reply.isImmutable)
        assertTrue(shadowOf(reply).flags and PendingIntent.FLAG_MUTABLE != 0)
        assertTrue(open.isImmutable)
        assertTrue(n.contentIntent.isImmutable)
        assertEquals(Notification.COLOR_DEFAULT, n.color)
        assertEquals(R.drawable.ic_stat_burrow, n.smallIcon.resId)
    }

    @Test
    fun `Open carries the install and the guarded path`() {
        NotificationPresenter.present(app, mention + ("url" to "//evil.example/x"))
        val intent = shadowOf(posted(app, mentionTag()).contentIntent).savedIntent
        assertEquals(NotificationPresenter.ACTION_OPEN, intent.action)
        assertEquals(HOST, intent.getStringExtra(NotificationPresenter.EXTRA_HOST))
        assertEquals("/", intent.getStringExtra(NotificationPresenter.EXTRA_PATH))
    }

    @Test
    fun `request codes and intents are unique per notification`() {
        NotificationPresenter.present(app, mention)
        NotificationPresenter.present(app, mention + ("message_id" to "0192-n"))
        val open = active(app).filter { !it.isGroup || it.notification.flags and Notification.FLAG_GROUP_SUMMARY == 0 }
        val codes = open.map { shadowOf(it.notification.contentIntent).requestCode }.toSet()
        assertEquals(2, codes.size)
        val data = open.map { shadowOf(it.notification.contentIntent).savedIntent.data }.toSet()
        assertEquals(2, data.size)
    }

    @Test
    fun `approvals stack under one summary that reads 3 approvals`() {
        NotificationPresenter.present(app, approval(1))
        assertNull(active(app).firstOrNull { it.notification.flags and Notification.FLAG_GROUP_SUMMARY != 0 })
        NotificationPresenter.present(app, approval(2, "task_plan_review"))
        NotificationPresenter.present(app, approval(3))

        val children = active(app).filter { it.notification.flags and Notification.FLAG_GROUP_SUMMARY == 0 }
        assertEquals(3, children.size)
        children.forEach {
            assertEquals("approvals:$HOST", it.notification.group)
            assertEquals("approvals:$HOST", it.notification.channelId)
            assertEquals(listOf("Open"), it.notification.actions.map { a -> a.title.toString() })
        }
        val summary = active(app).single { it.notification.flags and Notification.FLAG_GROUP_SUMMARY != 0 }.notification
        assertEquals("approvals:$HOST", summary.group)
        assertEquals("3 approvals", summary.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
    }

    @Test
    fun `the group count is right whether or not the new child is already active`() {
        // A device posts asynchronously, so the new child is usually missing
        // from activeNotifications; Robolectric posts synchronously.
        assertEquals(3, NotificationPresenter.groupCount(listOf("a", "b"), "c"))
        assertEquals(3, NotificationPresenter.groupCount(listOf("a", "b", "c"), "c"))
        assertEquals(1, NotificationPresenter.groupCount(emptyList(), "c"))
    }

    @Test
    fun `mentions in one space summarise as N new in the space`() {
        for (i in 1..4) NotificationPresenter.present(app, mention + ("message_id" to "m$i"))
        val summary = active(app).single { it.notification.flags and Notification.FLAG_GROUP_SUMMARY != 0 }.notification
        assertEquals("4 new in Internal Fabrikam SXI", summary.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
    }

    @Test
    fun `any other kind is a plain notification whose tap opens`() {
        NotificationPresenter.present(
            app,
            mapOf(
                "kind" to "generic",
                "title" to "Hi",
                "body" to "There",
                "url" to "/inbox",
                "install_host" to HOST,
            ),
        )
        val n = active(app).single().notification
        assertNull(n.actions)
        assertNotNull(n.contentIntent)
        assertNull(n.group)
        assertEquals("/inbox", shadowOf(n.contentIntent).savedIntent.getStringExtra(NotificationPresenter.EXTRA_PATH))
    }

    @Test
    fun `two channels, high importance, with the canvas copy`() {
        NotificationPresenter.present(app, mention)
        val mentions = manager.getNotificationChannel("mentions:$HOST")
        val approvals = manager.getNotificationChannel("approvals:$HOST")
        assertEquals("Mentions", mentions.name)
        assertEquals("When someone @mentions you in a space", mentions.description)
        assertEquals(NotificationManager.IMPORTANCE_HIGH, mentions.importance)
        assertEquals("Approvals", approvals.name)
        assertEquals("Plans and work waiting for your review", approvals.description)
        assertEquals(NotificationManager.IMPORTANCE_HIGH, approvals.importance)
        assertEquals(2, manager.notificationChannels.size)
    }

    @Test
    fun `one signed-in install has no channel groups, two have one group each`() {
        PushTestSupport.signIn(app)
        BurrowPush.ensureChannels(app)
        assertTrue(manager.notificationChannelGroups.isEmpty())
        assertNull(manager.getNotificationChannel("mentions:$HOST").group)

        PushTestSupport.signIn(app, "suite.milv.life")
        BurrowPush.ensureChannels(app)
        assertEquals(setOf("install:$HOST", "install:suite.milv.life"), manager.notificationChannelGroups.map { it.id }.toSet())
        assertEquals("install:$HOST", manager.getNotificationChannel("mentions:$HOST").group)
        assertEquals("install:suite.milv.life", manager.getNotificationChannel("approvals:suite.milv.life").group)
        assertNotEquals(manager.getNotificationChannel("mentions:$HOST").id, manager.getNotificationChannel("mentions:suite.milv.life").id)
    }

    @Test
    fun `nothing is created before anyone signs in`() {
        BurrowPush.ensureChannels(app)
        assertTrue(manager.notificationChannels.isEmpty())
    }
}
