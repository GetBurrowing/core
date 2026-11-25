# Pocket TTS: third-party code, weights and voices

Read and re-verified on 2026-11-24 (task 01a20fdd stage 1) from the Hugging Face
API (`/api/models/<repo>` and `/api/models/<repo>/tree/<revision>`) and the
GitHub API. Nothing below is bundled in the app binary except the vendored
Swift sources; the weights are downloaded on first use from the pinned revisions.

## Verdict

Shippable in a commercial app, provided a visible attribution line is shown
("Pocket TTS by Kyutai · CC BY 4.0"; stage 3 renders it). Kyutai's
prohibited-use terms apply: no voice impersonation or cloning without consent,
no deception, no presenting output as genuine recordings of real people.
Cloning is not used: the gated `kyutai/pocket-tts` checkpoint is NOT downloaded.

## Swift host (vendored here)

- Source: https://github.com/RahulRachuri/pocket-tts-swift
- Pinned commit: `50c08f8407bc5067dcdf4d42cf14ce16d3fa5398` (2026-08-25, tag
  v0.1.0 line), `Sources/PocketTTSKit/`
- Licence: Apache-2.0 (GitHub API `license.spdx_id`; full text in `LICENSE`
  here). The repository has no NOTICE file at that commit, so there is none to
  carry. It has no third-party dependencies.
- Vendored files: Chunker.swift, CoreAIGraph.swift, HubStore.swift,
  SafeTensors.swift, SentencePiece.swift, TorchRandom.swift, TTSPipeline.swift,
  TTSPipeline+Hub.swift, WAV.swift, Weights.swift.
- Not vendored: GraphProbe.swift (a graph-inspection debug tool), the
  `pocket-tts-cli` executable, the Python conversion scripts.
- Local changes, and only these: each file is wrapped in
  `#if canImport(CoreAI)` (the iOS simulator SDK has no CoreAI) and every
  top-level declaration carries `@available(iOS 27, *)`, because the app's
  deployment target is iOS 17 and CoreAI is weak-linked (project.yml). Each file
  starts with a header saying so.
- Lint: these ten files are excluded from `swift-format lint` as vendored code.
  The excluded list is exactly the files named above.

## Upstream code

- https://github.com/kyutai-labs/pocket-tts, MIT (GitHub API), main at
  `bc4d640c925a3782092a841e9bc7ba442a65a838` when read. The Swift host traces
  its Python package; no source from it is vendored here.

## Core AI bundles (downloaded)

- https://huggingface.co/rahulrachuri/pocket-tts-coreai
- Pinned revision: `d774360b912aa70d217e34204cef1cebfdadadd1` (also the
  current main sha when read)
- Licence: cc-by-4.0 (model card and API tag), `gated: false`. Derived from
  `kyutai/pocket-tts-without-voice-cloning`; its README names the source
  checkpoint revision `e041936c75475d350b405bc870bcf7c22da4e9e6`.
- Files used: `config.json` and the fp16 `flowlm_float16_s512.aimodel/`,
  `flow_decoder_float16_lsd1.aimodel/`, plus
  `mimi_decoder_float32_ring272_outer_q_gs.aimodel/` (fp32 at every setting).
- The model-zoo page `john-rocky/coreai-model-zoo` (models/pocket-tts) only
  points at these two repositories; nothing is taken from it.

## Kyutai weights (downloaded)

- https://huggingface.co/kyutai/pocket-tts-without-voice-cloning
- Pinned revision: `e041936c75475d350b405bc870bcf7c22da4e9e6` (2026-05-04).
  This is the revision the Core AI bundles were converted from and the one the
  Swift host pins. The repository's main is now `a7056f505a4a8ca72d8b5fb1440071d6f1a35739`
  (2026-10-21), whose `languages/english/model.safetensors` has a different
  sha256, so it is NOT used with these bundles.
- Licence at both revisions: cc-by-4.0, `gated: false` per the API.
  Commercial use allowed with attribution to Kyutai.
- Files used: `languages/english/model.safetensors`,
  `languages/english/tokenizer.model`, and the voice embeddings below.
- The cloning checkpoint `kyutai/pocket-tts` is `gated: auto` and is not used.

## The voices

Twenty built-in voices of the pinned weights are listed (task 01a20fdd stage 4,
read 2026-11-25): every one whose source clip in `kyutai/tts-voices` is CC0 or
CC BY 4.0. `marius` is the default and comes with the model; each of the others
is one embedding, `languages/english/embeddings/<name>.safetensors` at
`e041936c`, fetched only when it is picked (3.7 to 8.3 MB; 124.4 MB for all
nineteen). Each is pinned in `PocketTTSManifest.voices` by size and SHA-256, the
HF tree API's `lfs.oid`; all twenty were re-downloaded from the pinned `resolve`
URL and re-hashed on rock, and all matched.

### How each voice's source is proven

Two statements made at the pinned revision, which agree wherever both speak:

1. The weights README at `e041936c` (line 70 on) maps eight names to clips:
   alba, marius, javert, jean, fantine, cosette, eponine, azelma.
2. The upstream library that computed and published those embeddings,
   `kyutai-labs/pocket-tts` at `677126be9e236d84283fe0d4c5ac666fee1f1777`
   (2026-05-04, v2.1.0, the same day as `e041936c`),
   `pocket_tts/utils/utils.py`: `_ORIGINS_OF_PREDEFINED_VOICES` maps all
   twenty-six names to their clips, and in the same file
   `get_predefined_voice` resolves a name to
   `.../languages/{language}/embeddings/{name}.safetensors@e041936c75475d350b405bc870bcf7c22da4e9e6`,
   so the table describes exactly these files.

The repository's later README (main, `a7056f50`) gives the same clips, but its
embeddings were recomputed (every sha256 differs), so it is not used as proof.

Each clip exists in `kyutai/tts-voices` at `323332d33f997de8394f24a193e1a76df720e01a`
(an LFS redirect, HTTP 302, for each). Licences, from that repo's README at the
same revision:

- `voice-donations/`: "Voices of volunteers submitted through our Unmute Voice
  Donation Project, licensed as CC0."
- `voice-zero/`: voices from Voice-Zero, a curated selection from LibriVox,
  "Released under the CC0 licence."
- `unmute-prod-website/`: three named exceptions (`degaulle-2.wav`,
  `ex04_narration_longform_00001.wav`, `p329_022.wav`); "The others are our own
  recordings and you may use them as CC0." `developpeuse-3.wav` is not an
  exception. The library pins it at `1fc7395b`; its LFS oid there and at
  `323332d3` is the same (`d14dc373…`), so the statement covers that file.
- `alba-mackenna/`: voice-acted by Alba MacKenna, "Released under the CC BY 4.0
  licence."
- `vctk/`: from the Voice Cloning Toolkit dataset (CSTR, University of
  Edinburgh), "licensed under the Creative Commons License: Attribution 4.0
  International."

| Voice | Source clip in kyutai/tts-voices | Licence | Bytes | SHA-256 |
| --- | --- | --- | --- | --- |
| `marius` | `voice-donations/Selfie.wav` | CC0 | 6,194,424 | `04f84efcb77a…` |
| `javert` | `voice-donations/Butter.wav` | CC0 | 6,194,424 | `0ae88e03ca4e…` |
| `bill_boerst` | `voice-zero/bill_boerst.wav` | CC0 | 6,735,096 | `75610127d44e…` |
| `caro_davy` | `voice-zero/caro_davy.wav` | CC0 | 5,260,536 | `a5961b63a2e7…` |
| `peter_yearsley` | `voice-zero/peter_yearsley.wav` | CC0 | 3,736,816 | `dd977a6e1559…` |
| `stuart_bell` | `voice-zero/stuart_bell.wav` | CC0 | 5,260,536 | `5a49da7ca5df…` |
| `estelle` | `unmute-prod-website/developpeuse-3.wav` | CC0 | 8,258,808 | `ccebef7f5176…` |
| `alba` | `alba-mackenna/casual.wav` | CC BY 4.0 | 6,194,424 | `69c32db63ca5…` |
| `anna` | `vctk/p228_023_enhanced.wav` | CC BY 4.0 | 7,816,440 | `5ea82f78db00…` |
| `vera` | `vctk/p229_023_enhanced.wav` | CC BY 4.0 | 6,735,096 | `4bf50ddd957b…` |
| `fantine` | `vctk/p244_023_enhanced.wav` | CC BY 4.0 | 6,538,488 | `51a8a4355d7f…` |
| `charles` | `vctk/p254_023_enhanced.wav` | CC BY 4.0 | 6,194,424 | `299edc20182e…` |
| `paul` | `vctk/p259_023_enhanced.wav` | CC BY 4.0 | 6,980,856 | `ed7a019168f9…` |
| `eponine` | `vctk/p262_023_enhanced.wav` | CC BY 4.0 | 6,931,704 | `bda3b76a384f…` |
| `azelma` | `vctk/p303_023_enhanced.wav` | CC BY 4.0 | 7,963,896 | `9f3e69f29075…` |
| `george` | `vctk/p315_023_enhanced.wav` | CC BY 4.0 | 6,243,576 | `0c1c6c57c55a…` |
| `mary` | `vctk/p333_023_enhanced.wav` | CC BY 4.0 | 6,194,424 | `a8f2adf260ca…` |
| `jane` | `vctk/p339_023_enhanced.wav` | CC BY 4.0 | 7,374,072 | `37386227ca8e…` |
| `michael` | `vctk/p360_023_enhanced.wav` | CC BY 4.0 | 7,275,768 | `8937f724ac47…` |
| `eve` | `vctk/p361_023_enhanced.wav` | CC BY 4.0 | 6,538,488 | `ea9c2faf862a…` |

Credit for the CC BY 4.0 clips: `alba`, voice by Alba MacKenna; the twelve `vctk`
voices, CSTR VCTK Corpus, Centre for Speech Technology Research, University of
Edinburgh. Both CC BY 4.0, used unmodified as conditioning for the embeddings.

`estelle`'s clip is a French speaker (the library marks it `fr`); it is an
English-model embedding like the rest and is listed as one.

### Loudness

The vendored `VoiceGain` levels eight voices it measured. The fourteen listed
voices it does not cover were measured on rock (vendored host, fp16, seed 0,
median RMS of three sentences at unity gain) and are levelled by
`PocketLoudness` to the same 0.10 target, peak at most 0.99; the figures are
`measuredRMS` in the manifest (stuart_bell 0.021 to anna 0.116).

### Never listed or downloaded

| Voice | Source | Why |
| --- | --- | --- |
| `cosette` | `expresso/ex04-ex02_confused_001_channel1_499s.wav` | Expresso: CC BY-NC 4.0, non-commercial |
| `jean` | `ears/p010/freeform_speech_01_enhanced.wav` | EARS: CC BY-NC 4.0, non-commercial |
| `giovanni` | `kyutai/pocket-tts/common_voice_it_36520747-enhanced-v2.mp3` | not in kyutai/tts-voices; a clip in the gated cloning repo, with no licence stated for it |
| `lola` | `kyutai/pocket-tts/common_voice_es_19762977-enhanced-v2.mp3` | same |
| `juergen` | `kyutai/pocket-tts/de-DE-juergen.mp3` | same |
| `rafael` | `kyutai/pocket-tts/g-Vi8PgmSY0-enhanced-v2.wav` | same |

`PocketTTSManifest.excludedVoices` names these six; a test checks none is listed.

## Integrity

`Voice/PocketTTSSupport.swift` (`PocketTTSManifest`) pins every file's path,
size and SHA-256: 13 files, 437,400,422 bytes. LFS digests are the `lfs.oid`
values from the HF tree API. The seven small non-LFS files carry only a git blob
id in the API; their SHA-256 was computed from the pinned `resolve` download,
whose `git hash-object` matched the API blob id for every one.
