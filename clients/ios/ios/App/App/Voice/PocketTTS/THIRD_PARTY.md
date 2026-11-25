# Pocket TTS: third-party code, weights and voice

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
  `languages/english/tokenizer.model`, and one voice embedding.
- The cloning checkpoint `kyutai/pocket-tts` is `gated: auto` and is not used.

## The voice

- Chosen: `marius` (`languages/english/embeddings/marius.safetensors`).
- Mapping, from the file itself: the weights README at the pinned revision
  (`https://huggingface.co/kyutai/pocket-tts-without-voice-cloning/raw/e041936c75475d350b405bc870bcf7c22da4e9e6/README.md`,
  line 70) lists `marius` as
  `https://huggingface.co/kyutai/tts-voices/blob/main/voice-donations/Selfie.wav`.
  That file exists in `kyutai/tts-voices` at `323332d33f997de8394f24a193e1a76df720e01a`
  (HTTP 200). The embedding's safetensors header carries no metadata, so the README
  is the only stated link.
- Licence: the `kyutai/tts-voices` README (same revision), section
  `voice-donations/`: "Voices of volunteers submitted through our Unmute Voice
  Donation Project, licensed as CC0."
- Refused sources: `expresso/` and `ears/` (CC BY-NC 4.0, non-commercial). In
  the same README list, `jean` maps to `ears/p010` and `cosette` to `expresso/`;
  neither is downloaded. `alba` maps to `alba-mackenna/casual.wav` (CC BY 4.0, which
  would add a second attribution line), and `fantine`, `eponine` and `azelma` map to
  `vctk/` (CC BY 4.0).

## Integrity

`Voice/PocketTTSSupport.swift` (`PocketTTSManifest`) pins every file's path,
size and SHA-256: 13 files, 437,400,422 bytes. LFS digests are the `lfs.oid`
values from the HF tree API. The seven small non-LFS files carry only a git blob
id in the API; their SHA-256 was computed from the pinned `resolve` download,
whose `git hash-object` matched the API blob id for every one.
