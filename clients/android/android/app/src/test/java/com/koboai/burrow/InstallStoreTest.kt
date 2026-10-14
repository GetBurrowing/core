package com.koboai.burrow

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InstallStoreTest {
    private val prefs = InMemoryKeyValueStore()
    private val device = InMemoryKeyValueStore()
    private val store = InstallStore(prefs, device)

    private val legacyDefaults = listOf("suite.example.com", "suite.example.com", "suite.milv.life")

    /** Saves the three former defaults, as a tester's list after an Add. */
    private fun seedSaved(hosts: List<String> = legacyDefaults) {
        hosts.forEach { store.add(it) }
    }

    @Test
    fun `fresh store has no installs and no selection`() {
        // A bearer host present (restored prefs, a stale entry) must be
        // ignored: a store that is not legacy is a clean first launch.
        val fresh = InstallStore(prefs, device, tokenHosts = { setOf("suite.example.com") })
        assertEquals(emptyList<Install>(), fresh.installs)
        assertNull(fresh.selectedHost)
        assertNull(fresh.selectedInstall)
        assertFalse(fresh.hasConfirmedSelection)
        assertEquals("the empty list is persisted", "", prefs.getString("installs.v1"))
        assertEquals(emptyList<Install>(), InstallStore(prefs, device, tokenHosts = { setOf("suite.example.com") }).installs)
    }

    @Test
    fun `legacy upgrade keeps signed-in and selected installs`() {
        // Exactly what an old build leaves: confirmed, a selection, no saved
        // list (the built-in rows were virtual), plus a bearer.
        prefs.putBoolean("installs.confirmed.v1", true)
        prefs.putString("installs.selected.v1", "suite.example.com")
        val upgraded = InstallStore(prefs, device, tokenHosts = { linkedSetOf("suite.example.com", "SUITE.example.com") })
        assertEquals(listOf("suite.example.com", "suite.example.com"), upgraded.installs.map { it.host })
        assertEquals("suite.example.com", upgraded.selectedHost)
        assertTrue(upgraded.hasConfirmedSelection)
        assertNotNull(prefs.getString("installs.v1"))
        // The saved list is now authoritative: the bearers are not re-read.
        val reopened = InstallStore(prefs, device, tokenHosts = { setOf("other.example.com") })
        assertEquals(listOf("suite.example.com", "suite.example.com"), reopened.installs.map { it.host })
    }

    @Test
    fun `legacy saved list is kept whole`() {
        val hosts = legacyDefaults + "suite.example.com"
        prefs.putString("installs.v1", hosts.joinToString("\n"))
        prefs.putBoolean("installs.confirmed.v1", true)
        // Only one of the four holds a bearer; none may be dropped.
        val tokens = { setOf("suite.example.com") }
        assertEquals(hosts, InstallStore(prefs, device, tokenHosts = tokens).installs.map { it.host })
        assertEquals(hosts, InstallStore(prefs, device, tokenHosts = tokens).installs.map { it.host })
    }

    @Test
    fun `implicit default with no token is not adopted`() {
        // An old build where the person only pressed Continue on the implicit
        // first row: confirmed, no explicit selection, no bearer.
        prefs.putBoolean("installs.confirmed.v1", true)
        val upgraded = InstallStore(prefs, device, tokenHosts = { emptySet() })
        assertEquals(emptyList<Install>(), upgraded.installs)
        assertNull(upgraded.selectedHost)
    }

    @Test
    fun `selection persists and an unknown host is ignored`() {
        seedSaved()
        store.select("suite.milv.life")
        assertEquals("suite.milv.life", InstallStore(prefs, device).selectedHost)
        store.select("not-listed.example.com")
        assertEquals("suite.milv.life", store.selectedHost)
        store.confirmSelection()
        assertTrue(InstallStore(prefs, device).hasConfirmedSelection)
    }

    @Test
    fun `add by URL normalizes, appends and selects`() {
        seedSaved()
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
    fun `a removed install stays removed and selection falls back`() {
        seedSaved()
        store.select("suite.example.com")
        store.remove("suite.example.com")
        val reopened = InstallStore(prefs, device)
        assertEquals(listOf("suite.example.com", "suite.milv.life"), reopened.installs.map { it.host })
        assertEquals("suite.example.com", reopened.selectedHost)
    }

    @Test
    fun `names survive a round trip, including tabs and newlines`() {
        seedSaved()
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

    // Old builds saved the built-in rows (review finding 2, task 01a12787).

    /** The old build's state after only showing its picker: the defaults saved by a name refresh, fabrikam selected, Continue pressed. */
    private fun seedOldBuildDefaults() {
        prefs.putString("installs.v1", legacyDefaults.joinToString("\n") { "$it\tSuite" })
        prefs.putString("installs.selected.v1", "suite.example.com")
        prefs.putBoolean("installs.confirmed.v1", true)
    }

    @Test
    fun `the old built-in hosts are recognised by hash, not by name`() {
        assertEquals(legacyDefaults.map { InstallStore.hostHash(it) }.toSet(), InstallStore.LEGACY_DEFAULT_HOST_HASHES)
        assertTrue(legacyDefaults.all { InstallStore.isLegacyDefault(it) })
        assertTrue(InstallStore.isLegacyDefault("https://SUITE.example.com/chat"))
        assertFalse(InstallStore.isLegacyDefault("suite.example.com"))
        assertFalse(InstallStore.isLegacyDefault("burrow.red-st.ar"))
    }

    @Test
    fun `a defaults-only list without bearers clears to the add flow`() {
        seedOldBuildDefaults()
        val upgraded = InstallStore(prefs, device, tokenHosts = { emptySet() })
        assertEquals(emptyList<Install>(), upgraded.installs)
        assertNull(upgraded.selectedHost)
        assertFalse(upgraded.hasConfirmedSelection)
        assertNull(prefs.getString("installs.selected.v1"))
        assertEquals("the empty list is persisted", "", prefs.getString("installs.v1"))
        assertEquals(emptyList<Install>(), InstallStore(prefs, device).installs)
    }

    @Test
    fun `a defaults-only list where one default has a bearer is kept whole`() {
        seedOldBuildDefaults()
        val upgraded = InstallStore(prefs, device, tokenHosts = { setOf("SUITE.milv.life") })
        assertEquals(legacyDefaults, upgraded.installs.map { it.host })
        assertEquals("suite.example.com", upgraded.selectedHost)
        assertTrue(upgraded.hasConfirmedSelection)
    }

    @Test
    fun `defaults plus a custom host is kept whole`() {
        prefs.putString("installs.v1", (legacyDefaults + "rig.example.com").joinToString("\n"))
        prefs.putString("installs.selected.v1", "suite.example.com")
        prefs.putBoolean("installs.confirmed.v1", true)
        val upgraded = InstallStore(prefs, device, tokenHosts = { emptySet() })
        assertEquals(legacyDefaults + "rig.example.com", upgraded.installs.map { it.host })
        assertEquals("suite.example.com", upgraded.selectedHost)
        assertTrue(upgraded.hasConfirmedSelection)
    }

    @Test
    fun `the clear happens once, so a later add survives a relaunch`() {
        seedOldBuildDefaults()
        val upgraded = InstallStore(prefs, device, tokenHosts = { emptySet() })
        assertEquals(emptyList<Install>(), upgraded.installs)
        // The person then adds a former built-in host themselves, before signing in.
        upgraded.add("suite.example.com")
        val relaunched = InstallStore(prefs, device, tokenHosts = { emptySet() })
        assertEquals(listOf("suite.example.com"), relaunched.installs.map { it.host })
        assertEquals("suite.example.com", relaunched.selectedHost)
    }
}
