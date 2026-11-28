package com.koboai.burrow.voice

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.content.edit
import com.koboai.burrow.voice.pocket.HttpRangeFetcher
import com.koboai.burrow.voice.pocket.LiteRtPocketEngine
import com.koboai.burrow.voice.pocket.PocketGate
import com.koboai.burrow.voice.pocket.PocketManifest
import com.koboai.burrow.voice.pocket.PocketModelState
import com.koboai.burrow.voice.pocket.PocketModelStore
import com.koboai.burrow.voice.pocket.PocketSupport
import com.koboai.burrow.voice.pocket.PocketVoices
import com.koboai.burrow.voice.pocket.PocketWarmUp
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.abs

/**
 * DEBUG BUILDS ONLY (task 01a21e4a stage 3). Drives Pocket TTS and the
 * Voice turn on an emulator, from the adb shell (DUMP-protected like
 * DebugPushReceiver):
 *
 *   am broadcast -a com.koboai.burrow.debug.VOICE \
 *     -n com.koboai.burrow.debug/com.koboai.burrow.voice.DebugVoiceReceiver \
 *     --es action pocket_probe
 *
 * - `pocket_probe`: download (or verify) the model, load it, warm up, then
 *   synthesize a fixed three-sentence paragraph. Logs bytes, ms, RTF, peak
 *   PSS, each graph's accelerator and each sentence's synthesis time, and the
 *   start-up transient's level. Never any text.
 * - `pocket_reset`: deletes the model directory.
 * - `force_gate` with `--es gate supported` or `--es gate <reason>`: the
 *   Pocket gate's answer, kept across relaunches; `--es gate clear` drops it.
 * - `fake_transcriber` with `--esa partials a,b --es final c`: the plugin's
 *   transcriber becomes a script (the headless emulator has no microphone).
 *   Capabilities then say available; each turn sends the partials 400 ms
 *   apart and stop() answers the final.
 *
 * Logs ids, states, counts and timings only, under the tag BurrowVoiceDebug.
 */
class DebugVoiceReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent,
    ) {
        if (intent.action != ACTION) return
        val app = context.applicationContext
        when (intent.getStringExtra("action")) {
            "pocket_probe" -> Executors.newSingleThreadExecutor().execute { probe(app) }
            "pocket_reset" -> {
                directory(app).deleteRecursively()
                Handler(Looper.getMainLooper()).post {
                    BurrowVoicePlugin.live
                        ?.get()
                        ?.pocket
                        ?.reset()
                }
                Log.i(TAG, "pocket_reset done")
            }
            "force_gate" -> {
                val gate = intent.getStringExtra("gate")?.takeIf { it != "clear" }
                app.getSharedPreferences(PocketGate.DEBUG_PREFS, Context.MODE_PRIVATE).edit {
                    putString(PocketGate.DEBUG_FORCE_GATE, gate)
                }
                BurrowVoicePlugin.live
                    ?.get()
                    ?.pocket
                    ?.gate
                    ?.forced = gate
                Log.i(TAG, "force_gate gate=${gate ?: "cleared"}")
            }
            "fake_transcriber" -> {
                val script = intent.getStringArrayExtra("partials")?.toList().orEmpty()
                val last = intent.getStringExtra("final").orEmpty()
                Handler(Looper.getMainLooper()).post {
                    val plugin = BurrowVoicePlugin.live?.get()
                    plugin?.transcriber = ScriptedTranscriber(script, last)
                    val steps = script.size
                    Log.i(TAG, "scripted_turn steps=$steps plugin=${plugin != null}")
                }
            }
            else -> Log.i(TAG, "unknown action")
        }
    }

    private fun directory(app: Context) = PocketVoices.directory(app)

    private fun probe(app: Context) {
        val peak = AtomicInteger(0)
        val sampling = Executors.newSingleThreadScheduledExecutor()
        sampling.scheduleWithFixedDelay(
            { peak.accumulateAndGet(Debug.getPss().toInt()) { a, b -> maxOf(a, b) } },
            0,
            250,
            java.util.concurrent.TimeUnit.MILLISECONDS,
        )
        try {
            val dir = directory(app)
            val before = PocketManifest.FILES.sumOf { f -> File(dir, f.path).length().coerceAtMost(f.size) }
            val t0 = SystemClock.elapsedRealtime()
            var last: PocketModelState = PocketModelState.Absent
            val store =
                PocketModelStore(dir, PocketManifest.FILES, HttpRangeFetcher(), null, { it.run() }, { it() })
            store.onChange = { last = it }
            store.prepare()
            val downloadMs = SystemClock.elapsedRealtime() - t0
            Log.i(TAG, "download state=${last.name} bytes=${PocketManifest.TOTAL_BYTES - before} already=$before ms=$downloadMs")
            if (store.state != PocketModelState.Ready) return
            val engine = LiteRtPocketEngine(dir)
            val t1 = SystemClock.elapsedRealtime()
            val placements = engine.load()
            Log.i(TAG, "load ms=${SystemClock.elapsedRealtime() - t1} placements=$placements pss_kb=${Debug.getPss()}")
            val t2 = SystemClock.elapsedRealtime()
            val rtf = PocketWarmUp.rtf(engine)
            Log.i(TAG, "warmup ms=${SystemClock.elapsedRealtime() - t2} rtf=${"%.3f".format(rtf)} too_slow=${rtf > PocketSupport.MAX_RTF}")
            var synthMs = 0L
            var audioMs = 0.0
            SENTENCES.forEachIndexed { i, sentence ->
                val s0 = SystemClock.elapsedRealtime()
                val pcm = engine.synthesize(sentence, PocketManifest.VOICE) { false }
                val ms = SystemClock.elapsedRealtime() - s0
                val sentenceAudioMs = pcm.size * 1000.0 / PocketWarmUp.SAMPLE_RATE
                synthMs += ms
                audioMs += sentenceAudioMs
                Log.i(
                    TAG,
                    "sentence=$i synth_ms=$ms audio_ms=${sentenceAudioMs.toLong()} rtf=${"%.3f".format(ms / sentenceAudioMs)} " +
                        "startup_peak=${"%.4f".format(peakAbs(pcm, 0, 1920))} after_peak=${"%.4f".format(peakAbs(pcm, 1920, 3840))}",
                )
            }
            val gate = PocketGate.forContext(app).also { it.forced = null }
            gate.measuredRtf = rtf
            Log.i(
                TAG,
                "paragraph synth_ms=$synthMs audio_ms=${audioMs.toLong()} rtf=${"%.3f".format(synthMs / audioMs)} " +
                    "peak_pss_kb=${peak.get()} gate=${gate.current()}",
            )
            engine.release()
        } catch (e: Exception) {
            Log.i(TAG, "probe failed ${e.javaClass.simpleName}: ${e.message?.take(200)}")
        } finally {
            sampling.shutdownNow()
            Log.i(TAG, "probe done peak_pss_kb=${peak.get()}")
        }
    }

    private fun peakAbs(
        pcm: FloatArray,
        from: Int,
        to: Int,
    ): Float {
        var peak = 0f
        for (i in from until minOf(to, pcm.size)) peak = maxOf(peak, abs(pcm[i]))
        return peak
    }

    companion object {
        const val ACTION = "com.koboai.burrow.debug.VOICE"
        const val TAG = "BurrowVoiceDebug"
        private val SENTENCES =
            listOf(
                "The weather today is mild, with a light breeze from the west.",
                "Expect a few clouds this afternoon, but no rain is forecast.",
                "Tomorrow should be a little warmer than today.",
            )
    }
}

/** A transcriber that plays back a script: the emulator has no microphone. */
class ScriptedTranscriber(
    private val partials: List<String>,
    private val final: String,
) : VoiceTranscribing {
    private val main = Handler(Looper.getMainLooper())
    private var turn = 0

    override fun capabilityInputs(done: (VoiceCapabilityInputs) -> Unit) =
        done(VoiceCapabilityInputs(android.os.Build.VERSION.SDK_INT, true, "en-US", SpeechAssets.INSTALLED))

    override fun prepare(done: () -> Unit) = done()

    override fun start(
        onPartial: (String) -> Unit,
        onFailure: (String) -> Unit,
    ): Boolean {
        val mine = ++turn
        partials.forEachIndexed { i, text -> main.postDelayed({ if (turn == mine) onPartial(text) }, 400L * (i + 1)) }
        return true
    }

    override fun finish(done: (String) -> Unit) {
        turn++
        done(final)
    }

    override fun cancel() {
        turn++
    }
}
