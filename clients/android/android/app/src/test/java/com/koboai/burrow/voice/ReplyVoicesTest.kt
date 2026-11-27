package com.koboai.burrow.voice

import android.speech.tts.Voice
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale

class ReplyVoicesTest {
    private fun voice(
        name: String,
        language: String = "en-US",
        quality: Int = Voice.QUALITY_NORMAL,
        network: Boolean = false,
        notInstalled: Boolean = false,
    ) = EngineVoice(name, language, quality, network, notInstalled)

    private val engineVoices =
        listOf(
            voice("en-us-x-aaa-local", quality = Voice.QUALITY_HIGH),
            voice("en-us-x-bbb-network", quality = Voice.QUALITY_VERY_HIGH, network = true),
            voice("en-us-x-ccc-local", quality = Voice.QUALITY_VERY_HIGH, notInstalled = true),
            voice("en-us-x-ddd-local", quality = Voice.QUALITY_VERY_HIGH),
            voice("en-gb-x-eee-local", language = "en-GB", quality = Voice.QUALITY_VERY_HIGH),
            voice("en-us-x-fff-local", quality = Voice.QUALITY_NORMAL),
            voice("de-de-x-ggg-local", language = "de-DE", quality = Voice.QUALITY_VERY_HIGH),
        )

    @Test
    fun `network voices and voices whose data is not installed are excluded`() {
        val ids = ReplyVoices.installed(engineVoices, Locale.US).map { it.id }
        assertFalse(ids.contains("en-us-x-bbb-network"))
        assertFalse(ids.contains("en-us-x-ccc-local"))
        assertEquals(5, ids.size)
    }

    @Test
    fun `quality maps to the JS qualities`() {
        assertEquals("premium", ReplyVoices.quality(Voice.QUALITY_VERY_HIGH))
        assertEquals("enhanced", ReplyVoices.quality(Voice.QUALITY_HIGH))
        assertEquals("default", ReplyVoices.quality(Voice.QUALITY_NORMAL))
        assertEquals("default", ReplyVoices.quality(Voice.QUALITY_VERY_LOW))
        val js = listOf("neural", "premium", "enhanced", "default")
        assertEquals(js, ReplyVoice.QUALITIES)
        ReplyVoices.installed(engineVoices, Locale.US).forEach { assertTrue(it.quality in js) }
    }

    @Test
    fun `names are readable, never the engine's raw id`() {
        val voices = ReplyVoices.installed(engineVoices, Locale.US)
        voices.forEach { assertFalse(it.name, it.name.contains("-x-") || it.name.contains("local")) }
        assertEquals("English (United Kingdom)", voices.single { it.language == "en-GB" }.name)
        val us = voices.filter { it.language == "en-US" }.map { it.name }
        assertEquals(listOf("English (United States) 1", "English (United States) 2", "English (United States) 3"), us)
    }

    @Test
    fun `voices for the language are ranked by quality, exact region first`() {
        val ranked = ReplyVoicePicker.voices("en-US", ReplyVoices.installed(engineVoices, Locale.US)).map { it.id }
        assertEquals(listOf("en-us-x-ddd-local", "en-gb-x-eee-local", "en-us-x-aaa-local", "en-us-x-fff-local"), ranked)
        assertFalse("another language is not offered", ranked.contains("de-de-x-ggg-local"))
    }

    @Test
    fun `the default is the best installed voice`() {
        val all = ReplyVoices.installed(engineVoices, Locale.US)
        assertEquals("en-us-x-ddd-local", ReplyVoicePicker.best("en-US", all)!!.id)
        assertNull(ReplyVoicePicker.best("ja-JP", all))
    }

    @Test
    fun `a requested voice that is not installed falls back to the best one and says so`() {
        val all = ReplyVoices.installed(engineVoices, Locale.US)

        fun pick(requested: String?): Pair<String, Boolean> {
            val (voice, fellBack) = ReplyVoicePicker.resolve(requested, "en-US", all)
            return voice!!.id to fellBack
        }
        assertEquals("en-us-x-aaa-local" to false, pick("en-us-x-aaa-local"))
        assertEquals("en-us-x-ddd-local" to true, pick("en-us-x-ccc-local"))
        assertEquals("en-us-x-ddd-local" to true, pick("gone"))
        assertEquals("en-us-x-ddd-local" to false, pick(null))
    }
}
