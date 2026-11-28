package com.koboai.burrow.voice

import android.speech.SpeechRecognizer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The transcriber's turn logic, against a scripted recognizer session. */
class OnDeviceTranscriberTest {
    private class FakeSession : RecognizerSession {
        var events: RecognizerEvents? = null
        var listens = 0
        var stops = 0
        var cancels = 0
        var destroyed = false
        var languages = mutableListOf<String?>()

        override fun listen(
            languageTag: String?,
            events: RecognizerEvents,
        ) {
            listens++
            languages.add(languageTag)
            this.events = events
        }

        override fun stop() {
            stops++
        }

        override fun cancel() {
            cancels++
        }

        override fun destroy() {
            destroyed = true
        }
    }

    private class FakeScheduler : VoiceScheduler {
        val pending = mutableListOf<() -> Unit>()

        override fun after(
            delayMs: Long,
            task: () -> Unit,
        ): () -> Unit {
            pending.add(task)
            return { pending.remove(task) }
        }

        fun fire() = pending.toList().forEach { it() }
    }

    private object NoProbe : SpeechCapabilityProbe {
        override fun inputs(
            languageTag: String?,
            done: (VoiceCapabilityInputs) -> Unit,
        ) = done(VoiceCapabilityInputs(33, true, languageTag, SpeechAssets.INSTALLED))

        override fun download(
            languageTag: String?,
            done: () -> Unit,
        ) = done()
    }

    private val made = mutableListOf<FakeSession>()
    private val scheduler = FakeScheduler()
    private val transcriber =
        OnDeviceTranscriber(
            sessions = { FakeSession().also { made.add(it) } },
            languageTag = { "en-US" },
            probe = NoProbe,
            scheduler = scheduler,
        )
    private val partials = mutableListOf<String>()
    private val failures = mutableListOf<String>()

    private fun start(): FakeSession {
        assertTrue(transcriber.start({ partials.add(it) }, { failures.add(it) }))
        return made.last()
    }

    private fun finish(): String? {
        var text: String? = null
        transcriber.finish { text = it }
        return text
    }

    @Test
    fun `partials are the whole turn so far, and finish returns the final words`() {
        val session = start()
        assertEquals(listOf<String?>("en-US"), session.languages)
        session.events!!.onPartial("what is")
        session.events!!.onPartial("what is the weather")
        assertEquals(listOf("what is", "what is the weather"), partials)

        var text: String? = null
        transcriber.finish { text = it }
        assertEquals(1, session.stops)
        assertNull("waits for the recognizer's last words", text)
        session.events!!.onResult("what is the weather like today")
        assertEquals("what is the weather like today", text)
        assertTrue(session.destroyed)
    }

    @Test
    fun `a session that ends on silence is restarted, and the turn's words are concatenated`() {
        val session = start()
        session.events!!.onPartial("turn left")
        // The on-device recognizer gives up after a pause, mic still held.
        session.events!!.onResult("turn left")
        assertEquals("restarted at once", 2, session.listens)
        session.events!!.onPartial("at the lights")
        assertEquals("turn left at the lights", partials.last())
        // A silence error ends the next session the same way.
        session.events!!.onError(SpeechRecognizer.ERROR_SPEECH_TIMEOUT)
        assertEquals(3, session.listens)
        session.events!!.onError(SpeechRecognizer.ERROR_NO_MATCH)
        assertEquals(4, session.listens)
        session.events!!.onPartial("then right")

        transcriber.finish { partials.add("final:$it") }
        session.events!!.onResult("then right")
        assertEquals("final:turn left at the lights then right", partials.last())
        assertTrue(failures.isEmpty())
    }

    @Test
    fun `a stale session's late callback is dropped after a restart`() {
        val session = start()
        val old = session.events!!
        old.onResult("one")
        old.onPartial("ghost")
        assertFalse(partials.contains("one ghost"))
    }

    @Test
    fun `nothing heard finishes empty`() {
        val session = start()
        transcriber.finish { partials.add("final:$it") }
        session.events!!.onError(SpeechRecognizer.ERROR_NO_MATCH)
        assertEquals("final:", partials.last())
    }

    @Test
    fun `a recognizer that never answers the stop is cut off with what was heard`() {
        val session = start()
        session.events!!.onPartial("almost")
        var text: String? = null
        transcriber.finish { text = it }
        assertNull(text)
        scheduler.fire()
        assertEquals("almost", text)
        assertTrue(session.destroyed)
        // Its late result changes nothing.
        session.events!!.onResult("almost there")
        assertEquals("almost", text)
    }

    @Test
    fun `a real recognizer error mid-turn is a failure, not a restart`() {
        val session = start()
        session.events!!.onError(SpeechRecognizer.ERROR_AUDIO)
        assertEquals(listOf(OnDeviceTranscriber.REASON_RECOGNIZER_ERROR), failures)
        assertEquals(1, session.listens)
        assertTrue(session.destroyed)
    }

    @Test
    fun `cancel discards the turn and closes the recognizer`() {
        val session = start()
        session.events!!.onPartial("never mind")
        transcriber.cancel()
        assertTrue(session.destroyed)
        assertEquals(1, session.cancels)
        assertEquals("", finish())
    }

    @Test
    fun `a new turn starts clean, and answers a finish still waiting`() {
        val first = start()
        first.events!!.onResult("first turn")
        var text: String? = null
        transcriber.finish { text = it }
        val second = start()
        assertEquals("first turn", text)
        assertTrue(first.destroyed)
        second.events!!.onPartial("second")
        assertEquals("second", partials.last())
    }
}
