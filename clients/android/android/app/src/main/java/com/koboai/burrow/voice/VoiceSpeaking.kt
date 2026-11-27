package com.koboai.burrow.voice

/**
 * The reply speaker, as far as the mic needs it: opening the mic stops any
 * reply at once (barge-in, iOS `stopSpeakers(reason: "mic_opened")`). Stage 2
 * of task 01a21e4a fills this in with system TextToSpeech; until then
 * [NoReplySpeaker] has nothing to stop.
 */
interface VoiceSpeaking {
    fun stop(reason: String)
}

object NoReplySpeaker : VoiceSpeaking {
    override fun stop(reason: String) = Unit
}
