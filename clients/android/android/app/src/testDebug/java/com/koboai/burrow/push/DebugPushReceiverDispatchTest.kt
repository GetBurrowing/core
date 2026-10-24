package com.koboai.burrow.push

import android.content.Intent
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import java.util.Base64

/**
 * The debug replay (`com.koboai.burrow.debug.PUSH`) takes the same path as a
 * real push: an `insight_briefing` refreshes the widgets, a `chat_mention`
 * does not, and both post the notification (e2e 01a16200-7483-7003).
 */
@RunWith(RobolectricTestRunner::class)
class DebugPushReceiverDispatchTest {
    private var presented = 0
    private var refreshed = 0
    private val savedPresent = PushDispatch.present
    private val savedRefresh = PushDispatch.refresh

    @Before
    fun stub() {
        PushDispatch.present = { _, _ -> presented++ }
        PushDispatch.refresh = { _ -> refreshed++ }
    }

    @After
    fun restore() {
        PushDispatch.present = savedPresent
        PushDispatch.refresh = savedRefresh
    }

    private fun replay(kind: String) {
        val json = """{"message":{"data":{"kind":"$kind","install_host":"burrow.example.com"}}}"""
        val intent =
            Intent(DebugPushReceiver.ACTION)
                .putExtra(DebugPushReceiver.EXTRA_PAYLOAD, Base64.getEncoder().encodeToString(json.toByteArray()))
        DebugPushReceiver().onReceive(RuntimeEnvironment.getApplication(), intent)
    }

    @Test
    fun `a replayed insight_briefing refreshes the briefing widget`() {
        replay("insight_briefing")
        assertEquals(1, presented)
        assertEquals(1, refreshed)
    }

    @Test
    fun `a replayed chat_mention does not refresh the briefing widget`() {
        replay("chat_mention")
        assertEquals(1, presented)
        assertEquals(0, refreshed)
    }
}
