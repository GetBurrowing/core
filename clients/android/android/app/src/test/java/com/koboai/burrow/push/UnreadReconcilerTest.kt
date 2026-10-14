package com.koboai.burrow.push

import com.koboai.burrow.AppApiClient
import com.koboai.burrow.FakeTokenCipher
import com.koboai.burrow.HttpResponse
import com.koboai.burrow.InMemoryKeyValueStore
import com.koboai.burrow.KeystoreTokenStore
import com.koboai.burrow.RecordingTransport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class UnreadReconcilerTest {
    companion object {
        private const val COUNTS_BODY = """{"approvals":1,"tasks":0,"unread":4,"as_of":"2026-10-10T15:00:00Z"}"""
    }

    private val a = "suite-a.localhost"
    private val b = "suite-b.localhost"
    private val store = UnreadStore(InMemoryKeyValueStore()) { listOf(a, b) }

    @Test
    fun `answers are written and the total is returned`() {
        val total =
            UnreadReconciler({ host -> UnreadReconciler.Counts(if (host == a) 2 else 3, 5_000) }, store).reconcile(listOf(a, b))
        assertEquals(5, total)
        assertEquals(InstallUnread(3, 5_000, false), store.entry(b))
    }

    @Test
    fun `an install that fails is marked stale and keeps its last count`() {
        store.write(b, 2, 1_000)
        UnreadReconciler({ host -> if (host == b) throw IOException("down") else UnreadReconciler.Counts(0, 5_000) }, store)
            .reconcile(listOf(a, b))
        assertEquals(InstallUnread(2, 1_000, true), store.entry(b))
        assertEquals(InstallUnread(0, 5_000, false), store.entry(a))
        assertEquals(2, store.total)
    }

    @Test
    fun `the next answer clears stale`() {
        store.write(b, 2, 1_000)
        store.markStale(b)
        UnreadReconciler({ UnreadReconciler.Counts(0, 6_000) }, store).reconcile(listOf(b))
        assertEquals(InstallUnread(0, 6_000, false), store.entry(b))
    }

    @Test
    fun `a server without unread changes nothing`() {
        store.write(b, 2, 1_000)
        UnreadReconciler({ UnreadReconciler.Counts(null, 6_000) }, store).reconcile(listOf(b))
        assertEquals(InstallUnread(2, 1_000, false), store.entry(b))
    }

    @Test
    fun `at most four installs are fetched at once`() {
        val hosts = (1..7).map { "suite-$it.localhost" }
        val running = AtomicInteger()
        val peak = AtomicInteger()
        val fourIn = CountDownLatch(4)
        val reconciler =
            UnreadReconciler({ _ ->
                val now = running.incrementAndGet()
                peak.accumulateAndGet(now) { x, y -> maxOf(x, y) }
                fourIn.countDown()
                // Hold every slot until four are in flight, so the peak is measured, not luck.
                fourIn.await(5, TimeUnit.SECONDS)
                Thread.sleep(20)
                running.decrementAndGet()
                UnreadReconciler.Counts(1, 1_000)
            }, UnreadStore(InMemoryKeyValueStore()) { hosts })
        assertEquals(7, reconciler.reconcile(hosts))
        assertEquals(4, peak.get())
    }

    @Test
    fun `each install is asked with its own bearer`() {
        val tokens = KeystoreTokenStore(InMemoryKeyValueStore(), FakeTokenCipher())
        tokens.store(a, "bearer-a")
        tokens.store(b, "bearer-b")
        val transport =
            RecordingTransport(
                mapOf("GET /api/app/counts" to HttpResponse(200, COUNTS_BODY)),
            )
        UnreadReconciler(UnreadReconciler.fetcher(AppApiClient(tokens, transport)), store, maxConcurrent = 1).reconcile(listOf(a, b))
        val sent = transport.requests.associate { java.net.URI(it.url).host to it.headers["Authorization"] }
        assertEquals(mapOf(a to "Bearer bearer-a", b to "Bearer bearer-b"), sent)
        assertEquals(8, store.total)
    }

    @Test
    fun `counts parse unread and as_of, and tolerate an older server`() {
        val parsed = UnreadReconciler.parse("""{"approvals":1,"tasks":2,"unread":7,"as_of":"2026-10-10T15:00:00.5Z"}""")
        assertEquals(7, parsed.unread)
        assertEquals(1_791_644_400_500L, parsed.asOfMillis)
        assertNull(UnreadReconciler.parse("""{"approvals":1,"tasks":2,"as_of":"2026-10-10T15:00:00Z"}""").unread)
        assertTrue(runCatching { UnreadReconciler.parse("<html>") }.isFailure)
    }
}
