package com.koboai.burrow.voice

import com.getcapacitor.JSObject

/**
 * One change in a spoken reply, sent to the page as the `speech` event:
 * `{id, state, reason?}` with state started, finished, stopped or unheard.
 * Mirrors iOS `ReplySpeechEvent` (`ReplySpeaker.swift`).
 */
data class ReplySpeechEvent(
    val id: String,
    val state: String,
    val reason: String? = null,
) {
    fun data(): JSObject =
        JSObject().put("id", id).put("state", state).also { data ->
            if (reason != null) data.put("reason", reason)
        }

    companion object {
        const val STARTED = "started"
        const val FINISHED = "finished"
        const val STOPPED = "stopped"
        const val UNHEARD = "unheard"
        val STATES = listOf(STARTED, FINISHED, STOPPED, UNHEARD)
    }
}

/**
 * What the plugin needs from a reply voice: the system TextToSpeech
 * ([SystemReplySpeaker]) now, Pocket TTS later. Exactly one is active at a
 * time. Main thread only. Mirrors iOS `VoiceSpeaking` (`ReplySpeaker.swift`).
 */
interface VoiceSpeaking {
    var onEvent: ((ReplySpeechEvent) -> Unit)?

    /** True from [speak] / [begin] until the reply finishes or stops. */
    val isSpeaking: Boolean

    /** Why a reply in [voiceId] cannot be spoken at all right now, or null when it can. */
    fun unavailableReason(voiceId: String?): String?

    /** Stops any reply in flight (`replaced`), then speaks [text] in [voiceId] (null: the language's voice). */
    fun speak(
        id: String,
        text: String,
        voiceId: String?,
    ) {
        begin(id, voiceId)
        append(id, 0, text)
        finish(id)
    }

    /** Streaming: stops any reply in flight (`replaced`) and opens reply [id]; its parts follow by [append]. */
    fun begin(
        id: String,
        voiceId: String?,
    )

    /** One part of reply [id] (a sentence), spoken in [seq] order as soon as it can be. Ignored unless [id] is open. */
    fun append(
        id: String,
        seq: Int,
        text: String,
    )

    /** No more parts for [id]: `finished` follows the last one. */
    fun finish(id: String)

    /** Stops the reply in flight, if any, sending exactly one `stopped` with [reason]. */
    fun stop(reason: String)
}

/** A speaker with nothing to say: the plugin's default until `load()` builds the real one. */
object NoReplySpeaker : VoiceSpeaking {
    override var onEvent: ((ReplySpeechEvent) -> Unit)? = null
    override val isSpeaking = false

    override fun unavailableReason(voiceId: String?): String = "tts_unavailable"

    override fun begin(
        id: String,
        voiceId: String?,
    ) = Unit

    override fun append(
        id: String,
        seq: Int,
        text: String,
    ) = Unit

    override fun finish(id: String) = Unit

    override fun stop(reason: String) = Unit
}

/**
 * Orders a streamed reply's parts by `seq`: a part is released only once
 * every earlier one has been. A repeated or old seq is dropped. Pure; mirrors
 * iOS `ReplyPartQueue`.
 */
class ReplyPartQueue {
    private var next = 0
    private val held = sortedMapOf<Int, String>()

    val isEmpty: Boolean get() = held.isEmpty()

    /** The parts that are now in order, starting with this one if it is next. */
    fun add(
        seq: Int,
        text: String,
    ): List<String> {
        if (seq < next || held.containsKey(seq)) return emptyList()
        held[seq] = text
        val ready = mutableListOf<String>()
        while (true) {
            val part = held.remove(next) ?: break
            ready.add(part)
            next++
        }
        return ready
    }

    /** Everything still held, in seq order (the reply is final). */
    fun flush(): List<String> {
        val rest = held.values.toList()
        if (held.isNotEmpty()) next = held.lastKey() + 1
        held.clear()
        return rest
    }
}
