# Shared clip headline contract v1

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
