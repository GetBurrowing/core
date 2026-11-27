package com.koboai.burrow.voice.pocket

import com.getcapacitor.JSObject
import com.koboai.burrow.voice.ReplyVoice
import com.koboai.burrow.voice.VoiceRig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Pocket TTS through the plugin: the gate, the rows, prepareModel, model events, and choosing the speaker. */
@RunWith(RobolectricTestRunner::class)
class BurrowVoicePocketTest {
    @get:Rule val tmp = TemporaryFolder()

    private val gib = 1024L * 1024 * 1024
    private val rig = VoiceRig()
    private var lowRam = false
    private var rtf = 0.3
    private val gate = PocketGate { Triple(35, listOf("arm64-v8a"), lowRam to 12 * gib) }

    private val model = ByteArray(40) { it.toByte() }
    private val voiceBytes = PocketManifest.VOICES.associate { it.name to ByteArray(8) { i -> (it.name.length + i).toByte() } }
    private val fetcher =
        FakeFetcher(mapOf("pt_model.tflite" to model) + voiceBytes.mapKeys { (name, _) -> "pt_voice_$name.bin" })

    private fun voiceFile(name: String) = PocketFile("voices/pt_voice_$name.bin", 8, sha(voiceBytes.getValue(name)))

    private val coreFiles = listOf(PocketFile("pt_model.tflite", 40, sha(model)), voiceFile("marius"))
    private val engine = FakePocketEngine()
    private val output = FakeOutput()
    private val synthesis = ManualWorker()

    private val pocket =
        PocketVoices(
            gate = gate,
            makeStore = {
                PocketModelStore(tmp.root, coreFiles, fetcher, {
                    engine.load()
                    gate.measuredRtf = rtf
                }, { it.run() }, { it() })
            },
            makeVoiceStore = { v -> PocketModelStore(tmp.root, listOf(voiceFile(v.name)), fetcher, null, { it.run() }, { it() }) },
            makeSpeaker = { PocketSpeaker(engine, output, rig.focus, synthesis) { it() } },
            emit = { data -> rig.events.add("model" to data) },
        )

    init {
        rig.plugin.pocket = pocket
        rig.catalog.voices = mutableListOf(ReplyVoice("sys-best", "English (United States)", ReplyVoice.ENHANCED, "en-US"))
    }

    private fun ids(list: JSObject): List<String> {
        val rows = list.getJSONArray("voices")
        return (0 until rows.length()).map { rows.getJSONObject(it).getString("id") }
    }

    private fun ready() {
        assertEquals("ready", rig.plugin.prepareModel("pocket-tts:marius").getString("state"))
    }

    private fun models(): List<JSObject> = rig.events.filter { it.first == "model" }.map { it.second }

    @Test
    fun `the Pocket rows come first, the default voice first, and default stays the best system voice`() {
        val list = rig.plugin.voiceList()
        assertEquals(
            listOf(
                "pocket-tts:marius",
                "pocket-tts:alba",
                "pocket-tts:charles",
                "pocket-tts:eve",
                "pocket-tts:javert",
                "pocket-tts:mary",
                "sys-best",
            ),
            ids(list),
        )
        assertEquals("sys-best", list.getString("default"))
        val row = list.getJSONArray("voices").getJSONObject(0)
        assertEquals("Pocket TTS (Marius)", row.getString("name"))
        assertEquals("neural", row.getString("quality"))
        assertEquals(
            setOf("state", "received", "total"),
            row
                .getJSONObject("model")
                .keys()
                .asSequence()
                .toSet(),
        )
        assertEquals("absent", row.getJSONObject("model").getString("state"))
    }

    @Test
    fun `no Pocket row where the gate says no, or the language is not English`() {
        rig.plugin.languageTag = { "fr-FR" }
        assertTrue(ids(rig.plugin.voiceList()).none { it.startsWith("pocket-tts:") })
        rig.plugin.languageTag = { "en-US" }
        lowRam = true
        assertEquals(listOf("sys-best"), ids(rig.plugin.voiceList()))
    }

    @Test
    fun `prepareModel downloads, sends model events, and resolves the model data`() {
        val r = rig.plugin.prepareModel("pocket-tts:marius")
        assertEquals("ready", r.getString("state"))
        assertEquals(48L, r.getLong("total"))
        val states = models().map { it.getString("state") }.distinct()
        assertEquals(listOf("downloading", "compiling", "ready"), states)
        val received = models().filter { it.getString("state") == "downloading" }.map { it.getLong("received") }
        assertEquals(received.sorted(), received)
        assertTrue("the alba voice is not fetched with the model", fetcher.offsets.size == 2)
    }

    @Test
    fun `where the gate says no, prepareModel is absent with its reason and nothing is downloaded`() {
        lowRam = true
        val r = rig.plugin.prepareModel("pocket-tts:marius")
        assertEquals("absent", r.getString("state"))
        assertEquals("low_ram_device", r.getString("reason"))
        assertTrue(fetcher.offsets.isEmpty())
        assertTrue(
            tmp.root
                .listFiles()
                .orEmpty()
                .isEmpty(),
        )
        val reply = rig.plugin.speakReply("r1", "Hello.", "pocket-tts:marius")
        assertEquals("sys-best", reply.getString("voice"))
        assertTrue(reply.getBoolean("fellBack"))
        assertEquals("unsupported", reply.getString("reason"))
    }

    @Test
    fun `a Pocket voice while the model downloads is read by the best system voice, with fellBack`() {
        var during: JSObject? = null
        fetcher.during = { if (during == null) during = rig.plugin.speakReply("r1", "Hello there.", "pocket-tts:marius") }
        rig.plugin.prepareModel("pocket-tts:marius")
        val r = during!!
        assertTrue(r.getBoolean("spoken"))
        assertEquals("sys-best", r.getString("voice"))
        assertTrue(r.getBoolean("fellBack"))
        assertEquals("model_not_ready", r.getString("reason"))
        assertEquals(listOf("Hello there."), rig.engine.texts())
        assertTrue(engine.asked.isEmpty())
    }

    @Test
    fun `picking Pocket before the model is there starts the download`() {
        val r = rig.plugin.speakReply("r1", "Hello.", "pocket-tts:marius")
        assertEquals("model_not_ready", r.getString("reason"))
        assertEquals(PocketModelState.Ready, pocket.store()!!.state)
    }

    @Test
    fun `once ready, Pocket reads the reply`() {
        ready()
        val r = rig.plugin.speakReply("r1", "Hello.", "pocket-tts:marius")
        assertEquals("pocket-tts:marius", r.getString("voice"))
        assertFalse(r.getBoolean("fellBack"))
        synthesis.runAll()
        assertEquals(listOf("Hello." to "marius"), engine.asked)
        assertTrue(rig.engine.queued.isEmpty())
        assertEquals("started", rig.speech().last())
    }

    @Test
    fun `a slow warm-up flips the session to the system voice, and says too_slow`() {
        rtf = 1.2
        ready()
        assertEquals("too_slow", models().last().getString("reason"))
        assertEquals(listOf("sys-best"), ids(rig.plugin.voiceList()))
        val r = rig.plugin.speakReply("r1", "Hello.", "pocket-tts:marius")
        assertEquals("sys-best", r.getString("voice"))
        assertEquals("unsupported", r.getString("reason"))
        assertTrue(engine.asked.isEmpty())
    }

    @Test
    fun `another voice is fetched only when picked, and the system voice reads meanwhile`() {
        ready()
        assertFalse(java.io.File(tmp.root, "voices/pt_voice_alba.bin").exists())
        val first = rig.plugin.speakReply("r1", "Hello.", "pocket-tts:alba")
        assertEquals("model_not_ready", first.getString("reason"))
        assertTrue(java.io.File(tmp.root, "voices/pt_voice_alba.bin").exists())
        val next = rig.plugin.speakReply("r2", "Hello.", "pocket-tts:alba")
        assertEquals("pocket-tts:alba", next.getString("voice"))
        assertFalse(next.getBoolean("fellBack"))
    }

    @Test
    fun `opening the mic mid-stream sends one stopped mic_opened and drops the pending parts`() {
        ready()
        rig.part("r1", 0, "One.", voice = "pocket-tts:marius")
        synthesis.runOne()
        rig.part("r1", 1, "Two.")
        assertEquals(listOf("started"), rig.speech())

        assertTrue(rig.start().getBoolean("started"))
        assertEquals(listOf("started", "stopped:mic_opened"), rig.speech())
        val later = rig.part("r1", 2, "Three.", final = true)
        assertEquals("stopped", later.getString("reason"))
        synthesis.runAll()
        assertEquals("only the first sentence ever played", 1, output.played.size)
        assertEquals(listOf("One."), engine.asked.map { it.first }.filter { it != "Two." })
        assertEquals(1, rig.speech().count { it.startsWith("stopped") })
    }

    @Test
    fun `a system reply stops a Pocket reply in flight, and the other way round`() {
        ready()
        rig.plugin.speakReply("r1", "Pocket.", "pocket-tts:marius")
        rig.plugin.speakReply("r2", "System.")
        assertEquals(listOf("stopped:replaced"), rig.speech())
    }
}
