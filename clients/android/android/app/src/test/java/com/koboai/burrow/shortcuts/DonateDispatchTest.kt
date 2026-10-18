package com.koboai.burrow.shortcuts

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** `SuiteNative.donate`'s dispatch, with the plugin's logic extracted. */
class DonateDispatchTest {
    private val calls = mutableListOf<Triple<String?, String, List<Recipient>>>()
    private val noter =
        Noter { host, spaceId, recipients ->
            calls.add(Triple(host, spaceId, recipients))
            NoteResult.Noted("$host|$spaceId")
        }

    @Test
    fun `message_sent runs the noter with the host, space and recipients`() {
        val recipients = listOf(Recipient("user", "0192-u"))
        val outcome = DonateDispatch.dispatch("message_sent", "0192-s", recipients, "burrow.example.com", noter)
        assertEquals(DonateDispatch.Outcome.Ok, outcome)
        assertEquals(listOf(Triple("burrow.example.com", "0192-s", recipients)), calls)
    }

    @Test
    fun `every other kind resolves ok and never touches the noter`() {
        for (kind in listOf("task_created", "approval_acted", "meeting_started", "something_new", null)) {
            assertEquals(DonateDispatch.Outcome.Ok, DonateDispatch.dispatch(kind, "0192-s", emptyList(), "burrow.example.com", noter))
        }
        assertTrue(calls.isEmpty())
    }

    @Test
    fun `a noter rejection, or no space id, is a rejection with its code`() {
        val rejecting = Noter { _, _, _ -> NoteResult.Rejected(ConversationNoter.NOT_SIGNED_IN) }
        assertEquals(
            DonateDispatch.Outcome.Rejected(ConversationNoter.NOT_SIGNED_IN),
            DonateDispatch.dispatch("message_sent", "0192-s", emptyList(), null, rejecting),
        )
        assertEquals(
            DonateDispatch.Outcome.Rejected(ConversationNoter.BAD_SPACE),
            DonateDispatch.dispatch("message_sent", null, emptyList(), "h", noter),
        )
        assertTrue(calls.isEmpty())
    }
}
