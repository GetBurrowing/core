package com.koboai.burrow.voice

import com.getcapacitor.JSObject
import com.koboai.burrow.BuildConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The plugin, built with fake transcriber, audio, mic and speaker seams (not
 * through MainActivity, which does not boot under Robolectric). Mirrors the
 * iOS `BurrowVoicePluginTests`.
 */
@RunWith(RobolectricTestRunner::class)
class BurrowVoicePluginTest {
    private val rig = VoiceRig()

    private fun capabilities(inputs: VoiceCapabilityInputs): JSObject {
        rig.transcriber.inputs = inputs
        return rig.call(rig.plugin::capabilities).resolved!!
    }

    @Test
    fun `capabilities resolves the iOS payload shape`() {
        val caps = capabilities(VoiceCapabilityInputs(33, true, "en-US", SpeechAssets.INSTALLED))
        assertEquals(setOf("onDeviceSpeech", "reason", "locale", "testBuild", "micPermission"), caps.keys().asSequence().toSet())
        assertTrue(caps.getBoolean("onDeviceSpeech"))
        // null, not absent: the JS reads the iOS NSNull the same way.
        assertTrue(caps.isNull("reason"))
        assertEquals("en-US", caps.getString("locale"))
        assertEquals(BuildConfig.DEBUG, caps.getBoolean("testBuild"))
        assertEquals("granted", caps.getString("micPermission"))
    }

    @Test
    fun `every capability reason, per API level`() {
        fun reason(inputs: VoiceCapabilityInputs): String? {
            val caps = capabilities(inputs)
            return if (caps.isNull("reason")) null else caps.getString("reason")
        }

        assertEquals("os_too_old", reason(VoiceCapabilityInputs(26)))
        assertEquals("os_too_old", reason(VoiceCapabilityInputs(30, onDeviceAvailable = true, locale = "en-US")))
        assertEquals("unavailable", reason(VoiceCapabilityInputs(31, onDeviceAvailable = false, locale = "en-US")))
        assertEquals("unavailable", reason(VoiceCapabilityInputs(35, onDeviceAvailable = false, locale = "en-US")))
        // API 31-32: nothing to check, so a phone with the recognizer tries it.
        assertNull(reason(VoiceCapabilityInputs(31, true, "en-US", SpeechAssets.UNKNOWN)))
        assertNull(reason(VoiceCapabilityInputs(32, true, "en-US", SpeechAssets.UNKNOWN)))
        assertEquals("locale_unsupported", reason(VoiceCapabilityInputs(31, true, null)))
        // API 33+: checkRecognitionSupport decides.
        assertEquals("locale_unsupported", reason(VoiceCapabilityInputs(33, true, null, SpeechAssets.UNSUPPORTED)))
        assertEquals("assets_missing", reason(VoiceCapabilityInputs(33, true, "en-US", SpeechAssets.DOWNLOADABLE)))
        assertEquals("assets_missing", reason(VoiceCapabilityInputs(35, true, "en-US", SpeechAssets.DOWNLOADABLE)))
        assertEquals("unavailable", reason(VoiceCapabilityInputs(33, true, "en-US", SpeechAssets.UNKNOWN)))
        assertNull(reason(VoiceCapabilityInputs(35, true, "en-GB", SpeechAssets.INSTALLED)))
    }

    @Test
    fun `every reason the plugin can send is one the JS knows`() {
        val js = listOf("os_too_old", "unavailable", "locale_unsupported", "speech_permission_denied", "assets_missing")
        assertEquals(js, VoiceCapability.REASONS)
        for (sdk in listOf(26, 30, 31, 32, 33, 34, 35, 36)) {
            for (available in listOf(true, false)) {
                for (locale in listOf("en-US", null)) {
                    for (assets in SpeechAssets.entries) {
                        val reason = VoiceCapability.decide(VoiceCapabilityInputs(sdk, available, locale, assets)).reason
                        assertTrue("$reason", reason == null || reason in js)
                    }
                }
            }
        }
    }

    @Test
    fun `micPermission uses the iOS strings`() {
        for (state in listOf("granted", "denied", "undetermined")) {
            rig.mic.state = state
            assertEquals(state, capabilities(rig.transcriber.inputs).getString("micPermission"))
        }
    }

    @Test
    fun `prepare on assets_missing downloads, then resolves fresh capabilities`() {
        rig.transcriber.inputs = VoiceCapabilityInputs(34, true, "en-US", SpeechAssets.DOWNLOADABLE)
        assertEquals("assets_missing", rig.call(rig.plugin::capabilities).resolved!!.getString("reason"))
        rig.transcriber.afterPrepare = VoiceCapabilityInputs(34, true, "en-US", SpeechAssets.INSTALLED)

        val caps = rig.call(rig.plugin::prepare).resolved!!
        assertEquals(1, rig.transcriber.prepareCalls)
        assertTrue(caps.getBoolean("onDeviceSpeech"))
        assertTrue(caps.isNull("reason"))
    }

    @Test
    fun `start refuses mic_in_use during a call or a meeting`() {
        rig.audio.inCall = true
        val refused = rig.start()
        assertFalse(refused.getBoolean("started"))
        assertEquals("mic_in_use", refused.getString("reason"))
        assertEquals(-1, rig.log.indexOf("transcriber.start"))
    }

    @Test
    fun `start refuses mic_in_use while another client records`() {
        rig.audio.othersRecording = true
        assertEquals("mic_in_use", rig.start().getString("reason"))
        assertEquals(-1, rig.log.indexOf("transcriber.start"))
        assertEquals(-1, rig.log.indexOf("audio.begin"))
    }

    @Test
    fun `start refuses mic_permission_denied without asking again`() {
        rig.mic.state = "denied"
        val refused = rig.start()
        assertFalse(refused.getBoolean("started"))
        assertEquals("mic_permission_denied", refused.getString("reason"))
        assertEquals("denied", refused.getString("micPermission"))
        assertEquals(-1, rig.log.indexOf("mic.request"))
        assertEquals(-1, rig.log.indexOf("transcriber.start"))
        // The turn is over: the next start is not "busy".
        rig.mic.state = "granted"
        assertTrue(rig.start().getBoolean("started"))
    }

    @Test
    fun `start asks for the mic through the plugin alias, and a refusal is mic_permission_denied`() {
        assertEquals("microphone", BurrowVoicePlugin.MIC)
        rig.mic.state = "undetermined"
        val call = rig.call(rig.plugin::start)
        assertNull("waits for the prompt", call.resolved)
        assertTrue(rig.log.entries.contains("mic.request"))
        rig.mic.pending!!(false)
        assertEquals("mic_permission_denied", call.resolved!!.getString("reason"))
        assertEquals(-1, rig.log.indexOf("transcriber.start"))
    }

    @Test
    fun `a granted prompt opens the turn`() {
        rig.mic.state = "undetermined"
        val call = rig.call(rig.plugin::start)
        rig.mic.pending!!(true)
        assertTrue(call.resolved!!.getBoolean("started"))
        assertTrue(rig.log.entries.contains("transcriber.start"))
    }

    @Test
    fun `the activity pausing under the permission prompt does not cancel the turn`() {
        rig.mic.state = "undetermined"
        val call = rig.call(rig.plugin::start)
        rig.plugin.handleOnPause()
        rig.mic.pending!!(true)
        assertTrue(call.resolved!!.getBoolean("started"))
        assertFalse(rig.eventNames().contains("ended"))
    }

    @Test
    fun `start stops the reply BEFORE the recognizer opens (barge-in)`() {
        assertTrue(rig.start().getBoolean("started"))
        assertEquals(listOf("mic_opened"), rig.speaker.stops)
        val stop = rig.log.indexOf("speaker.stop:mic_opened")
        val open = rig.log.indexOf("transcriber.start")
        assertTrue("stop at $stop must precede open at $open: ${rig.log.entries}", stop in 0 until open)
    }

    @Test
    fun `even a refused start stops the reply`() {
        rig.audio.inCall = true
        rig.start()
        assertEquals(listOf("mic_opened"), rig.speaker.stops)
    }

    @Test
    fun `a second start while a turn is open is busy`() {
        assertTrue(rig.start().getBoolean("started"))
        assertEquals("busy", rig.start().getString("reason"))
    }

    @Test
    fun `a recognizer that cannot start is start_failed, and the turn is over`() {
        rig.transcriber.startSucceeds = false
        assertEquals("start_failed", rig.start().getString("reason"))
        assertEquals(-1, rig.log.indexOf("audio.begin"))
        rig.transcriber.startSucceeds = true
        assertTrue(rig.start().getBoolean("started"))
    }

    @Test
    fun `start then stop sends partials, then final and ended released, and resolves the text`() {
        rig.audio.routeLabel = "Bluetooth"
        val started = rig.start()
        assertTrue(started.getBoolean("started"))
        assertEquals("Bluetooth", started.getString("route"))
        assertEquals("Bluetooth", rig.event("route")!!.getString("label"))

        rig.transcriber.onPartial!!("what is")
        rig.transcriber.onPartial!!("what is the weather")
        rig.transcriber.heard = "  what is the weather like today "
        val stopped = rig.stop()

        assertEquals("what is the weather like today", stopped.getString("text"))
        val partials = rig.events.filter { it.first == "partial" }.map { it.second.getString("text") }
        assertEquals(listOf("what is", "what is the weather"), partials)
        assertEquals("what is the weather like today", rig.event("final")!!.getString("text"))
        assertEquals("released", rig.event("ended")!!.getString("reason"))
        val names = rig.eventNames()
        assertTrue(names.indexOf("final") < names.lastIndexOf("ended"))
        assertTrue("the mic is released", rig.log.entries.contains("audio.end"))
    }

    @Test
    fun `an empty stop is no_words, with no final`() {
        rig.start()
        rig.transcriber.heard = "   "
        assertEquals("", rig.stop().getString("text"))
        assertFalse(rig.eventNames().contains("final"))
        assertEquals("no_words", rig.event("ended")!!.getString("reason"))
        assertTrue(rig.log.entries.contains("audio.end"))
    }

    @Test
    fun `stop with no turn resolves empty text and sends nothing`() {
        assertEquals("", rig.stop().getString("text"))
        assertTrue(rig.events.isEmpty())
    }

    @Test
    fun `a partial from a cancelled turn is dropped`() {
        rig.start()
        val late = rig.transcriber.onPartial!!
        rig.call(rig.plugin::cancel).also { assertTrue(it.resolvedEmpty) }
        late("too late")
        assertFalse(rig.eventNames().contains("partial"))
        assertEquals(1, rig.transcriber.cancelCalls)
        assertFalse("cancel sends no event", rig.eventNames().contains("ended"))
    }

    @Test
    fun `pausing the app cancels the turn and sends ended background`() {
        rig.start()
        rig.plugin.handleOnPause()
        assertEquals("background", rig.event("ended")!!.getString("reason"))
        assertEquals(1, rig.transcriber.cancelCalls)
        assertTrue(rig.log.entries.contains("audio.end"))
        assertEquals(listOf("mic_opened", "background"), rig.speaker.stops)
        // onStop after onPause: the turn is already gone, nothing more is sent.
        rig.plugin.handleOnStop()
        assertEquals(1, rig.events.count { it.first == "ended" })
    }

    @Test
    fun `stopping the app with a turn open sends ended background`() {
        rig.start()
        rig.plugin.handleOnStop()
        assertEquals("background", rig.event("ended")!!.getString("reason"))
    }

    @Test
    fun `a call or a permanent focus loss ends the turn with interrupted`() {
        rig.start()
        rig.audio.listener!!.onInterrupted()
        assertEquals("interrupted", rig.event("ended")!!.getString("reason"))
        assertEquals(1, rig.transcriber.cancelCalls)
    }

    @Test
    fun `a recognizer failure mid-turn ends it`() {
        rig.start()
        rig.transcriber.onFailure!!(OnDeviceTranscriber.REASON_RECOGNIZER_ERROR)
        assertEquals("recognizer_error", rig.event("ended")!!.getString("reason"))
        assertTrue(rig.start().getBoolean("started"))
    }

    @Test
    fun `a route change during a turn sends route, and the label is null for the built-in mic`() {
        rig.start()
        rig.audio.routeLabel = null
        rig.audio.listener!!.onRouteChanged()
        val route = rig.event("route")
        assertNotNull(route)
        assertTrue(route!!.isNull("label"))
    }

    @Test
    fun `openSettings resolves opened`() {
        rig.plugin.openAppSettings = { true }
        assertTrue(rig.call(rig.plugin::openSettings).resolved!!.getBoolean("opened"))
    }

    @Test
    fun `every event the plugin sends is in EVENTS`() {
        rig.audio.routeLabel = "Headphones"
        rig.start()
        rig.transcriber.onPartial!!("hello")
        rig.transcriber.heard = "hello"
        rig.stop()
        rig.start()
        rig.plugin.handleOnStop()
        assertTrue(BurrowVoicePlugin.EVENTS.containsAll(rig.eventNames().toSet()))
        assertEquals(BurrowVoicePlugin.EVENTS.toSet(), rig.eventNames().toSet())
    }
}
