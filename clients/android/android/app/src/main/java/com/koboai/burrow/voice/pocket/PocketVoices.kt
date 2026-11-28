package com.koboai.burrow.voice.pocket

import android.content.ComponentCallbacks2
import android.content.Context
import android.os.Handler
import android.os.Looper
import com.getcapacitor.JSObject
import com.koboai.burrow.voice.ReplyVoicePicker
import com.koboai.burrow.voice.SystemReplyFocus
import com.koboai.burrow.voice.VoiceSpeaking
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/**
 * Pocket TTS for the plugin (task 01a21e4a stage 3): the gate, the model and
 * voice stores, and the speaker, each built on first use and only where the
 * gate allows. Mirrors the Pocket half of iOS `BurrowVoicePlugin.swift`.
 * Main thread only.
 */
class PocketVoices(
    val gate: PocketGate,
    private val makeStore: () -> PocketModelStore,
    private val makeVoiceStore: (PocketVoice) -> PocketModelStore,
    private val makeSpeaker: () -> VoiceSpeaking,
    /** Sends a `model` event. */
    private val emit: (JSObject) -> Unit,
) {
    enum class Availability { UNSUPPORTED, NOT_READY, READY }

    private var store: PocketModelStore? = null
    private val voiceStores = mutableMapOf<String, PocketModelStore>()

    /** The speaker, once a Pocket reply has been read. */
    var speakerOrNull: VoiceSpeaking? = null
        private set

    fun speaker(): VoiceSpeaking = speakerOrNull ?: makeSpeaker().also { speakerOrNull = it }

    /** English only: the graphs are Kyutai's English model. */
    fun speaks(languageTag: String): Boolean = ReplyVoicePicker.languagePart(languageTag) == "en"

    /** The model store; null where the gate says no. */
    fun store(): PocketModelStore? {
        store?.let { return if (gate.current().first) it else null }
        if (!gate.current().first) return null
        val made = makeStore()
        made.onChange = { emit(model(made)) }
        store = made
        return made
    }

    /** The store of a voice other than the default (which comes with the model). */
    private fun voiceStore(voice: PocketVoice): PocketModelStore? {
        if (voice.name == PocketManifest.VOICE || store() == null) return null
        voiceStores[voice.name]?.let { return it }
        val made = makeVoiceStore(voice)
        // While the model itself is not ready its progress is what the picker shows.
        made.onChange = { if (store?.state == PocketModelState.Ready) emit(model(made)) }
        voiceStores[voice.name] = made
        return made
    }

    /** Pocket TTS reads in [voice] only once the model and that voice's file are both ready. */
    fun availability(voice: PocketVoice): Availability {
        val core = store() ?: return Availability.UNSUPPORTED
        if (core.state != PocketModelState.Ready) return Availability.NOT_READY
        // The warm-up just measured this phone too slow: unsupported for the session.
        if (!gate.current().first) return Availability.UNSUPPORTED
        val extra = voiceStore(voice) ?: return Availability.READY
        return if (extra.state == PocketModelState.Ready) Availability.READY else Availability.NOT_READY
    }

    /** Starts whatever [voice] still needs: the model, its voice file, or both. */
    fun prepare(voice: PocketVoice?) {
        store()?.prepare()
        voice?.let { voiceStore(it)?.prepare() }
    }

    /** `prepareModel {voice?}` -> `{state, received, total, reason}`; `absent` with the gate's reason where it says no. */
    fun prepareModel(voiceId: String?): JSObject {
        val voice = PocketManifest.voiceFor(voiceId)
        val core = store() ?: return absent()
        prepare(voice)
        if (core.state != PocketModelState.Ready || voice == null) return model(core)
        return model(voiceStore(voice) ?: core)
    }

    /** The Pocket rows, the default voice first, then the others by name; none where the gate says no or the language is not English. */
    fun rows(languageTag: String): List<JSObject> {
        if (!speaks(languageTag)) return emptyList()
        val core = store() ?: return emptyList()
        val default = PocketManifest.voice(PocketManifest.VOICE)!!
        val others = PocketManifest.VOICES.filter { it != default }.sortedBy { it.displayName }
        return (listOf(default) + others).map { voice ->
            val source = if (core.state == PocketModelState.Ready) voiceStore(voice) ?: core else core
            val data = source.data()
            JSObject()
                .put("id", voice.id)
                .put("name", voice.rowName)
                .put("quality", "neural")
                .put("language", "en")
                .put(
                    "model",
                    JSObject()
                        .put("state", data.getString("state"))
                        .put("received", data.getLong("received"))
                        .put("total", data.getLong("total")),
                )
        }
    }

    /**
     * The memory is needed elsewhere: free the model if no Pocket reply is
     * playing. RUNNING_LOW is no longer delivered from API 34; the higher
     * levels still are.
     */
    @Suppress("DEPRECATION")
    fun trim(level: Int) {
        if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) (speakerOrNull as? PocketSpeaker)?.releaseIfIdle()
    }

    /** Debug `pocket_reset`: every downloaded file deleted. */
    fun reset() {
        store?.reset()
        voiceStores.values.forEach { it.reset() }
    }

    /** A store's data, with the gate's reason when it says no (`too_slow` after the warm-up). */
    private fun model(source: PocketModelStore): JSObject {
        val data = source.data()
        val (supported, reason) = gate.current()
        if (!supported) data.put("reason", reason)
        return data
    }

    private fun absent(): JSObject =
        JSObject()
            .put("state", "absent")
            .put("received", 0)
            .put("total", 0)
            .put("reason", gate.current().second ?: JSONObject.NULL)

    companion object {
        /** `noBackupFilesDir/pocket-tts/<revision>/`: excluded from backup, and not a cache the system can evict. */
        fun directory(context: Context): File = File(File(context.noBackupFilesDir, "pocket-tts"), PocketManifest.REVISION)

        /** The real wiring: `noBackupFilesDir/pocket-tts/<revision>/`, one download thread, one synthesis thread. */
        fun forContext(
            context: Context,
            emit: (JSObject) -> Unit,
        ): PocketVoices {
            val app = context.applicationContext
            val main = Handler(Looper.getMainLooper())
            val post: (() -> Unit) -> Unit = { task -> main.post(task) }
            val directory = directory(app)
            val engine = LiteRtPocketEngine(directory)
            val gate = PocketGate.forContext(app)
            val downloads = Executors.newSingleThreadExecutor()
            val synthesis = Executors.newSingleThreadExecutor()
            val fetcher = HttpRangeFetcher()
            return PocketVoices(
                gate = gate,
                makeStore = {
                    PocketModelStore(directory, PocketManifest.FILES, fetcher, {
                        engine.load()
                        gate.measuredRtf = PocketWarmUp.rtf(engine)
                    }, downloads, post)
                },
                makeVoiceStore = { voice -> PocketModelStore(directory, listOf(voice.file), fetcher, null, downloads, post) },
                makeSpeaker = { PocketSpeaker(engine, AudioTrackOutput(), SystemReplyFocus(app), synthesis, post) },
                emit = emit,
            )
        }
    }
}
