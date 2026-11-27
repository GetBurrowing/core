package com.koboai.burrow.voice.pocket

/** One file Pocket TTS needs, pinned to [PocketManifest.REVISION]. */
data class PocketFile(
    /** Path in the repository, and under the model directory. */
    val path: String,
    val size: Long,
    /** SHA-256 of the content: the HF tree API's `lfs.oid`, or computed from the pinned download (non-LFS). */
    val sha256: String,
)

/** One published voice: its prompt state, the kyutai/tts-voices clip it came from, and that clip's licence. */
data class PocketVoice(
    val name: String,
    val file: PocketFile,
    val source: String,
    val licence: String,
) {
    /** "marius" -> "Marius". */
    val displayName: String get() = name.split('_').joinToString(" ") { it.replaceFirstChar(Char::uppercase) }

    /** The row's id in the voice list: `pocket-tts:<name>`. */
    val id: String get() = PocketManifest.PREFIX + name

    /** "Pocket TTS (Marius)". */
    val rowName: String get() = "Pocket TTS ($displayName)"
}

/**
 * What Pocket TTS downloads on first use (task 01a21e4a stage 3), read from
 * the HF API on 2026-11-27. Sources, licences and the voice-to-clip proof are
 * in `clients/android/licenses/THIRD_PARTY.md`. Mirrors iOS
 * `PocketTTSManifest` (`PocketTTSSupport.swift`).
 */
object PocketManifest {
    /** LiteRT graphs converted from Kyutai's Pocket TTS, CC BY 4.0, ungated (no token). */
    const val REPO = "mlboydaisuke/Pocket-TTS-LiteRT"
    const val REVISION = "e0e68d4fb79feb529d7d0f8d0bbfad8d15a18a1e"
    const val PREFIX = "pocket-tts:"

    /** The default voice, downloaded with the model. */
    const val VOICE = "marius"

    /** The model: the three graphs and the host-side tables `PocketTtsSynthesizer` loads. */
    val MODEL_FILES =
        listOf(
            PocketFile("pt_flowlm_fused_fp16.tflite", 169_234_128, "3e9297e8c997226941b6d21149e7dec96168e08207a07e5a5d972da7d85574a7"),
            PocketFile("pt_mimi_dec_tx_fp16.tflite", 17_431_184, "5e4b277385bb7a2e5c7475d7421479a4b77431d6aa0ded535ae8c067c6edfa38"),
            PocketFile("pt_mimi_deconly_fp16.tflite", 10_550_208, "ea7bd858b8e2841b30be7599e4bfedce7a751d23a9e1946d14101b0440de4e7e"),
            PocketFile("pt_embed_f16.bin", 8_194_048, "82c06e512863fc5b45b14e55e55a911fa2bede6df50e2a7472206af74fc0ac78"),
            PocketFile("pt_input_linear_f32.bin", 131_072, "5f4738bbdba5b4c75ab64c5dfae1e37b884b5e1c7f93c0a1d487dcd5250f17fb"),
            PocketFile("pt_bos_input_f32.bin", 4_096, "184ae4fee2f3c629cc9908a351c8152204c5c076ea1ceae36c23badf8e7cacc8"),
            PocketFile("pt_neutral_latent_f32.bin", 128, "d5f0df1e55dcfcc01ab1f9e7ec41e799bad751911e3adda7f3833cfb7d0aa596"),
            // Not LFS: SHA-256 of the pinned download, whose git blob id matched the API's.
            PocketFile("pt_tokenizer.tsv", 126_498, "459022ec19619b30fa5cc807c2c756bf19cbfc14571e64f9fe51e20807a33092"),
        )

    /** Every published voice, the default first. None traces to a CC BY-NC clip. */
    val VOICES =
        listOf(
            voice(
                "marius",
                3_096_580,
                "261dd8eef5a3e1f20ff5244e0fc9342a0e4d2cf47142353dc486ba621f89e86f",
                "voice-donations/Selfie.wav",
                "CC0",
            ),
            voice(
                "alba",
                3_096_580,
                "f0f15ebfae5aa690ed3a3f25b478198d1892bd3022f39ca738ced07fcaec8e7b",
                "alba-mackenna/casual.wav",
                "CC BY 4.0",
            ),
            voice(
                "charles",
                3_096_580,
                "1ab35c90e580a4413b7391419c854b1bd644329692e3a0b15caa76c816aec32a",
                "vctk/p254_023_enhanced.wav",
                "CC BY 4.0",
            ),
            voice(
                "eve",
                3_268_612,
                "6a8a1391bbfc12c7b861708f82a3b39946baf178928b05915f359c327332af6f",
                "vctk/p361_023_enhanced.wav",
                "CC BY 4.0",
            ),
            voice(
                "javert",
                3_096_580,
                "d9bc65bad1c86041200d5e6b090802867ed32e8a76e07b52774d86d821b62dfb",
                "voice-donations/Butter.wav",
                "CC0",
            ),
            voice(
                "mary",
                3_096_580,
                "b872ee2e16f04726968c7217575e3986712586345787a65da0494b74c9f21cdd",
                "vctk/p333_023_enhanced.wav",
                "CC BY 4.0",
            ),
        )

    /** Kyutai voices whose clips are CC BY-NC (expresso, ears): never listed or fetched. */
    val EXCLUDED_VOICES = setOf("cosette", "jean")

    /** What a first use downloads: the model and the default voice. */
    val FILES: List<PocketFile> get() = MODEL_FILES + voice(VOICE)!!.file

    /** Every byte of [FILES]. */
    const val TOTAL_BYTES = 208_767_942L

    fun voice(name: String): PocketVoice? = VOICES.firstOrNull { it.name == name }

    fun isPocket(id: String?): Boolean = id?.startsWith(PREFIX) == true

    /** The listed voice an id names; null for anything else (an excluded voice included). */
    fun voiceFor(id: String?): PocketVoice? = if (isPocket(id)) voice(id!!.removePrefix(PREFIX)) else null

    /** `https://huggingface.co/<repo>/resolve/<revision>/<path>`. */
    fun url(file: PocketFile): String = "https://huggingface.co/$REPO/resolve/$REVISION/${file.path}"

    private fun voice(
        name: String,
        size: Long,
        sha256: String,
        source: String,
        licence: String,
    ) = PocketVoice(name, PocketFile("voices/pt_voice_$name.bin", size, sha256), source, licence)
}
