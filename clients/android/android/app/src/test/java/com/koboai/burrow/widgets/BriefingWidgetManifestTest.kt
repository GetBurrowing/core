package com.koboai.burrow.widgets

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * The Today's briefing receivers as declared in the source manifest and
 * res/xml. The cover receiver carries Samsung's documented Flex Window form
 * (developer.samsung.com/galaxy-z/flex_window.html): a second meta-data,
 * com.samsung.android.appwidget.provider, pointing at
 * <samsung-appwidget-provider display="sub_screen">, and keyguard 352x339dp
 * provider info. The home receiver stays a plain 2x2 home_screen widget.
 */
class BriefingWidgetManifestTest {
    private val android = "http://schemas.android.com/apk/res/android"

    private fun parse(path: String): Element {
        val file = File(path)
        assertTrue("$path missing", file.isFile)
        val factory = DocumentBuilderFactory.newInstance()
        factory.isNamespaceAware = true
        return factory.newDocumentBuilder().parse(file).documentElement
    }

    private fun Element.children(tag: String): List<Element> {
        val nodes = getElementsByTagName(tag)
        return (0 until nodes.length).map { nodes.item(it) as Element }
    }

    private fun receiver(name: String): Element {
        val found = parse("src/main/AndroidManifest.xml").children("receiver").filter { it.getAttributeNS(android, "name") == name }
        assertEquals("receivers named $name", 1, found.size)
        return found.single()
    }

    /** meta-data name -> resource, for one receiver. */
    private fun metaData(receiver: Element): Map<String, String> =
        receiver.children("meta-data").associate { it.getAttributeNS(android, "name") to it.getAttributeNS(android, "resource") }

    private fun xmlResource(ref: String): Element {
        assertTrue(ref, ref.startsWith("@xml/"))
        return parse("src/main/res/xml/${ref.removePrefix("@xml/")}.xml")
    }

    private fun assertWidgetReceiver(receiver: Element) {
        assertEquals("true", receiver.getAttributeNS(android, "exported"))
        val actions = receiver.children("action").map { it.getAttributeNS(android, "name") }
        assertEquals(listOf("android.appwidget.action.APPWIDGET_UPDATE"), actions)
    }

    @Test
    fun `cover receiver carries both meta-data, Samsung's pointing at sub_screen`() {
        val cover = receiver(".widgets.TodaysBriefingCoverWidgetReceiver")
        assertWidgetReceiver(cover)
        val meta = metaData(cover)
        assertEquals(setOf("android.appwidget.provider", "com.samsung.android.appwidget.provider"), meta.keys)

        val samsung = xmlResource(meta.getValue("com.samsung.android.appwidget.provider"))
        assertEquals("samsung-appwidget-provider", samsung.tagName)
        assertEquals("sub_screen", samsung.getAttribute("display"))

        val info = xmlResource(meta.getValue("android.appwidget.provider"))
        assertEquals("appwidget-provider", info.tagName)
        assertEquals("keyguard", info.getAttributeNS(android, "widgetCategory"))
        assertEquals("352dp", info.getAttributeNS(android, "minWidth"))
        assertEquals("339dp", info.getAttributeNS(android, "minHeight"))
        assertEquals("horizontal|vertical", info.getAttributeNS(android, "resizeMode"))
    }

    @Test
    fun `home receiver is a plain 2x2 home_screen widget with no Samsung meta-data`() {
        val home = receiver(".widgets.TodaysBriefingWidgetReceiver")
        assertWidgetReceiver(home)
        val meta = metaData(home)
        assertEquals(setOf("android.appwidget.provider"), meta.keys)
        val info = xmlResource(meta.getValue("android.appwidget.provider"))
        assertEquals("home_screen", info.getAttributeNS(android, "widgetCategory"))
        assertEquals("110dp", info.getAttributeNS(android, "minWidth"))
        assertEquals("110dp", info.getAttributeNS(android, "minHeight"))
        assertEquals("2", info.getAttributeNS(android, "targetCellWidth"))
        assertEquals("2", info.getAttributeNS(android, "targetCellHeight"))
        assertEquals("0", info.getAttributeNS(android, "updatePeriodMillis"))
        assertEquals("@string/widget_briefing_description", info.getAttributeNS(android, "description"))
        // maxResizeWidth stopped the Pixel launcher at 3 columns.
        assertEquals("", info.getAttributeNS(android, "maxResizeWidth"))
    }

    @Test
    fun `the parser sees what it is meant to (positive control)`() {
        // The count widgets' receiver parses and has no Samsung meta-data (out of scope for this task).
        val tasks = receiver(".widgets.MyTasksWidgetReceiver")
        assertNotNull(metaData(tasks)["android.appwidget.provider"])
        assertEquals(setOf("android.appwidget.provider"), metaData(tasks).keys)
    }
}
