package com.koboai.burrow

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class AppApiClientTest {
    private val host = "burrow.example.net"
    private val bearer = "tok_live_bearer_9f8e7d"
    private val code = "login-code-5150"
    private val verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    private val tokens = KeystoreTokenStore(InMemoryKeyValueStore(), FakeTokenCipher())

    private fun session(handoff: String = "https://$host/auth/app/handoff?code=h1") =
        HttpResponse(200, JSONObject().put("token", bearer).put("handoff_url", handoff).toString())

    @Test
    fun `exchange posts code, verifier, install id and device name, and stores the bearer`() {
        val transport = RecordingTransport(mapOf("POST /api/app/session" to session()))
        val session = AuthSession(Install(host), verifier)
        val handoff = session.complete(code, AppApiClient(tokens, transport), tokens, "install-1", "Pixel 9")

        assertEquals("https://$host/auth/app/handoff?code=h1", handoff)
        assertEquals(bearer, tokens.token(host))
        val request = transport.requests.single()
        assertEquals("https://$host/api/app/session", request.url)
        assertNull(request.headers["Authorization"])
        val body = JSONObject(request.body!!)
        assertEquals(code, body.getString("code"))
        assertEquals(verifier, body.getString("code_verifier"))
        assertEquals("install-1", body.getString("app_install_id"))
        assertEquals("Pixel 9", body.getString("device_name"))
    }

    @Test
    fun `a handoff URL on another host is refused`() {
        val transport = RecordingTransport(mapOf("POST /api/app/session" to session("https://evil.example/auth/app/handoff?code=h1")))
        try {
            AuthSession(Install(host), verifier).complete(code, AppApiClient(tokens, transport), tokens, "i", "d")
            fail("expected a refusal")
        } catch (e: ApiException) {
            assertEquals(ApiException.Kind.BAD_RESPONSE, e.kind)
        }
        assertNull(tokens.token(host))

        tokens.store(host, bearer)
        val handoffTransport =
            RecordingTransport(mapOf("POST /api/app/handoff" to HttpResponse(200, """{"handoff_url":"http://$host/x"}""")))
        try {
            AppApiClient(tokens, handoffTransport).handoff(host, null)
            fail("a non-HTTPS handoff URL must be refused")
        } catch (e: ApiException) {
            assertEquals(ApiException.Kind.BAD_RESPONSE, e.kind)
        }
    }

    @Test
    fun `handoff sends the install's bearer and the local path`() {
        tokens.store(host, bearer)
        val ok = HttpResponse(200, """{"handoff_url":"https://$host/auth/app/handoff?code=h2"}""")
        val transport = RecordingTransport(mapOf("POST /api/app/handoff" to ok))
        val url = AppApiClient(tokens, transport).handoff(host, "/chat/general")
        assertEquals("https://$host/auth/app/handoff?code=h2", url)
        val request = transport.requests.single()
        assertEquals("Bearer $bearer", request.headers["Authorization"])
        assertEquals("/chat/general", JSONObject(request.body!!).getString("path"))
    }

    @Test
    fun `errors and request descriptions never carry a token, code or verifier`() {
        tokens.store(host, bearer)
        val transport =
            RecordingTransport(
                mapOf(
                    "POST /api/app/session" to HttpResponse(400, """{"error":"bad code $code"}"""),
                    "POST /api/app/handoff" to HttpResponse(401, """{"error":"$bearer revoked"}"""),
                ),
                failing = setOf("DELETE /api/app/session"),
            )
        val client = AppApiClient(tokens, transport)
        val messages = mutableListOf<String>()
        listOf<() -> Unit>(
            { client.exchangeSession(host, code, verifier, "i", "d") },
            { client.handoff(host, null) },
            { client.delete(host, AppApiClient.SESSION_PATH) },
            { client.delete("other.example.com", AppApiClient.SESSION_PATH) },
        ).forEach { call ->
            try {
                call()
                fail("expected an ApiException")
            } catch (e: ApiException) {
                messages += e.toString()
                messages += e.message.orEmpty()
            }
        }
        messages += transport.requests.map { it.toString() }
        messages += SessionGrant(bearer, "https://$host/auth/app/handoff?code=$code").toString()
        messages += LaunchStep.Load("https://$host/auth/app/handoff?code=$code").toString()
        assertTrue(messages.isNotEmpty())
        messages.forEach { message ->
            assertFalse(message, message.contains(bearer))
            assertFalse(message, message.contains(code))
            assertFalse(message, message.contains(verifier))
        }
        assertTrue(messages.any { it.contains("401") })
    }
}
