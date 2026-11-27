package com.koboai.burrow.voice

import android.content.Context
import android.media.AudioAttributes
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import java.util.Locale

/** One TextToSpeech voice, as [ReplyVoices] needs it. */
data class EngineVoice(
    val name: String,
    /** BCP 47. */
    val language: String,
    /** `Voice.QUALITY_*`. */
    val quality: Int,
    val networkRequired: Boolean,
    /** Its features include `KEY_FEATURE_NOT_INSTALLED`: listed, but its data is not on the phone. */
    val notInstalled: Boolean,
)

/** What an utterance did, by utterance id. Delivered on the main thread. */
interface TtsEvents {
    fun onStart(utteranceId: String)

    fun onDone(utteranceId: String)

    /** An error, or the engine dropped the utterance (`onStop`). */
    fun onLost(utteranceId: String)
}

/** The slice of `TextToSpeech` the speaker uses. [AndroidTtsEngine] is the real one; tests inject a fake. */
interface TtsEngine {
    /** False once the engine failed to start: nothing can be spoken. */
    val usable: Boolean
    var events: TtsEvents?

    fun voices(): List<EngineVoice>

    /** True when the language has an installed voice. */
    fun hasLanguage(languageTag: String): Boolean

    /** Uses the voice named [voiceId], else the language's own; false when neither can be set. */
    fun select(
        voiceId: String?,
        languageTag: String,
    ): Boolean

    /** Queues one utterance after any already queued (`QUEUE_ADD`). */
    fun enqueue(
        text: String,
        utteranceId: String,
    )

    /** Drops everything queued and stops speaking now. */
    fun stop()
}

/** Audio focus for a reply only: may-duck, abandoned when the reply ends. */
interface ReplyFocus {
    fun request()

    fun abandon()
}

/**
 * The agent's reply read by the system TextToSpeech, for the current
 * language: the voice the page picked, else the best installed one
 * ([ReplyVoicePicker]). No bundled voice, no network voice. The text is never
 * logged. A streamed reply queues one utterance per part, in seq order
 * ([ReplyPartQueue]), so the voice starts on the first sentence. Mirrors iOS
 * `ReplySpeaker`.
 *
 * Generation guard: every utterance id carries the generation of the reply
 * that queued it, and a stop or a new reply bumps the generation. So a
 * replaced reply's late `onDone` (TextToSpeech delivers callbacks after
 * `stop()`, on its own thread) can never finish or start the next reply.
 */
class SystemReplySpeaker(
    private val engine: TtsEngine,
    private val focus: ReplyFocus,
    private val languageTag: () -> String,
) : VoiceSpeaking,
    TtsEvents {
    override var onEvent: ((ReplySpeechEvent) -> Unit)? = null

    private class Reply(
        val id: String,
        val generation: Int,
    ) {
        val parts = ReplyPartQueue()
        var queued = 0
        var done = 0
        var final = false
        var started = false
    }

    private var generation = 0
    private var current: Reply? = null

    init {
        engine.events = this
    }

    override val isSpeaking: Boolean get() = current != null

    override fun unavailableReason(voiceId: String?): String? =
        when {
            !engine.usable -> "tts_unavailable"
            voiceId == null && !engine.hasLanguage(languageTag()) -> "no_voice"
            else -> null
        }

    override fun begin(
        id: String,
        voiceId: String?,
    ) {
        stop(REASON_REPLACED)
        generation++
        engine.select(voiceId, languageTag())
        current = Reply(id, generation)
        focus.request()
    }

    override fun append(
        id: String,
        seq: Int,
        text: String,
    ) {
        val reply = current?.takeIf { it.id == id } ?: return
        queue(reply, reply.parts.add(seq, text))
    }

    override fun finish(id: String) {
        val reply = current?.takeIf { it.id == id } ?: return
        reply.final = true
        queue(reply, reply.parts.flush())
        finishIfDone(reply)
    }

    override fun stop(reason: String) {
        val reply = current ?: return
        // Cleared first: the engine's callbacks for what was queued are then
        // dropped, so the page gets exactly one `stopped`, with this reason.
        current = null
        generation++
        engine.stop()
        focus.abandon()
        onEvent?.invoke(ReplySpeechEvent(reply.id, ReplySpeechEvent.STOPPED, reason))
    }

    private fun queue(
        reply: Reply,
        texts: List<String>,
    ) {
        for (text in texts) {
            if (text.isBlank()) continue
            val n = reply.queued++
            engine.enqueue(text, "${reply.generation}:$n")
        }
    }

    /** The open reply, when [utteranceId] was queued by it. */
    private fun owner(utteranceId: String): Reply? {
        val reply = current ?: return null
        val generation = utteranceId.substringBefore(':').toIntOrNull()
        return reply.takeIf { generation == it.generation }
    }

    override fun onStart(utteranceId: String) {
        val reply = owner(utteranceId) ?: return
        if (reply.started) return
        reply.started = true
        onEvent?.invoke(ReplySpeechEvent(reply.id, ReplySpeechEvent.STARTED))
    }

    override fun onDone(utteranceId: String) {
        val reply = owner(utteranceId) ?: return
        reply.done++
        finishIfDone(reply)
    }

    override fun onLost(utteranceId: String) {
        val reply = owner(utteranceId) ?: return
        current = null
        generation++
        engine.stop()
        focus.abandon()
        onEvent?.invoke(ReplySpeechEvent(reply.id, ReplySpeechEvent.STOPPED, "system"))
    }

    private fun finishIfDone(reply: Reply) {
        if (current !== reply || !reply.final || reply.done < reply.queued) return
        current = null
        focus.abandon()
        onEvent?.invoke(ReplySpeechEvent(reply.id, ReplySpeechEvent.FINISHED))
    }

    companion object {
        const val REASON_REPLACED = "replaced"
    }
}

/**
 * `android.speech.tts.TextToSpeech`, speaking with USAGE_ASSISTANT and
 * CONTENT_TYPE_SPEECH. Utterances queued before the engine is ready wait for
 * it; a failed start makes it unusable. Callbacks hop to the main thread.
 */
class AndroidTtsEngine(
    context: Context,
) : TtsEngine {
    private val main = Handler(Looper.getMainLooper())
    private var state = State.STARTING
    private val waiting = mutableListOf<Pair<String, String>>()
    private var selection: Pair<String?, String>? = null
    override var events: TtsEvents? = null

    private enum class State { STARTING, READY, FAILED }

    private val tts: TextToSpeech =
        TextToSpeech(context.applicationContext) { status ->
            main.post { started(status == TextToSpeech.SUCCESS) }
        }

    init {
        tts.setAudioAttributes(
            AudioAttributes
                .Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANT)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build(),
        )
        tts.setOnUtteranceProgressListener(
            object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) = deliver(utteranceId) { events?.onStart(it) }

                override fun onDone(utteranceId: String?) = deliver(utteranceId) { events?.onDone(it) }

                @Deprecated("Deprecated in Java")
                @Suppress("OVERRIDE_DEPRECATION")
                override fun onError(utteranceId: String?) = deliver(utteranceId) { events?.onLost(it) }

                override fun onError(
                    utteranceId: String?,
                    errorCode: Int,
                ) = deliver(utteranceId) { events?.onLost(it) }
            },
        )
    }

    private fun deliver(
        utteranceId: String?,
        event: (String) -> Unit,
    ) {
        val id = utteranceId ?: return
        main.post { event(id) }
    }

    private fun started(ok: Boolean) {
        state = if (ok) State.READY else State.FAILED
        if (!ok) {
            waiting.clear()
            return
        }
        selection?.let { (voice, language) -> apply(voice, language) }
        waiting.forEach { (text, id) -> speakNow(text, id) }
        waiting.clear()
    }

    override val usable: Boolean get() = state != State.FAILED

    override fun voices(): List<EngineVoice> {
        if (state != State.READY) return emptyList()
        return runCatching { tts.voices.orEmpty().map(::engineVoice) }.getOrDefault(emptyList())
    }

    override fun hasLanguage(languageTag: String): Boolean {
        // Not started yet: assume so, and let the engine say otherwise.
        if (state != State.READY) return state == State.STARTING
        return tts.isLanguageAvailable(Locale.forLanguageTag(languageTag)) >= TextToSpeech.LANG_AVAILABLE
    }

    override fun select(
        voiceId: String?,
        languageTag: String,
    ): Boolean {
        selection = voiceId to languageTag
        if (state != State.READY) return state == State.STARTING
        return apply(voiceId, languageTag)
    }

    private fun apply(
        voiceId: String?,
        languageTag: String,
    ): Boolean {
        val voice: Voice? = voiceId?.let { id -> tts.voices.orEmpty().firstOrNull { it.name == id } }
        if (voice != null && tts.setVoice(voice) == TextToSpeech.SUCCESS) return true
        return tts.setLanguage(Locale.forLanguageTag(languageTag)) >= TextToSpeech.LANG_AVAILABLE
    }

    override fun enqueue(
        text: String,
        utteranceId: String,
    ) {
        when (state) {
            State.STARTING -> waiting.add(text to utteranceId)
            State.READY -> speakNow(text, utteranceId)
            State.FAILED -> main.post { events?.onLost(utteranceId) }
        }
    }

    private fun speakNow(
        text: String,
        utteranceId: String,
    ) {
        if (tts.speak(text, TextToSpeech.QUEUE_ADD, null, utteranceId) != TextToSpeech.SUCCESS) {
            main.post { events?.onLost(utteranceId) }
        }
    }

    override fun stop() {
        waiting.clear()
        if (state == State.READY) tts.stop()
    }

    fun shutdown() {
        waiting.clear()
        tts.shutdown()
    }

    companion object {
        fun engineVoice(voice: Voice): EngineVoice =
            EngineVoice(
                name = voice.name,
                language = voice.locale.toLanguageTag(),
                quality = voice.quality,
                networkRequired = voice.isNetworkConnectionRequired,
                notInstalled = voice.features.orEmpty().contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED),
            )
    }
}
