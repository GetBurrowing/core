package com.koboai.burrow.widgets

import com.koboai.burrow.ApiException
import com.koboai.burrow.AppApiClient
import com.koboai.burrow.FakeTokenCipher
import com.koboai.burrow.HttpResponse
import com.koboai.burrow.InMemoryKeyValueStore
import com.koboai.burrow.KeystoreTokenStore
import com.koboai.burrow.RecordingTransport
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class CountsRepositoryTest {
    private val host = "burrow.example.com"
    private val tokens = KeystoreTokenStore(InMemoryKeyValueStore(), FakeTokenCipher())

    private class MemoryStore : CountsStore {
        val map = mutableMapOf<String, Counts>()

        override suspend fun read(host: String) = map[host]

        override suspend fun write(
            host: String,
            counts: Counts,
        ) {
            map[host] = counts
        }

        override suspend fun remove(host: String) {
            map.remove(host)
        }
    }

    @Test
    fun `refresh stores the counts with THIS device's fetch time, on this install's bearer`() =
        runBlocking {
            tokens.store(host, "tok_a")
            val body = """{"approvals":3,"tasks":12,"as_of":"2020-01-01T00:00:00Z"}"""
            val transport = RecordingTransport(mapOf("GET /api/app/counts" to HttpResponse(200, body)))
            val store = MemoryStore()
            val repo = CountsRepository(AppApiClient(tokens, transport), store) { 42L }
            assertEquals(Counts(3, 12, 42L), repo.refresh(host))
            assertEquals(Counts(3, 12, 42L), store.map[host])
            val request = transport.requests.single()
            assertEquals("https://$host/api/app/counts", request.url)
            assertEquals("Bearer tok_a", request.headers["Authorization"])
        }

    @Test
    fun `a failed refresh keeps the last good counts (they go stale, not blank)`() =
        runBlocking {
            tokens.store(host, "tok_a")
            val store = MemoryStore().also { it.map[host] = Counts(3, 1, 5L) }
            for (transport in listOf(
                RecordingTransport(mapOf("GET /api/app/counts" to HttpResponse(500, "{}"))),
                RecordingTransport(failing = setOf("GET /api/app/counts")),
                RecordingTransport(mapOf("GET /api/app/counts" to HttpResponse(200, "not json"))),
            )) {
                assertNull(CountsRepository(AppApiClient(tokens, transport), store) { 99L }.refresh(host))
                assertEquals(Counts(3, 1, 5L), store.map[host])
            }
            // No bearer: no request at all.
            val none = RecordingTransport()
            assertNull(CountsRepository(AppApiClient(tokens, none), store).refresh("burrow.example.org"))
            assertTrue(none.requests.isEmpty())
        }

    @Test
    fun `sign-out forgets the host's counts`() =
        runBlocking {
            val store = MemoryStore().also { it.map[host] = Counts(3, 1, 5L) }
            CountsRepository(AppApiClient(tokens, RecordingTransport()), store).forget(host)
            assertNull(store.map[host])
        }

    @Test
    fun `parse needs both counts`() {
        assertEquals(Counts(0, 7, 1L), CountsRepository.parse("""{"approvals":0,"tasks":7}""", 1L))
        try {
            CountsRepository.parse("""{"approvals":0}""", 1L)
            fail("expected BAD_RESPONSE")
        } catch (e: ApiException) {
            assertEquals(ApiException.Kind.BAD_RESPONSE, e.kind)
        }
    }
}
