package com.koboai.burrow.push

import android.content.Context
import com.google.firebase.messaging.RemoteMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import java.io.File

@RunWith(RobolectricTestRunner::class)
class BriefingPushTest {
    private fun payload(kind: String) = PushPayload.from(mapOf("kind" to kind, "install_host" to "burrow.example.com"))

    private fun refreshes(kind: String): Int {
        var calls = 0
        BriefingPush.onMessage(RuntimeEnvironment.getApplication(), payload(kind)) { _: Context -> calls++ }
        return calls
    }

    @Test
    fun `insight_briefing refreshes the widgets, chat_mention does not`() {
        assertTrue(BriefingPush.shouldRefresh(payload("insight_briefing")))
        assertFalse(BriefingPush.shouldRefresh(payload("chat_mention")))
        assertEquals(1, refreshes("insight_briefing"))
        assertEquals(0, refreshes("chat_mention"))
        assertEquals(0, refreshes("task_plan_review"))
    }

    /** Runs [block] with PushDispatch's seams stubbed; returns (presented, refreshed) counts. */
    private fun dispatching(block: () -> Unit): Pair<Int, Int> {
        var presented = 0
        var refreshed = 0
        val savedPresent = PushDispatch.present
        val savedRefresh = PushDispatch.refresh
        PushDispatch.present = { _, _ -> presented++ }
        PushDispatch.refresh = { _ -> refreshed++ }
        try {
            block()
        } finally {
            PushDispatch.present = savedPresent
            PushDispatch.refresh = savedRefresh
        }
        return presented to refreshed
    }

    private fun data(kind: String) = mapOf("kind" to kind, "install_host" to "burrow.example.com")

    @Test
    fun `the shared dispatch presents every push and refreshes the widgets only for insight_briefing`() {
        val app = RuntimeEnvironment.getApplication()
        assertEquals(1 to 1, dispatching { PushDispatch.handle(app, data("insight_briefing")) })
        assertEquals(1 to 0, dispatching { PushDispatch.handle(app, data("chat_mention")) })
    }

    @Test
    fun `the messaging service hands every push to the shared dispatch`() {
        val service = Robolectric.buildService(BurrowMessagingService::class.java).get()
        val message = { kind: String -> RemoteMessage.Builder("burrow@fcm.googleapis.com").setData(data(kind)).build() }
        assertEquals(1 to 1, dispatching { service.onMessageReceived(message("insight_briefing")) })
        assertEquals(1 to 0, dispatching { service.onMessageReceived(message("chat_mention")) })
    }

    @Test
    fun `source guard - the messaging service calls the shared dispatch`() {
        val src = File("src/main/java/com/koboai/burrow/push/BurrowMessagingService.kt").readText()
        val body = src.substringAfter("override fun onMessageReceived").substringBefore("override fun onNewToken")
        assertTrue(body, body.contains("PushDispatch.handle(this, message.data)"))
    }

    @Test
    fun `source guard - the debug replay receiver calls the shared dispatch`() {
        // The debug receiver once called only NotificationPresenter.present, so a
        // replayed insight_briefing never refreshed the widget (e2e 01a16200-7483-7003).
        val src = File("src/debug/java/com/koboai/burrow/push/DebugPushReceiver.kt").readText()
        val body = src.substringAfter("override fun onReceive").substringBefore("companion object")
        assertTrue(body, body.contains("PushDispatch.handle(context, data)"))
        assertFalse(body, body.contains("NotificationPresenter.present("))
    }
}
