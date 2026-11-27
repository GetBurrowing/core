package com.koboai.burrow.voice

import com.getcapacitor.JSObject
import com.getcapacitor.PluginCall

/** One ordered log of every fake's calls, so a test can assert what happened first. */
class CallLog {
    val entries = mutableListOf<String>()

    fun add(entry: String) {
        entries.add(entry)
    }

    fun indexOf(entry: String): Int = entries.indexOf(entry)
}

/** A PluginCall that records its answer instead of sending it to a WebView. */
class FakeCall(
    data: JSObject = JSObject(),
) : PluginCall(null, "BurrowVoice", "callback", "method", data) {
    var resolved: JSObject? = null
    var resolvedEmpty = false

    override fun resolve(data: JSObject) {
        resolved = data
    }

    override fun resolve() {
        resolvedEmpty = true
    }
}

class FakeTranscriber(
    private val log: CallLog,
) : VoiceTranscribing {
    var inputs = VoiceCapabilityInputs(33, onDeviceAvailable = true, locale = "en-US", assets = SpeechAssets.INSTALLED)
    var afterPrepare: VoiceCapabilityInputs? = null
    var startSucceeds = true
    var prepareCalls = 0
    var cancelCalls = 0
    var onPartial: ((String) -> Unit)? = null
    var onFailure: ((String) -> Unit)? = null

    /** The text [finish] hands back. */
    var heard = ""

    override fun capabilityInputs(done: (VoiceCapabilityInputs) -> Unit) = done(inputs)

    override fun prepare(done: () -> Unit) {
        prepareCalls++
        afterPrepare?.let { inputs = it }
        done()
    }

    override fun start(
        onPartial: (String) -> Unit,
        onFailure: (String) -> Unit,
    ): Boolean {
        log.add("transcriber.start")
        if (!startSucceeds) return false
        this.onPartial = onPartial
        this.onFailure = onFailure
        return true
    }

    override fun finish(done: (String) -> Unit) {
        log.add("transcriber.finish")
        done(heard)
    }

    override fun cancel() {
        log.add("transcriber.cancel")
        cancelCalls++
    }
}

class FakeAudio(
    private val log: CallLog,
) : VoiceAudioControl {
    override var inCall = false
    override var othersRecording = false
    override var routeLabel: String? = null
    var listener: VoiceAudioListener? = null

    override fun beginCapture(listener: VoiceAudioListener) {
        log.add("audio.begin")
        this.listener = listener
    }

    override fun endCapture() {
        log.add("audio.end")
        listener = null
    }
}

class FakeMic(
    private val log: CallLog,
) : MicPermission {
    var state = "granted"
    var pending: ((Boolean) -> Unit)? = null

    override fun status(): String = state

    override fun request(
        call: PluginCall,
        done: (Boolean) -> Unit,
    ) {
        log.add("mic.request")
        pending = done
    }
}

class RecordingSpeaker(
    private val log: CallLog,
) : VoiceSpeaking {
    val stops = mutableListOf<String>()

    override fun stop(reason: String) {
        log.add("speaker.stop:$reason")
        stops.add(reason)
    }
}

/** A plugin wired to fakes, run inline: no bridge, no activity, no main-thread hop. */
class VoiceRig {
    val log = CallLog()
    val transcriber = FakeTranscriber(log)
    val audio = FakeAudio(log)
    val mic = FakeMic(log)
    val speaker = RecordingSpeaker(log)
    val events = mutableListOf<Pair<String, JSObject>>()
    val plugin =
        BurrowVoicePlugin().also { p ->
            p.transcriber = transcriber
            p.audio = audio
            p.micPermission = mic
            p.speaker = speaker
            p.onMain = { it() }
            p.eventSink = { name, data -> events.add(name to data) }
        }

    fun call(method: (PluginCall) -> Unit): FakeCall = FakeCall().also { method(it) }

    fun start(): JSObject = call(plugin::start).resolved!!

    fun stop(): JSObject = call(plugin::stop).resolved!!

    fun eventNames(): List<String> = events.map { it.first }

    fun event(name: String): JSObject? = events.lastOrNull { it.first == name }?.second
}
