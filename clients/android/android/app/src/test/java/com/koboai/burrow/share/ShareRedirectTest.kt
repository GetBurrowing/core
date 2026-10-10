package com.koboai.burrow.share

import com.koboai.burrow.AppApiClient
import com.koboai.burrow.FakeTokenCipher
import com.koboai.burrow.InMemoryKeyValueStore
import com.koboai.burrow.KeystoreTokenStore
import com.koboai.burrow.UrlConnectionTransport
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.ByteArrayInputStream

/**
 * The share sheet on the real transport against a TLS MockWebServer.
 *
 * On 2026-10-10 suite.milv.life began answering every path, the `/api/app` routes
 * included, with a 302 to burrow.red-st.ar. The transport never follows a
 * redirect, so `GET /api/app/spaces` failed, the sheet said "Couldn't load
 * your spaces", and because `upload_config` was only asked after the space
 * list loaded, it also said "Burrow can send files up to 8 MB each" about an
 * install that takes 1 GB.
 */
class ShareRedirectTest {
    private val bearer = "tok_share_bearer_5a4b3c"
    private val tokens = KeystoreTokenStore(InMemoryKeyValueStore(), FakeTokenCipher())
    private val big = SharedFile("big.bin", "application/octet-stream", 20_000_000) { ByteArrayInputStream(ByteArray(0)) }

    private lateinit var install: MockWebServer
    private lateinit var elsewhere: MockWebServer
    private lateinit var clientCerts: HandshakeCertificates

    @Before
    fun startServers() {
        val localhost = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverCerts = HandshakeCertificates.Builder().heldCertificate(localhost).build()
        clientCerts = HandshakeCertificates.Builder().addTrustedCertificate(localhost.certificate).build()
        install = MockWebServer().apply { useHttps(serverCerts.sslSocketFactory(), false) }
        elsewhere = MockWebServer().apply { useHttps(serverCerts.sslSocketFactory(), false) }
        install.start()
        elsewhere.start()
    }

    @After
    fun stopServers() {
        install.shutdown()
        elsewhere.shutdown()
    }

    private fun model(): ShareSheetModel {
        val host = "localhost:${install.port}"
        tokens.store(host, bearer)
        val api = AppApiClient(tokens, UrlConnectionTransport(5_000, clientCerts.sslSocketFactory()))
        return ShareSheetModel(host, AppShareClient(api), listOf(big), null).also { it.start() }
    }

    private fun redirect(path: String): MockResponse {
        val target = "https://127.0.0.1:${elsewhere.port}$path"
        return MockResponse().setResponseCode(302).setHeader("Location", target)
    }

    @Test
    fun `a redirecting install reads as moved, makes no 8 MB claim, and the bearer never leaves it`() {
        install.enqueue(redirect("/api/app/spaces"))
        install.enqueue(redirect("/api/app/upload_config"))

        val m = model()

        assertEquals(ShareSheetModel.Phase.READY, m.phase)
        assertEquals(ShareSheetModel.Banner.INSTALL_MOVED, m.banner)
        assertEquals(
            "This Suite moved to 127.0.0.1. Open Burrow, add 127.0.0.1 and sign in there, then share again.",
            m.bannerText,
        )
        // Never reached the install: no limit is claimed, least of all the old "8 MB".
        assertNull(m.size.notice)
        assertTrue(m.spaces.isEmpty())
        assertEquals(false, m.canSend)
        // Redirects are not followed: the other host saw nothing, so never the bearer.
        assertEquals(0, elsewhere.requestCount)
    }

    @Test
    fun `a failed space list still asks upload_config, so the limit is the install's, not 8 MB`() {
        install.enqueue(MockResponse().setResponseCode(500).setBody("""{"error":"boom"}"""))
        install.enqueue(
            MockResponse().setResponseCode(200).setBody(
                """{"max_upload_bytes":10000000,"max_upload_label":"10 MB","chunk_bytes":33554432,"multipart_max_bytes":8000000}""",
            ),
        )

        val m = model()

        assertEquals(ShareSheetModel.Banner.SPACES_FAILED, m.banner)
        assertEquals("10 MB", m.uploadConfig?.maxUploadLabel)
        assertEquals("big.bin is 20 MB. This Suite accepts files up to 10 MB.", m.size.notice)
        assertEquals(listOf("/api/app/spaces", "/api/app/upload_config"), List(install.requestCount) { install.takeRequest().path })
    }

    @Test
    fun `a same-host or non-https redirect is still moved, without naming a host`() {
        install.enqueue(MockResponse().setResponseCode(301).setHeader("Location", "http://example.com/api/app/spaces"))
        install.enqueue(MockResponse().setResponseCode(404))

        val m = model()

        assertEquals(ShareSheetModel.Banner.INSTALL_MOVED, m.banner)
        assertNull(m.movedTo)
        assertEquals(ShareSheetModel.Banner.INSTALL_MOVED.text, m.bannerText)
    }
}
