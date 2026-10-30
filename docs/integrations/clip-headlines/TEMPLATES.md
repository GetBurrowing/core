# Reusable HTC opening templates

Task `01a18ef6-f0aa-7000-84b2-0dbea407507a`, stage 1. This extends the existing
`captions.render_hook_title_png` / caption-track boundary in htc-clip-tool.
It retains `headline-review/1` and its existing voice and evidence checks.
The canonical runner remains the only Social job runner. This stage delivers
renderer samples and a reproducible installer; Social selection and runner
payload integration belong to the following approved stages. These samples
are private previews, with no approval, scheduling or publishing operation.

The three selectable names are `chrome-hook`, `neon-broadcast`, and
`arcade-punch`. `legacy` remains the reversible configuration default. No style
wins automatically. The comparison uses deterministic extractive selection proposals through the existing
`hooks.generate_variants(..., use_brain=False)` boundary and its evidence checks;
no live model generation is claimed. The provisional voice snapshot retains its
incomplete status. Production generation remains the existing headline-review/1
flow. The comparison uses one authorized original episode,
1479–1489 seconds of `GES6h4843C4`, and its saved transcript. It deliberately
uses three different headline lengths, all accepted by the existing
`hooks.check_variant` evidence checker. They demonstrate layout, not a
recommendation to replace the show's headline voice. The original project,
source mappings, delivered files, approvals and built-in profile are untouched.

## Exact installation

Run `install_templates.py --target /new/dedicated/renderer --core /path/to/core`
with Python 3.14, Git, uv and FFmpeg available. The target must not exist. This
creates a separate checkout pinned to upstream
`82ef5132b926fed33a80a304364fdda14335c2d5`, applies the existing headline patch,
the qualified caption patch from immutable Core commit
`d17048339c6cbbe95794ad748393c4724dffb410`, then this directory's
`htc-headline-templates-v1.patch`. Fetch that Core commit into your Core clone if
`git cat-file -e` cannot resolve it. The installer does not reset or modify an
operator's existing installation or running helper. It installs the pinned
Linux/Python 3.14 dependency receipt, including the sample's OpenCV dependency,
and writes `headline-install-receipt.json` in the new checkout.

Run the renderer's tests with its dedicated environment:

```sh
/new/renderer/.venv/bin/python -m pytest /new/renderer/clip-agent/tests/test_headline_templates.py
```

`clip version --json` must report `headline_templates: 1`, all three names,
`headline_review: 1`, retained caption styles, and the actual imported template
module's path and digest. Renderer version `0.9.0` alone is insufficient.
`assets-manifest.json` identifies the official channel logo original and its
lossless rectangular crop, font origins, rights and hashes. The show logo is
an HTC asset used under Jordan's explicit request, not an open-source brand
asset for third-party shows. No logo or host lettering was generated or redrawn.
The bundled font copies retain OFL notices, source receipts and upstream NOTICE.
No production frame photo or AI-generated title image is used.

## Configuration and safety contract

Use a derived user profile, never edit packaged `how-to-computer`. The following
fields live under `captions`, independently of the caption style:

- `hook_title_template`: `legacy` or one of the three names.
- `hook_title_logo_path` and `hook_title_logo_sha256`: exact authorized asset.
- `hook_title_emphasis`: zero-based whitespace-token indices, with
  `hook_title_emphasis_text` equal to the exact current text. Empty emphasis is
  permitted; stale, duplicate or out-of-range indices fail.
- `hook_title_seconds`: greater than 0.5 and at most 6 for branded templates.
  The title fades smoothly in over 0.2 s and out over the final 0.25 s. It is
  absent afterward; captions keep their own original timeline. There is no
  flashing, strobing or per-word title animation.

Typography measures actual Anton glyph advances, wraps only between original
words into at most three lines and shrinks no lower than 2.4% of output height
(with an absolute 12-pixel floor). Unsupported glyphs fail explicitly. Text,
stroke, glow, skew and frame are checked inside the reserved safe title band,
including a minimum 8% top margin and the platform right rail. Words are never truncated or ellipsized.
An impossible fit raises `HEADLINE_LAYOUT_SHORTEN_TEXT`.

`pipeline._headline_config_for_plan` derives face exclusion boxes from every
actual crop segment during the opening. A fit, split, unknown face or missing
geometry fails `HEADLINE_FACE_GEOMETRY_MISSING`. Intersection with the title
region fails `HEADLINE_FACE_REGION_UNSAFE`; there is no blur fallback. A direct
renderer harness must supply independently measured face boxes. The fixture
checks all decoded source frames using YuNet before constructing its crop.
This conservative guard may reject close-ups that have no headroom. Do not
weaken it to make a preview pass; use another authorized source span or fix the
upstream framing plan.

The existing packaging fingerprint includes template version/source digest,
exact font/logo hashes, wording, emphasis, safe margins and timing. Changing
any invalidates a tool-local approval. Core's immutable job/render snapshot
integration follows in stage 2. A prepared/applied headline, accepted config,
CLI capability, or UI picker alone is not a rendered-video claim.

## Reproduce the actual-source samples

```sh
/new/renderer/.venv/bin/python /path/to/core/apps/social/priv/scripts/clip_headline_templates_fixture.py \
  --source /private/original/source.mp4 \
  --project /private/original/htc-ges6-highlights \
  --logo /path/to/core/docs/integrations/clip-headlines/assets/htc-official-logo-crop.png \
  --face-model /private/models/face_detection_yunet_2023mar.onnx \
  --output /private/headline-samples
```

The source must match the original project's recorded source path. This uses
public tool APIs to read the cached transcript and render directly from the
original, retaining speech audio. It does not finalize or mutate the original
project. Each sample is a 540×960 full-frame face crop lasting 10 s, with an
independent clean single-line caption treatment and a 3.5 s opening title.
Actual decoded alpha frames assert title+caption coexistence, smooth entry,
cleared title after 3.5 s, continuing captions, 300-frame timing and single-line
caption bounds on every frame. Decoded MP4 stills and playable MP4s accompany
the contact-sheet canvas in the execution space. Receipts bind source digest,
actual imported modules, font/logo hashes, sizes, wraps and final output hashes.
