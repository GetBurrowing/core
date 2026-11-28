package com.koboai.burrow.voice

import org.junit.Assert.assertEquals
import org.junit.Test

class RecognitionLocalesTest {
    @Test
    fun `an installed model for the language wins`() {
        assertEquals(SpeechAssets.INSTALLED to "en-US", RecognitionLocales.pick("en-US", listOf("en-US"), listOf("fr-FR")))
        assertEquals(SpeechAssets.INSTALLED to "en-us", RecognitionLocales.pick("en-US", listOf("en-us"), emptyList()))
        // Same language, other region: the recognizer's own tag is the one asked for.
        assertEquals(SpeechAssets.INSTALLED to "en-US", RecognitionLocales.pick("en-GB", listOf("de-DE", "en-US"), emptyList()))
    }

    @Test
    fun `a model that can be downloaded is assets_missing`() {
        assertEquals(SpeechAssets.DOWNLOADABLE to "en-US", RecognitionLocales.pick("en-US", listOf("de-DE"), listOf("en-US")))
        val caps = VoiceCapability.decide(VoiceCapabilityInputs(33, true, "en-US", SpeechAssets.DOWNLOADABLE))
        assertEquals("assets_missing", caps.reason)
    }

    @Test
    fun `no model for the language is locale_unsupported`() {
        val (assets, locale) = RecognitionLocales.pick("cy-GB", listOf("en-US"), listOf("fr-FR"))
        assertEquals(SpeechAssets.UNSUPPORTED, assets)
        assertEquals(null, locale)
        assertEquals("locale_unsupported", VoiceCapability.decide(VoiceCapabilityInputs(34, true, locale, assets)).reason)
        assertEquals(SpeechAssets.UNSUPPORTED to null, RecognitionLocales.pick(null, listOf("en-US"), emptyList()))
    }
}
