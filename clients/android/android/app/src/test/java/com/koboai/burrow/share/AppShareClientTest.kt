package com.koboai.burrow.share

import com.koboai.burrow.ApiException
import com.koboai.burrow.AppApiClient
import com.koboai.burrow.FakeTokenCipher
import com.koboai.burrow.HttpResponse
import com.koboai.burrow.InMemoryKeyValueStore
import com.koboai.burrow.KeystoreTokenStore
import com.koboai.burrow.RecordingTransport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream

class AppShareClientTest {
    private val host = "suite.example.com"
    private val tokens = KeystoreTokenStore(InMemoryKeyValueStore(), FakeTokenCipher()).also { it.store(host, "tok_bearer") }

    @Test
    fun `each send is one multipart POST to the space's messages route on this install's bearer`() {
        val posts = mutableListOf<Triple<String, Map<String, String>, MultipartForm>>()
        val client =
            AppShareClient(AppApiClient(tokens, RecordingTransport())) { url, headers, form ->
                posts.add(Triple(url, headers, form))
                HttpResponse(201, "{}")
            }
        val file = SharedFile("a.jpg", "image/jpeg", 3) { ByteArrayInputStream(byteArrayOf(1, 2, 3)) }
        val form = MultipartForm(listOf("text" to "hi"), file)
        client.send(host, "0192-s1", form)

        val (url, headers, sent) = posts.single()
        assertEquals("https://$host/api/app/spaces/0192-s1/messages", url)
        assertEquals("Bearer tok_bearer", headers["Authorization"])
        assertTrue(headers.keys.none { it.equals("Content-Type", ignoreCase = true) })
        assertEquals(form, sent)
    }

    @Test
    fun `a non-2xx, a bad space id, or no bearer is an ApiException and nothing leaks`() {
        val client = AppShareClient(AppApiClient(tokens, RecordingTransport())) { _, _, _ -> HttpResponse(413, "{}") }
        val form = MultipartForm(listOf("text" to "hi"), null)
        for ((h, id) in listOf(host to "0192-s1", host to "../session", "suite.example.org" to "0192-s1")) {
            try {
                client.send(h, id, form)
                fail("expected a failure for $h $id")
            } catch (e: ApiException) {
                assertTrue(e.message!!.contains("tok_bearer").not())
            }
        }
    }

    @Test
    fun `parseSpaces reads kind and tolerates a missing kind and 01a111bb's org key`() {
        val body =
            """
            {"spaces": [
              {"id": "s1", "name": "Ops", "path_segment": "ops", "kind": "channel",
               "org": {"id": "o1", "name": "Legacy"}, "agents": []},
              {"id": "s2", "name": "Sam", "path_segment": "s2", "kind": "dm"},
              {"id": "s3", "name": "Old server"}
            ]}
            """.trimIndent()
        val spaces = AppShareClient.parseSpaces(body)
        assertEquals(listOf("channel", "dm", null), spaces.map { it.kind })
        assertEquals("ops", spaces[0].pathSegment)
        assertNull(spaces[2].pathSegment)
    }
}
