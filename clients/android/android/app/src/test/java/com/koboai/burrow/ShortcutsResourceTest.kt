package com.koboai.burrow

import android.content.res.XmlResourceParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.xmlpull.v1.XmlPullParser

/**
 * The launcher shortcut (res/xml/shortcuts.xml) as the MERGED resources of
 * this variant have it. Runs under both testDebugUnitTest and
 * testReleaseUnitTest, so it proves the debug override and the main file
 * each name their own package: a shortcut whose targetPackage is not the
 * installed application id never launches.
 */
@RunWith(RobolectricTestRunner::class)
class ShortcutsResourceTest {
    private val android = "http://schemas.android.com/apk/res/android"

    private data class Shortcut(
        val id: String?,
        val shortLabel: Int,
        val longLabel: Int,
        val icon: Int,
        val intents: List<Map<String, String?>>,
    )

    private fun shortcuts(): List<Shortcut> {
        val context = RuntimeEnvironment.getApplication()
        val parser: XmlResourceParser = context.resources.getXml(R.xml.shortcuts)
        val found = mutableListOf<Shortcut>()
        var current: Shortcut? = null
        while (parser.next() != XmlPullParser.END_DOCUMENT) {
            when {
                parser.eventType == XmlPullParser.START_TAG && parser.name == "shortcut" ->
                    current =
                        Shortcut(
                            id = parser.getAttributeValue(android, "shortcutId"),
                            shortLabel = parser.getAttributeResourceValue(android, "shortcutShortLabel", 0),
                            longLabel = parser.getAttributeResourceValue(android, "shortcutLongLabel", 0),
                            icon = parser.getAttributeResourceValue(android, "icon", 0),
                            intents = mutableListOf(),
                        )
                parser.eventType == XmlPullParser.START_TAG && parser.name == "intent" ->
                    (current!!.intents as MutableList).add(
                        listOf("action", "targetPackage", "targetClass").associateWith { parser.getAttributeValue(android, it) },
                    )
                parser.eventType == XmlPullParser.END_TAG && parser.name == "shortcut" -> {
                    found.add(current!!)
                    current = null
                }
            }
        }
        parser.close()
        return found
    }

    @Test
    fun `one Switch install shortcut that opens the trampoline in this variant's package`() {
        val context = RuntimeEnvironment.getApplication()
        val shortcut = shortcuts().single()
        assertEquals("switch_install", shortcut.id)
        assertEquals("Switch install", context.getString(shortcut.shortLabel))
        assertEquals("Switch install", context.getString(shortcut.longLabel))
        assertNotEquals(0, shortcut.icon)
        // The icon resolves to a drawable.
        context.getDrawable(shortcut.icon)!!
        val intent = shortcut.intents.single()
        assertEquals(LaunchRouter.ACTION_SWITCH_INSTALL, intent["action"])
        // The trampoline, never MainActivity: Android adds CLEAR_TASK to static shortcut intents.
        assertEquals(SwitchInstallActivity::class.java.name, intent["targetClass"])
        assertEquals(BuildConfig.APPLICATION_ID, intent["targetPackage"])
    }
}
