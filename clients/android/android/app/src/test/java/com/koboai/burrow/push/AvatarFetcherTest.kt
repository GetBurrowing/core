package com.koboai.burrow.push

import android.graphics.Color
import com.koboai.burrow.FakeTokenCipher
import com.koboai.burrow.InMemoryKeyValueStore
import com.koboai.burrow.KeystoreTokenStore
import com.koboai.burrow.push.AvatarServer.Companion.image
import com.koboai.burrow.push.AvatarServer.Companion.png
import okhttp3.mockwebserver.MockResponse
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.GraphicsMode
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * push/AvatarFetcher.kt (task 01a12773 stage 3): bearer only to the
 * install's own host, no redirects, a bounded fetch, a size cap, and the
 * caches. Every network test has a JUnit timeout, so a hang fails instead of
 * stalling the suite.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class AvatarFetcherTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val bearer = "tok_live_bearer_9f8e7d"
    private val tokens = KeystoreTokenStore(InMemoryKeyValueStore(), FakeTokenCipher())
    private lateinit var avatars: AvatarServer
    private var now = 1_000_000L

    @Before
    fun setUp() {
        avatars = AvatarServer()
    }

    @After
    fun tearDown() = avatars.shutdown()

    private fun fetcher(cache: File? = folder.root) = AvatarFetcher(tokens, cache, avatars.clientSockets, clock = { now })

    private fun timed(block: () -> Unit): Long {
        val start = System.nanoTime()
        block()
        return TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start)
    }

    @Test(timeout = 10_000)
    fun `a url on the install's own host carries that install's bearer`() {
        tokens.store(avatars.authority, bearer)
        avatars.server.enqueue(image())

        assertNotNull(fetcher().fetch(avatars.url(), avatars.authority))

        val request = avatars.server.takeRequest()
        assertEquals("Bearer $bearer", request.getHeader("Authorization"))
        assertEquals("*/*", request.getHeader("Accept"))
    }

    @Test(timeout = 10_000)
    fun `a url on any other host gets no Authorization header at all`() {
        // The install is suite.example.com and holds a bearer; the picture is
        // an OIDC url somewhere else.
        tokens.store("suite.example.com", bearer)
        tokens.store(avatars.authority, "a-bearer-for-another-install")
        avatars.server.enqueue(image())

        assertNotNull(fetcher().fetch(avatars.url("/idp/face.png"), "suite.example.com"))

        assertNull(avatars.server.takeRequest().getHeader("Authorization"))
    }

    @Test(timeout = 10_000)
    fun `the same name on another port is another host`() {
        tokens.store("localhost:1", bearer)
        avatars.server.enqueue(image())

        assertNotNull(fetcher().fetch(avatars.url(), "localhost:1"))
        assertNull(avatars.server.takeRequest().getHeader("Authorization"))
    }

    @Test(timeout = 10_000)
    fun `a redirect is not followed, is a failure, and its target sees nothing`() {
        val target = AvatarServer()
        try {
            tokens.store(avatars.authority, bearer)
            target.server.enqueue(image())
            avatars.server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", target.url("/stolen.png")))

            assertNull(fetcher().fetch(avatars.url(), avatars.authority))

            assertEquals(1, avatars.server.requestCount)
            assertEquals(0, target.server.requestCount)
        } finally {
            target.shutdown()
        }
    }

    @Test(timeout = 10_000)
    fun `a host that never sends the body is abandoned inside the deadline`() {
        avatars.server.enqueue(image().setBodyDelay(10, TimeUnit.SECONDS))

        var result: Any? = Unit
        val elapsed = timed { result = fetcher().fetch(avatars.url(), avatars.authority) }

        assertNull(result)
        assertTrue("took $elapsed ms", elapsed < 3_000)
    }

    @Test(timeout = 10_000)
    fun `a host that drips the body slowly is cut off by the total deadline, not the read timeout`() {
        // One 1 KB chunk a second: every read returns within the 1.5 s read
        // timeout, so only the 2.5 s wall-clock deadline can stop it.
        val body = AvatarServer.noisePng()
        assertTrue("the body must outlast the deadline at 1 KB/s: ${body.size}", body.size > 8 * 1_024)
        avatars.server.enqueue(image(body).throttleBody(1_024, 1, TimeUnit.SECONDS))

        var result: Any? = Unit
        val elapsed = timed { result = fetcher().fetch(avatars.url(), avatars.authority) }

        assertNull(result)
        assertTrue("took $elapsed ms", elapsed < 3_000)
    }

    @Test(timeout = 10_000)
    fun `a body over 256 KB is refused, with or without a Content-Length`() {
        val big = ByteArray(300 * 1024) { 7 }
        avatars.server.enqueue(MockResponse().setBody(Buffer().write(big)))
        avatars.server.enqueue(MockResponse().setChunkedBody(Buffer().write(big), 8_192))

        assertNull(fetcher(cache = null).fetch(avatars.url("/a.png"), avatars.authority))
        assertNull(fetcher(cache = null).fetch(avatars.url("/b.png"), avatars.authority))
        assertEquals(2, avatars.server.requestCount)
    }

    @Test(timeout = 10_000)
    fun `bytes that are not an image are a failure`() {
        avatars.server.enqueue(MockResponse().setHeader("Content-Type", "text/html").setBody("<html>sign in</html>"))
        assertNull(fetcher().fetch(avatars.url(), avatars.authority))
    }

    @Test(timeout = 10_000)
    fun `no url, a blank url or a non-https url makes no request`() {
        val f = fetcher()
        assertNull(f.fetch(null, avatars.authority))
        assertNull(f.fetch("  ", avatars.authority))
        assertNull(f.fetch("http://${avatars.authority}/a.png", avatars.authority))
        assertNull(f.fetch("/agents/a1/avatar", avatars.authority))
        assertEquals(0, avatars.server.requestCount)
    }

    @Test(timeout = 10_000)
    fun `one url is fetched once, then served from memory and, in a new process, from disk`() {
        avatars.server.enqueue(image())
        val url = avatars.url()

        val warm = fetcher()
        assertNotNull(warm.fetch(url, avatars.authority))
        assertNotNull(warm.fetch(url, avatars.authority))
        assertEquals(1, avatars.server.requestCount)

        // A cold process: a new fetcher over the same cache directory.
        val cold = fetcher()
        assertNotNull(cold.cached(url))
        assertNotNull(cold.fetch(url, avatars.authority))
        assertEquals(1, avatars.server.requestCount)
        assertTrue(File(folder.root, "avatars/${AvatarFetcher.sha256(url)}.png").isFile)
    }

    @Test(timeout = 10_000)
    fun `a new cache token is a new url and is fetched again`() {
        avatars.server.enqueue(image())
        avatars.server.enqueue(image(png(Color.BLUE)))
        val f = fetcher()

        assertNotNull(f.fetch(avatars.url("/api/app/agents/a1/avatar?v=1"), avatars.authority))
        assertNotNull(f.fetch(avatars.url("/api/app/agents/a1/avatar?v=2"), avatars.authority))
        assertEquals(2, avatars.server.requestCount)
    }

    @Test(timeout = 10_000)
    fun `a failure is remembered for ten minutes, then retried`() {
        avatars.server.enqueue(MockResponse().setResponseCode(500))
        avatars.server.enqueue(image())
        val f = fetcher()

        assertNull(f.fetch(avatars.url(), avatars.authority))
        now += 9 * 60 * 1_000L
        assertNull(f.fetch(avatars.url(), avatars.authority))
        assertEquals(1, avatars.server.requestCount)

        now += 2 * 60 * 1_000L
        assertNotNull(f.fetch(avatars.url(), avatars.authority))
        assertEquals(2, avatars.server.requestCount)
    }

    @Test
    fun `a large picture is decoded to at most 192 px on a side`() {
        val bitmap = AvatarFetcher.decode(png(Color.GREEN, 1_000, 500))!!
        assertTrue("${bitmap.width}x${bitmap.height}", bitmap.width <= AvatarFetcher.MAX_PX && bitmap.height <= AvatarFetcher.MAX_PX)
        assertTrue(bitmap.width >= 96)
    }
}
