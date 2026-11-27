package com.koboai.burrow.voice

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The system speaker's reply logic, against a scripted TextToSpeech engine. Mirrors iOS `ReplySpeakerTests`. */
class SystemReplySpeakerTest {
    private val engine = FakeTtsEngine()
    private val focus = FakeFocus()
    private val speaker = SystemReplySpeaker(engine, focus) { "en-US" }
    private val events = mutableListOf<String>()

    init {
        speaker.onEvent = { e -> events.add("${e.id}:${e.state}" + (e.reason?.let { ":$it" } ?: "")) }
    }

    @Test
    fun `seq 0 starts before the final part arrives`() {
        speaker.begin("r1", null)
        speaker.append("r1", 0, "First sentence.")
        assertEquals(listOf("First sentence."), engine.texts())
        engine.start("First sentence.")
        assertEquals(listOf("r1:started"), events)
        assertTrue(speaker.isSpeaking)

        speaker.append("r1", 1, "Second sentence.")
        engine.done("First sentence.")
        assertEquals("not finished before the final part", listOf("r1:started"), events)
        speaker.finish("r1")
        engine.start("Second sentence.")
        engine.done("Second sentence.")
        assertEquals(listOf("r1:started", "r1:finished"), events)
        assertFalse(speaker.isSpeaking)
    }

    @Test
    fun `parts play in seq order even when they arrive out of order`() {
        speaker.begin("r1", null)
        speaker.append("r1", 2, "three")
        speaker.append("r1", 1, "two")
        assertTrue("held until seq 0", engine.queued.isEmpty())
        speaker.append("r1", 0, "one")
        assertEquals(listOf("one", "two", "three"), engine.texts())
        // A repeated or old seq is dropped.
        speaker.append("r1", 1, "two again")
        assertEquals(3, engine.queued.size)
    }

    @Test
    fun `finish flushes parts still held after a gap`() {
        speaker.begin("r1", null)
        speaker.append("r1", 0, "one")
        speaker.append("r1", 2, "three")
        speaker.finish("r1")
        assertEquals(listOf("one", "three"), engine.texts())
    }

    @Test
    fun `stop sends exactly one stopped with its reason, and drops the engine's late callbacks`() {
        speaker.begin("r1", null)
        speaker.append("r1", 0, "one")
        speaker.append("r1", 1, "two")
        engine.start("one")
        speaker.stop("mic_opened")
        assertEquals(1, engine.stops)
        // TextToSpeech reports the flushed utterances after stop(): ignored.
        engine.done("one")
        engine.events!!.onLost(engine.idOf("two"))
        speaker.stop("mic_opened")
        assertEquals(listOf("r1:started", "r1:stopped:mic_opened"), events)
        // Later parts of the stopped reply are ignored.
        speaker.append("r1", 2, "three")
        assertEquals(2, engine.queued.size)
    }

    @Test
    fun `a replaced reply's late onDone does not finish the next reply`() {
        speaker.speak("old", "Old reply.", null)
        val oldId = engine.idOf("Old reply.")
        engine.start("Old reply.")
        speaker.begin("new", null)
        speaker.append("new", 0, "New reply.")
        speaker.finish("new")
        // The old utterance's completion lands after the new reply is queued.
        engine.events!!.onStart(oldId)
        engine.events!!.onDone(oldId)
        assertEquals(listOf("old:started", "old:stopped:replaced"), events)
        assertTrue(speaker.isSpeaking)
        engine.start("New reply.")
        engine.done("New reply.")
        assertEquals(listOf("old:started", "old:stopped:replaced", "new:started", "new:finished"), events)
    }

    @Test
    fun `focus is requested for the reply only, and abandoned after it finishes`() {
        assertEquals(0, focus.requests)
        speaker.speak("r1", "Hello.", null)
        assertTrue(focus.held)
        engine.start("Hello.")
        engine.done("Hello.")
        assertFalse(focus.held)
        assertEquals(1, focus.requests)
    }

    @Test
    fun `focus is abandoned when the reply stops`() {
        speaker.speak("r1", "Hello.", null)
        speaker.stop("route_lost")
        assertFalse(focus.held)
    }

    @Test
    fun `an utterance the engine drops stops the reply with system`() {
        speaker.speak("r1", "Hello.", null)
        engine.events!!.onLost(engine.idOf("Hello."))
        assertEquals(listOf("r1:stopped:system"), events)
        assertFalse(speaker.isSpeaking)
    }

    @Test
    fun `the picked voice is selected, and an unusable engine or a missing language is unavailable`() {
        speaker.speak("r1", "Hello.", "en-us-x-voice-a")
        assertEquals(listOf<String?>("en-us-x-voice-a"), engine.selected)
        assertEquals(null, speaker.unavailableReason("en-us-x-voice-a"))
        engine.languages.clear()
        assertEquals("no_voice", speaker.unavailableReason(null))
        engine.usable = false
        assertEquals("tts_unavailable", speaker.unavailableReason("en-us-x-voice-a"))
    }

    @Test
    fun `blank parts are not spoken, and an empty reply still finishes`() {
        speaker.begin("r1", null)
        speaker.append("r1", 0, "   ")
        speaker.finish("r1")
        assertTrue(engine.queued.isEmpty())
        assertEquals(listOf("r1:finished"), events)
    }
}
