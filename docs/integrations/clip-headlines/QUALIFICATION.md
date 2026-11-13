# HTC template qualification

Task `01a18ef6-f0aa-7000-84b2-0dbea407507a`, stage 4. This is isolated
Linux runtime evidence, not a production worker installation or publication.
The original ten-second short/medium/long comparisons remain available on the
[stage 1 canvas](https://burrow.kobo-ai.com/canvases/01a18f04-9946-7000-bac3-f573d9fdd428).
Chrome Hook is Jordan's chosen direction; Neon Broadcast and Arcade Punch remain
selectable. No caption preference or show default was silently changed.

## Reproduce

Install Python 3.14, uv, Git and FFmpeg, then use new dedicated directories:

```sh
python3 docs/integrations/clip-headlines/install_templates.py \
  --target /private/new-renderer --core /path/to/core
python3 docs/integrations/clip-headlines/materialize_runner.py \
  --output /private/new-runner
CLIP_TEMPLATE_TEST_ASSETS=/path/to/core/docs/integrations/clip-headlines \
  /private/new-renderer/.venv/bin/python -m pytest /private/new-runner/tests
/private/new-renderer/.venv/bin/python \
  apps/social/priv/scripts/clip_headline_templates_qualify.py \
  --helper /private/new-runner/clip_runner.py \
  --project /private/original/htc-ges6-highlights \
  --output /private/new-qualification \
  --assets /private/new-renderer/headline-assets \
  --model-dir /private/provisioned/transcription-models \
  --ollama-endpoint http://127.0.0.1:11438
```

The selected and combined profiles both run the existing full doctor. Provision
its selected local model/backend, whisper-cli, base.en and VAD first; this fixture
does not skip readiness checks or install models on behalf of an operator.
`--smoke` runs one real edit, a disabled render, and actual fail-closed fit/asset
probes. `--generation` additionally attempts the existing episode/regenerate
policy with a live local model; it never substitutes a quote or changes a prompt
when no variant passes that policy. `--verify-existing` explicitly rechecks a
completed private fixture after a harness assertion correction; it does not
claim another CLI render. Its receipt flags this reuse. It may rebuild private
fixture setup and controls, so use it only on disposable qualification output.

The harness verifies the authorized original source SHA256 and candidate
`facb5784c2`. It copies the manifest/transcript into its own private project and
seeds a two-second candidate at source 1502–1504 s for reproducible setup. Then
normal CLI review/apply/prepare/check/finalize, driven by the canonical helper,
performs all changes. A local protocol client and file-copy uploader record
receipts; no production job, Files row, approval or publication is created.
The original project/review hashes and source identity remain unchanged.
Synthetic tone/green-card assets test music/closing independently of HTC branding.

The fixture's existing user profile uses small single-line phrase-pop captions
for comparisons. The separate style cases exercise all six supported caption
styles; no production caption selection is changed. Headline timing is exactly
1.0 s (0.2 entrance, 0.55 hold, 0.25 exit), while speech/captions continue for
2.002 s. The source is native `24000/1001`: 48 body frames, or 72 including the
one-second closing. Decoded timing samples are explicitly resampled to 30 fps;
this does not describe the encoded output as 30 fps. Closing timing allows one
resampled frame for NTSC boundary rounding, and must be one contiguous append.
Speech-only outputs preserve the decoded control waveform. The mixed output
removes only the known 220 Hz fixture bed for correlation, requires correlation
above 0.995 and speech gain within 5%, and allows under 2 ms of AAC phase shift
(the measured shift is 1 ms). A 12.5 ms source shift fails its independent test.
Closing audio mute is independent of the music bed: the synthetic no-SFX card
may retain that bed, but the tail must contain over 95% of its energy around
220 Hz, without continuing source speech.

## Gaps caught by the real renderer

The original clean package lacked the Linux face detector that earlier local
renders had used. `htc-headline-linux-prerequisites-v1.patch` packages that local
YuNet adapter, with pinned MIT model bytes and license under `models/`. Inference
never downloads. The zero-context prerequisite patch uses Git `--unidiff-zero` against the exact
pinned base and preceding patches; it produces the same qualified module bytes.
The installer verifies model, fonts, logo and actual imported
module paths/hashes. UV cache keys include the model and its license; the full
suite caught and the installer tests verified that packaging correction.

Existing shot framing could enter the reserved title region. For branded
headlines only, the existing shot planner now reserves headroom using the union
of measured face bounds plus a conservative 2% source-height padding. It keeps
one crop for the whole shot, stays within the existing zoom cap, and requires
the complete face to fit. Legacy framing is unchanged; split, unknown or
impossible geometry still fails. No blur/padding fallback or inferred speaker
choice is introduced. An initial four-second span failed the independent
**delivered-frame** face check (top 0.286 versus required 0.29). That failure was
retained, the planning guard was tightened, and the final source span passes the
unchanged 0.29 opening exclusion check. The test was not relaxed to accept it.

A refreshed review export was also not necessarily byte-applied. Canonical
helper **0.10.2** applies that export through the normal CLI gate before headline
preparation. A stricter fake fixture changes refreshed bytes and refuses
preparation until they are applied. This never forges an approval fingerprint.
Content-free CLI rendering errors expose only a finite set of safe headline
codes on stdout, preserving private stderr while surfacing actionable failures.

## Evidence and limits

`qualification-artifact.json` and `evidence/qualification-v1/` bind exact source,
helper/archive, tool patches, model/assets, native timing, decoded checks and
output hashes. The canonical helper archive is materialized byte-for-byte; no
other task's editable checkout or serving worker is used. All templates retain
actual authorized logo/font provenance and the existing headline-review/1 policy.

The full upstream run is **not green**. It collected 3,543 cases (3,516 passed, 20 skipped) and had seven
failures: the existing legacy one-pixel geometry assertion, installer EOF timeout,
four variable audio-metric cases, and a newly introduced missing model cache key.
The cache-key defect is fixed; the final renderer/installer target passes 147
cases, with two macOS-only skips and the known EOF case explicitly deselected.
The existing audio failures vary across runs and are not counted as stable passes.
Audio implementation bytes were not changed. The earlier baseline controls are
retained under `evidence/templates-v1/`; remaining failures are reported, not
hidden behind a full-green claim.

An optional live new-clip attempt on the earlier thin four-second context failed
headline preparation; a direct policy diagnostic returned
`HEADLINE_OUTPUT_UNSUPPORTED` (no accepted evidence-backed variant). It is not
counted as successful live generation. New/edit/regenerate consumer behavior is
covered by the helper and Social suites; the template work does not weaken the
voice/evidence policy to make a fixture generate. All successful video fixtures
use explicit evidence-backed human wording through the supported edit boundary.

The template-removal mutant is killed by unchanged literal profile assertions
for all three names. That is a post-render protocol assertion, not before-upload
proof. The separate wrong-logo-digest mutant fails the unchanged happy tests
**before finalize/upload**, and real wrong-asset/unsafe-fit probes record no
upload. Restored helper and materialized tests pass. Fake protocol evidence is
kept separate from decoded real videos. No surviving test mutant was suppressed.

Changed Python/renderer files pass configured Ruff and formatting; the Elixir
formatter/compiler pass. Full helper/fixture Ruff still reports 14 inherited
findings, exactly matching the archived 0.10.1 baseline by file/code/message;
zero were introduced. The caption prerequisite retains its known I001 finding.
Committed log trailing whitespace is normalized; original log hashes are pinned.
