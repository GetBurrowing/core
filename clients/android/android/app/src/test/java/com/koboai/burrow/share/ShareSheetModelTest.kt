package com.koboai.burrow.share

import com.koboai.burrow.ApiException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

class ShareSheetModelTest {
    private val host = "suite.example.com"
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
    fun `the cap is pinned`() {
        assertEquals(8_388_608L, SizeCheck.MAX_SHARE_FILE_BYTES)
        assertEquals(8L * 1024 * 1024, SizeCheck.MAX_SHARE_FILE_BYTES)
        // The server's whole-body multipart limit (Plug.Parsers :length; iOS maxRequestBytes).
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
}
