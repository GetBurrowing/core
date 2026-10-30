# Caption comparison evidence

Three **10.302-second actual video samples**, pending show-owner review:

- [Type-on](/chat/attachments/01a18d9a-894a-7000-a4bd-f69c3c00b40b)
- [Focus word](/chat/attachments/01a18d9a-8acc-7000-a033-ceec122d9089)
- [Editorial punch](/chat/attachments/01a18d9a-8c47-7000-b6a5-f9679b89c3fe)

These corrected samples replace the earlier three messages, which exposed a
real caption-track tail defect. Nothing was approved, scheduled or published.
Media hashes match the upload responses. The decoded-frame evidence canvas is
`01a18d9a-e558-7000-91b7-2b3833ec82eb`; its frame grid is also attached to the
task space. Files require the existing space's access.

All samples use existing authorized How To Computer source `GES6h4843C4`,
original candidate `e951edb54d`. Requested source bounds were
3686.340–3697.140 seconds; supported review word snapping applied
3686.340–3697.050. The existing edit list produces 10.302 seconds of output.
Every sample is 360×640 at 24000/1001 fps; temporal alpha tracks are sampled
at 30 fps. Comparisons use the same fit framing as the picker, with headline,
music and closing disabled to isolate caption motion. Actual camera changes
are visible in the decoded grid; captions remain below faces and inside the
62–78% band. A separate deterministic fixture exercises the closing integration.

The harness copies the original project/candidates, retains original final
deliveries separately before finalization, and changes only supported review
fields in that copy. A complete before/after source-project hash inventory is
equal. No rendered delivery is used as source. Private transcripts and CLI
diagnostics remain in the operator's local workspace.

## Reproduce

Install the pinned combined tool using [README.md](README.md) and qualify the
exact imported source/font files with `verify_install.py`. Use current canonical
helper **0.9.1**, whose source and SHA256 are tracked in
[runner-artifact.json](runner-artifact.json). Historical 0.9.0 skill evidence
is retained in git history; the current complete skill is
[burrow-clip-runner-0.9.1.md](burrow-clip-runner-0.9.1.md).

```bash
python apps/social/priv/scripts/clip_caption_treatments_fixture.py \
  --clip /operator/qualified-tool/.venv/bin/clip \
  --helper docs/integrations/clip-captions/runner/clip_runner.py \
  --source-project /operator/original-show-project \
  --candidate e951edb54d --source-id GES6h4843C4 \
  --workspace /operator/new-comparison-workspace

python docs/integrations/clip-captions/verify_comparison_frames.py \
  /operator/new-comparison-workspace

python docs/integrations/clip-captions/verify_temporal_frames.py \
  /operator/new-temporal-workspace
python docs/integrations/clip-captions/verify_decoded_motion.py \
  /operator/new-temporal-workspace
```

Use the qualified tool's Python for the last three commands (Pillow/numpy).
The comparison workspace must not exist. Its private receipt records actual
executable/import paths and source identity; the checked-in sanitized equivalent
and [receipt schema](caption-comparison-receipt.schema.json) live with the
[stage-4 evidence](evidence/stage4). The harness uses the unmodified canonical
helper's real render path with a local artifact sink. It does not simulate a live
Social claim, Files upload or completion; fake protocol tests and server tests
cover those contracts separately. The comparison videos were subsequently
uploaded as media and verified by SHA256.

Rebuild the six picker loops and eighteen decoded entry/mid/hold stills with
[build_preview_assets.py](build_preview_assets.py), using the same source and
3.8-second requested portion documented in [PICKER.md](PICKER.md). Actual loop
duration remains 3.336667 seconds for every card. The three legacy MP4 hashes
are byte-identical to stage 3. [preview-assets.json](preview-assets.json) pins
all 24 current assets; the three dynamic loops and their final hold stills have
been corrected.

## Timing defect and independent guards

The new real-source last-word check failed: captions cleared early at the tail,
despite accepted configuration and successful rendering. The initial synthetic
five-second alpha tracks decoded only 143/144 frames. The concat sentinel PNG
was missing the temporal inputs' 30 Hz timebase. Temporal durations also used
three-decimal precision. The corrected existing renderer uses the same 30 Hz
timebase for that sentinel and nine-decimal temporal durations, preserving the
legacy writer branch.

Three new upstream regressions decode a real five-second MOV and require exactly
150 frames plus a nonempty final spoken-word frame. All three fail against the
previous packaged source and pass with the correction. The independent source
check now confirms first/last words and pre/on/mid/post phrase timestamps, with
changed caption pixels entirely within rows 396–500 at 640 px height. It uses
supported delivery MP4/SRT outputs, not internal transcript caches.

Decoded synthetic pixel measurements separately establish intermediate type-on
intensity/alpha, moving **both** pill edges and width, and rising/fading editorial
text. Freezing an intermediate pill frame to its start pose fails the unchanged
guard; restoring it passes. Synthetic edge fixtures additionally cover long
words, rapid speech, gaps over 1.5 seconds and supplied camera/edit boundaries.
These supplement the actual source samples, which do not contain every edge.

The source, patch, helper and server qualification digests are repinned together.
An old receipt leaves new styles unavailable until the operator reinstalls and
requalifies. No production worker or server configuration was changed.

## Integrated ending checks

`clip_closing_video_fixture.py --caption-style STYLE` accepts each new style
and preserves its existing default. Seven real CLI/helper scenarios per style
cover keep/mute, replacement, disabled, headline, caption-word and music edits.
The fixture seeds process-time `caption_style=none`, so visible new captions
also verify explicit finalize override. All 21 initial scenarios passed; all 21 scenarios passed again with the
corrected renderer/helper.

Enabled results measure 6.2 seconds, disabled results 5.0 seconds. Exactly 36
decoded closing frames occur once; caption/headline pixels stop before them.
The 997 Hz closing tone is present for keep and absent for mute, while source
speech-tone audio remains. Correction/headline changes are independently visible.
Invalid video bytes fail before upload and temporary assets/profiles are removed.
These deterministic TEST ONLY fixtures make no claim of production upload or
customer ending artwork. Full run outcomes and honest baseline failures are
recorded in `evidence/stage4/validation.json`.

## Design deviations — stage 4

`canvas 01a18d1c-57fd-7000-8ebd-6d0ad909fb33 node md | shared caption
legibility | retains stage-1's always-on phrase-local scrim, including dark
shots | deterministic contrast shared across all three treatments.`

The stage-3 picker deviations in [PICKER.md](PICKER.md) remain unchanged.
Caption samples are comparison media using the existing fit framing, not a
change to the show's production framing policy. No engagement or retention
uplift is claimed.
