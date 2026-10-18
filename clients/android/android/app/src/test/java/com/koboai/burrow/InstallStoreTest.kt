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

    // Stand-ins for the former built-in hosts. The store under test is
    // given their digests through the legacyHostHashes seam, so no real
    // former host appears here; the pin test below guards the shipped list.
    private val legacyDefaults = listOf("old-a.example.com", "old-b.example.com", "old-c.example.com")
    private val legacyHashes = legacyDefaults.map { InstallStore.hostHash(it) }.toSet()

    private fun newStore(tokenHosts: () -> Set<String> = { emptySet() }): InstallStore =
        InstallStore(prefs, device, tokenHosts = tokenHosts, legacyHostHashes = legacyHashes)

    private val store = newStore()

    /** Saves the three former defaults, as a tester's list after an Add. */
    private fun seedSaved(hosts: List<String> = legacyDefaults) {
        hosts.forEach { store.add(it) }
    }

    @Test
    fun `fresh store has no installs and no selection`() {
        // A bearer host present (restored prefs, a stale entry) must be
        // ignored: a store that is not legacy is a clean first launch.
        val fresh = newStore(tokenHosts = { setOf("old-a.example.com") })
        assertEquals(emptyList<Install>(), fresh.installs)
        assertNull(fresh.selectedHost)
        assertNull(fresh.selectedInstall)
        assertFalse(fresh.hasConfirmedSelection)
        assertEquals("the empty list is persisted", "", prefs.getString("installs.v1"))
        assertEquals(emptyList<Install>(), newStore(tokenHosts = { setOf("old-a.example.com") }).installs)
    }

    @Test
    fun `legacy upgrade keeps signed-in and selected installs`() {
        // Exactly what an old build leaves: confirmed, a selection, no saved
        // list (the built-in rows were virtual), plus a bearer.
        prefs.putBoolean("installs.confirmed.v1", true)
        prefs.putString("installs.selected.v1", "old-b.example.com")
        val upgraded = newStore(tokenHosts = { linkedSetOf("old-a.example.com", "OLD-B.example.com") })
        assertEquals(listOf("old-b.example.com", "old-a.example.com"), upgraded.installs.map { it.host })
        assertEquals("old-b.example.com", upgraded.selectedHost)
        assertTrue(upgraded.hasConfirmedSelection)
        assertNotNull(prefs.getString("installs.v1"))
        // The saved list is now authoritative: the bearers are not re-read.
        val reopened = newStore(tokenHosts = { setOf("other.example.com") })
        assertEquals(listOf("old-b.example.com", "old-a.example.com"), reopened.installs.map { it.host })
    }

    @Test
    fun `legacy saved list is kept whole`() {
        val hosts = legacyDefaults + "burrow.example.com"
        prefs.putString("installs.v1", hosts.joinToString("\n"))
        prefs.putBoolean("installs.confirmed.v1", true)
        // Only one of the four holds a bearer; none may be dropped.
        val tokens = { setOf("burrow.example.com") }
        assertEquals(hosts, newStore(tokenHosts = tokens).installs.map { it.host })
        assertEquals(hosts, newStore(tokenHosts = tokens).installs.map { it.host })
    }

    @Test
    fun `implicit default with no token is not adopted`() {
        // An old build where the person only pressed Continue on the implicit
        // first row: confirmed, no explicit selection, no bearer.
        prefs.putBoolean("installs.confirmed.v1", true)
        val upgraded = newStore(tokenHosts = { emptySet() })
        assertEquals(emptyList<Install>(), upgraded.installs)
        assertNull(upgraded.selectedHost)
    }

    @Test
    fun `selection persists and an unknown host is ignored`() {
        seedSaved()
        store.select("old-c.example.com")
        assertEquals("old-c.example.com", newStore().selectedHost)
        store.select("not-listed.example.com")
        assertEquals("old-c.example.com", store.selectedHost)
        store.confirmSelection()
        assertTrue(newStore().hasConfirmedSelection)
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
        store.select("old-a.example.com")
        store.remove("old-a.example.com")
        val reopened = newStore()
        assertEquals(listOf("old-b.example.com", "old-c.example.com"), reopened.installs.map { it.host })
        assertEquals("old-b.example.com", reopened.selectedHost)
    }

    @Test
    fun `names survive a round trip, including tabs and newlines`() {
        seedSaved()
        store.add("a.example.com", "Tab\there\nand there")
        store.updateName("Mine", "old-c.example.com")
        val reopened = newStore().installs
        assertEquals("Tab here and there", reopened.first { it.host == "a.example.com" }.name)
        assertEquals("Mine", reopened.first { it.host == "old-c.example.com" }.name)
        assertNull(reopened.first { it.host == "old-a.example.com" }.name)
    }

    @Test
    fun `normalizeHost accepts DNS names only`() {
        assertEquals("old-a.example.com", InstallStore.normalizeHost("old-a.example.com."))
        assertEquals("a.b.example.com", InstallStore.normalizeHost("http://A.B.example.com/path?q=1"))
        listOf(
            "",
            "localhost",
            "-bad.example.com",
            "bad-.example.com",
            "a..b",
            "a b.example.com",
            "a.example.com:8443",
            "user@a.example.com",
            "a_b.example.com",
        ).forEach { assertNull(it, InstallStore.normalizeHost(it)) }
        assertNull(InstallStore.normalizeHost("a".repeat(64) + ".example.com"))
    }

    @Test
    fun `app install id is stable and lives in the device file, not the installs file`() {
        val id = store.appInstallId
        assertTrue(id.matches(Regex("^[0-9a-f-]{36}$")))
        assertEquals(id, newStore().appInstallId)
        assertTrue(device.rawValues().contains(id))
        assertFalse(prefs.rawValues().contains(id))
    }

    // Old builds saved the built-in rows (review finding 2, task 01a12787).

    /** The old build's state after only showing its picker: the defaults saved by a name refresh, the first selected, Continue pressed. */
    private fun seedOldBuildDefaults() {
        prefs.putString("installs.v1", legacyDefaults.joinToString("\n") { "$it\tBurrow" })
        prefs.putString("installs.selected.v1", "old-a.example.com")
        prefs.putBoolean("installs.confirmed.v1", true)
    }

    @Test
    fun `the old built-in hosts are recognised by hash, not by name`() {
        assertTrue(legacyDefaults.all { InstallStore.isLegacyHost(it, legacyHashes) })
        assertTrue(InstallStore.isLegacyHost("https://OLD-A.Example.com/chat", legacyHashes))
        assertFalse(InstallStore.isLegacyHost("burrow.example.com", legacyHashes))
        assertFalse(InstallStore.isLegacyHost("new.example.com", legacyHashes))
        // The stand-ins are not the shipped hosts: production keeps its own list.
        assertFalse(legacyDefaults.any { InstallStore.isLegacyDefault(it) })
    }

    @Test
    fun `the shipped legacy host digests are pinned`() {
        // The preimages are checked outside this repo (a private core-ops
        // script); here a changed or dropped digest goes red.
        assertEquals(
            setOf(
                "bf8aedd7f65fd728e9ebfec07705bc51e26ae0f54a35e00e8b2ed514b2bb664e",
                "11a3b9f3cee6dab41a8d8ded38d71da667774c858c9eb82c3c596b21b6273717",
                "c3d59dfdd4a743b27afbfd9fe449cbe919dd425ac7dcabee8790365371c2dde3",
            ),
            InstallStore.LEGACY_DEFAULT_HOST_HASHES,
        )
    }

    @Test
    fun `a defaults-only list without bearers clears to the add flow`() {
        seedOldBuildDefaults()
        val upgraded = newStore(tokenHosts = { emptySet() })
        assertEquals(emptyList<Install>(), upgraded.installs)
        assertNull(upgraded.selectedHost)
        assertFalse(upgraded.hasConfirmedSelection)
        assertNull(prefs.getString("installs.selected.v1"))
        assertEquals("the empty list is persisted", "", prefs.getString("installs.v1"))
        assertEquals(emptyList<Install>(), newStore().installs)
    }

    @Test
    fun `a defaults-only list where one default has a bearer is kept whole`() {
        seedOldBuildDefaults()
        val upgraded = newStore(tokenHosts = { setOf("OLD-C.example.com") })
        assertEquals(legacyDefaults, upgraded.installs.map { it.host })
        assertEquals("old-a.example.com", upgraded.selectedHost)
        assertTrue(upgraded.hasConfirmedSelection)
    }

    @Test
    fun `defaults plus a custom host is kept whole`() {
        prefs.putString("installs.v1", (legacyDefaults + "rig.example.com").joinToString("\n"))
        prefs.putString("installs.selected.v1", "old-b.example.com")
        prefs.putBoolean("installs.confirmed.v1", true)
        val upgraded = newStore(tokenHosts = { emptySet() })
        assertEquals(legacyDefaults + "rig.example.com", upgraded.installs.map { it.host })
        assertEquals("old-b.example.com", upgraded.selectedHost)
        assertTrue(upgraded.hasConfirmedSelection)
    }

    @Test
    fun `the clear happens once, so a later add survives a relaunch`() {
        seedOldBuildDefaults()
        val upgraded = newStore(tokenHosts = { emptySet() })
        assertEquals(emptyList<Install>(), upgraded.installs)
        // The person then adds a former built-in host themselves, before signing in.
        upgraded.add("old-a.example.com")
        val relaunched = newStore(tokenHosts = { emptySet() })
        assertEquals(listOf("old-a.example.com"), relaunched.installs.map { it.host })
        assertEquals("old-a.example.com", relaunched.selectedHost)
    }
}
