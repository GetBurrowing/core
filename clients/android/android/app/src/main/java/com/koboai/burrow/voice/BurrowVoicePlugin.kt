package com.koboai.burrow.voice

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import com.getcapacitor.JSObject
import com.getcapacitor.PermissionState
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import com.getcapacitor.annotation.Permission
import com.getcapacitor.annotation.PermissionCallback
import com.koboai.burrow.BuildConfig
import org.json.JSONObject

/** The microphone grant, behind a seam for tests. */
interface MicPermission {
    /** "granted", "denied" or "undetermined": the iOS strings (JS acts only on "denied"). */
    fun status(): String

    /** Shows the system prompt; [done] gets whether it was granted. */
    fun request(
        call: PluginCall,
        done: (Boolean) -> Unit,
    )
}

/**
 * `BurrowVoice` (task 01a21e4a stage 1): the Voice tab on an Android phone
 * that can transcribe on the device. The mic's words are transcribed here and
 * the page sends them as text, as on iOS. Registered beside
 * `BurrowNativePlugin` in `MainActivity`, and exposed to the install's origin
 * by `NativeBridgeExposure.PLUGIN_IDS`.
 *
 * The contract is the iOS plugin's (`clients/ios/ios/App/App/Plugins/
 * BurrowVoicePlugin.swift`), names unchanged, because the page's JS
 * (`assets/js/lib/on_device_voice.js`, `hooks/voice_tab_native_runtime.js`)
 * checks only that the plugin is there. [METHODS] and [EVENTS] are this
 * stage's half: reply speech (`speak`, `speakPart`, `stopSpeaking`,
 * `voices`, `speech`) and Pocket TTS (`prepareModel`, `model`) come later.
 *
 * Every method hops to the main thread; the recognizer and the audio
 * callbacks live there.
 *
 * Never logs what was said, the reply, or a device name.
 */
@CapacitorPlugin(
    name = "BurrowVoice",
    permissions = [Permission(alias = BurrowVoicePlugin.MIC, strings = [Manifest.permission.RECORD_AUDIO])],
)
class BurrowVoicePlugin : Plugin() {
    // Seams: load() builds the real ones; tests set fakes and never call load().
    lateinit var transcriber: VoiceTranscribing
    lateinit var audio: VoiceAudioControl
    lateinit var micPermission: MicPermission
    var speaker: VoiceSpeaking = NoReplySpeaker
    var isTestBuild: () -> Boolean = { BuildConfig.DEBUG }
    var openAppSettings: () -> Boolean = { false }

    /** Runs a method's body on the main thread. */
    var onMain: (() -> Unit) -> Unit = { task -> Handler(Looper.getMainLooper()).post(task) }

    /** Every event goes here; null sends it to the page. */
    var eventSink: ((String, JSObject) -> Unit)? = null

    private enum class Turn { IDLE, STARTING, LISTENING }

    private var turn = Turn.IDLE

    /** Bumped by every cancel and stop, so a start still waiting knows its turn was discarded meanwhile. */
    private var generation = 0

    /** The system permission prompt is up: the activity pauses under it, and that is not leaving Voice. */
    private var awaitingPermission = false
    private var permissionAnswer: ((Boolean) -> Unit)? = null

    override fun load() {
        val app = context.applicationContext
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (!::transcriber.isInitialized) transcriber = OnDeviceTranscriber.forContext(app)
            if (!::audio.isInitialized) audio = SystemVoiceAudio(app)
        } else {
            if (!::transcriber.isInitialized) transcriber = OldOsTranscriber
            if (!::audio.isInitialized) audio = NoVoiceAudio
        }
        if (!::micPermission.isInitialized) micPermission = CapacitorMicPermission()
        openAppSettings = {
            val intent =
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", app.packageName, null))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            runCatching { app.startActivity(intent) }.isSuccess
        }
    }

    private fun emit(
        name: String,
        data: JSObject,
    ) {
        val sink = eventSink
        if (sink != null) sink(name, data) else notifyListeners(name, data)
    }

    private val audioListener =
        object : VoiceAudioListener {
            override fun onInterrupted() = stopEverything(REASON_INTERRUPTED)

            override fun onRouteChanged() {
                if (turn == Turn.LISTENING) emitRoute()
            }
        }

    // MARK: Methods

    /** `{onDeviceSpeech, reason, locale, testBuild, micPermission}`, the iOS `capabilityPayload`. */
    @PluginMethod
    fun capabilities(call: PluginCall) {
        onMain { capabilityPayload { call.resolve(it) } }
    }

    /** Asks the system for the speech model (`assets_missing`), then resolves the fresh `capabilities()`. */
    @PluginMethod
    fun prepare(call: PluginCall) {
        onMain { transcriber.prepare { capabilityPayload { call.resolve(it) } } }
    }

    /**
     * Opens the mic -> `{started: true, route}` or `{started: false, reason}`.
     * Always stops the reply first (barge-in). Refusals:
     * - `mic_in_use`: a call or a meeting holds the audio, or another client records;
     * - `mic_permission_denied` (with `micPermission: "denied"`);
     * - `busy`: a turn is already open;
     * - `start_failed`, `cancelled`.
     */
    @PluginMethod
    fun start(call: PluginCall) {
        onMain { startTurn(call) { call.resolve(it) } }
    }

    /**
     * Release: closes the mic, then `final {text}` and `ended {reason:
     * "released"}`; with no words, only `ended {reason: "no_words"}`.
     * Resolves `{text}`.
     */
    @PluginMethod
    fun stop(call: PluginCall) {
        onMain { stopTurn { call.resolve(it) } }
    }

    /** Slide-off: discards the turn. Sends no event. */
    @PluginMethod
    fun cancel(call: PluginCall) {
        onMain {
            cancelTurn()
            call.resolve()
        }
    }

    /** The app's page in Settings, for the permission card. */
    @PluginMethod
    fun openSettings(call: PluginCall) {
        onMain { call.resolve(JSObject().put("opened", openAppSettings())) }
    }

    // MARK: Turn

    fun capabilityPayload(done: (JSObject) -> Unit) {
        transcriber.capabilityInputs { inputs ->
            val capability = VoiceCapability.decide(inputs)
            done(
                JSObject()
                    .put("onDeviceSpeech", capability.onDeviceSpeech)
                    .put("reason", capability.reason ?: JSONObject.NULL)
                    .put("locale", capability.locale ?: JSONObject.NULL)
                    .put("testBuild", isTestBuild())
                    .put("micPermission", micPermission.status()),
            )
        }
    }

    fun startTurn(
        call: PluginCall,
        done: (JSObject) -> Unit,
    ) {
        speaker.stop(REASON_MIC_OPENED)
        if (turn != Turn.IDLE) return done(refusal("busy"))
        if (audio.inCall || audio.othersRecording) return done(refusal("mic_in_use"))
        turn = Turn.STARTING
        val mine = generation
        when (micPermission.status()) {
            GRANTED -> open(mine, done)
            DENIED -> {
                turn = Turn.IDLE
                done(permissionDenied())
            }
            else -> {
                awaitingPermission = true
                micPermission.request(call) { granted ->
                    awaitingPermission = false
                    when {
                        generation != mine -> done(refusal("cancelled"))
                        granted -> open(mine, done)
                        else -> {
                            turn = Turn.IDLE
                            done(permissionDenied())
                        }
                    }
                }
            }
        }
    }

    private fun open(
        mine: Int,
        done: (JSObject) -> Unit,
    ) {
        val started =
            transcriber.start(
                onPartial = { text -> if (generation == mine) emit("partial", JSObject().put("text", text)) },
                onFailure = { reason -> if (generation == mine) stopEverything(reason) },
            )
        if (!started) {
            turn = Turn.IDLE
            return done(refusal("start_failed"))
        }
        audio.beginCapture(audioListener)
        turn = Turn.LISTENING
        emitRoute()
        done(JSObject().put("started", true).put("route", audio.routeLabel ?: JSONObject.NULL))
    }

    fun stopTurn(done: (JSObject) -> Unit) {
        when (turn) {
            Turn.IDLE -> done(JSObject().put("text", ""))
            Turn.STARTING -> {
                // Released before the mic opened: nothing was heard.
                cancelTurn()
                emit("ended", JSObject().put("reason", "no_words"))
                done(JSObject().put("text", ""))
            }
            Turn.LISTENING -> {
                turn = Turn.IDLE
                generation++
                transcriber.finish { raw ->
                    val text = raw.trim()
                    // A new turn may already hold the capture.
                    if (turn == Turn.IDLE) audio.endCapture()
                    if (text.isEmpty()) {
                        emit("ended", JSObject().put("reason", "no_words"))
                    } else {
                        emit("final", JSObject().put("text", text))
                        emit("ended", JSObject().put("reason", "released"))
                    }
                    done(JSObject().put("text", text))
                }
            }
        }
    }

    fun cancelTurn() {
        if (turn == Turn.IDLE) return
        generation++
        turn = Turn.IDLE
        transcriber.cancel()
        audio.endCapture()
    }

    /** Stops the reply and discards any turn, with [reason] (iOS `stopEverything`). */
    private fun stopEverything(reason: String) {
        speaker.stop(reason)
        if (turn == Turn.IDLE) return
        cancelTurn()
        emit("ended", JSObject().put("reason", reason))
    }

    private fun emitRoute() {
        emit("route", JSObject().put("label", audio.routeLabel ?: JSONObject.NULL))
    }

    private fun refusal(reason: String): JSObject = JSObject().put("started", false).put("reason", reason)

    private fun permissionDenied(): JSObject = refusal("mic_permission_denied").put("micPermission", DENIED)

    // MARK: Lifecycle

    /** Leaving the app stops the turn natively: the page's JS may already be suspended. */
    public override fun handleOnPause() {
        if (!awaitingPermission) stopEverything(REASON_BACKGROUND)
    }

    public override fun handleOnStop() {
        stopEverything(REASON_BACKGROUND)
    }

    public override fun handleOnDestroy() {
        cancelTurn()
    }

    // MARK: Permission

    @Suppress("UNUSED_PARAMETER") // Capacitor calls it with the saved call
    @PermissionCallback
    private fun micPermissionResult(call: PluginCall) {
        val answer = permissionAnswer ?: return
        permissionAnswer = null
        answer(getPermissionState(MIC) == PermissionState.GRANTED)
    }

    private inner class CapacitorMicPermission : MicPermission {
        override fun status(): String =
            when (getPermissionState(MIC)) {
                PermissionState.GRANTED -> GRANTED
                PermissionState.DENIED -> DENIED
                else -> "undetermined"
            }

        override fun request(
            call: PluginCall,
            done: (Boolean) -> Unit,
        ) {
            permissionAnswer = done
            requestPermissionForAlias(MIC, call, "micPermissionResult")
        }
    }

    companion object {
        const val MIC = "microphone"
        private const val GRANTED = "granted"
        private const val DENIED = "denied"
        const val REASON_MIC_OPENED = "mic_opened"
        const val REASON_BACKGROUND = "background"
        const val REASON_INTERRUPTED = "interrupted"

        /** The `@PluginMethod`s, in the iOS names (BurrowVoiceMethodsTest pins both). */
        val METHODS = listOf("capabilities", "prepare", "start", "stop", "cancel", "openSettings")

        /** The events this plugin sends, in the iOS names. */
        val EVENTS = listOf("partial", "final", "ended", "route")
    }
}

/** Below API 31 there is no on-device recognizer: `os_too_old`, and today's Voice tab stays. */
object OldOsTranscriber : VoiceTranscribing {
    override fun capabilityInputs(done: (VoiceCapabilityInputs) -> Unit) = done(VoiceCapabilityInputs(Build.VERSION.SDK_INT))

    override fun prepare(done: () -> Unit) = done()

    override fun start(
        onPartial: (String) -> Unit,
        onFailure: (String) -> Unit,
    ): Boolean = false

    override fun finish(done: (String) -> Unit) = done("")

    override fun cancel() = Unit
}

object NoVoiceAudio : VoiceAudioControl {
    override val inCall = false
    override val othersRecording = false
    override val routeLabel: String? = null

    override fun beginCapture(listener: VoiceAudioListener) = Unit

    override fun endCapture() = Unit
}
