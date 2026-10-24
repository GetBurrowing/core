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
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import java.time.LocalDate

@RunWith(RobolectricTestRunner::class)
class BriefingRepositoryTest {
    private val host = "burrow.example.com"
    private val tokens = KeystoreTokenStore(InMemoryKeyValueStore(), FakeTokenCipher())
    private val day = LocalDate.parse("2026-10-23")

    private val withBriefing =
        """
        {"today":"2026-10-23","zone":"America/Chicago",
         "briefing":{"date":"2026-10-23","total":9,"open":4,"calls":2,"handled":5,
                     "summary":"2 calls are yours","url":"/inbox?briefing=2026-10-23"}}
        """.trimIndent()

    private class MemoryStore : BriefingStore {
        val map = mutableMapOf<String, CachedBriefing>()

        override suspend fun read(host: String) = map[host]

        override suspend fun write(
            host: String,
            cached: CachedBriefing,
        ) {
            map[host] = cached
        }

        override suspend fun remove(host: String) {
            map.remove(host)
        }
    }

    @Test
    fun `parse reads both payload shapes`() {
        assertEquals(
            CachedBriefing(day, "America/Chicago", Briefing(day, 9, 4, 2, 5), 7L),
            BriefingRepository.parse(withBriefing, 7L),
        )
        assertEquals(
            CachedBriefing(day, "America/Chicago", null, 7L),
            BriefingRepository.parse("""{"today":"2026-10-23","zone":"America/Chicago","briefing":null}""", 7L),
        )
        for (bad in listOf(
            "not json",
            """{"today":"2026-10-23","briefing":null}""",
            """{"today":"2026-10-23","zone":"America/Chicago","briefing":{"date":"2026-10-23","total":1}}""",
            """{"today":"yesterday","zone":"America/Chicago","briefing":null}""",
            """{"today":"2026-10-23","zone":"Not/AZone","briefing":null}""",
        )) {
            try {
                BriefingRepository.parse(bad, 1L)
                fail("expected BAD_RESPONSE for $bad")
            } catch (e: ApiException) {
                assertEquals(ApiException.Kind.BAD_RESPONSE, e.kind)
            }
        }
    }

    @Test
    fun `refresh stores the briefing with THIS device's fetch time, on this install's bearer`() =
        runBlocking {
            tokens.store(host, "tok_a")
            val transport = RecordingTransport(mapOf("GET /api/app/briefing" to HttpResponse(200, withBriefing)))
            val store = MemoryStore()
            val repo = BriefingRepository(AppApiClient(tokens, transport), store) { 42L }
            val expected = CachedBriefing(day, "America/Chicago", Briefing(day, 9, 4, 2, 5), 42L)
            assertEquals(expected, repo.refresh(host))
            assertEquals(expected, store.map[host])
            assertEquals(expected, repo.cached(host))
            val request = transport.requests.single()
            assertEquals("https://$host/api/app/briefing", request.url)
            assertEquals("Bearer tok_a", request.headers["Authorization"])
        }

    @Test
    fun `a failed refresh keeps the cache`() =
        runBlocking {
            tokens.store(host, "tok_a")
            val old = CachedBriefing(day, "America/Chicago", Briefing(day, 3, 1, 1, 2), 5L)
            val store = MemoryStore().also { it.map[host] = old }
            for (transport in listOf(
                RecordingTransport(mapOf("GET /api/app/briefing" to HttpResponse(500, "{}"))),
                RecordingTransport(failing = setOf("GET /api/app/briefing")),
                RecordingTransport(mapOf("GET /api/app/briefing" to HttpResponse(200, "not json"))),
            )) {
                assertNull(BriefingRepository(AppApiClient(tokens, transport), store) { 99L }.refresh(host))
                assertEquals(old, store.map[host])
            }
            val none = RecordingTransport()
            assertNull(BriefingRepository(AppApiClient(tokens, none), store).refresh("burrow.example.org"))
            assertTrue(none.requests.isEmpty())
        }

    @Test
    fun `the DataStore keeps only counts, dates and zone, and forget removes every key`() =
        runBlocking {
            val store = DataStoreBriefingStore(RuntimeEnvironment.getApplication())
            // A payload with items and other unknown fields stores nothing extra.
            val noisy =
                """
                {"today":"2026-10-23","zone":"America/Chicago","items":[{"id":"x","title":"secret"}],"user":"u",
                 "briefing":{"date":"2026-10-23","total":9,"open":4,"calls":2,"handled":5,
                             "summary":"2 calls are yours","url":"/inbox","items":[{"id":"y"}]}}
                """.trimIndent()
            val parsed = BriefingRepository.parse(noisy, 11L)
            store.write(host, parsed)
            val expectedKeys =
                listOf("date", "total", "open", "calls", "handled", "today", "zone", "fetched_at")
                    .map { "$it.v1.$host" }
                    .toSet()
            assertEquals(expectedKeys, store.storedKeyNames())
            assertEquals(parsed, store.read(host))

            // A second host's entry must survive the first host's forget.
            val other = "burrow.example.org"
            store.write(other, CachedBriefing(day, "America/Chicago", null, 3L))

            BriefingRepository(AppApiClient(tokens, RecordingTransport()), store).forget(host)
            assertNull(store.read(host))
            assertEquals(emptySet<String>(), store.storedKeyNames().filter { it.endsWith(".v1.$host") }.toSet())
            assertEquals(CachedBriefing(day, "America/Chicago", null, 3L), store.read(other))

            // Writing "no briefing" over a briefing clears the old counts.
            store.write(other, parsed)
            store.write(other, CachedBriefing(day, "America/Chicago", null, 4L))
            assertEquals(CachedBriefing(day, "America/Chicago", null, 4L), store.read(other))
            assertEquals(
                setOf("today", "zone", "fetched_at").map { "$it.v1.$other" }.toSet(),
                store.storedKeyNames(),
            )
        }
}
