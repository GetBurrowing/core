package com.koboai.burrow.push

import com.koboai.burrow.InMemoryKeyValueStore
import com.koboai.burrow.InstallStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UnreadStoreTest {
    private val a = "suite-a.localhost"
    private val b = "suite-b.localhost"
    private val prefs = InMemoryKeyValueStore()
    private var signedIn = listOf(a, b)
    private val store = UnreadStore(prefs) { signedIn }

    @Test
    fun `a newer as-of replaces the stored count`() {
        assertTrue(store.write(b, 3, 1_000))
        assertTrue(store.write(b, 0, 2_000))
        assertEquals(InstallUnread(0, 2_000, false), store.entry(b))
    }

    @Test
    fun `an older as-of is ignored, so a late push cannot bring back a cleared count`() {
        store.write(b, 0, 2_000)
        assertFalse(store.write(b, 3, 1_000))
        assertEquals(0, store.entry(b)!!.count)
    }

    @Test
    fun `an equal as-of is ignored too`() {
        store.write(b, 2, 1_000)
        assertFalse(store.write(b, 5, 1_000))
        assertEquals(2, store.entry(b)!!.count)
    }

    @Test
    fun `stale keeps the count, and a refresh that answered clears it even when it lost on as-of`() {
        store.write(b, 2, 2_000)
        store.markStale(b)
        assertEquals(InstallUnread(2, 2_000, true), store.entry(b))
        assertFalse(store.write(b, 9, 1_000, clearStale = true))
        assertEquals(InstallUnread(2, 2_000, false), store.entry(b))
    }

    @Test
    fun `marking an install with no count stale stores nothing`() {
        store.markStale(a)
        assertNull(store.entry(a))
    }

    @Test
    fun `the total is the sum over signed-in installs and excludes a removed one`() {
        val installPrefs = InMemoryKeyValueStore()
        val installs = InstallStore(installPrefs, InMemoryKeyValueStore(), prefs)
        installs.add(a)
        installs.add(b)
        signedIn = installs.installs.map { it.host }.filter { it == a || it == b }
        store.write(a, 2, 1_000)
        store.write(b, 3, 1_000)
        assertEquals(5, store.total)

        installs.remove(b)
        signedIn = installs.installs.map { it.host }.filter { it == a || it == b }
        assertEquals(2, store.total)
        // InstallStore.remove cleared B's entry too, so a re-add starts from nothing.
        assertNull(store.entry(b))
    }

    @Test
    fun `a signed-out install's count is not in the total`() {
        store.write(a, 2, 1_000)
        store.write(b, 3, 1_000)
        signedIn = listOf(a)
        assertEquals(2, store.total)
        assertEquals(setOf(a), store.entries().keys)
    }

    @Test
    fun `installBadges is true only when ANOTHER install has unread`() {
        store.write(a, 4, 1_000)
        assertFalse(store.othersUnread(a))
        assertTrue(store.othersUnread(b))
        store.write(b, 1, 1_000)
        assertTrue(store.othersUnread(a))
        store.write(b, 0, 2_000)
        assertFalse(store.othersUnread(a))
    }

    @Test
    fun `server times parse with any fraction, and junk is null`() {
        assertEquals(1_791_644_400_000L, UnreadStore.parseAsOf("2026-10-10T15:00:00Z"))
        assertEquals(1_791_644_400_123L, UnreadStore.parseAsOf("2026-10-10T15:00:00.123456Z"))
        assertNull(UnreadStore.parseAsOf("yesterday"))
        assertNull(UnreadStore.parseAsOf(null))
        assertEquals(3, UnreadStore.parseCount("3"))
        assertNull(UnreadStore.parseCount("-1"))
        assertNull(UnreadStore.parseCount("x"))
    }
}
