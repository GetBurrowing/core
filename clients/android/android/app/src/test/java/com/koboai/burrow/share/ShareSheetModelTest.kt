package com.koboai.burrow.share

import com.koboai.burrow.ApiException
import com.koboai.burrow.InMemoryKeyValueStore
import com.koboai.burrow.InstallStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

class ShareSheetModelTest {
    private val host = "suite.example.net"
    private val space = ShareSpace("0192-s1", "Ops", "ops", listOf(ShareSpace.Agent("a1", "Higgins")))

    /** Records every call; never touches a network. */
    private class FakeClient(
        var signedIn: Boolean = true,
        var spacesError: ApiException? = null,
        val failOn: Set<Int> = emptySet(),
        val spaces: List<ShareSpace> = emptyList(),
    ) : ShareClient {
        val sent = mutableListOf<MultipartForm>()
        var calls = 0

        override fun isSignedIn(host: String) = signedIn

        override fun spaces(host: String): List<ShareSpace> {
            calls++
            spacesError?.let { throw it }
            return spaces
        }

        override fun send(
            host: String,
            spaceId: String,
            form: MultipartForm,
        ) {
            calls++
            if (sent.size in failOn) throw ApiException(ApiException.Kind.STATUS, 500, "messages")
            sent.add(form)
        }
    }

    // A file that reports a size but whose bytes are never read by the size check.
    private fun file(
        name: String,
        bytes: Long,
    ) = SharedFile(name, "application/pdf", bytes) { ByteArrayInputStream(ByteArray(0)) }

    private fun model(
        files: List<SharedFile>,
        text: String? = null,
        client: FakeClient = FakeClient(spaces = listOf(space)),
    ) = ShareSheetModel(host, client, files, text).also {
        it.start()
        it.selectedSpaceId = space.id
    }

    @Test
    fun `the multipart threshold is pinned`() {
        // Task 01a120be: the 8 MiB MAX_SHARE_FILE_BYTES user limit is gone (the
        // per-file limit is the server's upload_config); what remains is the
        // server's whole-body multipart limit (Plug.Parsers :length; iOS maxRequestBytes),
        // and only as the multipart threshold.
        assertEquals(8_000_000L, SizeCheck.MAX_REQUEST_BYTES)
    }

    @Test
    fun `one file over 8 MB - the canvas copy and Send disabled`() {
        val m = model(listOf(file("Q3 board deck.pdf", 12_400_000)))
        assertEquals("Q3 board deck.pdf is 12.4 MB. Burrow can send files up to 8 MB each.", m.size.notice)
        assertFalse(m.canSend)
        assertEquals("Send", m.sendLabel)
        assertFalse(m.send())
        assertTrue(m.size.sendable.isEmpty())
    }

    @Test
    fun `some of several over - k of n copy and Send n-k`() {
        val m =
            model(
                listOf(file("a.jpg", 1_000_000), file("Q3 board deck.pdf", 12_400_000), file("c.pdf", 7_900_000)),
            )
        assertEquals("1 of 3 files are over 8 MB and won't be sent.", m.size.notice)
        assertEquals("Send 2", m.sendLabel)
        assertTrue(m.canSend)

        val five = model(listOf(file("1", 1), file("2", 9_000_000), file("3", 2), file("4", 20_000_000), file("5", 3)))
        assertEquals("2 of 5 files are over 8 MB and won't be sent.", five.size.notice)
        assertEquals("Send 3", five.sendLabel)
    }

    @Test
    fun `all of several over - the canvas copy and Send disabled`() {
        val m = model(listOf(file("a.pdf", 9_000_000), file("b.pdf", 12_400_000)))
        assertEquals("These files are each over 8 MB. Burrow can send files up to 8 MB each.", m.size.notice)
        assertFalse(m.canSend)
    }

    @Test
    fun `a file under 8 MiB whose request would pass 8_000_000 bytes is over too`() {
        // 8.2 MB < 8 MiB, but the server 413s any body over 8_000_000 bytes.
        val m = model(listOf(file("big.pdf", 8_200_000)))
        assertEquals("big.pdf is 8.2 MB. Burrow can send files up to 8 MB each.", m.size.notice)
        assertFalse(m.canSend)
        // 7.9 MB plus the multipart overhead still fits.
        assertNull(model(listOf(file("ok.pdf", 7_900_000))).size.notice)
    }

    @Test
    fun `one request per file, text and agent on the first only, oversized never sent`() {
        val client = FakeClient(spaces = listOf(space))
        val big = file("big.pdf", 12_400_000)
        val m = model(listOf(file("a.jpg", 10), big, file("c.pdf", 20)), "https://example.com/x", client)
        m.message = "  Have a look  "
        m.selectedAgentId = "a1"
        assertTrue(m.send())

        assertEquals(2, client.sent.size)
        assertEquals("a.jpg", client.sent[0].file!!.name)
        assertEquals("c.pdf", client.sent[1].file!!.name)
        assertEquals("Have a look\nhttps://example.com/x", client.sent[0].field("text"))
        assertEquals("a1", client.sent[0].field("agent_id"))
        assertNull(client.sent[1].field("text"))
        assertNull(client.sent[1].field("agent_id"))
        assertTrue(client.sent.none { it.file === big })
        assertEquals(ShareSheetModel.Phase.SENT, m.phase)
    }

    @Test
    fun `a text-only share is one message`() {
        val client = FakeClient(spaces = listOf(space))
        val m = model(emptyList(), "https://example.com/x", client)
        assertTrue(m.send())
        assertEquals(1, client.sent.size)
        assertNull(client.sent.single().file)
        assertEquals("https://example.com/x", client.sent.single().field("text"))
    }

    @Test
    fun `a partial failure keeps the rest, and the retry sends only what is left, without the text again`() {
        val client = FakeClient(spaces = listOf(space), failOn = setOf(1))
        val m = model(listOf(file("a", 1), file("b", 2)), "note", client)
        assertFalse(m.send())
        assertEquals(ShareSheetModel.Banner.SEND_FAILED, m.banner)
        assertEquals(ShareSheetModel.Phase.READY, m.phase)
        assertEquals(1, m.sentFiles)
        val retry = m.requests()
        assertEquals(listOf("b"), retry.map { it.file!!.name })
        assertNull(retry.single().field("text"))
    }

    @Test
    fun `not signed in makes no request`() {
        val client = FakeClient(signedIn = false, spaces = listOf(space))
        val m = ShareSheetModel(host, client, listOf(file("a", 1)), null)
        m.start()
        assertEquals(ShareSheetModel.Phase.NOT_SIGNED_IN, m.phase)
        assertEquals(0, client.calls)
        val noInstall = ShareSheetModel(null, client, emptyList(), "x").also { it.start() }
        assertEquals(ShareSheetModel.Phase.NOT_SIGNED_IN, noInstall.phase)
    }

    @Test
    fun `a 401 on the space list is not signed in, anything else a banner`() {
        val unauthorized = FakeClient(spacesError = ApiException(ApiException.Kind.STATUS, 401, "spaces"))
        assertEquals(ShareSheetModel.Phase.NOT_SIGNED_IN, ShareSheetModel(host, unauthorized, emptyList(), "x").also { it.start() }.phase)
        val offline = FakeClient(spacesError = ApiException(ApiException.Kind.NETWORK, route = "spaces"))
        val m = ShareSheetModel(host, offline, emptyList(), "x").also { it.start() }
        assertEquals(ShareSheetModel.Banner.SPACES_FAILED, m.banner)
    }

    @Test
    fun `back asks only when something is typed`() {
        val m = model(listOf(file("a", 1)))
        assertFalse(m.hasTypedText)
        m.message = "   "
        assertFalse(m.hasTypedText)
        m.message = "hi"
        assertTrue(m.hasTypedText)
    }

    @Test
    fun `multipart content length is exactly what is written`() {
        val bytes = ByteArray(1234) { it.toByte() }
        val form =
            MultipartForm(
                listOf("text" to "héllo", "agent_id" to "a1"),
                SharedFile("Q3 \"deck\".pdf", "application/pdf", bytes.size.toLong()) { ByteArrayInputStream(bytes) },
                boundary = "b",
            )
        val out = ByteArrayOutputStream()
        form.writeTo(out)
        assertEquals(form.contentLength(), out.size().toLong())
        val text = out.toString(Charsets.UTF_8.name())
        assertTrue(text.contains("name=\"file\"; filename=\"Q3 'deck'.pdf\""))
        assertTrue(text.endsWith("--b--\r\n"))
        assertFalse(form.toString().contains("héllo"))
    }

    @Test
    fun `the space list parses name and path segment`() {
        val spaces =
            AppShareClient.parseSpaces(
                """{"spaces":[{"id":"s1","name":"Ops","path_segment":"ops","agents":[{"id":"a1","name":"Higgins"}]},{"name":"no id"}]}""",
            )
        assertEquals(listOf(ShareSpace("s1", "Ops", "ops", listOf(ShareSpace.Agent("a1", "Higgins")))), spaces)
    }

    // Task 01a116c4: direct share from a conversation shortcut.

    private val other = ShareSpace("0192-s2", "Design", "design", emptyList(), kind = "group")

    @Test
    fun `a direct-share target opens its own signed-in host with its space preselected`() {
        val (h, space) =
            ShareSheetModel.target("suite.example.test|0192-s2", host) { it == "suite.example.test" }
        assertEquals("suite.example.test", h)
        assertEquals("0192-s2", space)

        val m = ShareSheetModel(h, FakeClient(spaces = listOf(this.space, other)), emptyList(), "x", space)
        m.start()
        assertEquals("0192-s2", m.selectedSpaceId)
    }

    @Test
    fun `a target whose host is not signed in, or no target, falls back to the selected install`() {
        assertEquals(host to null, ShareSheetModel.target("suite.example.test|0192-s2", host) { it == host })
        assertEquals(host to null, ShareSheetModel.target(null, host) { true })
        assertEquals(host to null, ShareSheetModel.target("switch_install", host) { true })
    }

    @Test
    fun `an unknown preselected space selects nothing and does not crash`() {
        val m = ShareSheetModel(host, FakeClient(spaces = listOf(space, other)), emptyList(), "x", "0192-gone")
        m.start()
        assertEquals(ShareSheetModel.Phase.READY, m.phase)
        assertNull(m.selectedSpaceId)
    }

    @Test
    fun `a sent share reports the conversation, a failed one does not`() {
        val noted = mutableListOf<Pair<String, String>>()
        val ok = ShareSheetModel(host, FakeClient(spaces = listOf(space)), emptyList(), "hi") { h, s -> noted.add(h to s.id) }
        ok.start()
        assertTrue(ok.send())
        assertEquals(listOf(host to space.id), noted)

        noted.clear()
        val failingClient = FakeClient(spaces = listOf(space), failOn = setOf(0))
        val failing = ShareSheetModel(host, failingClient, emptyList(), "hi") { h, s -> noted.add(h to s.id) }
        failing.start()
        assertFalse(failing.send())
        assertTrue(noted.isEmpty())
    }

    @Test
    fun `a fresh app with no install is the not-signed-in state, not a crash`() {
        // Task 01a12787: the app ships no installs, so a fresh app's selected
        // install is null. ShareActivity passes that null host straight in.
        val installs = InstallStore(InMemoryKeyValueStore(), InMemoryKeyValueStore())
        val selected = installs.selectedInstall?.host
        assertNull(selected)
        val (host, preselect) = ShareSheetModel.target(null, selected) { true }
        assertNull(host)
        assertNull(preselect)
        val client = FakeClient(spaces = listOf(space))
        val model = ShareSheetModel(host, client, emptyList(), "x").also { it.start() }
        assertEquals(ShareSheetModel.Phase.NOT_SIGNED_IN, model.phase)
        assertEquals(0, client.calls)
        assertEquals("Sign in to Burrow first. Open the Burrow app, sign in, then share again.", ShareSheetModel.NOT_SIGNED_IN_TEXT)
    }
}
