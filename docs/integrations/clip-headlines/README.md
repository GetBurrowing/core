# Shared clip headline contract v1

## Chrome Hook refinement (plan v2)

The current package adds independent `subtle` captions and bounded reusable
assets. Use canonical helper **0.10.3**, materialized with
`materialize_runner.py`, with the current `install_templates.py` package.
The helper checks the exact caption/headline source, dependency and font hashes.
An older CLI fails before finalize/upload; a palette or UI selection is not
evidence of renderer support. Previous snapshots retain their original hashes
and need their compatible installed renderer; none are rewritten.

In the existing Social headline controls, **Save Chrome Hook + subtle defaults**
uses `ClipJobs.save_show_default` for future clips. Existing clips keep their
immutable look and playable version. Choose **Subtle** in the separate caption
controls and request a new render to change an existing clip. Reset uses the
existing show-default action. The generic defaults and packaged
`how-to-computer` profile remain unchanged. Production default activation must
follow deployment and qualification of the serving operator's renderer; this
package does not silently update a running host or historical reviews.

Subtle captions use unmodified OFL Inter Regular4.001, pinned in
`assets-manifest.json`:24px at540×960 (25% below the32px sample baseline),
sentence case preserved from the transcript, white with a restrained35% soft
shadow. They have no outline, pill or word highlight. Measured phrase breaks
keep one short line; unfit words or unsupported glyphs fail explicitly instead
of shrinking or omitting text. Placement stays inside the configured safe area.
The fixture's current subtle comparisons use the production0.645 bottom limit.
All previous caption styles remain available in the CLI/helper.

`packaging_assets.py` keeps one process-local LRU budget of64MiB accounted
payload/key memory and256 entries. It caches verified bytes/cmap, font sizes,
decoded/resized logo, layouts and final effect rasters. Every file lookup stats
device/inode/size/mtime/ctime; replacements invalidate byte identity, and pinned
digests are checked even before completed-raster hits. Derived keys also bind
text/emphasis, template revision, dimensions and relevant config. Callers receive
copies of cached images. Entries evict under the budget; no cache survives the
CLI process. `packaging_assets.info()` exposes accounting and `clear()` resets
it for tests. Native renderer allocations are separate from this accounted
cache budget.

Reproduce the three Chrome Hook lengths with the installed tool's Python:

```bash
python apps/social/priv/scripts/clip_headline_templates_fixture.py \
  --source "$ORIGINAL_SOURCE" --project "$ORIGINAL_PROJECT" \
  --logo docs/integrations/clip-headlines/assets/htc-official-logo-crop.png \
  --face-model docs/integrations/clip-headlines/models/face_detection_yunet_2023mar.onnx \
  --chrome-only --output "$PRIVATE_EVIDENCE"
```

This uses extractive fixture proposals through the existing evidence policy.
It does not prove accepted live new-clip/regenerate generation. That missing
qualification and the muted-closing measurement remain in the following plan
stages. No production installation, approval or publication is claimed here.

Final isolated CLI, installation, face safety and mutation qualification is in
[QUALIFICATION.md](QUALIFICATION.md). It uses canonical helper 0.10.2 and retains
the earlier source comparisons and immutable receipts. No production rollout or
publication is implied.

The reusable Chrome Hook, Neon Broadcast and Arcade Punch extension, isolated
installer and actual-source sample checks are documented in [TEMPLATES.md](TEMPLATES.md).
The existing headline-review/1 text policy below remains the generation boundary.

Task: 01a17e37-6f5f-7000-b57b-564bc84dbf2d, stage 1.

This artifact extends JackEFoster/htc-clip-tool commit
`58960577337d5682761e1538ff4365d4ba0b4e18`. It is an upstream patch, not a second
Burrow runner. Install it in the clip tool before enabling this capability.
The canonical `burrow-clip-runner` skill/helper remains the only job runner.
Stage 2 integrates this boundary and proves final video frames. Stage 1 tests
application and content-free receipts; it does not establish live model access,
episode fanout, production availability, or a completed headline render.

The existing tool has `title` in review.toml, but `review._title_candidates`
prefers `Candidate.titles`. Editing title alone therefore need not change the
burned overlay. The patch adds an explicit `headline` review field that replaces
the variants with the exact requested text, checks the delivered transcript,
invalidates the old render, and uses normal packaging/approval fingerprints.
Empty or unbacked text fails instead of silently rendering without a headline.
It preserves legacy `title` semantics; no parallel UI route or event is added.

## One boundary for both consumers

Episode automation (task 01a17e37-97c2) uses `consumer = "episode"`.
The version regenerate action (task 01a17e37-836f) uses `"regenerate"`;
human text editing uses `"edit"` and supplies `requested_headline`.
All use `clip_agent.headline.HeadlineRequest` and the CLI below, with no new
model client, prompt template, backend, sampling budget or ranking policy.

Write the request to a private local file (0600), never an MCP payload containing
transcript-derived text. This fixture illustrates the shape; identifiers and
voice snapshots come from runtime configuration, never hardcoded core defaults:

```json
{
  "version": 1,
  "consumer": "regenerate",
  "candidate_id": "candidate-fixture",
  "source": {"id": "source-fixture", "start": 12.0, "end": 36.0},
  "voice": {
    "revision": "configured-snapshot-revision",
    "direction": "Entertainment first, comedy and positivity; remaining rules incomplete."
  },
  "base_render_id": "render-fixture",
  "requested_headline": null,
  "export_text": false
}
```

The runner must bind source id/candidate id/span to its existing immutable job
snapshot and mapping, and compare base_render_id under the existing lock. The
tool independently checks the current candidate and delivered bounds. Omit the
base only for an initial episode pick; edit/regenerate require an explicit base.
Use the tool's actual snapped source bounds after initial trim application.

The live HTC bible, master canvas `01a17da0-dcc4-7000-a634-acda1f00d78f`,
section `sec-bible`, was read at document revision **8** on 2026-10-27.
`bible-5` provides entertainment/comedy/positivity direction, but adjectives,
example line, forbidden voice and words to avoid remain owed. `bible-intro`
says earlier call material is unratified. Store the snapshot revision and this
incompleteness in runtime configuration; do not claim a complete ratified voice.
Missing voice fails `HEADLINE_VOICE_MISSING`. Runtime voice direction feeds the
existing `selection.title_hint` customization of the existing hook policy.
This is policy reuse, not a new model/prompt experiment; future tuning should
use the project's existing eval conventions and the snapshot revision as data.

## Supported tool flow

1. Require `clip version --json` to return `headline_review: 1`; version 0.9.0
   alone is insufficient. An unpatched tool fails `HEADLINE_CLI_UNSUPPORTED`.
2. Export fresh review.toml, apply the desired source bounds through the existing
   tool-local review approval, and refresh the review file from applied state.
   Enable `captions.hook_title` in a derived **user** profile. Never edit the
   built-in how-to-computer profile.
3. Run `CLIP_NO_CONTENT=1 clip hooks prepare-review PROJECT --request FILE
   --profile USER_PROFILE`. It drafts through `hooks.generate_variants`, with
   normal quote evidence and rotation; an edit bypasses generation. It prepares
   only the selected `headline` field in review.toml, with existing base hashes.
   It refuses to overwrite unapplied review edits. It emits a safe JSON receipt
   with `status: "prepared"`; preparation is never rendering success.
4. Run `clip review PROJECT --apply --profile USER_PROFILE`, followed by
   `clip hooks prepare-review PROJECT --request FILE --profile USER_PROFILE
   --check-applied`. Verification checks the fully applied review digest,
   selected headline, actual `hook_title_for` overlay, candidate status and
   approval, then returns `status: "applied"`. A missing field or a different
   overlay fails visibly.
5. Run `clip finalize PROJECT --profile USER_PROFILE --regenerate`. Use existing
   upload/version completion only after a fresh render exists. Preserve derived
   profile cleanup, other review edits, prior version files, idempotency and
   safe errors. A verified applied receipt does not prove render completion.

No picks JSON or internal project manifest is edited by the runner. The patch
updates tool state only inside the tool's ordinary review application path.
There is no timeline, keyframe or canvas editor, and no publishing operation.
Tool-local approval is permission to render selected packaging; it grants no
Burrow approval, scheduling, post approval, or publication permission.

## Privacy and failures

Every child command retains CLIP_NO_CONTENT=1 and excludes the Burrow token.
The CLI receipt contains only contract version, ids, bounds, voice revision,
status and backed flag; it never prints requested/generated text, even for cloud
projects. Requests, transcript and generated headline stay local. Optional
internal receipt text is permitted only for explicit cloud privacy; local text
export is rejected with `HEADLINE_PRIVACY_EXPORT_REFUSED`. The new CLI never
requests text export. Existing local provenance preflight and network_guard
still apply to generation. Failure messages are stable codes, not provider
messages or transcript excerpts.

Contract errors include HEADLINE_CLI_UNSUPPORTED, HEADLINE_REQUEST_UNSUPPORTED,
HEADLINE_VOICE_MISSING, HEADLINE_BASE_MISSING, HEADLINE_SPAN_INVALID,
HEADLINE_SPAN_STALE, HEADLINE_CANDIDATE_MISSING, HEADLINE_EMPTY,
HEADLINE_UNBACKED, HEADLINE_OUTPUT_UNSUPPORTED, HEADLINE_OVERLAY_DISABLED,
HEADLINE_RENDER_APPROVAL_REQUIRED, HEADLINE_REVIEW_NOT_APPLIED,
HEADLINE_APPLIED_MISMATCH and HEADLINE_PRIVACY_EXPORT_REFUSED.
Unexpected CLI errors collapse to HEADLINE_PREPARE_FAILED with no content.

Apply the patch with `git apply --check` against the pinned upstream revision,
then `git apply`. Run the included `tests/test_headline_contract.py` plus upstream
review/hooks tests and lint. The patch's digest and actual test counts are
recorded in the stage evidence. A failed patch application means upstream drift:
stop and rederive against that revision rather than modifying internal state.

## Canonical runner integration (stage 2)

The centrally registered `burrow-clip-runner` skill now carries helper **0.4.0**
and six fixture/test blocks. The helper digest and installed-tool prerequisite
are pinned in [artifact.json](artifact.json). Core contains no second job runner.

- `new_clip` automatically prepares a generated headline using consumer `episode`.
- `payload.fix.operation = "regenerate_headline"` uses the same generation boundary.
- Human edits use `payload.headline = {"consumer":"edit", "requested_headline":"<user text>"}`;
  these bypass generation. Any `export_text` request fails closed.
- The agent loop provides private `context.headline_voice = {revision, direction}`.
  No missing-voice fallback or invented ratification exists.
- Edit/regenerate require an explicit `payload.base_render_id` equal to the
  selected immutable `context.base_render_id`. Source id comes from the immutable
  payload `source_id`, episode file id, or a SHA256 of its source URL. The existing
  ClipJobs clip lock, immutable snapshots, and idempotent completion remain the
  authority; sibling version/episode/UI integrations must populate those inputs.
  This stage does not replace their in-flight ClipJobs implementations or add a
  migration alongside their reserved timestamps.

The helper creates a 0600 local request, applies actual snapped bounds, refreshes
base hashes, prepares the headline, applies review, verifies the safe receipt and
actual overlay, and calls `finalize --regenerate`. It uses a derived user profile
for consistent packaging hashes; enabled caption styles are preserved and `none`
is enabled as phrase-pop. Temporary profiles/requests are removed on all paths.
Completion requires the selected new output's timestamp to follow finalize; it
cannot upload a stale or unrelated MP4. Receipts stay in local state.json and do
not add unsupported fields to Burrow's completion schema. Generated text is never
exported through MCP. The local render approval is not Burrow post approval,
scheduling or publishing permission.

### Reproduce the real renderer proof

Install the pinned upstream patch into an isolated clip environment, and extract
`clip_runner.py` from the canonical skill with the pinned digest. Run with that
environment's Python (which imports the compatible installed `clip_agent`):

```bash
python docs/integrations/clip-headlines/verify_real_renderer.py \
  --helper /private/path/clip_runner.py \
  --clip /private/path/to/installed/clip \
  --output /private/fixture-evidence
```

The harness seeds only a five-second source, cached transcript, candidate and
user profile. It then uses real CLI review/application/finalize and the canonical
helper's render boundary, with real FFmpeg. It does not mock rendering, use a
live model, claim a Burrow job, or upload a production file. Before and after
frames were viewed: the top line changes from “We shipped the app” to
“The team celebrated”, and the lower caption region stays pixel-identical.
The video hashes are in artifact.json; frame evidence is below.

![Before: We shipped the app](evidence/before.png)
![After: The team celebrated](evidence/after.png)

Both mutation probes were killed and restored green: deleting the helper's
`requested_headline` forwarding fails the unchanged independent text assertion;
deleting the tool's `headline` review field fails the unchanged
`entry["headline"] == "The team celebrated"` assertion. Generated-new-pick and
human-edit runner tests separately inspect the exact applied review.toml field.
Live generation availability and a production worker run remain runtime
prerequisites, not results inferred from these fixtures.

### Validation and limits

Canonical helper fixtures: **83 passed**. Upstream contract/review/hooks:
**125 passed**. This runtime's private OTP 28.1 / Elixir 1.20.4 / PostgreSQL 16.15
Social suite: **1,273 passed**, source SHA `61690d6d40b75c65d0038deb844c57defe1b35c0`;
this stage changes no Elixir source. Configured upstream Ruff, helper/harness
syntax/import lint and whitespace checks pass.

The full upstream run is **not green**: 3,404 passed, 23 skipped and the same two
failures reproduced on unmodified upstream in stage 1:
`test_hook_title_png_in_top_band_and_safe_area` (one-pixel baseline geometry) and
`test_eof_at_the_name_prompt_stops_with_a_message` (120-second PTY EOF timeout).
Neither was suppressed or counted as a pass. Final helper and video digests,
commands, mutation dispositions and fixture limits are pinned in artifact.json.
The real fixture also seeds a saved `caption_style = "none"`; explicit enabled
finalize captions must override it for the changed burn to appear.

## Review bay integration (stage 3)

The single **Headline** input and **Render headline** action are in the existing
Social Clips review bay. They require the same fresh human approver check as
other review writes. The form sends its displayed immutable `base_render_id`;
the server never substitutes a fresh base for a stale submitted form.
`ClipJobs.enqueue_fix` locks the clip and resolves that version in the org and
profile, preserving source/candidate, snapped bounds, look and caption fixes.
Its internal `edit_headline` operation becomes `payload.headline =
{"consumer":"edit","requested_headline":"<human text>"}`, with no `fix`
operation: canonical helper 0.4.0 recognizes this edit boundary and skips
generation. Exact human input is retained in the new immutable snapshot even
when the local runner returns `title: null`. Empty or multiline inputs are
rejected. Queueing and failure leave the prior playable video intact.

Both episode task `01a17e37-97c2` and regenerate task `01a17e37-836f` use helper
0.4.0: new_clip automatically selects consumer episode;
`fix.operation = regenerate_headline` selects consumer regenerate. The private
agent loop resolves `context.headline_voice = {revision, direction}` and
`context.base_render_id` from the selected immutable snapshot. No transcript,
generated headline or voice direction is shipped through MCP. Missing context
is a visible runner failure, never a default show identity or voice policy.

The review input displays only privacy-permitted stored text: human-authored
edits or metadata the runner was permitted to export. Local generated headlines
remain absent from its completion payload, snapshot and input; the burn is
visible in the uploaded video. Error UI exposes a fixed allowlist of stable
headline codes with a generic fallback, never raw runner error text. Errors
survive reload through persisted job status; users can retry a failed attempt.
No approval, schedule or publish is performed by a headline edit.

This branch adopts the sibling's immutable ClipVersions and typed-fix commits
through `f13c6af5`; it adds no competing store or migration. `selected_render`
is the bay's immutable version assign (latest on open/promotion); the sibling
version selector must reuse it for the hidden base ID and headline value. A
historical base is refused by the shared enqueue guard once a newer revision
has been promoted. Existing title metadata editing remains distinct from the
one headline render input. No timeline, keyframes or canvas editor was added.
