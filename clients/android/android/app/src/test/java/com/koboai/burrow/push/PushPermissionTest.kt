package com.koboai.burrow.push

import com.koboai.burrow.InMemoryKeyValueStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class PushPermissionTest {
    @Test
    fun `pushState on Android 13 and later`() {
        assertEquals("granted", PushPermission.state(33, notificationsEnabled = true, explainerShown = false))
        assertEquals("granted", PushPermission.state(35, notificationsEnabled = true, explainerShown = true))
        // Never asked on this device: "prompt", so the web hook calls enablePush.
        assertEquals("prompt", PushPermission.state(33, notificationsEnabled = false, explainerShown = false))
        assertEquals("prompt", PushPermission.state(35, notificationsEnabled = false, explainerShown = false))
        // Asked once (explainer shown, whatever the answer): never "prompt" again,
        // so the web never auto-calls enablePush on a later mount.
        assertEquals("denied", PushPermission.state(33, notificationsEnabled = false, explainerShown = true))
    }

    @Test
    fun `pushState below Android 13 is never prompt`() {
        assertEquals("granted", PushPermission.state(32, notificationsEnabled = true, explainerShown = false))
        assertEquals("denied", PushPermission.state(32, notificationsEnabled = false, explainerShown = false))
        assertEquals("denied", PushPermission.state(26, notificationsEnabled = false, explainerShown = false))
    }

    @Test
    fun `enablePush steps`() {
        assertEquals(PermissionStep.REGISTER, PushPermission.nextStep(35, true, systemAsked = false, canAskAgain = false))
        assertEquals(PermissionStep.REGISTER, PushPermission.nextStep(30, true, systemAsked = false, canAskAgain = false))
        // Below 13: no explainer, no prompt.
        assertEquals(PermissionStep.DENIED, PushPermission.nextStep(32, false, systemAsked = false, canAskAgain = false))
        // 13+, never asked: the explainer.
        assertEquals(PermissionStep.EXPLAIN, PushPermission.nextStep(33, false, systemAsked = false, canAskAgain = false))
        // Denied once: Android allows one more prompt (re-ask from the settings row).
        assertEquals(PermissionStep.EXPLAIN, PushPermission.nextStep(33, false, systemAsked = true, canAskAgain = true))
        // Denied twice: settings only.
        assertEquals(
            PermissionStep.EXPLAIN_DENIED_PERMANENTLY,
            PushPermission.nextStep(33, false, systemAsked = true, canAskAgain = false),
        )
    }

    /**
     * The gate case (task 01a10d8e stage 6): Not now, relaunch, then the
     * settings row twice. pushState must say "denied" after every ask, so the
     * web hook never re-asks on a relaunch, while enablePush (the row's
     * click) must still reach a real next step each time.
     */
    @Test
    fun `Not now never re-asks on relaunch, and the settings row always can`() {
        val sdk = 35
        // First launch: "prompt", so the hook's on-mount call shows the explainer.
        assertEquals("prompt", PushPermission.state(sdk, false, explainerShown = false))
        assertEquals(PermissionStep.EXPLAIN, PushPermission.nextStep(sdk, false, systemAsked = false, canAskAgain = false))

        // Not now: the explainer was shown, Android's prompt was not.
        assertEquals("denied", PushPermission.state(sdk, false, explainerShown = true))
        assertEquals(PermissionStep.EXPLAIN, PushPermission.nextStep(sdk, false, systemAsked = false, canAskAgain = false))

        // First system denial: still "denied" on relaunch; the row re-asks via the explainer.
        assertEquals("denied", PushPermission.state(sdk, false, explainerShown = true))
        assertEquals(PermissionStep.EXPLAIN, PushPermission.nextStep(sdk, false, systemAsked = true, canAskAgain = true))

        // Second denial: Android will not prompt again; the row opens the settings variant.
        assertEquals("denied", PushPermission.state(sdk, false, explainerShown = true))
        assertEquals(
            PermissionStep.EXPLAIN_DENIED_PERMANENTLY,
            PushPermission.nextStep(sdk, false, systemAsked = true, canAskAgain = false),
        )
    }

    @Test
    fun `the explainer flags are device-local prefs and nothing else`() {
        val store = InMemoryKeyValueStore()
        val prefs = PushPrefs(store)
        assertFalse(prefs.explainerShown)
        prefs.explainerShown = true
        prefs.systemAsked = true
        assertTrue(PushPrefs(store).explainerShown)
        assertTrue(PushPrefs(store).systemAsked)
        assertEquals(setOf("explainer_shown.v1", "system_asked.v1"), store.keys())
    }

    @Test
    fun `the server banner state is not an input`() {
        // pushState's only inputs are the SDK, Android's switch and this
        // device's flag: the per-user web banner dismissal (PR #1190) cannot
        // reach it. The plugin source reads no banner or server state either.
        val plugin = File("src/main/java/com/koboai/burrow/BurrowNativePlugin.kt").readText()
        val pushState = plugin.substringAfter("fun pushState(").substringBefore("@PluginMethod")
        assertTrue(pushState.contains("BurrowPush.prefs(context).explainerShown"))
        for (word in listOf("banner", "dismiss", "push_permission", "client(", "handoff")) {
            assertFalse("pushState must not consult '$word'", pushState.contains(word, ignoreCase = true))
        }
    }

    @Test
    fun `the explainer flag file is excluded from backup, so a restored phone is still asked`() {
        for (path in listOf("src/main/res/xml/data_extraction_rules.xml", "src/main/res/xml/backup_rules.xml")) {
            val xml = File(path).readText()
            assertTrue("$path must exclude ${PushPrefs.FILE}", xml.contains("path=\"${PushPrefs.FILE}.xml\""))
        }
    }
}
