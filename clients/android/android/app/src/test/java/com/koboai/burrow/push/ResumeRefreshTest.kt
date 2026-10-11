package com.koboai.burrow.push

import com.koboai.burrow.AppApiClient
import com.koboai.burrow.FakeTokenCipher
import com.koboai.burrow.HttpResponse
import com.koboai.burrow.InMemoryKeyValueStore
import com.koboai.burrow.KeystoreTokenStore
import com.koboai.burrow.RecordingTransport
import com.koboai.burrow.widgets.Counts
import com.koboai.burrow.widgets.CountsStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.net.URI

/** One app open = ONE `/api/app/counts` per signed-in install (task 01a1261e remediation, case 7009). */
class ResumeRefreshTest {
    private val a = "suite-a.localhost"
    private val b = "suite-b.localhost"

    private class MemoryCounts : CountsStore {
        val map = mutableMapOf<String, Counts>()

        override suspend fun read(host: String): Counts? = map[host]

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

    private val tokens =
        KeystoreTokenStore(InMemoryKeyValueStore(), FakeTokenCipher()).apply {
            store(a, "bearer-a")
            store(b, "bearer-b")
        }

    private fun transport() =
        RecordingTransport(
            mapOf("GET /api/app/counts" to HttpResponse(200, """{"approvals":2,"tasks":5,"unread":3,"as_of":"2026-10-10T15:00:00Z"}""")),
        )

    @Test
    fun `an open asks each signed-in install for its counts exactly once and feeds the widget cache from that answer`() {
        val transport = transport()
        val unread = UnreadStore(InMemoryKeyValueStore()) { listOf(a, b) }
        val widgets = MemoryCounts()
        val refresh = ResumeRefresh(UnreadReconciler(UnreadReconciler.fetcher(AppApiClient(tokens, transport)), unread), widgets) { 42L }

        val outcome = refresh.run(listOf(a, b), selectedHost = a)

        val perHost = transport.requests.groupingBy { "${URI(it.url).host} ${URI(it.url).path}" }.eachCount()
        assertEquals(mapOf("$a /api/app/counts" to 1, "$b /api/app/counts" to 1), perHost)
        assertEquals(6, outcome.total)
        // The widgets show the selected install: its approvals and tasks came from the same body.
        assertEquals(Counts(2, 5, 42L), widgets.map[a])
        assertNull(widgets.map[b])
        assertEquals(Counts(2, 5, 42L), outcome.widgetCounts)
    }

    @Test
    fun `a failed selected install writes no widget counts and keeps its unread stale`() {
        val transport = RecordingTransport(failing = setOf("GET /api/app/counts"))
        val unread = UnreadStore(InMemoryKeyValueStore()) { listOf(a) }
        unread.write(a, 4, 1_000)
        val widgets = MemoryCounts()
        val outcome =
            ResumeRefresh(UnreadReconciler(UnreadReconciler.fetcher(AppApiClient(tokens, transport)), unread), widgets).run(listOf(a), a)
        assertEquals(1, transport.requests.size)
        assertTrue(widgets.map.isEmpty())
        assertNull(outcome.widgetCounts)
        assertEquals(InstallUnread(4, 1_000, true), unread.entry(a))
    }

    private fun body(
        source: String,
        signature: String,
    ): String {
        val start = source.indexOf(signature)
        assertTrue("$signature not found", start >= 0)
        val open = source.indexOf('{', start)
        var depth = 0
        for (i in open until source.length) {
            if (source[i] == '{') depth++
            if (source[i] == '}') depth--
            if (depth == 0) return source.substring(open, i + 1)
        }
        error("unbalanced")
    }

    @Test
    fun `MainActivity's resume path makes no second counts fetch`() {
        val source = File("src/main/java/com/koboai/burrow/MainActivity.kt").readText()
        val onResume = body(source, "override fun onResume()")
        val reconcile = body(source, "private fun reconcileUnread()")
        // The one fetch is ResumeRefresh; the widgets only re-render.
        assertTrue(onResume.contains("reconcileUnread()"))
        assertTrue(reconcile.contains("resumeRefresh(app).run("))
        assertTrue(reconcile.contains("WidgetRefresh.renderNow("))
        for (path in listOf(onResume, reconcile)) {
            assertFalse(path.contains("WidgetRefresh.now("))
            assertFalse(path.contains("CountsRepository"))
        }
    }

    @Test
    fun `the guard can go red`() {
        val fake = "override fun onResume() {\n super.onResume()\n WidgetRefresh.now(this)\n reconcileUnread()\n}"
        assertTrue(body(fake, "override fun onResume()").contains("WidgetRefresh.now("))
    }
}
