package com.koboai.burrow.voice.pocket

import com.koboai.burrow.voice.FakeFocus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A scripted Pocket engine: one second of PCM per sentence, and a record of what was asked. */
class FakePocketEngine : PocketEngine {
    val asked = mutableListOf<Pair<String, String>>()
    var releases = 0
    var fail = false
    override var isLoaded = false

    override fun load(): String {
        isLoaded = true
        return "lm:CPU dectx:CPU dec:CPU"
    }

    override fun synthesize(
        text: String,
        voice: String,
        cancelled: () -> Boolean,
    ): FloatArray {
        asked.add(text to voice)
        if (fail) throw IllegalStateException("graph")
        return FloatArray(24_000) { 0.5f }
    }

    override fun release() {
        releases++
        isLoaded = false
    }
}

/** Records what would play; [finishAll] says it all played. */
class FakeOutput : PcmOutput {
    val played = mutableListOf<Int>()
    private val pending = mutableListOf<() -> Unit>()
    var stops = 0

    override fun play(
        samples: FloatArray,
        done: () -> Unit,
    ) {
        played.add(samples.size)
        pending.add(done)
    }

    override fun stop() {
        stops++
        pending.clear()
    }

    override fun release() = Unit

    fun finishOne() = pending.removeAt(0)()

    fun finishAll() {
        while (pending.isNotEmpty()) finishOne()
    }
}

/** A worker that runs only when told: a sentence can still be "synthesizing" when the reply stops. */
class ManualWorker : java.util.concurrent.Executor {
    val queue = ArrayDeque<Runnable>()

    override fun execute(command: Runnable) {
        queue.addLast(command)
    }

    fun runOne() = queue.removeFirst().run()

    fun runAll() {
        while (queue.isNotEmpty()) runOne()
    }
}

class PocketSpeakerTest {
    private val engine = FakePocketEngine()
    private val output = FakeOutput()
    private val focus = FakeFocus()
    private val worker = ManualWorker()
    private val speaker = PocketSpeaker(engine, output, focus, worker) { it() }
    private val events = mutableListOf<String>()

    init {
        speaker.onEvent = { e -> events.add("${e.id}:${e.state}" + (e.reason?.let { ":$it" } ?: "")) }
    }

    @Test
    fun `sentence 1 plays while sentence 2 synthesizes, one sentence at a time, in order`() {
        speaker.begin("r1", "pocket-tts:alba")
        speaker.append("r1", 0, "One.")
        speaker.append("r1", 1, "Two.")
        assertEquals("one synthesis at a time", 1, worker.queue.size)
        worker.runOne()
        assertEquals(listOf("One." to "alba"), engine.asked)
        assertEquals(1, output.played.size)
        assertEquals(listOf("r1:started"), events)
        assertEquals("the next sentence is already synthesizing", 1, worker.queue.size)
        speaker.finish("r1")
        worker.runOne()
        assertEquals(listOf("One.", "Two."), engine.asked.map { it.first })
        output.finishOne()
        assertEquals(listOf("r1:started"), events)
        output.finishOne()
        assertEquals(listOf("r1:started", "r1:finished"), events)
        assertFalse(focus.held)
    }

    @Test
    fun `a missing voice id reads in the default voice`() {
        speaker.speak("r1", "Hello.", null)
        worker.runAll()
        assertEquals("marius", engine.asked.single().second)
    }

    @Test
    fun `stop is synchronous and sends exactly one stopped, and a late sentence is dropped`() {
        speaker.begin("r1", null)
        speaker.append("r1", 0, "One.")
        speaker.stop("mic_opened")
        assertEquals(1, output.stops)
        assertFalse(focus.held)
        assertEquals(listOf("r1:stopped:mic_opened"), events)
        // The sentence that was synthesizing finishes after the stop: never played.
        worker.runAll()
        assertTrue(output.played.isEmpty())
        speaker.stop("mic_opened")
        assertEquals(listOf("r1:stopped:mic_opened"), events)
    }

    @Test
    fun `a replaced reply's late sentence does not play in the next reply`() {
        speaker.begin("old", null)
        speaker.append("old", 0, "Old sentence.")
        speaker.begin("new", null)
        speaker.append("new", 0, "New sentence.")
        speaker.finish("new")
        // The old reply's synthesis completes first.
        worker.runOne()
        assertTrue("${output.played}", output.played.isEmpty())
        assertEquals(listOf("old:stopped:replaced"), events)
        worker.runOne()
        assertEquals(1, output.played.size)
        output.finishAll()
        assertEquals(listOf("old:stopped:replaced", "new:started", "new:finished"), events)
    }

    @Test
    fun `parts arriving out of order are synthesized in seq order`() {
        speaker.begin("r1", null)
        speaker.append("r1", 1, "Two.")
        assertTrue(worker.queue.isEmpty())
        speaker.append("r1", 0, "One.")
        worker.runAll()
        assertEquals(listOf("One.", "Two."), engine.asked.map { it.first })
    }

    @Test
    fun `an engine failure stops the reply with system`() {
        engine.fail = true
        speaker.speak("r1", "Hello.", null)
        worker.runAll()
        assertEquals(listOf("r1:stopped:system"), events)
        assertFalse(speaker.isSpeaking)
    }

    @Test
    fun `the model is released when idle, never mid-reply`() {
        speaker.begin("r1", null)
        speaker.append("r1", 0, "One.")
        speaker.releaseIfIdle()
        worker.runAll()
        assertEquals(0, engine.releases)
        speaker.finish("r1")
        output.finishAll()
        speaker.releaseIfIdle()
        worker.runAll()
        assertEquals(1, engine.releases)
    }

    @Test
    fun `each sentence drops the decoder start-up frame and fades in and out`() {
        val pcm = FloatArray(24_000) { 1f }
        val shaped = PocketSpeaker.shaped(pcm)
        assertEquals(24_000 - 1_920, shaped.size)
        assertEquals(0f, shaped.first())
        assertTrue(shaped[239] < 1f && shaped[240] == 1f)
        assertEquals(0f, shaped.last())
        assertTrue(shaped[shaped.size - 121] == 1f)
        assertEquals(0, PocketSpeaker.shaped(FloatArray(1_920)).size)
    }
}
