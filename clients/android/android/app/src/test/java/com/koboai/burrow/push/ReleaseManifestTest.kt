package com.koboai.burrow.push

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * The debug push-replay receiver must never ship. Parses the MERGED
 * manifests Gradle writes (build.gradle makes the unit tests depend on both
 * process*MainManifest tasks and passes their paths in), so a receiver that
 * slipped in through main, a library or a manifest placeholder is caught,
 * not only one in src/main/AndroidManifest.xml.
 */
class ReleaseManifestTest {
    private val android = "http://schemas.android.com/apk/res/android"

    private fun receivers(property: String): List<Element> = elements(property, "receiver")

    private fun elements(
        property: String,
        tag: String,
    ): List<Element> {
        val path = System.getProperty(property) ?: error("system property $property not set (run through Gradle)")
        val file = File(path)
        assertTrue("merged manifest missing: $path", file.isFile)
        val factory = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        val doc = factory.newDocumentBuilder().parse(file)
        val nodes = doc.getElementsByTagName(tag)
        return (0 until nodes.length).map { nodes.item(it) as Element }
    }

    private fun Element.name() = getAttributeNS(android, "name")

    private fun Element.actions(): List<String> {
        val nodes = getElementsByTagName("action")
        return (0 until nodes.length).map { (nodes.item(it) as Element).getAttributeNS(android, "name") }
    }

    @Test
    fun `the release manifest has no DebugPushReceiver and no debug PUSH action`() {
        val release = receivers("burrow.releaseManifest")
        assertFalse(release.any { it.name().endsWith("DebugPushReceiver") })
        assertFalse(release.flatMap { it.actions() }.contains("com.koboai.burrow.debug.PUSH"))
        assertTrue(elements("burrow.releaseManifest", "activity-alias").none { it.name().endsWith("DebugExplainer") })
        // The reply receiver does ship, and is not exported.
        val reply = release.single { it.name() == "com.koboai.burrow.push.ReplyReceiver" }
        assertEquals("false", reply.getAttributeNS(android, "exported"))
    }

    @Test
    fun `positive control - the debug manifest has it, exported only to the adb shell`() {
        val debug = receivers("burrow.debugManifest").single { it.name() == "com.koboai.burrow.push.DebugPushReceiver" }
        assertEquals(listOf("com.koboai.burrow.debug.PUSH"), debug.actions())
        assertEquals("android.permission.DUMP", debug.getAttributeNS(android, "permission"))
        val alias = elements("burrow.debugManifest", "activity-alias").single { it.name().endsWith("DebugExplainer") }
        assertEquals("android.permission.DUMP", alias.getAttributeNS(android, "permission"))
    }

    @Test
    fun `the unread evidence seam is debug-only and exported only to the adb shell`() {
        assertTrue(receivers("burrow.releaseManifest").none { it.name().endsWith("DebugUnreadReceiver") })
        val debug = receivers("burrow.debugManifest").single { it.name() == "com.koboai.burrow.push.DebugUnreadReceiver" }
        assertEquals(listOf("com.koboai.burrow.debug.UNREAD"), debug.actions())
        assertEquals("android.permission.DUMP", debug.getAttributeNS(android, "permission"))
    }

    @Test
    fun `the share target is its own task-less activity, not MainActivity`() {
        val activities = elements("burrow.releaseManifest", "activity")
        val share = activities.single { it.name() == "com.koboai.burrow.share.ShareActivity" }
        assertEquals("", share.getAttributeNS(android, "taskAffinity"))
        assertTrue(share.hasAttributeNS(android, "taskAffinity"))
        assertEquals("true", share.getAttributeNS(android, "excludeFromRecents"))
        assertEquals(
            listOf("android.intent.action.SEND", "android.intent.action.SEND_MULTIPLE"),
            share.actions(),
        )
        val main = activities.single { it.name() == "com.koboai.burrow.MainActivity" }
        assertFalse(main.actions().any { it.startsWith("android.intent.action.SEND") })
        // Both widget receivers ship.
        val receivers = receivers("burrow.releaseManifest").map { it.name() }
        assertTrue(receivers.contains("com.koboai.burrow.widgets.MyApprovalsWidgetReceiver"))
        assertTrue(receivers.contains("com.koboai.burrow.widgets.MyTasksWidgetReceiver"))
    }

    @Test
    fun `MainActivity declares the launcher shortcuts in the release and debug manifests`() {
        for (property in listOf("burrow.releaseManifest", "burrow.debugManifest")) {
            val main = elements(property, "activity").single { it.name() == "com.koboai.burrow.MainActivity" }
            val metas = main.getElementsByTagName("meta-data")
            val shortcuts =
                (0 until metas.length)
                    .map { metas.item(it) as Element }
                    .filter { it.name() == "android.app.shortcuts" }
            assertEquals(property, 1, shortcuts.size)
            assertEquals(property, "@xml/shortcuts", shortcuts.single().getAttributeNS(android, "resource"))
            assertEquals(property, "singleTask", main.getAttributeNS(android, "launchMode"))
        }
    }

    @Test
    fun `the shortcut trampoline has no UI, no recents entry and its own task affinity`() {
        for (property in listOf("burrow.releaseManifest", "burrow.debugManifest")) {
            val trampoline = elements(property, "activity").single { it.name() == "com.koboai.burrow.SwitchInstallActivity" }
            // An empty affinity: the CLEAR_TASK Android adds to static
            // shortcut intents must clear this throwaway task, not MainActivity's.
            assertTrue(property, trampoline.hasAttributeNS(android, "taskAffinity"))
            assertEquals(property, "", trampoline.getAttributeNS(android, "taskAffinity"))
            assertEquals(property, "true", trampoline.getAttributeNS(android, "excludeFromRecents"))
            assertEquals(property, "true", trampoline.getAttributeNS(android, "noHistory"))
            assertEquals(property, "false", trampoline.getAttributeNS(android, "exported"))
            assertEquals(property, "@android:style/Theme.NoDisplay", trampoline.getAttributeNS(android, "theme"))
            assertTrue(property, trampoline.actions().isEmpty())
        }
    }
}
