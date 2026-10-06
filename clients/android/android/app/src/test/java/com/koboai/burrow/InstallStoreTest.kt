package com.koboai.burrow

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InstallStoreTest {
    private val prefs = InMemoryKeyValueStore()
    private val device = InMemoryKeyValueStore()
    private val store = InstallStore(prefs, device)

    @Test
    fun `first launch pre-lists the three installs with suite_kobo-ai_com selected`() {
        assertEquals(
            listOf("suite.example.com", "suite.example.com", "suite.milv.life"),
            store.installs.map { it.host },
        )
        assertEquals("suite.example.com", store.selectedHost)
        assertFalse(store.hasConfirmedSelection)
    }

    @Test
    fun `selection persists and an unknown host is ignored`() {
        store.select("suite.milv.life")
        assertEquals("suite.milv.life", InstallStore(prefs, device).selectedHost)
        store.select("not-listed.example.com")
        assertEquals("suite.milv.life", store.selectedHost)
        store.confirmSelection()
        assertTrue(InstallStore(prefs, device).hasConfirmedSelection)
    }

    @Test
    fun `add by URL normalizes, appends and selects`() {
        val added = store.add("  HTTPS://Burrow.Example.com/chat/x ", "Example")
        assertEquals(Install("burrow.example.com", "Example"), added)
        assertEquals("burrow.example.com", store.selectedHost)
        assertEquals(4, store.installs.size)
        assertEquals("Example", store.selectedInstall?.displayName)
        // Adding again keeps one row and updates the name.
        store.add("burrow.example.com", "Renamed")
        assertEquals(4, store.installs.size)
        assertEquals("Renamed", store.installs.last().name)
    }

    @Test
    fun `a removed default stays removed and selection falls back`() {
        store.select("suite.example.com")
        store.remove("suite.example.com")
        val reopened = InstallStore(prefs, device)
        assertEquals(listOf("suite.example.com", "suite.milv.life"), reopened.installs.map { it.host })
        assertEquals("suite.example.com", reopened.selectedHost)
    }

    @Test
    fun `names survive a round trip, including tabs and newlines`() {
        store.add("a.example.com", "Tab\there\nand there")
        store.updateName("Mine", "suite.milv.life")
        val reopened = InstallStore(prefs, device).installs
        assertEquals("Tab here and there", reopened.first { it.host == "a.example.com" }.name)
        assertEquals("Mine", reopened.first { it.host == "suite.milv.life" }.name)
        assertNull(reopened.first { it.host == "suite.example.com" }.name)
    }

    @Test
    fun `normalizeHost accepts DNS names only`() {
        assertEquals("suite.example.com", InstallStore.normalizeHost("suite.example.com."))
        assertEquals("a.b", InstallStore.normalizeHost("http://A.B/path?q=1"))
        listOf("", "localhost", "-bad.example.com", "bad-.example.com", "a..b", "a b.com", "a.com:8443", "user@a.com", "a_b.com")
            .forEach { assertNull(it, InstallStore.normalizeHost(it)) }
        assertNull(InstallStore.normalizeHost("a".repeat(64) + ".com"))
    }

    @Test
    fun `app install id is stable and lives in the device file, not the installs file`() {
        val id = store.appInstallId
        assertTrue(id.matches(Regex("^[0-9a-f-]{36}$")))
        assertEquals(id, InstallStore(prefs, device).appInstallId)
        assertTrue(device.rawValues().contains(id))
        assertFalse(prefs.rawValues().contains(id))
    }
}
