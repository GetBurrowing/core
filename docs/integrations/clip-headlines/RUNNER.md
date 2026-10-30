# Canonical runner template contract

Stage 2 extends `burrow-clip-runner`; it adds no rendering pipeline or generator.
The immutable `canonical-runner-0.10.0.md` archive contains the exact shared
skill helper and tests. Its accompanying patch is against the canonical 0.9.2
skill read at 2026-10-30T21:34:47Z. Operator processes and installed renderers are
not updated by publishing the skill. Do not replace a serving process mid-job.

Install the dedicated renderer and authorized assets as described in
[TEMPLATES.md](TEMPLATES.md). Materialize the archived canonical helper into a
new directory, inspect the helper digest in the archive, run the tests, and use
the skill's existing installation/handoff flow. For example:

```sh
python3 docs/integrations/clip-headlines/materialize_runner.py --output /private/new-runner
CLIP_TEMPLATE_TEST_ASSETS=/path/to/core/docs/integrations/clip-headlines \
  python3 -m pytest /private/new-runner/tests
export CLIP_RUNNER_HEADLINE_ASSETS=/stable/renderer/headline-assets
```

Python 3.11+ and pytest are needed for helper checks. The renderer installer
pins its separate Python/dependency environment. The materializer verifies the
full skill archive and exact helper digest, refuses existing destinations, and
whitelists code-block paths. The archived helper is the canonical helper itself,
not another worker. The canonical skill is updated only after materialized tests
pass. Keep both selected-profile and combined-profile doctor checks; retain
all existing caption/music/closing/privacy tests.

`look.title.template` accepts `chrome-hook`, `neon-broadcast`, `arcade-punch`,
and explicit `legacy` to reverse the treatment. Omitting it leaves historical
behavior unchanged. Selection never changes caption styling. `title.secs` is
0.5 < seconds <= 6 for an explicitly selected template. Branded motion is a
0.2-second entrance and 0.25-second exit; explicit legacy has neither motion.
If actual applied source bounds are too short, rendering fails instead of
silently changing the pinned timing. No winner/default is selected here; the
following Social UI stage owns the user controls and current product direction.

`title.emphasis` is a unique list of zero-based whitespace-token indices.
Nonempty emphasis requires `title.emphasis_text` to equal the exact wording;
it is revalidated locally after existing headline preparation. A wording change
cannot silently move emphasis to another word. Empty emphasis needs no copy of
generated text. Human headline edits normalize whitespace through the existing
fix boundary, preserving the wording and voice/evidence policy.

Core resolves `payload.headline_template` under existing enqueue locks, including
for automatic episode parents. Their child jobs reuse the pinned parent look
and template rather than today's changed defaults. Per-clip look overrides take
precedence. The contract pins revision, template module hash, exact licensed
font/authorized logo hashes and provenance, emphasis and timing. Only the one
disposable USER profile receives resolved renderer keys and local asset paths.
Packaged show profiles remain unchanged. No compatibility UI shim was added.

The canonical helper requires the exact compatible CLI capability and imported
font bytes before rendering. It combines the template with existing caption,
music and closing settings, and uses the existing original-project/candidate
and review/apply/finalize path. No uploaded rendered clip becomes a new source.
It requires a fresh output file and applied headline verification before upload.
Core also checks the uploaded Files content hash against the receipt and refuses
the already-playing file. Missing capabilities/assets/content, unsafe layouts,
stale emphasis and stale MP4s fail explicitly; no cosmetic success is returned.

Generated text stays tool-local under `CLIP_NO_CONTENT`. Exact wording is stored
in private canonical JSON at `STATE/headline-content/<sha256>.json` with a 0700
directory and 0600 file, created exclusively and never overwritten. It contains
wording, emphasis, voice revision and source identity. It is a permanent private
reproduction artifact, unlike temporary request/profile/media downloads, and
must accompany private runner backups and worker handoffs. Core receives only
`{artifact: "sha256:<digest>", sha256: "<digest>"}`, no path or generated text.
Human-entered wording retains the existing Core edit semantics.

Immutable render `provenance.headline` records that content reference together
with the resolved template/assets/timing and output SHA256. Rerender payload
`headline_base` comes from the selected immutable version. The helper verifies
and restores those bytes through the existing supported headline edit/review
boundary. Missing or corrupted content fails; mutable `review.toml`, a current
title or fresh generation cannot substitute. Historical rows without a receipt
stay unknown; there is no migration or backfill. Old Files, approvals and
published media are untouched. This stage neither publishes nor upgrades a
production worker.

Qualification on isolated-linux-runtime: the complete canonical helper suite
passes 172 tests (14 template cases), and all 14 template cases pass again from
the byte-verified archived skill materialization. The clean private-database
Social suite passes 1,559 tests; the final whitespace-control guard refinement
then passes all 57 focused headline/job/version/fix/look tests. Compilation
with warnings-as-errors, changed Elixir formatting, helper Python syntax and
Ruff F/E9 checks pass. Deleting immutable-content restore kills the unchanged
replay test (exit1); restored helper passes. Earlier failed legacy-shape and
reused-database fixture-collision runs are not counted as passes. Raw logs and
exact hashes are recorded in runner-artifact.json and evidence/runner-v1/.
