# Shared caption treatments v1

Task `01a18d1b-a5c1-7000-947c-7931a3ec53e5`, implementation stage 1.
This is a patch to **the existing htc-clip-tool renderer**, not a Core renderer,
parallel cutter, timeline, editor, runner, or production rollout. Social must
not advertise the new styles until the executable actually invoked by its
runner passes qualification. Runner skill 0.8.0, music/outro handling and immutable
render history are unchanged in this stage; later stages integrate the runner
and picker and deliver the authorized-source comparison samples.

## Install the exact combined tool

Upstream: `https://github.com/JackEFoster/htc-clip-tool`, pinned commit
`82ef5132b926fed33a80a304364fdda14335c2d5`. That revision already contains
music and outro. The tracked headline patch applies cleanly to it; do not import
another task's Python directory or overwrite another renderer installation.
Use a dedicated operator-owned checkout and virtual environment. From that
checkout, substitute the absolute path of your Core checkout below:

```bash
git checkout 82ef5132b926fed33a80a304364fdda14335c2d5
git apply --check /absolute/core/docs/integrations/clip-headlines/htc-headline-review-v1.patch
git apply /absolute/core/docs/integrations/clip-headlines/htc-headline-review-v1.patch
git apply --check /absolute/core/docs/integrations/clip-captions/htc-caption-treatments-v1.patch
git apply /absolute/core/docs/integrations/clip-captions/htc-caption-treatments-v1.patch
uv venv .venv
uv pip install --python .venv/bin/python -e './clip-agent[dev]'
.venv/bin/python /absolute/core/docs/integrations/clip-captions/verify_install.py \
  --clip "$PWD/.venv/bin/clip" --checkout "$PWD"
cd clip-agent
../.venv/bin/python -m pytest tests/test_dynamic_captions.py
```

If either patch fails its applicability check, stop and reconcile against the
actual source; do not force it. For an install already carrying headline-review/1,
verify its tracked source rather than applying headline twice. Never run reset
or clean in an operator's existing installation to make these instructions fit.
The patch contains the Inter ExtraBold font bytes, with the upstream OFL notice
and source URL; there is no runtime font download. Digest receipts are in
[artifact.json](artifact.json). Qualification requires the digests of all changed
installed source/font files and checks paths and digests reported from the actual
`clip version --json` process's imported renderer modules. Distribution metadata
and the unchanged `0.9.0` version string alone cannot qualify a tool. It also
checks music/outro configuration and the retained headline-review capability.

## Capability and behavior

`clip version --json` adds `caption_treatments: 1`, an explicit `caption_styles`
array (`none`, `plain`, `phrase-pop`, `karaoke`, `type-on`, `focus-word`,
`editorial-punch`), and `caption_renderer` with imported module paths/digests.
Existing CLI `--captions` choices and `captions.style` configuration use the same
enum. Unsupported/misspelled styles fail validation. Existing preset behavior,
legacy styles, review snapshots and packaging hashes retain their semantics.

All three new styles use the same sentence-case Inter SemiBold, font size,
off-white text, shadow, fixed word boxes and placement. One original longest
word per editorial phrase uses Inter ExtraBold (600 → 800); no token is added,
removed, substituted, reordered or uppercased. Shared layout reserves the
heavier glyph widths for every style, so even that emphasis cannot move text.
The renderer uses the existing bundled Inter family plus its same-release OFL
ExtraBold weight. New treatments deliberately have a shared opinionated look;
legacy palette/preset fields continue to affect the legacy styles as before.
There is no yellow in new treatments.

- **Type-on:** words fade at their spoken starts over 80 ms; the newest word
  receives a 3 px teal underline fading over 300 ms. The complete phrase's
  fixed layout is reserved before entry. Finished phrases hold and are replaced
  with a cut; that replacement is not described as a smooth entrance.
- **Focus word:** all phrase text remains at full opacity. A violet rounded
  background eases both its position and width over 120 ms. Interrupted rapid
  transitions continue from their actually reached position, avoiding a snap.
  This differs from legacy karaoke's foreground-color switching.
- **Editorial punch:** the phrase fades/rises 12 px over 180 ms, then holds.
  Phrases lasting less than 250 ms cut instead of playing an incomplete entrance.
  There is no rotation, bounce or emoji.

The 1080×1920 reference size uses 72 px text; geometry scales to the output.
Captions stay in the 62–78% height band, with left/right margins that clear the
platform rail; at most two balanced short lines, roughly 26 characters each.
Individual long words shrink uniformly with the phrase rather than clipping;
an extreme token that cannot fit even at the minimum size fails visibly.
Seven-word/52-character phrase limits bound layout work. Words remain on their
original timeline. Speaker changes, EDL/camera discontinuity breaks and >1.5 s
gaps break phrases; captions clear during long gaps rather than hanging there.
This stage uses supplied renderer/EDL break boundaries and does not add a new
camera detector. The fixed band is below the face zone; original-source framing
and faces still require the stage-5 frame comparisons.

Only transition windows are sampled at 30 Hz, with explicit event endpoints;
static holds use a single PNG. Each sampled phrase is bounded by its original
word count and transition windows rather than hold duration. The existing
concat/alpha overlay pipeline creates the video, with a 30 fps PNG timebase for
new styles. Legacy concat inputs and style branches are left unchanged.

## Evidence and reproduction

The design direction was read whole and recreated through
`Platform.Chat.create_canvas` on this runtime's dev server; screenshots at
1280×800 and 375×812 were posted before the implementation commit:
[reference canvas](https://suite.kobo-ai.com/canvases/01a18d28-1c19-7000-a812-deed35fa8208).
Actual decoded motion phases are in the
[evidence canvas](https://suite.kobo-ai.com/canvases/01a18d2b-6980-7000-9fab-2a854909ce2c)
and [decoded phase grid](decoded-phases.png).

Reproduce the real alpha-track/MP4 fixture with the qualified tool's Python:

```bash
.venv/bin/python /absolute/core/docs/integrations/clip-captions/verify_temporal_frames.py \
  /private/caption-temporal-evidence
```

This seeds a **TEST ONLY synthetic transcript** and uses unmocked renderer and
FFmpeg calls to make three 5 s, 360×640 alpha tracks plus light/dark video
composites. It decodes first/intermediate/hold/last-word frames, asserts safe
bounds and cleared gap frames, and records actual imported module path, Python,
frame hashes/counts and video-track hashes. This is not the requested 8–12 s
original-source samples, not production upload, not approval, and not publication.
Those comparison clips are required by the later approved stage.

Unmodified upstream and the patched renderer produced byte-identical PNGs and
segment timings for plain/phrase-pop/karaoke; the original snapshots are pinned
in [legacy-baseline.json](legacy-baseline.json), with literal regression hashes
in upstream tests. The tests independently assert 50% entry opacity, eased pill
position and width, actual purple-pixel bounds, rise offset, rapid interruption
continuity, first/last-word handling, exact tokens, gap/cut boundaries and long
word placement. A mutation snapping the pill instead of easing was killed by
the unchanged intermediate/continuity assertions, then restored green.

Final focused validation: **425 passed**, with one explicitly deselected hook-title
baseline failure independently reproduced on untouched source. New temporal tests:
**11 passed**. Clean-install models/preferences/temporal checks: **36 passed**.
Configured Ruff, formatting, syntax, patch applicability and source-digest checks pass.

The initial full patched run was **3,479 passed / 20 skipped / 8 failed**. Two
caption integration failures (enum expectation and exposing the internal weight
in the font picker) were corrected and pass in final focused checks. A full
untouched upstream control was **3,451 passed / 20 skipped / 5 failed**: the
hook-title one-pixel boundary, 120-second installer PTY EOF timeout, and three
music metric assertions fail without this patch. The music assertions also flip
which variants fail on repeated unchanged runs, so they are reported as flakes
or order-sensitive failures, never counted as passes. Audio renderer/test bytes
are identical to pristine; this stage does not change or suppress them. Full
suite green is **not** claimed. Raw receipts, controls and mutation failures are
in [evidence](evidence/) and exact commands/dependency versions in artifact.json.
No Elixir or Social UI code changes in this stage.

## Design deviations — stage 1

`canvas 01a18d1c-57fd-7000-8ebd-6d0ad909fb33 node md | 60%-black per-line
scrim is always present, including dark shots | deterministic phrase-local
contrast without introducing another frame-analysis path; actual light/dark
decoded frames inspected.` All three new treatments share that choice. The
canvas's font, size, text color, motion and position constraints are preserved.

Research basis: [Captions styles](https://captions.ai/help/docs/captions/styles)
and [Descript word-level animations](https://www.descript.com/blog/article/new-in-descript-word-level-animations-on-fancy-captions-santa-overdub-voice)
describe available design approaches. These original restrained interpretations
make no engagement or retention improvement claim.
