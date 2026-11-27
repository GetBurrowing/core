package com.koboai.burrow.voice.pocket

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.SystemClock
import com.koboai.burrow.voice.ReplyFocus
import com.koboai.burrow.voice.ReplyPartQueue
import com.koboai.burrow.voice.ReplySpeechEvent
import com.koboai.burrow.voice.VoiceSpeaking
import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** The Pocket TTS engine, as the speaker and the store need it. Called on one worker thread only. */
interface PocketEngine {
    val isLoaded: Boolean

    /** Loads the graphs (idempotent); returns the placements, e.g. "lm:GPU dectx:CPU dec:GPU". */
    fun load(): String

    /** 24 kHz mono PCM for [text] in [voice]; empty when [cancelled] cut it short. */
    fun synthesize(
        text: String,
        voice: String,
        cancelled: () -> Boolean,
    ): FloatArray

    /** Frees the graphs; the next use loads them again. */
    fun release()
}

/** [PocketSynthesizer] over the downloaded files in [directory]. */
class LiteRtPocketEngine(
    private val directory: File,
) : PocketEngine {
    private var synthesizer: PocketSynthesizer? = null

    override val isLoaded: Boolean get() = synthesizer != null

    @Synchronized
    override fun load(): String = (synthesizer ?: PocketSynthesizer(directory).also { synthesizer = it }).placements

    @Synchronized
    override fun synthesize(
        text: String,
        voice: String,
        cancelled: () -> Boolean,
    ): FloatArray {
        load()
        return synthesizer!!.synthesize(text, voice, cancelled).audio
    }

    @Synchronized
    override fun release() {
        synthesizer?.close()
        synthesizer = null
    }
}

/** The warm-up that decides `too_slow`: one fixed sentence, synthesis time over audio time. */
object PocketWarmUp {
    /** About four seconds of speech, a typical reply sentence. */
    const val SENTENCE = "Here is a short sentence, about as long as a typical spoken reply."

    fun rtf(
        engine: PocketEngine,
        voice: String = PocketManifest.VOICE,
        clock: () -> Long = SystemClock::elapsedRealtime,
    ): Double {
        val start = clock()
        val pcm = engine.synthesize(SENTENCE, voice) { false }
        val ms = clock() - start
        val audioMs = pcm.size * 1000.0 / SAMPLE_RATE
        return if (audioMs <= 0) Double.MAX_VALUE else ms / audioMs
    }

    const val SAMPLE_RATE = 24_000
}

/** Plays PCM buffers back to back. [AudioTrackOutput] is the real one. */
interface PcmOutput {
    /** Queues [samples] after anything already queued; [done] (any thread) once they have played. */
    fun play(
        samples: FloatArray,
        done: () -> Unit,
    )

    /** Stops at once and drops everything queued; no [done] follows. */
    fun stop()

    fun release()
}

/**
 * The agent's reply read by Pocket TTS on the device (task 01a21e4a stage 3).
 * Mirrors iOS `PocketSpeaker`: a synthesis worker produces PCM one sentence
 * (part) at a time, and each buffer plays as soon as it exists, so sentence 1
 * plays while sentence 2 synthesizes. The text is never logged.
 *
 * [stop] is synchronous: the output is paused and flushed, in-flight
 * synthesis is told to stop, and exactly one `stopped` is sent. A generation
 * guard drops every late result (a sentence that finishes synthesizing, or a
 * buffer that finishes playing, after its reply was stopped or replaced).
 */
class PocketSpeaker(
    private val engine: PocketEngine,
    private val output: PcmOutput,
    private val focus: ReplyFocus,
    private val worker: Executor,
    private val post: (() -> Unit) -> Unit,
) : VoiceSpeaking {
    override var onEvent: ((ReplySpeechEvent) -> Unit)? = null

    private class Reply(
        val id: String,
        val voice: String,
        val generation: Int,
    ) {
        val parts = ReplyPartQueue()
        val texts = ArrayDeque<String>()
        var synthesizing = false
        var scheduled = 0
        var played = 0
        var final = false
        var started = false
    }

    /** Read by the worker too, so a stopped reply's synthesis gives up early. */
    private val generation = AtomicInteger(0)
    private var current: Reply? = null

    override val isSpeaking: Boolean get() = current != null

    override fun unavailableReason(voiceId: String?): String? = null

    override fun begin(
        id: String,
        voiceId: String?,
    ) {
        stop(REASON_REPLACED)
        val voice = PocketManifest.voiceFor(voiceId)?.name ?: PocketManifest.VOICE
        current = Reply(id, voice, generation.incrementAndGet())
        focus.request()
    }

    override fun append(
        id: String,
        seq: Int,
        text: String,
    ) {
        val reply = current?.takeIf { it.id == id } ?: return
        reply.parts
            .add(seq, text)
            .filter { it.isNotBlank() }
            .forEach { reply.texts.addLast(it) }
        pump(reply)
    }

    override fun finish(id: String) {
        val reply = current?.takeIf { it.id == id } ?: return
        reply.final = true
        reply.parts
            .flush()
            .filter { it.isNotBlank() }
            .forEach { reply.texts.addLast(it) }
        pump(reply)
        finishIfDone(reply)
    }

    override fun stop(reason: String) {
        val reply = current ?: return
        // Cleared and bumped first: every late result is then dropped.
        current = null
        generation.incrementAndGet()
        output.stop()
        focus.abandon()
        onEvent?.invoke(ReplySpeechEvent(reply.id, ReplySpeechEvent.STOPPED, reason))
    }

    /** Frees the model when nothing is speaking (`onTrimMemory`); it loads again for the next reply. */
    fun releaseIfIdle() {
        if (current != null) return
        worker.execute { if (current == null) engine.release() }
    }

    /** Synthesizes the next sentence, one at a time, in order. */
    private fun pump(reply: Reply) {
        if (reply.synthesizing || reply.texts.isEmpty() || current !== reply) return
        val text = reply.texts.removeFirst()
        reply.synthesizing = true
        val mine = reply.generation
        worker.execute {
            val pcm =
                try {
                    engine.synthesize(text, reply.voice) { generation.get() != mine }
                } catch (_: Exception) {
                    null
                }
            post { synthesized(mine, pcm) }
        }
    }

    private fun synthesized(
        mine: Int,
        pcm: FloatArray?,
    ) {
        // The generation guard: a sentence of a stopped or replaced reply is dropped.
        if (generation.get() != mine) return
        val reply = current ?: return
        reply.synthesizing = false
        if (pcm == null) {
            current = null
            generation.incrementAndGet()
            output.stop()
            focus.abandon()
            onEvent?.invoke(ReplySpeechEvent(reply.id, ReplySpeechEvent.STOPPED, "system"))
            return
        }
        val shaped = shaped(pcm)
        if (shaped.isNotEmpty()) {
            reply.scheduled++
            output.play(shaped) { post { played(mine) } }
            if (!reply.started) {
                reply.started = true
                onEvent?.invoke(ReplySpeechEvent(reply.id, ReplySpeechEvent.STARTED))
            }
        }
        pump(reply)
        finishIfDone(reply)
    }

    private fun played(mine: Int) {
        if (generation.get() != mine) return
        val reply = current ?: return
        reply.played++
        finishIfDone(reply)
    }

    private fun finishIfDone(reply: Reply) {
        if (current !== reply || !reply.final || reply.synthesizing || reply.texts.isNotEmpty()) return
        if (reply.played < reply.scheduled) return
        current = null
        generation.incrementAndGet()
        focus.abandon()
        onEvent?.invoke(ReplySpeechEvent(reply.id, ReplySpeechEvent.FINISHED))
    }

    companion object {
        const val REASON_REPLACED = "replaced"

        /** The decoder's start-up frame, dropped from every sentence (one Mimi frame at 24 kHz). */
        const val STARTUP_MS = 80
        const val FADE_IN_MS = 10
        const val FADE_OUT_MS = 5

        /**
         * A sentence's PCM as it is played, as iOS `PocketSpeaker.shaped`:
         * each sentence is a fresh synthesis whose Mimi decoder starts from
         * zeroed state, so the first decoder frame is dropped, then a short
         * linear fade-in and fade-out, so no buffer starts or ends on a step.
         */
        fun shaped(
            samples: FloatArray,
            sampleRate: Int = PocketWarmUp.SAMPLE_RATE,
        ): FloatArray {
            val trim = sampleRate * STARTUP_MS / 1000
            if (samples.size <= trim) return FloatArray(0)
            val out = samples.copyOfRange(trim, samples.size)
            val fadeIn = minOf(sampleRate * FADE_IN_MS / 1000, out.size)
            for (i in 0 until fadeIn) out[i] *= i.toFloat() / fadeIn
            val fadeOut = minOf(sampleRate * FADE_OUT_MS / 1000, out.size)
            for (i in 0 until fadeOut) out[out.size - 1 - i] *= i.toFloat() / fadeOut
            return out
        }
    }
}

/**
 * An `AudioTrack`: 24 kHz mono float, USAGE_ASSISTANT / CONTENT_TYPE_SPEECH,
 * streamed. Buffers are written in order on one writer thread; each one's
 * `done` fires when the playback head passes its last frame.
 */
class AudioTrackOutput : PcmOutput {
    private val rate = PocketWarmUp.SAMPLE_RATE
    private val writer = Executors.newSingleThreadExecutor()
    private val watcher = Executors.newSingleThreadScheduledExecutor()
    private val epoch = AtomicInteger(0)
    private val marks = ArrayDeque<Pair<Long, () -> Unit>>()
    private var written = 0L

    private val track: AudioTrack =
        AudioTrack
            .Builder()
            .setAudioAttributes(
                AudioAttributes
                    .Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANT)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            ).setAudioFormat(
                AudioFormat
                    .Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                    .setSampleRate(rate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
            ).setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(rate * 4 / 2)
            .build()

    init {
        watcher.scheduleWithFixedDelay({ fireDue() }, 20, 20, TimeUnit.MILLISECONDS)
    }

    override fun play(
        samples: FloatArray,
        done: () -> Unit,
    ) {
        val mine = epoch.get()
        writer.execute {
            if (epoch.get() != mine) return@execute
            if (track.playState != AudioTrack.PLAYSTATE_PLAYING) track.play()
            var offset = 0
            while (offset < samples.size && epoch.get() == mine) {
                val n = track.write(samples, offset, samples.size - offset, AudioTrack.WRITE_NON_BLOCKING)
                if (n < 0) break
                offset += n
                if (n == 0) Thread.sleep(10)
            }
            if (epoch.get() != mine) return@execute
            synchronized(marks) {
                written += samples.size
                marks.addLast(written to done)
            }
        }
    }

    private fun fireDue() {
        val head = track.playbackHeadPosition.toLong() and 0xffffffffL
        val due = mutableListOf<() -> Unit>()
        synchronized(marks) {
            while (marks.isNotEmpty() && marks.first().first <= head) due.add(marks.removeFirst().second)
        }
        due.forEach { it() }
    }

    /** Synchronous: the track is paused and flushed before this returns; the writer gives up its buffer. */
    override fun stop() {
        epoch.incrementAndGet()
        synchronized(marks) {
            marks.clear()
            written = 0
        }
        runCatching {
            track.pause()
            // A flushed track counts frames from zero again.
            track.flush()
        }
    }

    override fun release() {
        stop()
        writer.execute { track.release() }
        writer.shutdown()
        watcher.shutdownNow()
    }
}
