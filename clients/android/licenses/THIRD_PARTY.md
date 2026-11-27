# Android Voice: third-party runtimes, weights and voices

Read and re-verified on 2026-11-27 (task 01a21e4a stage 1) from the Hugging Face
API (`/api/models/<repo>` and `/api/models/<repo>/tree/<revision>?recursive=true`),
the GitHub API, and Google's Maven repository. The iOS reading this extends is
`clients/ios/ios/App/App/Voice/PocketTTS/THIRD_PARTY.md` (task 01a20fdd); the
voice-to-clip proof below reuses it.

Nothing listed here is bundled in the APK or AAB except the LiteRT runtime
libraries (stage 3 adds the dependency). The model files and voices are
downloaded on first use from the pinned revision.

## Verdict

Shippable in a commercial app, with the visible attribution line
"Pocket TTS by Kyutai · CC BY 4.0" (the server already renders it in the
"Reply voice" sheet: `voice_components.ex`, `pocket_credit/1`). Every licence
below allows redistribution and commercial use. Kyutai's prohibited uses apply
(quoted below). No voice is cloned: none of the files below contains the Mimi
encoder, and no reference audio is ever used.

Feasibility on Android: the LiteRT graphs load and run on the x86_64 emulator
on CPU (measured, see "Emulator probe"), so the STOP rule did not fire and
Pocket TTS stays the chosen runtime.

## Speech input

On-device speech input uses Android's own `SpeechRecognizer`
(`createOnDeviceSpeechRecognizer`, API 31+) and the recognition models the
system manages. The app ships no speech model and no third-party code for it.

## LiteRT runtime (a Maven dependency from stage 3)

- Artifact: `com.google.ai.edge.litert:litert:2.1.6`,
  https://dl.google.com/android/maven2/com/google/ai/edge/litert/litert/2.1.6/litert-2.1.6.aar
  (11,542,373 bytes, SHA-256
  `6bbbf3e1fedb7504d9f4ea492b9ee35b9d6e1185476601c987d7ec88a4ba31ed`). It
  depends on `litert-api:2.1.6` (1,316,955 bytes, SHA-256
  `985e2fe0924312c903f8bab3914bd63f9a38dc268543dab1d29f00762fb9ab20`),
  which carries `liblitert_jni.so`. The POM of each names "The Apache Software
  License, Version 2.0". `litert-api`'s POM also pulls in lifecycle-runtime,
  guava, kotlinx-coroutines-guava and ai-delivery; stage 3 records the APK
  size those add.
- Native libraries: `libLiteRt.so` and `libLiteRtClGlAccelerator.so` for
  `arm64-v8a`, `armeabi-v7a` and `x86_64` (no 32-bit `x86`). No ABI filter is
  set, so the x86_64 emulator gets its own libraries.
- Licence: Apache-2.0. The AAR's own `LICENSE` (13,575 bytes, SHA-256
  `71c6915d04265772a0339bed47276942c678b45cc01534210ebe6984fd1aec65`: the
  Apache-2.0 text plus the notices of code TensorFlow derives from) is kept
  verbatim in `LiteRT-Apache-2.0.txt` beside this file. Each AAR also carries a
  9,026,393-byte `THIRD_PARTY_NOTICE.txt`; stage 3 decides how the app shows it
  (it ships inside the AAR either way).
- Upstream: https://github.com/google-ai-edge/LiteRT.

## Android sample code (MIT, ported in stage 3)

- https://github.com/john-rocky/LiteRT-Models, path `pockettts/`.
- Pinned commit: `823729ddaa4d4f148ee40e5b6f960ea576453f6c`
  (2026-09-17), the last commit on that path; `main` was
  `5adaa31a7e733cb126f30ec25652e020ee723ece` when read and `pockettts/` is
  unchanged there.
- Licence: MIT (GitHub API `license.spdx_id`). The `LICENSE` file is NOT in the
  tree at `823729dd`: it was added by the next commit,
  `b669b3c04e09295e629f4cbe6111c8e94202b9d7` ("LICENSE: MIT for the code in
  this repository"), whose compare against `823729dd` changes only `LICENSE`.
  That text (git blob `3bd190bd1915e2755ce74dc28647117355c368d6`, SHA-256
  `b9c556fb5df9d9d1578d1b8e9f1b0d8f196e36d1ebbd4aab7c90016209df5103`) is kept
  verbatim in `LiteRT-Models-MIT.txt` beside this file.
- Files stage 3 ports: `app/src/main/java/com/pockettts/PocketTtsSynthesizer.kt`
  (19,066 bytes) and `SpTokenizer.kt` (5,059 bytes). Not taken: the sample's
  `MainActivity.kt`, `WaveformView.kt`, the conversion script, and its
  `abiFilters += setOf("arm64-v8a")`.

## Pocket TTS LiteRT graphs (downloaded)

- https://huggingface.co/mlboydaisuke/Pocket-TTS-LiteRT
- Pinned revision: `e0e68d4fb79feb529d7d0f8d0bbfad8d15a18a1e`
  (lastModified 2026-10-02, also the current `sha` when read).
- Licence: cc-by-4.0 (card and API tag), `gated: false`. The card says the
  weights were converted from `kyutai/pocket-tts` (Kyutai, CC BY 4.0) and that
  the graphs cover the preset-voice path only: "Voice cloning needs the Mimi
  *encoder*, whose weights ship only in the gated kyutai/pocket-tts repo".
  Its host code reads the tokenizer from `kyutai/pocket-tts-without-voice-cloning`.
- Files the sample loads (the constants in `PocketTtsSynthesizer.kt`: three
  graphs, the flow head being fused into the language model), with the tree
  API's size and `lfs.oid` (SHA-256):

| File | Bytes | SHA-256 |
| --- | --- | --- |
| `pt_flowlm_fused_fp16.tflite` | 169,234,128 | `3e9297e8c997226941b6d21149e7dec96168e08207a07e5a5d972da7d85574a7` |
| `pt_mimi_dec_tx_fp16.tflite` | 17,431,184 | `5e4b277385bb7a2e5c7475d7421479a4b77431d6aa0ded535ae8c067c6edfa38` |
| `pt_mimi_deconly_fp16.tflite` | 10,550,208 | `ea7bd858b8e2841b30be7599e4bfedce7a751d23a9e1946d14101b0440de4e7e` |
| `pt_embed_f16.bin` | 8,194,048 | `82c06e512863fc5b45b14e55e55a911fa2bede6df50e2a7472206af74fc0ac78` |
| `pt_input_linear_f32.bin` | 131,072 | `5f4738bbdba5b4c75ab64c5dfae1e37b884b5e1c7f93c0a1d487dcd5250f17fb` |
| `pt_bos_input_f32.bin` | 4,096 | `184ae4fee2f3c629cc9908a351c8152204c5c076ea1ceae36c23badf8e7cacc8` |
| `pt_neutral_latent_f32.bin` | 128 | `d5f0df1e55dcfcc01ab1f9e7ec41e799bad751911e3adda7f3833cfb7d0aa596` |
| `pt_tokenizer.tsv` | 126,498 | `459022ec19619b30fa5cc807c2c756bf19cbfc14571e64f9fe51e20807a33092` |

  `pt_tokenizer.tsv` is not an LFS file, so the API gives only its git blob id
  (`db02b7699a575b11c8a55d39eea27778ec8c10fb`); its SHA-256 was computed from
  the pinned `resolve` download, whose `git hash-object` matched that blob id.
  The three graphs were also downloaded and re-hashed, and matched.
- Total: 205,671,362 bytes for the model, 208,767,942 with the default voice
  (marius), 224,422,874 with all six voices. iOS downloads 437,400,422.
- Not used: the fp32 graphs, the split `pt_flowlm_step*` and `pt_flow_head*`
  graphs, `assets/` and `samples/`.

## Kyutai's terms

`kyutai/pocket-tts` (gated: auto) and `kyutai/pocket-tts-without-voice-cloning`
(gated: false) are both cc-by-4.0 per the API. Both cards carry the same
prohibited-use text (`extra_gated_prompt`), verbatim:

> Prohibited use: Use of our model must comply with all applicable laws and
> regulations and must not result in, involve, or facilitate any illegal,
> harmful, deceptive, fraudulent, or unauthorized activity. Prohibited uses
> include, without limitation, voice impersonation or cloning without explicit
> and lawful consent; misinformation, disinformation, or deception (including
> fake news, fraudulent calls, or presenting generated content as genuine
> recordings of real people or events); and the generation of unlawful,
> harmful, libelous, abusive, harassing, discriminatory, hateful, or
> privacy-invasive content. We disclaim all liability for any non-compliant use.

None of this forbids redistribution or commercial use. The app reads an agent's
reply in a preset voice and never presents it as a recording of a person.

## The voices

The repository publishes six voices, `voices/pt_voice_<name>.bin`: Kyutai's
published per-voice prompt states, repacked for the packed-KV layout. Each name
is mapped to its source clip by `_ORIGINS_OF_PREDEFINED_VOICES` in
`kyutai-labs/pocket-tts` at `677126be9e236d84283fe0d4c5ac666fee1f1777`
(`pocket_tts/utils/utils.py`), the same table and revision the iOS reading
used. The clip licences are those of `kyutai/tts-voices` at
`323332d33f997de8394f24a193e1a76df720e01a` (iOS THIRD_PARTY, "How each voice's
source is proven"). The card's own table agrees ("alba: alba-mackenna, CC BY
4.0; marius, javert: Kyutai voice donations, CC0; charles, mary, eve: VCTK
corpus, CC BY 4.0").

| Voice | Source clip in kyutai/tts-voices | Licence | Bytes | SHA-256 |
| --- | --- | --- | --- | --- |
| `marius` (default) | `voice-donations/Selfie.wav` | CC0 | 3,096,580 | `261dd8eef5a3e1f20ff5244e0fc9342a0e4d2cf47142353dc486ba621f89e86f` |
| `javert` | `voice-donations/Butter.wav` | CC0 | 3,096,580 | `d9bc65bad1c86041200d5e6b090802867ed32e8a76e07b52774d86d821b62dfb` |
| `alba` | `alba-mackenna/casual.wav` | CC BY 4.0 | 3,096,580 | `f0f15ebfae5aa690ed3a3f25b478198d1892bd3022f39ca738ced07fcaec8e7b` |
| `charles` | `vctk/p254_023_enhanced.wav` | CC BY 4.0 | 3,096,580 | `1ab35c90e580a4413b7391419c854b1bd644329692e3a0b15caa76c816aec32a` |
| `mary` | `vctk/p333_023_enhanced.wav` | CC BY 4.0 | 3,096,580 | `b872ee2e16f04726968c7217575e3986712586345787a65da0494b74c9f21cdd` |
| `eve` | `vctk/p361_023_enhanced.wav` | CC BY 4.0 | 3,268,612 | `6a8a1391bbfc12c7b861708f82a3b39946baf178928b05915f359c327332af6f` |

No voice traces to `expresso/` or `ears/` (CC BY-NC); `cosette` and `jean`,
which do, are not published in this repository and are refused.

Credit for the CC BY 4.0 clips: `alba`, voice by Alba MacKenna; `charles`,
`mary` and `eve`, CSTR VCTK Corpus, Centre for Speech Technology Research,
University of Edinburgh. All used unmodified as conditioning for the states.

## Rejected: sherpa-onnx

`k2-fsa/sherpa-onnx` (Apache-2.0; release v2.0.3, 2026-11-22, with
`sherpa-onnx-2.0.3.aar`, 52,411,426 bytes) runs Pocket TTS on Android
(`csukuangfj2/sherpa-onnx-pocket-tts-int8-2026-01-26`, 198,312,544 bytes). It is
rejected because its Kotlin API voices every reply from a reference WAV: in
`kotlin-api-examples/test_pocket_tts.kt` the config names
`pocketEncoder = "encoder.onnx"` and generation passes
`referenceAudio = wave.samples`, and `sherpa-onnx/kotlin-api/Tts.kt`
(`GenerationConfig.referenceAudio`) has no preset-voice path. That is zero-shot
cloning through the Mimi encoder, which ships only in the gated cloning
checkpoint and which the iOS verdict excludes ("Cloning is not used").
`KevinAHM/pocket-tts-onnx` is Python only and fetches its built-in voice
states from the gated `kyutai/pocket-tts`, so it was not considered further.

## Emulator probe (feasibility, 2026-11-27)

A throwaway debug build (never committed) added `litert:2.1.6` and loaded each
graph with `CompiledModel.create(path, Options(Accelerator.CPU))`, then ran it
twice on zero inputs. API 35 google_apis x86_64 emulator (4 cores, 4 GB),
`primaryCpuAbi=x86_64`, `liblitert_jni.so` loaded from `lib/x86_64`, XNNPACK
CPU delegate:

| Graph | Load | Run 1 | Run 2 | Output |
| --- | --- | --- | --- | --- |
| `pt_mimi_dec_tx_fp16` | 53 ms | 183 ms | 158 ms | 524,288 floats, all finite |
| `pt_mimi_deconly_fp16` | 7 ms | 32,161 ms | 30,147 ms | 491,520 samples, all finite |
| `pt_flowlm_fused_fp16` | 301 ms | 47 ms | 15 ms | 12,321 floats, all finite |

Process PSS after the SEANet decoder: 1,447,104 kB. These are emulator CPU
numbers and say nothing about a phone's GPU. The SEANet decoder runs one fixed
256-frame window (20.48 s of audio) per call, about 30 s on this CPU, so the
emulator will not reach real time on CPU and stage 3's `too_slow` gate is
expected to fire there.
