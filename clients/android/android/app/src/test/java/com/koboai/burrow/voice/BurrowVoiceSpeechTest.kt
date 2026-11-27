package com.koboai.burrow.voice

import com.getcapacitor.JSObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.shadows.ShadowLog

/** Replies through the plugin: speak, speakPart, stopSpeaking, voices and the speech event. */
@RunWith(RobolectricTestRunner::class)
class BurrowVoiceSpeechTest {
    private val rig = VoiceRig()

    private fun voice(
        id: String,
        quality: String = ReplyVoice.DEFAULT,
        language: String = "en-US",
    ) = ReplyVoice(id, "Voice $id", quality, language)

    @Test
    fun `speakPart seq 0 starts speaking before the final part`() {
        val first = rig.part("r1", 0, "It is sunny.")
        assertTrue(first.getBoolean("spoken"))
        assertTrue(first.has("fellBack"))
        assertEquals(listOf("It is sunny."), rig.engine.texts())
        rig.engine.start("It is sunny.")
        assertEquals(listOf("started"), rig.speech())

        assertTrue(rig.part("r1", 1, "Highs of twenty.").getBoolean("spoken"))
        rig.part("r1", 2, "No rain.", final = true)
        assertEquals(listOf("It is sunny.", "Highs of twenty.", "No rain."), rig.engine.texts())
        rig.engine.texts().forEach { rig.engine.done(it) }
        assertEquals(listOf("started", "finished"), rig.speech())
    }

    @Test
    fun `opening the mic mid-stream sends one stopped mic_opened and drops the rest of the reply`() {
        rig.part("r1", 0, "One.")
        rig.part("r1", 1, "Two.")
        rig.engine.start("One.")
        val queued = rig.engine.queued.size

        assertTrue(rig.start().getBoolean("started"))
        assertEquals(listOf("started", "stopped:mic_opened"), rig.speech())
        assertTrue("the engine was flushed", rig.engine.stops >= 1)
        // Its later parts, and its final one, are dropped and never spoken.
        val later = rig.part("r1", 2, "Three.")
        assertFalse(later.getBoolean("spoken"))
        assertEquals("stopped", later.getString("reason"))
        rig.part("r1", 3, "Four.", final = true)
        assertEquals(queued, rig.engine.queued.size)
        // Late callbacks of the flushed utterances change nothing.
        rig.engine.done("One.")
        rig.engine.done("Two.")
        assertEquals(1, rig.speech().count { it.startsWith("stopped") })
        assertFalse(rig.speech().contains("finished"))
    }

    @Test
    fun `the speaker stops before the recognizer opens`() {
        rig.part("r1", 0, "One.")
        rig.start()
        val stop = rig.log.indexOf("tts.stop")
        val open = rig.log.indexOf("transcriber.start")
        assertTrue("${rig.log.entries}", stop in 0 until open)
    }

    @Test
    fun `losing the output device stops the reply with route_lost, and nothing more plays`() {
        rig.part("r1", 0, "One.")
        rig.engine.start("One.")
        rig.audio.onOutputLost!!()
        assertEquals(listOf("started", "stopped:route_lost"), rig.speech())
        val queued = rig.engine.queued.size
        rig.part("r1", 1, "Two.", final = true)
        assertEquals("never continues on the loudspeaker", queued, rig.engine.queued.size)
        assertFalse(rig.focus.held)
    }

    @Test
    fun `going to the background stops the reply`() {
        rig.plugin.speakReply("r1", "Hello there.")
        rig.plugin.handleOnStop()
        assertEquals(listOf("stopped:background"), rig.speech())
    }

    @Test
    fun `a reply is refused while the mic is open, and during a call it is unheard`() {
        rig.start()
        val listening = rig.plugin.speakReply("r1", "Hello.")
        assertFalse(listening.getBoolean("spoken"))
        assertEquals("listening", listening.getString("reason"))
        assertEquals("listening", rig.part("r2", 0, "Hello.").getString("reason"))
        rig.call(rig.plugin::cancel)

        rig.audio.inCall = true
        val call = rig.plugin.speakReply("r3", "Hello.")
        assertEquals("mic_in_use", call.getString("reason"))
        assertEquals(listOf("unheard:mic_in_use"), rig.speech())
        assertTrue(rig.engine.queued.isEmpty())
    }

    @Test
    fun `an engine that cannot speak resolves spoken false and sends unheard`() {
        rig.engine.usable = false
        val r = rig.plugin.speakReply("r1", "Hello.")
        assertFalse(r.getBoolean("spoken"))
        assertEquals("tts_unavailable", r.getString("reason"))
        assertEquals(listOf("unheard:tts_unavailable"), rig.speech())
    }

    @Test
    fun `a requested voice that is not installed reads in the best one, with fellBack`() {
        rig.catalog.voices = mutableListOf(voice("a"), voice("b", ReplyVoice.PREMIUM))
        val r = rig.plugin.speakReply("r1", "Hello.", "gone")
        assertTrue(r.getBoolean("spoken"))
        assertEquals("b", r.getString("voice"))
        assertTrue(r.getBoolean("fellBack"))
        assertEquals(listOf<String?>("b"), rig.engine.selected)

        val picked = rig.part("r2", 0, "Hi.", voice = "a")
        assertEquals("a", picked.getString("voice"))
        assertFalse(picked.getBoolean("fellBack"))
    }

    @Test
    fun `voices lists the language's installed voices, best first, with the best as default`() {
        rig.catalog.voices =
            mutableListOf(voice("a"), voice("b", ReplyVoice.PREMIUM), voice("c", ReplyVoice.ENHANCED), voice("d", language = "fr-FR"))
        val list = rig.call(rig.plugin::voices).resolved!!
        val rows = list.getJSONArray("voices")
        val ids = (0 until rows.length()).map { rows.getJSONObject(it).getString("id") }
        assertEquals(listOf("b", "c", "a"), ids)
        assertEquals("b", list.getString("default"))
        val row = rows.getJSONObject(0)
        assertEquals(setOf("id", "name", "quality", "language"), row.keys().asSequence().toSet())
    }

    @Test
    fun `no installed voice gives a null default`() {
        assertTrue(rig.call(rig.plugin::voices).resolved!!.isNull("default"))
    }

    @Test
    fun `stopSpeaking stops with the page's reason`() {
        rig.plugin.speakReply("r1", "Hello.")
        val call = rig.call { c -> rig.plugin.stopSpeaking(c) }
        assertTrue(call.resolvedEmpty)
        assertEquals(listOf("stopped:stopped"), rig.speech())
        rig.plugin.speakReply("r2", "Hello again.")
        rig.plugin.stopSpeaking(FakeCall(JSObject().put("reason", "left")))
        assertEquals("stopped:left", rig.speech().last())
    }

    @Test
    fun `a speak replaces a stream in flight`() {
        rig.part("r1", 0, "One.")
        rig.plugin.speakReply("r2", "Other.")
        assertEquals(listOf("stopped:replaced"), rig.speech())
    }

    @Test
    fun `reply text never reaches a log`() {
        ShadowLog.clear()
        val secret = "the quarterly figures are confidential"
        rig.part("r1", 0, secret)
        rig.engine.start(secret)
        rig.part("r1", 1, "$secret again", final = true)
        rig.engine.texts().forEach { rig.engine.done(it) }
        rig.plugin.speakReply("r2", secret)
        rig.start()
        assertTrue(ShadowLog.getLogs().none { it.msg?.contains("quarterly") == true })
    }
}
