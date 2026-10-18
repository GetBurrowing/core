package com.koboai.burrow

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class InstallSessionTest {
    private val install = Install("suite.example.com")
    private val tokens = KeystoreTokenStore(InMemoryKeyValueStore(), FakeTokenCipher())

    private val removed = mutableListOf<String>()

    private fun launcher(transport: RecordingTransport) = InstallLauncher(AppApiClient(tokens, transport), tokens) { removed.add(it) }

    @Test
    fun `no bearer means native sign-in, with no request at all`() {
        val transport = RecordingTransport()
        assertEquals(LaunchStep.SignIn, launcher(transport).start(install, null))
        assertEquals(0, transport.requests.size)
    }

    @Test
    fun `a stored bearer relaunches through POST api-app-handoff`() {
        tokens.store(install.host, "b1")
        val ok = HttpResponse(200, """{"handoff_url":"https://suite.example.com/auth/app/handoff?code=x"}""")
        val transport = RecordingTransport(mapOf("POST /api/app/handoff" to ok))
        val step = launcher(transport).start(install, "https://suite.example.com/tasks?id=1")
        assertEquals(LaunchStep.Load("https://suite.example.com/auth/app/handoff?code=x"), step)
        assertEquals("""{"path":"/tasks?id=1"}""", transport.requests.single().body)
    }

    @Test
    fun `a 401 forgets the bearer and signs in again`() {
        tokens.store(install.host, "b1")
        val transport = RecordingTransport(mapOf("POST /api/app/handoff" to HttpResponse(401, "{}")))
        assertEquals(LaunchStep.SignIn, launcher(transport).start(install, null))
        assertNull(tokens.token(install.host))
    }

    @Test
    fun `offline or a 5xx loads the page itself and keeps the bearer`() {
        tokens.store(install.host, "b1")
        val offline = RecordingTransport(failing = setOf("POST /api/app/handoff"))
        assertEquals(LaunchStep.Load(install.baseUrl), launcher(offline).start(install, null))
        val broken = RecordingTransport(mapOf("POST /api/app/handoff" to HttpResponse(502, "")))
        assertEquals(LaunchStep.Load("https://suite.example.com/x"), launcher(broken).start(install, "https://suite.example.com/x"))
        assertEquals("b1", tokens.token(install.host))
    }

    @Test
    fun `localPath keeps only a path on the same host`() {
        assertEquals("/chat/x?y=1", InstallLauncher.localPath("https://suite.example.com/chat/x?y=1", "suite.example.com"))
        assertNull(InstallLauncher.localPath("https://suite.example.com/", "suite.example.com"))
        assertNull(InstallLauncher.localPath("https://evil.example/chat", "suite.example.com"))
        assertNull(InstallLauncher.localPath(null, "suite.example.com"))
    }

    @Test
    fun `sign-out deletes the device, revokes the session, then forgets the bearer`() {
        tokens.store(install.host, "b1")
        tokens.store("suite.example.org", "b2")
        val transport =
            RecordingTransport(
                mapOf(
                    "DELETE /api/app/devices/install-1" to HttpResponse(204, ""),
                    "DELETE /api/app/session" to HttpResponse(204, ""),
                ),
            )
        NativeSignOut(AppApiClient(tokens, transport), tokens, "install-1") { removed.add(it) }.run(install.host)
        assertEquals(
            listOf("DELETE /api/app/devices/install-1", "DELETE /api/app/session"),
            transport.requests.map { "${it.method} ${java.net.URI(it.url).path}" },
        )
        assertEquals(listOf("Bearer b1", "Bearer b1"), transport.requests.map { it.headers["Authorization"] })
        assertNull(tokens.token(install.host))
        assertEquals("b2", tokens.token("suite.example.org"))
    }

    @Test
    fun `sign-out forgets that install's push key with its bearer`() {
        tokens.store(install.host, "b1")
        val forgotten = mutableListOf<String>()
        NativeSignOut(AppApiClient(tokens, RecordingTransport()), tokens, "i", { forgotten.add(it) }) { removed.add(it) }.run(install.host)
        assertEquals(listOf(install.host), forgotten)
        assertEquals(listOf(install.host), removed)
    }

    @Test
    fun `sign-out offline still forgets the bearer`() {
        tokens.store(install.host, "b1")
        val transport = RecordingTransport(failing = setOf("DELETE /api/app/devices/i", "DELETE /api/app/session"))
        NativeSignOut(AppApiClient(tokens, transport), tokens, "i") { removed.add(it) }.run(install.host)
        assertNull(tokens.token(install.host))
    }

    // Task 01a116c4: only that install's conversation shortcuts go.

    @Test
    fun `signing out of A removes A's shortcuts only`() {
        tokens.store(install.host, "b1")
        tokens.store("suite.example.org", "b2")
        NativeSignOut(AppApiClient(tokens, RecordingTransport()), tokens, "i") { removed.add(it) }.run(install.host)
        assertEquals(listOf(install.host), removed)
    }

    @Test
    fun `a revoked bearer (401) removes that install's shortcuts only, other failures remove none`() {
        tokens.store(install.host, "b1")
        launcher(RecordingTransport(mapOf("POST /api/app/handoff" to HttpResponse(401, "{}")))).start(install, null)
        assertEquals(listOf(install.host), removed)

        removed.clear()
        tokens.store(install.host, "b1")
        launcher(RecordingTransport(mapOf("POST /api/app/handoff" to HttpResponse(502, "")))).start(install, null)
        assertEquals(emptyList<String>(), removed)
    }
}
