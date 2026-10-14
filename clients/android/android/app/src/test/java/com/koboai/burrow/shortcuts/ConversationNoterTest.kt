package com.koboai.burrow.shortcuts

import com.koboai.burrow.InMemoryKeyValueStore
import com.koboai.burrow.share.MultipartForm
import com.koboai.burrow.share.ShareClient
import com.koboai.burrow.share.ShareSpace
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class ConversationNoterTest {
    private val host = "suite.example.com"
    private val design = ShareSpace("0192-s", "Design", "design", emptyList(), kind = "group")
    private val dm = ShareSpace("0192-d", "Harper", "0192-d", emptyList(), kind = "dm")

    private class FakeClient(
        var signedIn: Boolean = true,
        var spaces: List<ShareSpace> = emptyList(),
    ) : ShareClient {
        var gets = 0

        override fun isSignedIn(host: String) = signedIn

        override fun spaces(host: String): List<ShareSpace> {
            gets++
            return spaces
        }

        override fun send(
            host: String,
            spaceId: String,
            form: MultipartForm,
        ) = error("the noter never sends")
    }

    private var now = 1_000_000L
    private val sink = RecordingShortcutSink()
    private val shortcuts = ConversationShortcuts(RuntimeEnvironment.getApplication(), sink, InMemoryKeyValueStore()) { now }

    private fun noter(client: FakeClient) = ConversationNoter(client, shortcuts) { now }

    @Test
    fun `publish uses the API's name, kind and path, and reports the use`() {
        val client = FakeClient(spaces = listOf(design, dm))
        val result = noter(client).note(host, "0192-d", listOf(Recipient("user", "0192-u"), Recipient("admin", "x")))

        assertEquals(NoteResult.Noted("$host|0192-d"), result)
        val shortcut = sink.pushed.single()
        assertEquals("Harper", shortcut.shortLabel.toString())
        assertEquals("/chat/0192-d", shortcut.intent.getStringExtra(com.koboai.burrow.LaunchRouter.EXTRA_CONVERSATION_PATH))
        assertEquals(false, shortcut.extras!!.getBoolean(ConversationShortcuts.EXTRA_IS_GROUP))
        // Only the well-formed recipient, keyed like stage 1's sender.
        assertEquals(listOf("$host|user:0192-u"), shortcut.personsForTest.map { it.key })
        assertEquals(listOf("$host|0192-d"), sink.reported)

        noter(client).note(host, "0192-s", emptyList())
        assertEquals(
            "/chat/design",
            sink.pushed
                .last()
                .intent
                .getStringExtra(com.koboai.burrow.LaunchRouter.EXTRA_CONVERSATION_PATH),
        )
        assertEquals(
            true,
            sink.pushed
                .last()
                .extras!!
                .getBoolean(ConversationShortcuts.EXTRA_IS_GROUP),
        )
    }

    @Test
    fun `no bearer is not_signed_in, with no request and nothing published`() {
        val client = FakeClient(signedIn = false, spaces = listOf(design))
        assertEquals(NoteResult.Rejected(ConversationNoter.NOT_SIGNED_IN), noter(client).note(host, "0192-s", emptyList()))
        assertEquals(NoteResult.Rejected(ConversationNoter.NOT_SIGNED_IN), noter(client).note(null, "0192-s", emptyList()))
        assertEquals(0, client.gets)
        assertTrue(sink.pushed.isEmpty())
    }

    @Test
    fun `a bad space id is rejected with no request`() {
        val client = FakeClient(spaces = listOf(design))
        assertEquals(NoteResult.Rejected(ConversationNoter.BAD_SPACE), noter(client).note(host, "../session", emptyList()))
        assertEquals(0, client.gets)
        assertTrue(sink.pushed.isEmpty())
    }

    @Test
    fun `a second call within 10 minutes makes no second GET, after 10 minutes it refetches`() {
        val client = FakeClient(spaces = listOf(design))
        val n = noter(client)
        n.note(host, "0192-s", emptyList())
        now += ConversationNoter.CACHE_MILLIS - 1
        n.note(host, "0192-s", emptyList())
        assertEquals(1, client.gets)
        now += 1
        n.note(host, "0192-s", emptyList())
        assertEquals(2, client.gets)
    }

    @Test
    fun `a miss refetches once, then an unknown space is rejected`() {
        val client = FakeClient(spaces = listOf(design))
        val n = noter(client)
        n.note(host, "0192-s", emptyList())
        client.spaces = listOf(design, dm)
        assertEquals(NoteResult.Noted("$host|0192-d"), n.note(host, "0192-d", emptyList()))
        assertEquals(2, client.gets)
        assertEquals(NoteResult.Rejected(ConversationNoter.UNKNOWN_SPACE), n.note(host, "0192-x", emptyList()))
        assertEquals(3, client.gets)
    }
}
