package com.koboai.burrow.voice

import android.speech.tts.Voice
import com.getcapacitor.JSObject
import java.util.Locale

/**
 * One on-device system voice the reply can be read in. Only voices already on
 * the phone are listed: nothing is downloaded, no network voice is used and
 * none is bundled. Mirrors iOS `ReplyVoice` (`ReplyVoices.swift`).
 */
data class ReplyVoice(
    val id: String,
    val name: String,
    /** One of [QUALITIES], the JS `QUALITIES` (`voice_tab_native_runtime.js`). */
    val quality: String,
    val language: String,
) {
    fun data(): JSObject =
        JSObject()
            .put("id", id)
            .put("name", name)
            .put("quality", quality)
            .put("language", language)

    companion object {
        const val NEURAL = "neural"
        const val PREMIUM = "premium"
        const val ENHANCED = "enhanced"
        const val DEFAULT = "default"

        /** Best first. */
        val QUALITIES = listOf(NEURAL, PREMIUM, ENHANCED, DEFAULT)
    }
}

/** The phone's installed voices; injected by tests. */
interface ReplyVoiceCatalog {
    fun installedVoices(): List<ReplyVoice>
}

/** The installed voices of a [TtsEngine]. */
class EngineVoiceCatalog(
    private val engine: TtsEngine,
) : ReplyVoiceCatalog {
    override fun installedVoices(): List<ReplyVoice> = ReplyVoices.installed(engine.voices())
}

object ReplyVoices {
    /** `QUALITY_VERY_HIGH` is premium, `QUALITY_HIGH` enhanced, anything lower default. */
    fun quality(quality: Int): String =
        when {
            quality >= Voice.QUALITY_VERY_HIGH -> ReplyVoice.PREMIUM
            quality >= Voice.QUALITY_HIGH -> ReplyVoice.ENHANCED
            else -> ReplyVoice.DEFAULT
        }

    /**
     * The voices a reply may use: no network voice, none whose data is not
     * installed. Each gets a readable name, the language's display name
     * ("English (United States)"), numbered when the language has several
     * ("English (United States) 2"), never the engine's raw id.
     */
    fun installed(
        voices: List<EngineVoice>,
        display: Locale = Locale.getDefault(),
    ): List<ReplyVoice> {
        val usable = voices.filter { !it.networkRequired && !it.notInstalled }.sortedBy { it.name }
        val byLanguage = usable.groupBy { it.language }
        return usable.map { voice ->
            val language = Locale.forLanguageTag(voice.language).getDisplayName(display).ifBlank { voice.language }
            val siblings = byLanguage.getValue(voice.language)
            val name = if (siblings.size == 1) language else "$language ${siblings.indexOf(voice) + 1}"
            ReplyVoice(voice.name, name, quality(voice.quality), voice.language)
        }
    }
}

/** Which voice reads a reply. Pure; mirrors iOS `ReplyVoicePicker`. */
object ReplyVoicePicker {
    /** The voices for [language] ("en-US"): its language ("en"), best quality first, the exact region first, then by name. */
    fun voices(
        language: String,
        all: List<ReplyVoice>,
    ): List<ReplyVoice> {
        val base = languagePart(language)
        return all
            .filter { languagePart(it.language) == base }
            .sortedWith(
                compareBy<ReplyVoice> { rank(it.quality) }
                    .thenBy { if (it.language.equals(language, ignoreCase = true)) 0 else 1 }
                    .thenBy { it.name.lowercase() },
            )
    }

    /** The default: the best installed voice for the language. */
    fun best(
        language: String,
        all: List<ReplyVoice>,
    ): ReplyVoice? = voices(language, all).firstOrNull()

    /** The voice to speak with. A requested voice that is not installed falls back to the default, and says so. */
    fun resolve(
        requested: String?,
        language: String,
        all: List<ReplyVoice>,
    ): Pair<ReplyVoice?, Boolean> {
        if (requested.isNullOrEmpty()) return best(language, all) to false
        all.firstOrNull { it.id == requested }?.let { return it to false }
        return best(language, all) to true
    }

    fun languagePart(language: String): String = language.split('-', '_').first().lowercase()

    private fun rank(quality: String): Int = ReplyVoice.QUALITIES.indexOf(quality).let { if (it < 0) ReplyVoice.QUALITIES.size else it }
}
