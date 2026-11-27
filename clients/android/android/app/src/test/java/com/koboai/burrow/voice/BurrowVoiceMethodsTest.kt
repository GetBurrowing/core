package com.koboai.burrow.voice

import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import com.koboai.burrow.NativeBridgeExposure
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Pins the bridge contract: the plugin's name, its `@PluginMethod`s and its
 * events, against [BurrowVoicePlugin.METHODS] and [BurrowVoicePlugin.EVENTS].
 * The names are the iOS plugin's (`BurrowVoicePlugin.swift` pluginMethods
 * and `events`). The web half reads the same source: stage 4's vitest scan
 * parses `@PluginMethod fun <name>` and the EVENTS list in
 * [SOURCE], so this test also pins the shapes that scan relies on.
 */
class BurrowVoiceMethodsTest {
    companion object {
        const val SOURCE = "src/main/java/com/koboai/burrow/voice/BurrowVoicePlugin.kt"
        private val METHOD_DECL = Regex("""@PluginMethod\s+fun\s+(\w+)\s*\(""")
        private val EVENTS_DECL = Regex("""val EVENTS = listOf\(([^)]*)\)""")
        private val EMIT = Regex("""emit\(\s*"(\w+)"""")
    }

    private val source = File(SOURCE).readText()

    @Test
    fun `the plugin is BurrowVoice`() {
        assertEquals("BurrowVoice", BurrowVoicePlugin::class.java.getAnnotation(CapacitorPlugin::class.java)!!.name)
    }

    @Test
    fun `the methods are the iOS methods so far, by reflection and in the source`() {
        val expected =
            listOf("capabilities", "prepare", "start", "stop", "cancel", "openSettings", "speak", "speakPart", "stopSpeaking", "voices")
        assertEquals(expected, BurrowVoicePlugin.METHODS)
        val reflected =
            BurrowVoicePlugin::class.java.declaredMethods
                .filter { it.isAnnotationPresent(PluginMethod::class.java) }
                .map { it.name }
                .toSet()
        assertEquals(expected.toSet(), reflected)
        val declared = METHOD_DECL.findAll(source).map { it.groupValues[1] }.toList()
        assertEquals(expected, declared)
    }

    @Test
    fun `the events are the iOS names, and the source sends exactly those`() {
        assertEquals(listOf("partial", "final", "ended", "route", "speech"), BurrowVoicePlugin.EVENTS)
        val listed =
            EVENTS_DECL
                .find(source)!!
                .groupValues[1]
                .split(',')
                .map { it.trim().trim('"') }
        assertEquals(BurrowVoicePlugin.EVENTS, listed)
        val sent = EMIT.findAll(source).map { it.groupValues[1] }.toSet()
        assertEquals(BurrowVoicePlugin.EVENTS.toSet(), sent)
    }

    @Test
    fun `the install origin's bridge script includes BurrowVoice`() {
        // Without it the page never sees the plugin and Voice silently keeps
        // its LiveKit path (NativeBridgeExposure builds the script from this list).
        assertTrue(NativeBridgeExposure.PLUGIN_IDS.contains("BurrowVoice"))
    }

    @Test
    fun `MainActivity registers the plugin`() {
        val activity = File("src/main/java/com/koboai/burrow/MainActivity.kt").readText()
        assertTrue(activity.contains("registerPlugin(BurrowVoicePlugin::class.java)"))
        assertTrue(activity.contains("registerPlugin(BurrowNativePlugin::class.java)"))
    }

    @Test
    fun `the manifest already declares the mic permissions, and the plugin asks for RECORD_AUDIO by alias`() {
        val manifest = File("src/main/AndroidManifest.xml").readText()
        assertTrue(manifest.contains("android.permission.RECORD_AUDIO"))
        assertTrue(manifest.contains("android.permission.MODIFY_AUDIO_SETTINGS"))
        // Package visibility: without it a non-system TextToSpeech engine is invisible.
        assertTrue(manifest.contains("android.intent.action.TTS_SERVICE"))
        val permission =
            BurrowVoicePlugin::class.java
                .getAnnotation(CapacitorPlugin::class.java)!!
                .permissions
                .single()
        assertEquals(BurrowVoicePlugin.MIC, permission.alias)
        assertEquals(listOf("android.permission.RECORD_AUDIO"), permission.strings.toList())
    }
}
