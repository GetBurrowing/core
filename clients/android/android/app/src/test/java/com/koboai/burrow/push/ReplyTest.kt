package com.koboai.burrow.push

import android.app.Application
import android.app.Notification
import androidx.core.app.NotificationCompat
import com.koboai.burrow.AppApiClient
import com.koboai.burrow.HttpResponse
import com.koboai.burrow.R
import com.koboai.burrow.RecordingTransport
import com.koboai.burrow.push.PushTestSupport.HOST
import com.koboai.burrow.push.PushTestSupport.mention
import com.koboai.burrow.push.PushTestSupport.posted
import com.koboai.burrow.push.PushTestSupport.text
import com.koboai.burrow.shortcuts.ConversationShortcuts
import com.koboai.burrow.shortcuts.RecordingShortcutSink
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

@RunWith(RobolectricTestRunner::class)
class ReplyTest {
    private lateinit var app: Application
    private lateinit var sink: RecordingShortcutSink
    private val payload = PushPayload.from(mention)
    private val route = "POST /api/app/spaces/0192-s/messages"

    @Before
    fun setUp() {
        app = PushTestSupport.app()
        sink = RecordingShortcutSink()
        ConversationShortcuts.sinkOverride = sink
        PushTestSupport.signIn(app)
        NotificationPresenter.present(app, mention)
    }

    @After
    fun tearDown() = PushTestSupport.reset()

    private fun handler(transport: RecordingTransport) = ReplyHandler(AppApiClient(BurrowPush.tokens(app), transport))

    @Test
    fun `Reply posts text and reply_to the mentioned message, with no thread field, on the payload's install`() {
        val transport = RecordingTransport(mapOf(route to HttpResponse(201, """{"message":{"id":"r1"}}""")))
        assertTrue(handler(transport).handle(app, payload, "  On it  "))

        val request = transport.requests.single()
        assertEquals("https://$HOST/api/app/spaces/0192-s/messages", request.url)
        assertEquals("Bearer ${PushTestSupport.BEARER}", request.headers["Authorization"])
        val body = JSONObject(request.body!!)
        assertEquals(setOf("text", "reply_to"), body.keys().asSequence().toSet())
        assertEquals("On it", body.getString("text"))
        assertEquals("0192-m", body.getString("reply_to"))
        assertFalse(request.body!!.contains("thread"))
    }

    @Test
    fun `a sent reply is appended to the conversation as You, in place`() {
        val transport = RecordingTransport(mapOf(route to HttpResponse(201, "{}")))
        handler(transport).handle(app, payload, "On it")

        val n = posted(app, payload.tag)
        val style = NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n)!!
        assertEquals(listOf("@Marlowe can you check the banner copy", "On it"), style.messages.map { it.text.toString() })
        assertNull(style.messages.last().person)
        assertEquals("You", style.user.name)
        // MessagingStyle renders a person-less message under the user's
        // name: the shade shows "You: On it".
        assertEquals(listOf("Reply", "Open"), n.actions.map { it.title.toString() })
    }

    @Test
    fun `a failed reply updates the notification to Couldn't send, keeps the text, and is not cancelled by the tap`() {
        for (transport in listOf(
            RecordingTransport(mapOf(route to HttpResponse(500, "{}"))),
            RecordingTransport(failing = setOf(route)),
        )) {
            NotificationPresenter.present(app, mention)
            assertFalse(handler(transport).handle(app, payload, "On it"))

            val n = posted(app, payload.tag)
            val all = text(n)
            assertTrue(all, all.contains("Couldn't send. Tap to open."))
            assertTrue(all, all.contains("You: On it"))
            assertEquals(R.drawable.ic_stat_error, n.smallIcon.resId)
            assertEquals(0, n.flags and Notification.FLAG_AUTO_CANCEL)
            assertEquals(
                "/chat/internal-fabrikam-sxi?message=0192-m",
                shadowOf(n.contentIntent).savedIntent.getStringExtra(NotificationPresenter.EXTRA_PATH),
            )
        }
    }

    @Test
    fun `an empty reply sends nothing and re-posts the notification so the spinner stops`() {
        val transport = RecordingTransport()
        assertFalse(handler(transport).handle(app, payload, "   "))
        assertTrue(transport.requests.isEmpty())
        val n = posted(app, payload.tag)
        assertEquals(listOf("Reply", "Open"), n.actions.map { it.title.toString() })
    }

    @Test
    fun `a reply to another install uses that install's bearer only`() {
        val other = PushPayload.from(mention + ("install_host" to "suite.milv.life"))
        val transport = RecordingTransport(mapOf(route to HttpResponse(201, "{}")))
        assertFalse(handler(transport).handle(app, other, "On it"))
        // Not signed in there: no request, and never install A's bearer.
        assertTrue(transport.requests.isEmpty())
    }

    // Task 01a116c4: a reply the server took is a use of the conversation.

    @Test
    fun `a 201 reply re-publishes the conversation and reports its use, a 500 does not`() {
        val failing = RecordingTransport(mapOf(route to HttpResponse(500, "{}")))
        assertFalse(handler(failing).handle(app, payload, "nope"))
        assertTrue(sink.reported.isEmpty())

        val pushedBefore = sink.pushed.size
        val ok = RecordingTransport(mapOf(route to HttpResponse(201, """{"message":{"id":"r1"}}""")))
        assertTrue(handler(ok).handle(app, payload, "on it"))
        assertEquals(listOf("$HOST|0192-s"), sink.reported)
        assertEquals(pushedBefore + 1, sink.pushed.size)
    }
}
