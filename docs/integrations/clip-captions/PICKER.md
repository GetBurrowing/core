# Real caption previews

The six picker cards play actual CLI output from one authorized How To Computer
excerpt. They are 360×640, 3.336667 seconds each, muted and synchronized in the
browser. The three new styles share their caption typography and placement.
Legacy captions retain their original appearance. These are representative
samples; applying a style queues a fresh render of the selected clip.

Media lives in `apps/platform/priv/static/images/caption-previews/v1/`, served by
the existing static asset pipeline. The source episode is an existing authorized
show source, GES6h4843C4, candidate e951edb54d, starting at source 3686.340 seconds.
The requested end was 3690.140; the public CLI's word snapping/edit list produced
3.336667 seconds. `preview-assets.json` records every media file's digest and
size. The generated source project and its private transcript remain local.
Neither the original project nor Social approval/publishing state was changed.

## Reproduce the assets

Install and qualify the exact combined tool as described in `README.md` and
`verify_install.py`. The builder uses `clip version --json` to verify the imported
caption and temporal source digests, not just the version string. It calls only
the public `review` and `finalize` commands against a copied project, using a
new disposable workspace and user profile. It never edits the built-in show
profile or the original project's manifest, review file, candidates or finals.

```bash
python docs/integrations/clip-captions/build_preview_assets.py \
  --clip /operator/qualified-tool/.venv/bin/clip \
  --source-project /operator/original-show-project \
  --candidate e951edb54d \
  --workspace /operator/new-disposable-caption-preview-workspace \
  --output apps/platform/priv/static/images/caption-previews/v1 \
  --manifest /operator/new-preview-assets.json \
  --source-id GES6h4843C4
```

The workspace must not already exist. Inspect its content-bearing CLI diagnostics
locally if rendering fails; do not put them in chat or completion evidence.
Only operator-authorized source media may be copied into the shipped sample
folder. The stage-3 assets were reproduced with byte-identical video digests
using the tracked builder. Stage 4 regenerated the dynamic assets after a
decoded tail-timing correction; the three legacy MP4 hashes remain unchanged.
Current hashes are in `preview-assets.json`. No speech model or remote
brain call is made during this workflow: it reuses the original transcript.

The profile uses the existing renderer's fit framing, with no headline, music or
outro in the comparison, so every style shows the same source and timing. The
three decoded stills per style are sampled at 0.1, 1.5 and 3.2 seconds. The picker
shows all three when reduced motion is requested, and pauses every video.

## Runtime behavior

`ClipCaptionRenderer.styles/0` remains the authority for selectable treatments.
A missing/mismatched server qualification receipt disables the three new cards.
The browser never claims a renderer is supported because a video loaded. Preview
network failure shows "Preview unavailable" and does not change capability.
The existing job API validates the exact immutable base and rechecks qualification
at enqueue time. The current render's badge is separate from draft selection.
Version history shows each saved style; missing old style snapshots display
"Existing render (style not recorded)" and are never backfilled.

The small `SyncedVideoPreviews` coordinator corrects drift at 250 ms intervals,
pauses while the document is hidden or reduced motion is active, and removes
listeners, observers and timers when destroyed. Media state sits inside an
ignored LiveView boundary; selection, current badges and disabled controls remain
server-owned. This prevents LiveView patches from resetting loaded media to a
loading state.

## Design deviations, stage 3

- Canvas 01a18d1c-57fd-7000-8ebd-6d0ad909fb33 node md, descriptions: use the
  semantic muted-content `text-subtle` slot instead of `--color-neutral` text.
  Painted contrast measured 1.87:1 for neutral on dark cards, compared with
  5.33:1 for muted content in dark mode and 4.69:1 in light mode. The pixel
  reader was checked against pure white and black. Full descriptions remain available through each card's title.
- Canvas 01a18d1c-57fd-7000-8ebd-6d0ad909fb33 node md, desktop cards: the existing
  review details pane keeps a horizontal scroll row at desktop widths as well as
  on phones. All six cards are in one row at about 150 px each; the surrounding
  review/player/closing-video layout remains usable. Two cards are visible at
  375 px, with native keyboard focus scrolling the chosen card into view.
- Loading, unavailable, preview error, pending, and keyboard-focus states are
  not in canvas. They use semantic surface/content/muted/primary/error slots,
  truthful copy and native buttons. The canvas's named states and action string
  are retained. These additions do not change the video treatments.
