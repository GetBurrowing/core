package com.koboai.burrow.push

import com.koboai.burrow.AppApiClient
import com.koboai.burrow.FakeTokenCipher
import com.koboai.burrow.HttpResponse
import com.koboai.burrow.HttpTransport
import com.koboai.burrow.InMemoryKeyValueStore
import com.koboai.burrow.KeystoreTokenStore
import com.koboai.burrow.RecordingTransport
import com.koboai.burrow.UrlConnectionTransport
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.IOException

class PushRegistrarTest {
    private val host = "suite.example.com"
    private val bearer = "tok_live_bearer_9f8e7d"
    private val fcm = "fcm-instance-id-0123456:APA91bFakeTokenBodyForTests"
    private val tokens = KeystoreTokenStore(InMemoryKeyValueStore(), FakeTokenCipher())
    private val slept = mutableListOf<Long>()

    private lateinit var server: MockWebServer
    private lateinit var clientCerts: HandshakeCertificates

    @Before
    fun startServer() {
        val localhost = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverCerts = HandshakeCertificates.Builder().heldCertificate(localhost).build()
        clientCerts = HandshakeCertificates.Builder().addTrustedCertificate(localhost.certificate).build()
        server = MockWebServer()
        server.useHttps(serverCerts.sslSocketFactory(), false)
        server.start()
    }

    @After
    fun stopServer() {
        server.shutdown()
    }

    private fun registrar(
        client: AppApiClient,
        source: PushTokenSource = FixedTokenSource(fcm),
    ) = PushRegistrar(client, source, "com.koboai.burrow.debug", "install-1", sleep = { slept.add(it) })

    @Test
    fun `enablePush is Registered only on a 2xx (MockWebServer 500, then 201)`() {
        val serverHost = "localhost:${server.port}"
        tokens.store(serverHost, bearer)
        val client = AppApiClient(tokens, UrlConnectionTransport(5_000, clientCerts.sslSocketFactory()))
        server.enqueue(MockResponse().setResponseCode(500).setBody("""{"error":"boom"}"""))
        server.enqueue(MockResponse().setResponseCode(201).setBody("""{"registered":true}"""))

        assertEquals(EnableOutcome.Failed(PushError.REGISTRATION_FAILED), registrar(client).outcome(serverHost))
        // A status is an answer: not retried.
        assertTrue(slept.isEmpty())
        assertEquals(1, server.requestCount)

        assertEquals(EnableOutcome.Registered, registrar(client).outcome(serverHost))

        server.takeRequest()
        val request = server.takeRequest()
        assertEquals("POST", request.method)
        assertEquals("/api/app/devices", request.path)
        assertEquals("Bearer $bearer", request.getHeader("Authorization"))
        val body = JSONObject(request.body.readUtf8())
        assertEquals(fcm, body.getString("token"))
        assertEquals("android", body.getString("platform"))
        assertEquals("com.koboai.burrow.debug", body.getString("package_name"))
        assertEquals("install-1", body.getString("app_install_id"))
        assertEquals("burrow", body.getString("push_category_scheme"))
    }

    @Test
    fun `the registration declares the burrow push category scheme, with or without a key`() {
        tokens.store(host, bearer)
        val transport = RecordingTransport(mapOf("POST /api/app/devices" to HttpResponse(201, "{}")))
        assertEquals(EnableOutcome.Registered, registrar(AppApiClient(tokens, transport)).outcome(host))
        assertEquals("burrow", JSONObject(transport.requests.single().body!!).getString("push_category_scheme"))
    }

    @Test
    fun `the registration carries this install's push public key, base64url without padding`() {
        tokens.store(host, bearer)
        val transport = RecordingTransport(mapOf("POST /api/app/devices" to HttpResponse(201, "{}")))
        val keys = PushKeyStore(InMemoryKeyValueStore(), FakeTokenCipher())
        val registrar =
            PushRegistrar(AppApiClient(tokens, transport), FixedTokenSource(fcm), "com.koboai.burrow.debug", "install-1", publicKey = {
                keys.publicKey(it)
            })
        assertEquals(EnableOutcome.Registered, registrar.outcome(host))
        val body = JSONObject(transport.requests.single().body!!)
        assertEquals(keys.publicKey(host), body.getString("push_public_key"))
        assertTrue(Regex("^[A-Za-z0-9_-]{43}$").matches(body.getString("push_public_key")))
    }

    @Test
    fun `without a key the registration is the old shape`() {
        tokens.store(host, bearer)
        val transport = RecordingTransport(mapOf("POST /api/app/devices" to HttpResponse(201, "{}")))
        assertEquals(EnableOutcome.Registered, registrar(AppApiClient(tokens, transport)).outcome(host))
        assertFalse(JSONObject(transport.requests.single().body!!).has("push_public_key"))
    }

    @Test
    fun `other non-2xx answers are failures too`() {
        for (status in listOf(401, 422, 302)) {
            tokens.store(host, bearer)
            val transport = RecordingTransport(mapOf("POST /api/app/devices" to HttpResponse(status, "{}")))
            assertEquals(EnableOutcome.Failed(PushError.REGISTRATION_FAILED), registrar(AppApiClient(tokens, transport)).outcome(host))
        }
    }

    @Test
    fun `a transport failure is retried after 0_5 s, 2 s and 5 s, then rejected`() {
        tokens.store(host, bearer)
        val transport = RecordingTransport(failing = setOf("POST /api/app/devices"))
        assertEquals(EnableOutcome.Failed(PushError.REGISTRATION_FAILED), registrar(AppApiClient(tokens, transport)).outcome(host))
        assertEquals(listOf(500L, 2_000L, 5_000L), slept)
        assertEquals(4, transport.requests.size)
    }

    @Test
    fun `a transport failure followed by a 2xx registers`() {
        tokens.store(host, bearer)
        var calls = 0
        val transport =
            HttpTransport { _ ->
                calls++
                if (calls < 3) throw IOException("offline")
                HttpResponse(200, """{"registered":true}""")
            }
        assertEquals(EnableOutcome.Registered, registrar(AppApiClient(tokens, transport)).outcome(host))
        assertEquals(listOf(500L, 2_000L), slept)
    }

    @Test
    fun `not signed in is rejected before any token or request`() {
        val transport = RecordingTransport()
        var asked = false
        val source =
            PushTokenSource {
                asked = true
                fcm
            }
        assertEquals(EnableOutcome.Failed(PushError.NOT_SIGNED_IN), registrar(AppApiClient(tokens, transport), source).outcome(host))
        assertFalse(asked)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `a token failure is token_failed and nothing is posted`() {
        tokens.store(host, bearer)
        val transport = RecordingTransport()
        val source = PushTokenSource { throw IllegalStateException("no Firebase") }
        assertEquals(EnableOutcome.Failed(PushError.TOKEN_FAILED), registrar(AppApiClient(tokens, transport), source).outcome(host))
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `errors and token sources never carry the token`() {
        assertEquals("registration_failed", PushError(PushError.REGISTRATION_FAILED).message)
        assertFalse(FixedTokenSource(fcm).toString().contains(fcm))
    }
}
