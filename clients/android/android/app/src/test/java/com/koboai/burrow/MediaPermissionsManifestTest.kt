package com.koboai.burrow

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * The voice tab and meetings call getUserMedia inside the WebView.
 * Capacitor's BridgeWebChromeClient grants a WebView media request only by
 * asking for the matching runtime permission, and Android refuses to ask for
 * one the manifest does not declare. So the shipped (merged, release)
 * manifest must declare them, and must not make the hardware a hard
 * requirement for installing.
 */
class MediaPermissionsManifestTest {
    private val android = "http://schemas.android.com/apk/res/android"

    private fun elements(tag: String): List<Element> {
        val path = System.getProperty("burrow.releaseManifest") ?: error("burrow.releaseManifest not set (run through Gradle)")
        val file = File(path)
        assertTrue("merged manifest missing: $path", file.isFile)
        val factory = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        val nodes = factory.newDocumentBuilder().parse(file).getElementsByTagName(tag)
        return (0 until nodes.length).map { nodes.item(it) as Element }
    }

    private fun Element.name() = getAttributeNS(android, "name")

    @Test
    fun `the release manifest declares the mic and camera permissions getUserMedia needs`() {
        val permissions = elements("uses-permission").map { it.name() }
        for (needed in listOf(
            "android.permission.RECORD_AUDIO",
            "android.permission.MODIFY_AUDIO_SETTINGS",
            "android.permission.CAMERA",
        )) {
            assertTrue("$needed missing from the release manifest", needed in permissions)
        }
    }

    @Test
    fun `camera and microphone hardware stay optional`() {
        val features = elements("uses-feature").associate { it.name() to it.getAttributeNS(android, "required") }
        for (feature in listOf("android.hardware.camera", "android.hardware.microphone")) {
            assertEquals("$feature must be required=false", "false", features[feature])
        }
    }
}
