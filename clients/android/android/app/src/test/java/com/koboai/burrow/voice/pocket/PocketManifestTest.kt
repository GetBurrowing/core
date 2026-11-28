package com.koboai.burrow.voice.pocket

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The pinned constants, against the HF tree API reading recorded in licenses/THIRD_PARTY.md (2026-11-27). */
class PocketManifestTest {
    @Test
    fun `the revision is pinned`() {
        assertEquals("mlboydaisuke/Pocket-TTS-LiteRT", PocketManifest.REPO)
        assertEquals("e0e68d4fb79feb529d7d0f8d0bbfad8d15a18a1e", PocketManifest.REVISION)
        assertEquals(
            "https://huggingface.co/mlboydaisuke/Pocket-TTS-LiteRT/resolve/e0e68d4fb79feb529d7d0f8d0bbfad8d15a18a1e/pt_tokenizer.tsv",
            PocketManifest.url(PocketManifest.MODEL_FILES.last()),
        )
    }

    @Test
    fun `the model files are the ones the synthesizer loads, with their sizes and sha256`() {
        val expected =
            mapOf(
                "pt_flowlm_fused_fp16.tflite" to (169_234_128L to "3e9297e8c997226941b6d21149e7dec96168e08207a07e5a5d972da7d85574a7"),
                "pt_mimi_dec_tx_fp16.tflite" to (17_431_184L to "5e4b277385bb7a2e5c7475d7421479a4b77431d6aa0ded535ae8c067c6edfa38"),
                "pt_mimi_deconly_fp16.tflite" to (10_550_208L to "ea7bd858b8e2841b30be7599e4bfedce7a751d23a9e1946d14101b0440de4e7e"),
                "pt_embed_f16.bin" to (8_194_048L to "82c06e512863fc5b45b14e55e55a911fa2bede6df50e2a7472206af74fc0ac78"),
                "pt_input_linear_f32.bin" to (131_072L to "5f4738bbdba5b4c75ab64c5dfae1e37b884b5e1c7f93c0a1d487dcd5250f17fb"),
                "pt_bos_input_f32.bin" to (4_096L to "184ae4fee2f3c629cc9908a351c8152204c5c076ea1ceae36c23badf8e7cacc8"),
                "pt_neutral_latent_f32.bin" to (128L to "d5f0df1e55dcfcc01ab1f9e7ec41e799bad751911e3adda7f3833cfb7d0aa596"),
                "pt_tokenizer.tsv" to (126_498L to "459022ec19619b30fa5cc807c2c756bf19cbfc14571e64f9fe51e20807a33092"),
            )
        assertEquals(expected, PocketManifest.MODEL_FILES.associate { it.path to (it.size to it.sha256) })
        val loaded =
            Regex("""const val \w+ = "(pt_[^"]+)"""")
                .findAll(File("src/main/java/com/koboai/burrow/voice/pocket/PocketSynthesizer.kt").readText())
                .map { it.groupValues[1] }
                .toSet()
        assertEquals(loaded, expected.keys)
    }

    @Test
    fun `a first use downloads the model and the default voice, 208,767,942 bytes`() {
        assertEquals(PocketManifest.MODEL_FILES.map { it.path } + "voices/pt_voice_marius.bin", PocketManifest.FILES.map { it.path })
        assertEquals(PocketManifest.TOTAL_BYTES, PocketManifest.FILES.sumOf { it.size })
        assertEquals(208_767_942L, PocketManifest.TOTAL_BYTES)
    }

    @Test
    fun `the six published voices, the default first, none from a non-commercial clip`() {
        assertEquals(listOf("marius", "alba", "charles", "eve", "javert", "mary"), PocketManifest.VOICES.map { it.name })
        assertEquals("marius", PocketManifest.VOICE)
        val sizes = PocketManifest.VOICES.associate { it.name to it.file.size }
        assertEquals(3_268_612L, sizes["eve"])
        assertTrue(sizes.filterKeys { it != "eve" }.values.all { it == 3_096_580L })
        assertEquals(
            "261dd8eef5a3e1f20ff5244e0fc9342a0e4d2cf47142353dc486ba621f89e86f",
            PocketManifest.voice("marius")!!.file.sha256,
        )
        PocketManifest.VOICES.forEach { v ->
            assertTrue(v.licence in setOf("CC0", "CC BY 4.0"))
            assertTrue(!v.source.startsWith("expresso/") && !v.source.startsWith("ears/"))
            assertTrue(v.name !in PocketManifest.EXCLUDED_VOICES)
            assertEquals(64, v.file.sha256.length)
        }
        assertEquals("Pocket TTS (Marius)", PocketManifest.voice("marius")!!.rowName)
        assertEquals("pocket-tts:alba", PocketManifest.voice("alba")!!.id)
        assertEquals(null, PocketManifest.voiceFor("pocket-tts:cosette"))
    }

    @Test
    fun `the model is never bundled in the app`() {
        val bundled =
            File("src").walkTopDown().filter { it.isFile && (it.extension == "tflite" || it.name.startsWith("pt_voice_")) }.toList()
        assertTrue("$bundled", bundled.isEmpty())
    }
}
