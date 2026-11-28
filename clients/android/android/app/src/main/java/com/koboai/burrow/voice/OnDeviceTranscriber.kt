package com.koboai.burrow.voice

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.ModelDownloadListener
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.annotation.RequiresApi
import java.util.Locale
import java.util.concurrent.Executor

/** What a recognizer session reports, already reduced to text and codes. */
interface RecognizerEvents {
    /** The words still forming in this session. */
    fun onPartial(text: String)

    /** The session ended with these final words (possibly empty). */
    fun onResult(text: String)

    /** The session ended with a [SpeechRecognizer] `ERROR_*` code. */
    fun onError(code: Int)
}

/** One `SpeechRecognizer`, seen through [RecognizerEvents]. Main thread only. */
interface RecognizerSession {
    fun listen(
        languageTag: String?,
        events: RecognizerEvents,
    )

    /** Stop listening and deliver the final result (`stopListening`). */
    fun stop()

    /** Stop and deliver nothing (`cancel`). */
    fun cancel()

    fun destroy()
}

/**
 * On-device transcription for the Voice tab on Android (task 01a21e4a stage
 * 1): the system's own on-device `SpeechRecognizer` (API 31+), with the
 * recognition models Android manages. The app ships no model. Nothing here
 * logs or stores what was said.
 *
 * The on-device recognizer ends a session on its own after a stretch of
 * silence, while the person is still holding the mic. So until [finish] the
 * transcriber restarts the session each time it ends, and the turn's text is
 * every finished session's words followed by the words still forming.
 *
 * Mirrors iOS `OnDeviceTranscriber.swift`: `partial` is the whole turn so far,
 * [finish] returns the finalized text, [cancel] discards it.
 */
class OnDeviceTranscriber(
    private val sessions: () -> RecognizerSession,
    private val languageTag: () -> String?,
    private val probe: SpeechCapabilityProbe,
    private val scheduler: VoiceScheduler,
) : VoiceTranscribing {
    private var session: RecognizerSession? = null

    /** Bumped by every start, finish and cancel: a stale session's callbacks are dropped. */
    private var generation = 0

    /** Finished sessions' words, this turn. */
    private val committed = mutableListOf<String>()

    /** The words still forming in the current session. */
    private var forming = ""
    private var onPartial: ((String) -> Unit)? = null
    private var onFailure: ((String) -> Unit)? = null
    private var finishing: ((String) -> Unit)? = null
    private var finishTimer: (() -> Unit)? = null

    override fun capabilityInputs(done: (VoiceCapabilityInputs) -> Unit) = probe.inputs(languageTag(), done)

    override fun prepare(done: () -> Unit) = probe.download(languageTag(), done)

    override fun start(
        onPartial: (String) -> Unit,
        onFailure: (String) -> Unit,
    ): Boolean {
        // A finish still waiting on the old session answers now, with what it has.
        deliverFinish()
        teardown()
        committed.clear()
        forming = ""
        this.onPartial = onPartial
        this.onFailure = onFailure
        return try {
            open()
            true
        } catch (_: RuntimeException) {
            teardown()
            false
        }
    }

    override fun finish(done: (String) -> Unit) {
        val current = session
        if (current == null) {
            done(text())
            return
        }
        finishing = done
        onPartial = null
        onFailure = null
        // A recognizer that never answers the stop must not hold the turn.
        finishTimer = scheduler.after(FINISH_TIMEOUT_MS) { deliverFinish() }
        current.stop()
    }

    override fun cancel() {
        finishing = null
        cancelTimer()
        teardown()
        committed.clear()
        forming = ""
    }

    private fun open() {
        val mine = ++generation
        val next = session ?: sessions().also { session = it }
        next.listen(
            languageTag(),
            object : RecognizerEvents {
                override fun onPartial(text: String) {
                    if (mine != generation) return
                    forming = text
                    onPartial?.invoke(text())
                }

                override fun onResult(text: String) {
                    if (mine != generation) return
                    commit(text)
                    sessionEnded()
                }

                override fun onError(code: Int) {
                    if (mine != generation) return
                    // The words formed before the error were still heard.
                    commit(forming)
                    if (finishing != null || code in SILENCE_ERRORS) {
                        sessionEnded()
                    } else {
                        val failed = onFailure
                        teardown()
                        failed?.invoke(REASON_RECOGNIZER_ERROR)
                    }
                }
            },
        )
    }

    /** A session ended: the turn is over if [finish] asked, else the mic is still held. */
    private fun sessionEnded() {
        if (finishing != null) {
            deliverFinish()
        } else {
            // Ended on silence during a held turn: listen again, keeping the words.
            onPartial?.invoke(text())
            open()
        }
    }

    private fun commit(text: String) {
        val words = text.trim()
        if (words.isNotEmpty()) committed.add(words)
        forming = ""
    }

    private fun text(): String = (committed + forming.trim()).filter { it.isNotEmpty() }.joinToString(" ")

    private fun deliverFinish() {
        val done = finishing ?: return
        finishing = null
        cancelTimer()
        val text = text()
        teardown()
        committed.clear()
        forming = ""
        done(text)
    }

    private fun cancelTimer() {
        finishTimer?.invoke()
        finishTimer = null
    }

    private fun teardown() {
        generation++
        onPartial = null
        onFailure = null
        session?.let {
            it.cancel()
            it.destroy()
        }
        session = null
    }

    companion object {
        /** How long [finish] waits for the recognizer's last words. */
        const val FINISH_TIMEOUT_MS = 2_000L
        const val REASON_RECOGNIZER_ERROR = "recognizer_error"

        /** The session ended because nothing more was said: not a failure. */
        val SILENCE_ERRORS = setOf(SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT)

        @RequiresApi(Build.VERSION_CODES.S)
        fun forContext(context: Context): OnDeviceTranscriber {
            val app = context.applicationContext
            val main = Handler(Looper.getMainLooper())
            return OnDeviceTranscriber(
                sessions = { AndroidRecognizerSession(app) },
                languageTag = { Locale.getDefault().toLanguageTag() },
                probe = SystemSpeechProbe(app),
                scheduler = { delay, task ->
                    val runnable = Runnable { task() }
                    main.postDelayed(runnable, delay)
                    ({ main.removeCallbacks(runnable) })
                },
            )
        }
    }
}

/** The capability check and the model download, behind a seam for tests. */
interface SpeechCapabilityProbe {
    fun inputs(
        languageTag: String?,
        done: (VoiceCapabilityInputs) -> Unit,
    )

    fun download(
        languageTag: String?,
        done: () -> Unit,
    )
}

/** The real probe: `isOnDeviceRecognitionAvailable` and, on API 33+, `checkRecognitionSupport`. */
class SystemSpeechProbe(
    private val context: Context,
) : SpeechCapabilityProbe {
    private val main = Executor { Handler(Looper.getMainLooper()).post(it) }

    override fun inputs(
        languageTag: String?,
        done: (VoiceCapabilityInputs) -> Unit,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            done(VoiceCapabilityInputs(Build.VERSION.SDK_INT))
            return
        }
        val available = SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        val base = VoiceCapabilityInputs(Build.VERSION.SDK_INT, available, languageTag)
        if (!available || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            done(base)
            return
        }
        checkSupport(languageTag, base, done)
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun checkSupport(
        languageTag: String?,
        base: VoiceCapabilityInputs,
        done: (VoiceCapabilityInputs) -> Unit,
    ) {
        val recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        var answered = false

        fun answer(inputs: VoiceCapabilityInputs) {
            if (answered) return
            answered = true
            recognizer.destroy()
            done(inputs)
        }
        try {
            recognizer.checkRecognitionSupport(
                recognizerIntent(languageTag),
                main,
                object : RecognitionSupportCallback {
                    override fun onSupportResult(support: RecognitionSupport) {
                        val (assets, locale) =
                            RecognitionLocales.pick(
                                languageTag,
                                support.installedOnDeviceLanguages,
                                support.pendingOnDeviceLanguages + support.supportedOnDeviceLanguages,
                            )
                        answer(base.copy(locale = locale, assets = assets))
                    }

                    override fun onError(error: Int) = answer(base.copy(assets = SpeechAssets.UNKNOWN))
                },
            )
        } catch (_: RuntimeException) {
            answer(base.copy(assets = SpeechAssets.UNKNOWN))
        }
    }

    override fun download(
        languageTag: String?,
        done: () -> Unit,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            done()
            return
        }
        trigger(languageTag, done)
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun trigger(
        languageTag: String?,
        done: () -> Unit,
    ) {
        val recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        val intent = recognizerIntent(languageTag)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                // API 34 says when the download is done (or scheduled for later).
                recognizer.triggerModelDownload(intent, main, downloadListener(recognizer, done))
                return
            }
            // API 33 only starts it: the fresh capabilities may still say assets_missing.
            recognizer.triggerModelDownload(intent)
        } catch (_: RuntimeException) {
            // Answer with whatever the capabilities now say.
        }
        recognizer.destroy()
        done()
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun downloadListener(
        recognizer: SpeechRecognizer,
        done: () -> Unit,
    ) = object : ModelDownloadListener {
        private var answered = false

        private fun answer() {
            if (answered) return
            answered = true
            recognizer.destroy()
            done()
        }

        override fun onProgress(completedPercent: Int) = Unit

        override fun onSuccess() = answer()

        override fun onScheduled() = answer()

        override fun onError(error: Int) = answer()
    }
}

/** A real `createOnDeviceSpeechRecognizer` session. Main thread only. */
@RequiresApi(Build.VERSION_CODES.S)
class AndroidRecognizerSession(
    private val context: Context,
) : RecognizerSession {
    private var recognizer: SpeechRecognizer? = null

    // RECORD_AUDIO is checked by the plugin before a turn opens.
    @SuppressLint("MissingPermission")
    override fun listen(
        languageTag: String?,
        events: RecognizerEvents,
    ) {
        val next = recognizer ?: SpeechRecognizer.createOnDeviceSpeechRecognizer(context).also { recognizer = it }
        next.setRecognitionListener(Listener(events))
        next.startListening(recognizerIntent(languageTag))
    }

    override fun stop() {
        recognizer?.stopListening()
    }

    override fun cancel() {
        recognizer?.cancel()
    }

    override fun destroy() {
        recognizer?.destroy()
        recognizer = null
    }

    private class Listener(
        private val events: RecognizerEvents,
    ) : RecognitionListener {
        override fun onPartialResults(partialResults: Bundle?) = events.onPartial(best(partialResults))

        override fun onResults(results: Bundle?) = events.onResult(best(results))

        override fun onError(error: Int) = events.onError(error)

        override fun onReadyForSpeech(params: Bundle?) = Unit

        override fun onBeginningOfSpeech() = Unit

        override fun onRmsChanged(rmsdB: Float) = Unit

        override fun onBufferReceived(buffer: ByteArray?) = Unit

        override fun onEndOfSpeech() = Unit

        override fun onEvent(
            eventType: Int,
            params: Bundle?,
        ) = Unit

        private fun best(bundle: Bundle?): String =
            bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
    }
}

/** Free-form dictation in [languageTag], with partial results, never sent off the device. */
internal fun recognizerIntent(languageTag: String?): Intent =
    Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        if (languageTag != null) putExtra(RecognizerIntent.EXTRA_LANGUAGE, languageTag)
    }
