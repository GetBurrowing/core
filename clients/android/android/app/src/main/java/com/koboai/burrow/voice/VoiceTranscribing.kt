package com.koboai.burrow.voice

/**
 * What [BurrowVoicePlugin] needs from the transcriber. [OnDeviceTranscriber]
 * is the real one; tests inject a fake. Main thread only, like iOS's
 * `@MainActor VoiceTranscribing`.
 */
interface VoiceTranscribing {
    /** What [VoiceCapability.decide] needs, gathered on the phone. */
    fun capabilityInputs(done: (VoiceCapabilityInputs) -> Unit)

    /** Asks the system to download the speech model, if one is missing; [done] when it has answered. */
    fun prepare(done: () -> Unit)

    /**
     * Opens the mic and starts transcribing. [onPartial] gets the whole turn's
     * text so far each time it changes; [onFailure] gets a reason when the
     * recognizer gives up mid-turn. False when it could not start.
     */
    fun start(
        onPartial: (String) -> Unit,
        onFailure: (String) -> Unit,
    ): Boolean

    /** Closes the mic and hands back the turn's finalized text. */
    fun finish(done: (String) -> Unit)

    /** Closes the mic and discards the turn. */
    fun cancel()
}

/** Delayed work on the main thread; the returned function cancels it. */
fun interface VoiceScheduler {
    fun after(
        delayMs: Long,
        task: () -> Unit,
    ): () -> Unit
}
