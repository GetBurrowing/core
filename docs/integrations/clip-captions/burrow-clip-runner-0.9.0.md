# burrow-clip-runner

Runs Burrow Clip Studio jobs on a machine that has the `clip` CLI (htc-clip-tool 0.9.0+) installed. Burrow never runs `clip` itself. A human enqueues manual jobs; automatic episode discovery enqueues episode jobs. This runner claims each job, drives `clip`, uploads the render to Burrow Files, and completes or fails the job through the five job tools.

**Helper version: 0.9.0 (qualified dynamic captions; preserves closing video/music 0.8.0).** Explicit caption styles override saved process-time style through finalize --captions; appearance rerenders require the mapped original project and exact candidate, and never reprocess the submitted rendered video. Styles plain, phrase-pop and karaoke have real CLI render evidence. Refresh context.clip_next_rev from social_clip_list.next_rev when rerendering after removal; immutable tombstones can leave revision gaps.  Adds typed version-based nudge, caption-word and alternate-cut fixes. The expanded fake suite passes (88 tests), including episode fan-out, zero picks and partial failure. Real installed `clip` 0.9.0 commit `58960577337d5682761e1538ff4365d4ba0b4e18` rendered a short deterministic fixture with all four ±1s nudges, a visibly changed caption word, and alternate promotion followed by process/resume and finalize. Fixture transcript/proposals were supplied during test setup; rendering and resume CLI subprocesses were real and unpatched. This was an isolated renderer test, not a production upload/claim run.



## Headline integration (helper 0.4.0)

Requires the upstream `headline-review/1` patch and `clip version --json` capability `headline_review: 1`, not merely CLI version 0.9.0. Patch installation is an explicit prerequisite; an unpatched installed CLI fails HEADLINE_CLI_UNSUPPORTED. No production rollout or upstream merge is implied.

- Every `new_clip` generates automatically through existing tool policy (`consumer: episode`). `fix.operation: regenerate_headline` uses `consumer: regenerate`. A human edit sets `payload.headline = {"consumer":"edit", "requested_headline":"<user-entered text>"}` and bypasses generation. Do not supply generated text through MCP.
- The loop supplies `context.headline_voice = {revision, direction}` privately from the current show bible snapshot. Missing direction or revision fails HEADLINE_VOICE_MISSING; no hardcoded show/canvas ids or fabricated ratification. HTC's entertainment/comedy/positivity direction is known, remaining voice rules incomplete.
- Edit/regenerate require `payload.base_render_id` equal to `context.base_render_id` fetched from the selected immutable current render snapshot. Missing/stale bases fail. Source identity is `payload.source_id`, the immutable episode source_file_id, or a SHA256 of its source URL. Core remains responsible for binding these payload fields under its clip lock, protecting immutable versions, and idempotent completion; the helper never invents a base or overwrites an older version.
- Apply bounds, export fresh review hashes and use actual snapped bounds. The derived USER profile enables captions.hook_title, preserves an enabled caption style, and enables phrase-pop only when the inherited style is none. The initial review apply/refresh and headline apply use that same derived profile so their packaging hashes describe the actual render. Prepare-review writes explicit headline, normal review --apply applies it, and --check-applied verifies actual hook_title_for equality including stale variant precedence. Only then finalize --regenerate with an explicit enabled --captions style (overriding any saved process-time none). Existing captions/other review edits remain intact; a stale/missing output fails HEADLINE_RENDER_MISSING rather than uploading an old file.
- Request JSON is 0600 and removed on every exit. Every clip subprocess has CLIP_NO_CONTENT=1, including cloud projects, and excludes the Burrow token. Generated text stays local. Completion never sends headline text; the safe applied receipt is stored in local state.json only, with ids, bounds, voice revision and status. Explicit text export is refused. A prepared/applied receipt is not render success.
- Tool-local approval permits rendering only. It never grants Burrow approval, scheduling or publishing. No timeline, keyframes or canvas editor; no picks JSON, internal-manifest writes or built-in profile changes.

Real evidence: compatible isolated installed CLI 0.9.0 plus the pinned hook patch rendered a seeded 5-second MP4 before and after a real helper edit. Viewed frames changed “We shipped the app” to “The team celebrated”, while the lower caption region stayed pixel-identical. Transcript/proposal were fixture setup; CLI review/application/finalize and FFmpeg were real. This does not prove live model availability or production claim/upload; generation policy is covered by tool/runner fixtures and may fail visibly until the runtime local model is provisioned. The full test suite and mutation evidence are recorded with the task's stage evidence.


## Automatic episodes (helper 0.5.0)

Requires core's episode progress-picks and headline_applied completion contract plus the existing headline-review/1 CLI capability. An older core or unpatched CLI fails visibly; this is not proof of a production rollout or live local-model availability. The episode path has fake-CLI and isolated Social integration evidence.

- Claim the episode job normally. The helper requests social_clip_job_source itself; execute that request and return the short-lived signed URL through the reply file. Never log or persist the URL. Supply the existing private headline_voice context from the show's bible snapshot; missing/incomplete required voice fields fail rather than inventing policy.
- Process the episode once, cache its project locally, and read only the supported exported review.toml. Register non-rejected cut candidates as content-free candidate_id/in_s/out_s picks through social_clip_job_progress. Core locks the parent, binds source/profile, persists child ids, and rejects changed replay plans. No picks JSON or custom renderer.
- For each returned child, claim it and reuse the processed project with the canonical new-clip headline handler. headline-review/1 prepares, applies and verifies the exact headline, then finalize produces a fresh rendered MP4. Generated text remains local. Completion sends headline_applied=true only after that succeeds; immutable render history and explicit human approval remain core-owned.
- Execute and acknowledge EVERY reply_file request, including child claim, complete and fail. Child terminal requests do not finish the parent run: only the terminal line for the original parent job ends it. A child completion is acknowledged before parent completion. Child heartbeat updates also keep the parent live.
- Failed children fail the parent without discarding completed pending-review children. Zero picks completes explicitly without rendering. No Burrow approval, scheduling or publishing calls. A supported fresh headline render is required; an intent or prepared receipt alone is not success.

## Episode mutation evidence (2026-10-28)

The three-pick fake-CLI case independently pins exact review.toml headlines, one process, three finalizes, prepare/apply/check-applied ordering, content-free completion and no approval/schedule/publisher calls. Removing the actual helper `_apply_headline` invocation makes the unchanged literal review.toml assertion fail (all three headline fields become absent), exit 1; restoring it returns exit 0. This is helper protocol evidence, not live CLI/model provisioning or production upload evidence. The helper source remains 0.5.0; this update adds fixture coverage and corrects its installation digest.

## When to run

- Run it on the machine that has `clip` installed, when that machine should serve Burrow clip jobs: at session start, after any restart or crash of the runner, and on a poll loop while it is serving (every 30 to 60 s while idle is enough).
- Run it only for the Burrow profiles you were told to serve. Do not run two runners against one state dir. A second `run`/`reclaim` gets exit 75 (`busy`).
- Do not run it to review, approve or post clips. That is a human's job in Burrow's Review. The runner only renders.

## Typed version fixes (0.3.0)

Burrow enqueues `rerender` with `base_render_id`, `expected_rev`, immutable source/look/bounds and a `fix` object. Core rejects stale versions and duplicate in-flight jobs under the clip lock. The runner uses `candidate_id` when supplied and fails `BASE_CANDIDATE_MISSING` rather than substituting another cut.

- `nudge`: `edge` is start/end; `delta_s` is exactly ±1; payload in_s/out_s contains the requested source bounds. Tool-applied bounds are re-exported after apply and returned as safe numeric actual_in_s/actual_out_s. A newly changed safe title overlay may require one fresh-base approval of the target before finalize; hashes are never forged.
- `caption_word`: `caption_fixes` identifies zero-based whitespace-word position, original and replacement. Check the local review entry's full transcript override, or its untruncated `# says:` excerpt. Reject stale targets. A truncated excerpt fails `CAPTION_CONTRACT_UNSUPPORTED`; do not read internal transcript/project files or replace an unseen tail. Correct only that word via transcript= in the selected review entry. Existing caption corrections accumulate in the immutable core snapshot as user-supplied inputs.
- `alternate_cut`: choose the first different eligible alternate in the exported review file; approve its own bounds, apply, run `clip process SOURCE --project NAME --profile PROFILE --resume` to cut it, refresh review, then finalize --regenerate with an explicit enabled --captions style (overriding any saved process-time none). Return candidate_id and alternate_id, keeping the Burrow clip id.
- `regenerate_headline`: uses the integrated shared headline-review/1 boundary below. No parallel prompt or generator; enqueued intent is never rendering success.

Missing review base fields fail `REVIEW_CONTRACT_UNSUPPORTED`; an apply that still leaves the target pending fails `REVIEW_NOT_APPLIED`. All local clip commands retain CLIP_NO_CONTENT=1, Burrow token is removed from child environments, and no tool-derived transcript/title is returned locally. Derived profiles are removed on errors as well as success. Real-run results distinguish requested end4.5/6.5s from applied4.3/6.3s (word snapping).

## Config

Everything the runner needs is either in this skill or kept privately by the agent running it. None of it goes in this skill.

| What | Where it comes from |
|---|---|
| Profile ids to serve | `social_profile_list`. Keep the list privately. |
| Each profile's Files project id | `social_profile_get` (its project). Passed per job as `context.project_id`. |
| Your agent id | Your own identity. Used by `reclaim --agent-id`. |
| State dir | `~/.clip-runner` by default. `--state-dir` or `CLIP_RUNNER_HOME` overrides. Holds `bin/`, `jobs/` (the crash journal), `outbox/`, `replies/`, `state.json` (Burrow clip id → clip project) and the lock. |
| `CLIP_RUNNER_TOKEN` | Your agent token, exported into the `run` process only. Never echoed, never written down. |
| `CLIP_RUNNER_BASE_URL` | Your Burrow base URL. Must be https (plain http is accepted only for 127.0.0.1, a local dev server). |
| `CLIP_BIN` / `--clip-bin` | The `clip` binary, if it is not on PATH (the installer puts it in `~/.local/bin`). |
| `CLIP_RUNNER_YTDLP` | Optional yt-dlp path, for `source_url` episodes. |
| `clip` itself | Installed with the tool's own `install.sh --profile how-to-computer`. Its AI key is stored by `clip auth set anthropic`, never by the runner. |

## Rules (non-negotiable)

- The helper runs only `clip` commands. It also edits review.toml, and it may use yt-dlp to fetch an episode by URL. It never writes picks JSON.
- Read clip state only through `clip version --json`, `clip doctor --json`, `clip project info --json` and `clip config get`. Project files are internal. The only project file the helper edits is review.toml: only supported `start`, `end`, `decision`, `title` and `transcript` fields of the selected entry. It preserves edl/captions/packaging hashes verbatim. The tool alone writes the supported headline field through prepare-review; the helper reads it to verify exact forwarding.
- Never edit the built-in `how-to-computer` profile (a git pull overwrites it, and the tool's `test_htc_lock` pins it). Looks go in user profiles:
  - `burrow-<profile id>` (`payload.clip_user_profile`) has `extends = "how-to-computer"` and holds the show default.
  - A per-clip look goes in `burrow-<profile id>-job-<job id>`, which extends `burrow-<profile id>`. It is used for one render and then deleted, on the failure path too.
- Failure messages are content-free: a step name, an exit code, an error code and numbers. They never include a title, transcript text, file name or stderr.
- The runner renders and completes jobs. It never approves, schedules or publishes a post.
- Never print or store the agent token. The helper reads it from the environment, sends it only to `CLIP_RUNNER_BASE_URL`, and strips it from the environment of every `clip` command.

## Project music (helper 0.7.0)

Core's `payload.music` is the full selected track contract: `file_id`, `enabled`, `level_db` (−60..0). Legacy music/level look flags never select a song. For each render, the helper checks the installed CLI's `config get music.enabled --profile P`: an enabled music job fails `MUSIC_CLI_UNSUPPORTED` if unsupported, even if the version string says 0.9.0. Use a current compatible upstream tool; older 0.9.0 installs lack music. A disabled music job remains compatible with those old CLIs.

The single helper requests `social_clip_job_source(job_id, asset="music")`; forward it through MCP like every other request. Core takes the asset ONLY from the persisted job, checks claimer/open status plus current project/org/finalized audio, and returns a 15-minute Files URL. Never supply another file id, save the URL, or echo it. The bridge deletes its private reply file. The helper validates returned identity/project/type/size, downloads to a 0700 job directory with 0600 audio bytes, bounds streamed bytes to declared size and 25 MB, and gives only the disposable local path to a temporary user profile's `music.path`. `music.enabled` and `music.level_db` use upstream MusicConfig; speech loudness, ducking, speech margin and fades stay renderer-owned. No FFmpeg mixer in Burrow or this helper. Track, partial download and derived profile are removed on success/failure; downloads receive no agent token and signed URLs never enter CLI argv/env, journal/state or complete/fail. The runner also strips BURROW_TOKEN/BURROW_API_TOKEN and CF access credentials from child environments. Muting retains the asset/gain in Core and downloads nothing.

Canonical helper SHA256 `67152ecee851db7df9d5bf99200270dfcfb58320358e8da0d8052c386e9a5b21`. Isolated local fixture used unmodified upstream 82ef513 music implementation through the existing compatible Python environment (version metadata still identifies the installed 0.9.0 distribution; actual module path/commit recorded in receipt). It rendered original project/candidate with a 997 Hz test song: off amplitude 1.97e−6, −42 dB 0.0003233, −24 dB 0.002562, three distinct MP4 hashes. This proves actual audio/gain change under the upstream renderer; it is not a production run or an upstream headline patch rollout. 106 helper tests pass, including 12 music identity/download/privacy/failure/cleanup cases.

## Closing video (helper 0.8.0)

Core pins `payload.closing_video` at enqueue: `enabled`, `file_id`, `audio` (`keep`/`mute`), `project_id`, `profile_id`, `org_id`, SHA256 `content_hash`, `content_type`, `byte_size` and verified video measurements. The helper never selects from the old boolean look.outro, latest show default, a caller URL or a suffixed render. The clip's original mapped project/candidate remains its source.

- Verify installed `config get outro.audio` and `config get outro.path` support, as well as the existing headline-review/1 boundary. A version 0.9.0 string alone is insufficient: older distributions lack outro/music. Enabled jobs on an incapable CLI fail `CLOSING_CLI_UNSUPPORTED`. Disabled/legacy jobs can run on an old CLI. On a capable CLI they explicitly set `outro.path=""`, clearing inherited settings; no invented `outro.enabled`.
- Enabled jobs request `social_clip_job_source(job_id, asset="closing_video")`. Core serves only that job's pinned asset. Forward every request/reply through the existing loop. The helper verifies file/project/type/size/SHA256 against the snapshot and derives the download byte cap from the source endpoint's `max_bytes` (Core's single 200 MiB contract). It validates the streamed count and SHA256 again. No arbitrary file identifier, path or URL is accepted from a separate runner input.
- Download directly into `tmp/closing-<job id>/` (0700); bytes and partial bytes are0600. Media requests and redirects carry no Burrow/CF token, reject credentials and non-HTTP(S) redirects, use HTTPS except loopback fixture HTTP, and do not inherit proxy headers. Signed URLs never enter CLI argv/env, journal, state, outbox, completion/failure or logs.
- One derived user profile combines look/music with `outro.path=<private file>` and the pinned `outro.audio`. Source/imported temporary profiles are private (0600 via subprocess umask), and all CLI processes retain `CLIP_NO_CONTENT=1` and stripped Burrow/CF credentials. The compatible upstream finish graph owns real decoding/probing, scaling/padding/framerate/audio normalization, captions/headline cutoff, music and loudness guards. The helper adds no concatenator or mixer.
- Private video/partial bytes, profile import files, request/reply files and derived profiles are removed on success/failure/SIGTERM; startup reclaim scrubs journaled video/music/headline/profile/reply remnants. Cleanup failures fail safely before upload/completion rather than promoting a render. An invalid or unavailable asset fails visibly. Core preserves the playing version until a new render exists and a human approves it.
- Enabled completion omits runner-estimated content `duration_s`: Core measures total output duration/dimensions/bytes from the uploaded file. Requested/actual source bounds remain content-only. Repeated headline/caption/music rerenders finalize the original source/candidate, so the closing video appends exactly once.

Verification on isolated-linux-runtime:138 complete protocol tests, separate from real rendering. The repository harness `apps/social/priv/scripts/clip_closing_video_fixture.py` seeds deterministic proposals/transcript only, then runs unpatched process/resume, review/apply and real helper finalize on upstream 82ef513 plus the existing headline-review/1 patch. Seven TEST ONLY renders cover two clip/project identities, A/keep, A/mute, replacement B, disabled and headline/caption/music rerenders. Decoded frames prove exactly 36 closing frames; totals 6.2s enabled/5.0s disabled; the 997 Hz closing tone is present for keep (~0.1395) and absent for mute, with 440 Hz source sound retained. Closing delivery/clean pixels match; changed headline/caption pixels are verified before the seam. A hash-correct fake-video fixture fails before upload. The exact imported module/source/patch/helper hashes and command receipts live alongside the harness fixtures. The real HTC logo video is still requested; these assets are visibly labeled TEST ONLY and are never represented as customer media.

The existing three-render real music regression also passes (off/-42/-24dB have distinct measured tone amplitudes). Additional upstream renderer tests were 19/21, with two acoustic-tolerance failures also reproduced on unmodified 82ef513 (case variability recorded); they are NOT counted as a green suite. No renderer guard was weakened or changed.

## Dynamic caption treatments (helper 0.9.0)

Extends the current helper in place, preserving its 0.8.0 closing-video, music,
headline, private downloads, source-project mapping and child request/reply
protocol. Core tracks the exact source, eleven test blocks, install verifier
and digests under `docs/integrations/clip-captions/`.

- New values are `type-on`, `focus-word`, `editorial-punch`; legacy `plain`,
  `phrase-pop`, `karaoke` and historical visual presets retain their meanings.
  This is a motion distinction, not a palette alias; no retention claim.
- Install pinned upstream `82ef5132b926fed33a80a304364fdda14335c2d5` plus Core's
  tracked headline and caption patches following that directory's README.
  Verify the executable/import paths and all packaged source/font digests with
  `verify_install.py`; the unchanged CLI 0.9.0 version label is insufficient.
  Use a stable operator-owned install, not another task's scratch imports.
- Before a new treatment renders, the SAME invoked `clip version --json` must
  report `caption_treatments:1`, all six enabled style names and the pinned
  imported `captions.py`/`dynamic_captions.py` SHA256 values. Otherwise fail
  `CAPTION_CLI_UNSUPPORTED` before finalize/upload, with no silent fallback.
  Unknown style values fail `CAPTION_STYLE_UNSUPPORTED`. Explicit dynamic-style
  jobs also require a fresh candidate output after finalize; a successful CLI
  exit with only stale previous bytes fails `CAPTION_RENDER_MISSING`.
- The immutable payload `look.cap.style` is forwarded even when identical to
  the show default (empty delta). Both the disposable combined USER profile's
  `captions.style` and explicit finalize `--captions STYLE` are required, so a
  saved process-time `none` cannot override the selection. Headline rendering
  retains the explicit chosen style. No built-in show profile is edited.
- Run the verifier with `--helper <installed helper> --receipt <private json>`
  after installation. Operators configure its content-free receipt through
  `CLIP_CAPTION_RENDERER_RECEIPT` on the Social server; browser assertions do
  not qualify an install. Missing/mismatched qualification leaves only legacy
  styles selectable. Every worker still checks its actual executable per job.
  A receipt is installation evidence, not a render, approval or publication.
- Fake protocol suite: 153 passed on this runtime, including literal profile
  and finalize forwarding for all three styles, inherited/default look,
  unsupported/malformed capabilities, changed digests, privacy and cleanup.
  Omitting explicit finalize `--captions` kills six unchanged literal tests;
  restored code passes. Actual same-excerpt media/UI comparison remains the
  later task stage; no production rollout is claimed here.

## Privacy (both modes are supported)

- `[privacy] mode` is read from `clip project info --json` once a project exists. Before that, it is read from `clip config get effective_privacy_mode` and `clip config get privacy.mode` for the user profile.
- This follows the clip-studio plugin's `preflight.sh`: only an explicit `cloud` counts as cloud. A mode that was only inferred from the AI backend counts as local, and so does an unreadable or missing one.
- **Cloud** (this mini's runner): complete may return the clip tool's title, but only when the Burrow clip has no title of its own.
- **Local**: every `clip` command runs with `CLIP_NO_CONTENT=1` (also retained in cloud mode). Complete and fail carry ids, seconds, numbers, error codes and the `file_id` only, and `title`, `caption`, `speaker` and `episode_code` are sent as null.
- The helper never prints review.toml, transcript, srt or final-folder file names. Uploads are named `clip-<clip id>-r<rev>.mp4`.
- Until the mode is known (version, doctor, config get), `clip` always runs with `CLIP_NO_CONTENT=1`, so it fails closed. A `save_default` job never reads the mode and is always treated as local.
- `clip version --json` `content_free >= 2` is recorded as `CLIP_CONTENT_FREE`. The helper never forwards `clip` output either way.

## Setup (once per machine)

1. Pick a state dir. The default is `~/.clip-runner` (override with `CLIP_RUNNER_HOME` or `--state-dir`).
2. Write the `clip_runner.py` block below to `~/.clip-runner/bin/clip_runner.py`, byte for byte. Check it with `shasum -a 256`; the result must equal the pinned sha256 below. If it does not, stop.
3. Optional self-test:
   - Write the helper to `~/.clip-runner/src/clip_runner.py` and the eleven `tests/` blocks to `~/.clip-runner/src/tests/`.
   - Run `python3 -m pytest -q ~/.clip-runner/src/tests` (needs pytest). Expect 153 passed.
   - The tests use a fake `clip` and never touch a real project or profile.
4. Keep a private note of the Burrow profile ids this runner serves (from `social_profile_list`), your agent id, and each profile's Files project id (from `social_profile_get`). These do not go in this skill.
5. The upload token is the `token` key of your agent credentials file. Export it only into the `run` process's environment, as `CLIP_RUNNER_TOKEN`, together with `CLIP_RUNNER_BASE_URL`, your Burrow base URL (https). Never echo the token.
6. Optional: install yt-dlp, or set `CLIP_RUNNER_YTDLP`, to fetch episodes by `source_url`.

Pinned sha256 of `clip_runner.py` 0.9.0: `67152ecee851db7df9d5bf99200270dfcfb58320358e8da0d8052c386e9a5b21`

## The loop (you are the only MCP caller)

The helper reads JSON on stdin. It writes the tool calls it wants made, one JSON object per line: `{"tool": "<name>", "args": {...}}`.

- Forward every line, in order, as that MCP call, with exactly those args.
- A line that also has `"reply_file"` is a request. Make the call, then write the tool's JSON result to that path. Write it to `<path>.tmp` and rename it into place. The helper waits up to `--reply-timeout-s` (default 900) for it.
- On a tool error, write `{"error": true, "code": "<code>"}` to the reply file instead.
- Content-free warnings (for example `LOOK_KEYS_UNMAPPED cap.hl`) go to stderr. Do not forward them. Log them if you like.

**1. Startup reclaim.** Run it first, every time the runner starts.
- For each served profile, call `social_clip_job_list` with `status=claimed` and again with `status=running`.
- Pipe the jobs in as `{"jobs": [...]}` to `python3 ~/.clip-runner/bin/clip_runner.py reclaim --agent-id <your agent id>`.
- Forward each `social_clip_job_fail` line (code `RUNNER_RESTARTED`).
- `job_closed` and `not_claimer` refusals are harmless.
- Exit 75 (`{"busy": true}`) means a `run` holds the lock. Do not reclaim then.

**2. Poll.**
- Call `social_clip_job_list` with `status=queued` for each served profile.
- Pipe the jobs to `clip_runner.py order`. It prints the claim order, oldest first.
- Call `social_clip_job_claim` on each id in turn. `already_claimed` means another runner won: skip it silently and try the next id.
- If nothing is claimed, wait and poll again.

**3. Build the run context for the claimed job.**
- `clip_rev`: the clip's current `rev`, from `social_clip_list` for the profile (match the clip id). Required for `rerender`. Also supply `clip_next_rev` from the same row’s `next_rev`: removing a newer render can leave revision gaps. The helper requires `payload.expected_rev == clip_next_rev` for rerender (legacy contexts fall back to clip_rev + 1), and refuses a revision at or below clip_rev. For new_clip, expected_rev must equal clip_rev. Refresh both values immediately before execution; do not infer next_rev from the displayed version.
- `project_id`: the Files project of the Burrow profile.
- Episode, `new_clip` only (and a `rerender` whose mapping was lost):
  - For `payload.episode.source_url`, the helper fetches it itself (yt-dlp, or a direct media URL).
  - For `payload.episode.source_file_id`, pass `episode_path` (a local copy you already have) or `episode_url` (a signed download URL). No agent tool mints a download URL for a Burrow file today. Without either, the job fails with `SOURCE_FILE_NO_DOWNLOAD`.

**4. Run it.**
- Start it in the background, with the token in its environment only:

  `echo '{"job": <claimed job>, "context": {...}}' | CLIP_RUNNER_TOKEN=… CLIP_RUNNER_BASE_URL=… python3 ~/.clip-runner/bin/clip_runner.py run`

- Forward the lines as they appear: progress at step boundaries, plus a heartbeat at least every 60 s.
- Answer the one `file_add` request, which uses the presigned branch: `byte_size`, `content_type` `video/mp4` and your `project_id`. Write its result (`id`, `upload_url`) to the reply file.
- The helper then POSTs the bytes with the bearer token, checks that the returned `content_hash` matches the local sha256, and completes with that `file_id`.
- There is one final terminal line for the original job, `social_clip_job_complete` or `social_clip_job_fail`. Episode child completions/failures are request/reply messages; acknowledge them and keep serving the parent until its own terminal line.
- Exit 0 means done and 1 means failed. Every line is also appended to `<state>/outbox/<job_id>.jsonl`.

## What each kind runs

`P` = `payload.clip_user_profile` (`burrow-<profile id>`). `N` = `burrow-<clip id>`, the clip project name. `clip` keeps projects under its own clips folder. `D` = the project folder, as reported by `project info`.

- **Preflight (every job):** `clip version --json` (0.9.0 or later, else `CLIP_TOO_OLD`), then `clip doctor --json` (any `fix` check fails the job as `CLIP_DOCTOR_FIX (<check names>)`).
- **new_clip:**
  1. `profile path P`; if P is missing, `profile import <tmp> --name P --force --yes`, where the file is `extends = "how-to-computer"`.
  2. `config get effective_privacy_mode --profile P`, then `config get privacy.mode --profile P`.
  3. Fetch the episode.
  4. `process <video> --project N --profile P`.
  5. `project info --json N`. This gives the authoritative privacy mode and D.
  6. `review D --overwrite`.
  7. Edit review.toml: on the cut clip that best overlaps `[in_s, out_s]`, set `start = in_s`, `end = out_s` and `decision = "approve"`. Alternates are never picked.
  8. Record Burrow clip id → {project, path, tool clip id} in `<state>/state.json`.
  9. If `clip_overrides.mapped` is non-empty, `profile import` the derived profile.
  10. `review D --apply`.
  11. Prepare/apply/check the headline using the integration above; then `finalize D --profile <derived> --regenerate`.
  12. Delete the derived profile.
  13. Upload `final/<stem>.mp4`, the captioned render. It is never the `_clean` render or the srt.
  14. Complete.
- **rerender / trim:** preflight. If the mapping exists: `project info --json D`, then `review D --overwrite`. Edit only the mapped clip's `start`/`end` (and `decision = "approve"`, which the trim needs to render), then derived profile if needed, `review D --apply`, `finalize D [--profile <derived>] --regenerate`, delete the derived profile, upload, and complete. If the mapping is missing, re-process from the episode exactly as new_clip does.
- **save_default:** preflight, then `profile import <tmp> --name P --force --yes` (`extends = "how-to-computer"` plus the mapped look), then `profile use P`. It completes with no file.
- Look keys: `clip_overrides.mapped` (dotted `section.key`, for example `captions.size_frac`) becomes TOML sections. The `clip_overrides.unmapped` keys are reported on stderr as `LOOK_KEYS_UNMAPPED`. They are never invented.
- The derived profile is removed by resolving `clip profile path <name>` and unlinking that file, because `clip` has no `profile delete`. The helper refuses any path that is not `<name>.toml` or that sits inside the tool's package.

## Failure codes

- From `clip`: its JSON `error.code` or `code`, else `CLIP_EXIT_<n>` or `CLIP_SIGNAL_<n>`. Also `CLIP_TOO_OLD`, `CLIP_VERSION_UNKNOWN`, `CLIP_DOCTOR_FIX`, `CLIP_TIMEOUT` and `CLIP_NOT_INSTALLED`.
- From the job: `REV_MISMATCH`, `REV_UNKNOWN`, `BAD_PAYLOAD`, `UNKNOWN_KIND`, `NO_CANDIDATE`, `CANDIDATE_NOT_CUT`, `REVIEW_FORMAT`, `REVIEW_MISSING`, `PROJECT_NOT_FOUND` and `OUTPUT_MISSING`.
- Fetch: `SOURCE_UNAVAILABLE`, `SOURCE_MISSING`, `SOURCE_FILE_NO_DOWNLOAD`, `SOURCE_NEEDS_YTDLP`, `FETCH_HTTP_<n>`, `FETCH_YTDLP_EXIT_<n>` and `FETCH_FAILED`.
- Upload: `UPLOAD_UNAVAILABLE` (no token, base URL or project id), `UPLOAD_HOST_MISMATCH`, `UPLOAD_HTTP_<n>`, `UPLOAD_HASH_MISMATCH`, `UPLOAD_NO_URL`, `REPLY_TIMEOUT` and `REPLY_ERROR`.
- Runner: `RUNNER_SIGTERM`, `RUNNER_SIGINT`, `RUNNER_EXCEPTION` and `RUNNER_RESTARTED` (startup reclaim). When the job tool refuses complete, the job fails with that tool's code, upper-cased.

## Known gaps and open questions

- These are open with the htc-clip-tool maintainer:
  - Does `clip` have a per-clip look override, so the derived profile could be dropped?
  - May a review.toml `start`/`end` extend beyond a candidate's own bounds for a user-chosen IN/OUT?
- A Burrow file episode (`source_file_id`) needs a download path an agent can use. ClipJobs puts no signed URL in the payload, and no agent tool mints one.
- `finalize` prints no JSON. `duration_s` is the applied `end - start`, and `width`/`height` are not sent.
- There is one clip project per Burrow clip. Each new clip re-processes (transcribes) its episode in its own project.
- `profile use P` (save_default) changes `clip`'s global default profile. The runner always passes `--profile`, so its own jobs are unaffected.
- Burrow has no server-side lease. A runner that dies and never restarts leaves its claimed job stuck in `claimed`. Restart the runner to reclaim.

## Source

### `clip_runner.py`

````python
#!/usr/bin/env python3
"""burrow-clip-runner helper: the deterministic half of the Burrow Clip Studio runner.

The agent running the `burrow-clip-runner` skill is the only MCP caller. This
helper never talks to Burrow's MCP. It reads job JSON on stdin and writes the
tool calls it wants made, one JSON object per line, on stdout:

    {"tool": "social_clip_job_progress", "args": {"job_id": ..., "progress": 0.4, "eta_s": 90}}

The agent forwards every line, in order, as the named MCP call. A line that
also carries "reply_file" is a request: the agent makes the call and writes
the tool's JSON result to that path (the helper waits for it). The last line
of `run` is always `social_clip_job_complete` or `social_clip_job_fail`.

Subcommands (all JSON on stdin, JSONL on stdout):
    version                              print {"version": ...}
    reclaim --agent-id ID                stdin {"jobs": [claimed + running jobs]};
                                         emits a fail (RUNNER_RESTARTED) for every job
                                         claimed by ID and every job the local journal
                                         records as in flight
    order                                stdin {"jobs": [queued jobs]}; prints
                                         {"claim_order": [job ids]} oldest first
    run                                  stdin {"job": <the job returned by claim>,
                                                "context": {"clip_rev": n, "project_id": id,
                                                            "episode_path"?: p, "episode_url"?: u}};
                                         runs it, emits progress, then complete or fail

Environment for `run` (never logged or stored): CLIP_RUNNER_TOKEN (the agent's
bearer token, sent only to CLIP_RUNNER_BASE_URL for the presigned upload POST),
CLIP_RUNNER_BASE_URL, optional CLIP_RUNNER_YTDLP (path of yt-dlp).

Rules this file keeps: only `clip` commands plus review.toml (and yt-dlp to
fetch an episode); never writes picks JSON; never writes the built-in
how-to-computer profile (looks go in user profiles that extend it); never
prints stderr, transcript text, titles or file names; error messages are
content-free (step name, exit code, error code only). Under the clip tool's
local privacy mode every clip command runs with CLIP_NO_CONTENT=1 and
complete/fail carry ids, numbers, codes and the file_id only.

Python 3.11+ stdlib only.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable, Iterable
from pathlib import Path
from typing import Any, Protocol

VERSION = "0.9.0"

KINDS = ("new_clip", "rerender", "save_default", "episode")
RESULT_KEYS = (
    "file_id",
    "title",
    "caption",
    "speaker",
    "episode_code",
    "platforms",
    "duration_s",
    "width",
    "height",
    "source_label",
    "actual_in_s",
    "actual_out_s",
    "candidate_id",
    "alternate_id",
    "headline_applied",
)
META_KEYS = ("title", "caption", "speaker", "episode_code")
SOURCE_LABEL = "htc-clip-tool"
BASE_PROFILE = "how-to-computer"
LEGACY_CAPTION_STYLES = ("plain", "phrase-pop", "karaoke")
DYNAMIC_CAPTION_STYLES = ("type-on", "focus-word", "editorial-punch")
CAPTION_STYLES = LEGACY_CAPTION_STYLES + DYNAMIC_CAPTION_STYLES
# Pinned actual imported renderer sources, not the CLI's distribution label.
CAPTION_RENDERER_SHA256 = "25595724985663807fb7f9976cdabf9f2d4a04c1bb98df73fd92b47b7e056141"
CAPTION_TEMPORAL_SHA256 = "385f5e446c09bd06bb5fb11aaa4228fa95e47fa808e1c1d750bf6633d039aee7"


def _qualify_caption_style(runner, style):
    if style not in CAPTION_STYLES:
        raise ClipError("CAPTION_STYLE_UNSUPPORTED", "captions")
    if style in DYNAMIC_CAPTION_STYLES:
        info = runner.clip("caption_capability", ["version", "--json"])
        renderer = info.get("caption_renderer") or {}
        styles = info.get("caption_styles")
        if (type(info.get("caption_treatments")) is not int or
                info["caption_treatments"] != 1 or
                not isinstance(styles, list) or
                not all(isinstance(s, str) for s in styles) or
                not set(CAPTION_STYLES).issubset(styles) or
                not isinstance(renderer, dict) or
                renderer.get("sha256") != CAPTION_RENDERER_SHA256 or
                renderer.get("temporal_sha256") != CAPTION_TEMPORAL_SHA256):
            raise ClipError("CAPTION_CLI_UNSUPPORTED", "captions")


MIN_CLIP_VERSION = (0, 9, 0)
MIN_CONTENT_FREE = 2
DEFAULT_STATE_DIR = Path(os.environ.get("CLIP_RUNNER_HOME", "~/.clip-runner")).expanduser()
DEFAULT_HEARTBEAT_S = 30.0  # contract: at least every 60s
DEFAULT_TIMEOUT_S = 3 * 3600.0
DEFAULT_REPLY_TIMEOUT_S = 900.0
EXIT_BUSY = 75

_CODE_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,64}$")
_PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,120}$")  # clip's own profile-name rule
_LOOK_KEY_RE = re.compile(r"^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$")  # section.key, as ClipLook maps them


# ── Errors ──────────────────────────────────────────────────────────────


class JobToolError(Exception):
    """A job tool refused the call; `code` is the envelope's code."""

    def __init__(self, code: str, message: str = ""):
        super().__init__(message or code)
        self.code = code


class AlreadyClaimed(JobToolError):
    def __init__(self, message: str = "already_claimed"):
        super().__init__("already_claimed", message)


class ClipError(Exception):
    """A job step failed. `code` goes to social_clip_job_fail; the message is content-free."""

    def __init__(self, code: str, step: str, detail: str = ""):
        self.code = code
        self.step = step
        self.detail = detail
        super().__init__(f"{step} failed" + (f" ({detail})" if detail else ""))


class RunnerInterrupted(BaseException):
    """Raised from the SIGTERM/SIGINT handler so try/finally paths still run."""

    def __init__(self, signum: int):
        self.signum = signum
        self.code = {signal.SIGTERM: "RUNNER_SIGTERM", signal.SIGINT: "RUNNER_SIGINT"}.get(
            signum, f"RUNNER_SIGNAL_{signum}"
        )
        super().__init__(self.code)


def warn(code: str, detail: str = "") -> None:
    """A content-free warning on stderr (never forwarded to Burrow)."""
    sys.stderr.write(f"clip_runner: warning {code}" + (f" {detail}" if detail else "") + "\n")
    sys.stderr.flush()


# ── Job-tool client ─────────────────────────────────────────────────────


class JobClient(Protocol):
    """The five Burrow job tools (the claimer is always the calling agent), plus
    `request` for a call whose result the helper needs (file_add)."""

    def list_jobs(self, profile_id: str, status: str) -> list[dict]: ...

    def claim(self, job_id: str) -> dict: ...

    def progress(self, job_id: str, progress: float, eta_s: float | None = None) -> None: ...

    def complete(self, job_id: str, result: dict) -> None: ...

    def fail(self, job_id: str, error: str, code: str) -> None: ...

    def request(self, tool: str, args: dict, wait: Callable[[], None] | None = None) -> dict: ...


class OutboxClient:
    """The CLI's client: list_jobs reads a stdin snapshot, writes become JSONL lines.

    Claim is request/response, so the agent makes it itself (see `order`).
    `request` emits a line with "reply_file" and waits for the agent to write
    the tool's result there.
    """

    def __init__(
        self,
        out=None,
        snapshot: Iterable[dict] = (),
        outbox: Path | None = None,
        reply_dir: Path | None = None,
        reply_timeout_s: float = DEFAULT_REPLY_TIMEOUT_S,
    ):
        self.out = out or sys.stdout
        self.snapshot = list(snapshot)
        self.outbox = outbox
        self.reply_dir = reply_dir
        self.reply_timeout_s = reply_timeout_s
        self._seq = 0

    def list_jobs(self, profile_id: str, status: str) -> list[dict]:
        return [
            j
            for j in self.snapshot
            if j.get("status") == status and (profile_id is None or j.get("profile_id") == profile_id)
        ]

    def claim(self, job_id: str) -> dict:  # pragma: no cover - agent-side
        raise NotImplementedError("the agent claims with social_clip_job_claim")

    def _emit(self, tool: str, args: dict, extra: dict | None = None) -> None:
        line = json.dumps({"tool": tool, "args": args, **(extra or {})}, sort_keys=True)
        self.out.write(line + "\n")
        self.out.flush()
        if self.outbox is not None:
            self.outbox.parent.mkdir(parents=True, exist_ok=True)
            with self.outbox.open("a") as fh:
                fh.write(line + "\n")

    def progress(self, job_id: str, progress: float, eta_s: float | None = None) -> None:
        args: dict[str, Any] = {"job_id": job_id, "progress": progress}
        if eta_s is not None:
            args["eta_s"] = eta_s
        self._emit("social_clip_job_progress", args)

    def complete(self, job_id: str, result: dict) -> None:
        self._emit("social_clip_job_complete", {"job_id": job_id, **result})

    def fail(self, job_id: str, error: str, code: str) -> None:
        self._emit("social_clip_job_fail", {"job_id": job_id, "error": error, "code": code})

    def request(self, tool: str, args: dict, wait: Callable[[], None] | None = None) -> dict:
        if self.reply_dir is None:
            raise ClipError("REPLY_UNAVAILABLE", tool)
        self.reply_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.reply_dir.chmod(0o700)
        self._seq += 1
        reply = self.reply_dir / f"{os.getpid()}-{self._seq}-{tool}.json"
        with contextlib.suppress(FileNotFoundError):
            reply.unlink()
        try:
            self._emit(tool, args, {"reply_file": str(reply)})
            deadline = time.monotonic() + self.reply_timeout_s
            last_beat = time.monotonic()
            while time.monotonic() < deadline:
                if reply.exists():
                    try:
                        doc = json.loads(reply.read_text())
                    except ValueError:
                        time.sleep(0.1)  # agent mid-write
                        continue
                    reply.unlink()
                    if not isinstance(doc, dict):
                        raise ClipError("REPLY_INVALID", tool)
                    if doc.get("error") or doc.get("code"):
                        code = str(doc.get("code") or "REPLY_ERROR").upper()
                        raise ClipError(code if _CODE_RE.match(code) else "REPLY_ERROR", tool)
                    return doc
                if wait is not None and time.monotonic() - last_beat >= 20:
                    wait()
                    last_beat = time.monotonic()
                time.sleep(0.1)
            raise ClipError("REPLY_TIMEOUT", tool)
        finally:
            reply.unlink(missing_ok=True)
            reply.with_suffix(reply.suffix + ".tmp").unlink(missing_ok=True)



# ── Journal ─────────────────────────────────────────────────────────────


class Journal:
    """~/.clip-runner/jobs/<job_id>.json, written BEFORE every clip command."""

    def __init__(self, state_dir: Path):
        self.dir = Path(state_dir) / "jobs"

    def path(self, job_id: str) -> Path:
        if not _CODE_RE.match(job_id or ""):
            raise ValueError("bad job id")
        return self.dir / f"{job_id}.json"

    def write(self, job: dict, step: str) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)
        entry = {
            "job_id": job["id"],
            "kind": job.get("kind") or (job.get("payload") or {}).get("kind"),
            "profile_id": job.get("profile_id"),
            "step": step,
            "pid": os.getpid(),
            "at": time.time(),
        }
        tmp = self.path(job["id"]).with_suffix(".tmp")
        tmp.write_text(json.dumps(entry))
        os.replace(tmp, self.path(job["id"]))

    def read_all(self) -> list[dict]:
        if not self.dir.is_dir():
            return []
        entries = []
        for p in sorted(self.dir.glob("*.json")):
            try:
                entries.append(json.loads(p.read_text()))
            except (OSError, ValueError):
                entries.append({"job_id": p.stem, "step": "unknown"})
        return entries

    def clear(self, job_id: str) -> None:
        with contextlib.suppress(FileNotFoundError):
            self.path(job_id).unlink()


class ClipMap:
    """~/.clip-runner/state.json: Burrow clip_id -> clip project + the tool's clip id.

    Ids and paths only (the project name is `burrow-<clip id>`, never a title).
    """

    def __init__(self, state_dir: Path):
        self.path = Path(state_dir) / "state.json"

    def _load(self) -> dict:
        try:
            doc = json.loads(self.path.read_text())
        except (OSError, ValueError):
            return {"clips": {}}
        return doc if isinstance(doc.get("clips"), dict) else {"clips": {}}

    def get(self, clip_id: str) -> dict | None:
        entry = self._load()["clips"].get(clip_id)
        return entry if isinstance(entry, dict) else None

    def put(self, clip_id: str, entry: dict) -> None:
        doc = self._load()
        doc["clips"][clip_id] = entry
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(doc, indent=1, sort_keys=True))
        os.replace(tmp, self.path)


@contextlib.contextmanager
def runner_lock(state_dir: Path):
    """One runner per state dir: reclaim must never fail a job a live `run` holds."""
    state_dir.mkdir(parents=True, exist_ok=True)
    fh = (state_dir / "runner.lock").open("w")
    try:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
            return
        yield True
    finally:
        fh.close()


# ── clip invocation ─────────────────────────────────────────────────────


def clip_error_code(stdout: str, returncode: int) -> str:
    """The clip tool's own error code from its --json output, else one from the exit."""
    try:
        doc = json.loads(stdout.strip().splitlines()[-1]) if stdout.strip() else None
    except (ValueError, IndexError):
        doc = None
    code = None
    if isinstance(doc, dict):
        err = doc.get("error")
        if isinstance(err, dict):
            code = err.get("code")
        code = code or doc.get("code") or doc.get("error_code")
    if isinstance(code, str) and _CODE_RE.match(code):
        return code
    if returncode < 0:
        return f"CLIP_SIGNAL_{-returncode}"
    return f"CLIP_EXIT_{returncode}"


def _parse_json(stdout: str) -> dict:
    text = stdout.strip()
    if not text:
        return {}
    for candidate in (text, text.splitlines()[-1]):
        try:
            doc = json.loads(candidate)
        except ValueError:
            continue
        return doc if isinstance(doc, dict) else {"value": doc}
    return {}


def _last_line(stdout: str) -> str:
    lines = [ln.strip() for ln in stdout.strip().splitlines() if ln.strip()]
    return lines[-1] if lines else ""


def parse_version(text: Any) -> tuple[int, ...] | None:
    m = re.match(r"^\s*v?(\d+)(?:\.(\d+))?(?:\.(\d+))?", str(text or ""))
    if not m:
        return None
    return tuple(int(x or 0) for x in m.groups())


# ── review.toml (start / end / decision of ONE entry; every other byte kept) ──


class ReviewEntry:
    def __init__(self, index: int, first: int, last: int, alternate: bool):
        self.index = index
        self.first = first  # line index of "[[clip]]"
        self.last = last  # exclusive
        self.alternate = alternate
        self.fields: dict[str, Any] = {}
        self.lines: dict[str, int] = {}
        self.file_stem: str | None = None

    @property
    def start(self) -> float | None:
        v = self.fields.get("start")
        return float(v) if isinstance(v, (int, float)) else None

    @property
    def end(self) -> float | None:
        v = self.fields.get("end")
        return float(v) if isinstance(v, (int, float)) else None


_FIELD_RE = re.compile(r"^(id|title|headline|decision|start|end|transcript|edl|captions|packaging)\s*=")
_FILE_RE = re.compile(r"^# file: (.+?) · rank ")


class ReviewFile:
    """A line-level view of clip's review.toml: `[[clip]]` tables, the ALTERNATES
    section after its marker. Edits replace whole `start`/`end`/`decision` lines of
    one table; nothing else is rewritten. The text is never printed or returned."""

    def __init__(self, text: str):
        self.lines = text.splitlines(keepends=True)
        self.entries: list[ReviewEntry] = []
        alternate = False
        current: ReviewEntry | None = None
        for i, raw in enumerate(self.lines):
            line = raw.rstrip("\r\n")
            if line.startswith("# ALTERNATES"):
                alternate = True
            if line.strip() == "[[clip]]":
                if current is not None:
                    current.last = i
                current = ReviewEntry(len(self.entries), i, len(self.lines), alternate)
                self.entries.append(current)
                continue
            if current is None:
                continue
            m = _FIELD_RE.match(line)
            if m and m.group(1) not in current.lines:
                try:
                    current.fields.update(tomllib.loads(line))
                except tomllib.TOMLDecodeError:
                    continue
                current.lines[m.group(1)] = i
                continue
            fm = _FILE_RE.match(line)
            if line.startswith('# transcript = ') and "transcript" not in current.lines:
                current.lines["transcript"] = i
            if line.startswith('# says: '):
                current.fields["said"] = line[len('# says: '):]
            if fm and current.file_stem is None and fm.group(1) != "(not cut)":
                current.file_stem = Path(fm.group(1)).stem

    def by_id(self, tool_id: str) -> ReviewEntry | None:
        for e in self.entries:
            if e.fields.get("id") == tool_id:
                return e
        return None

    def best_overlap(self, in_s: float, out_s: float) -> ReviewEntry | None:
        """The cut (non-alternate) clip that best overlaps [in_s, out_s]."""
        scored = []
        for e in self.entries:
            if e.alternate or e.start is None or e.end is None or not e.fields.get("id"):
                continue
            overlap = max(0.0, min(e.end, out_s) - max(e.start, in_s))
            distance = abs(e.start - in_s) + abs(e.end - out_s)
            scored.append((-overlap, distance, e.index, e))
        return min(scored)[3] if scored else None

    def set_fields(self, entry: ReviewEntry, **values: Any) -> None:
        for key, value in values.items():
            if key not in ("start", "end", "decision", "title", "transcript"):
                raise ValueError("only supported review fields are written")
            if key not in entry.lines:
                raise ClipError("REVIEW_FORMAT", "review_edit")
            i = entry.lines[key]
            raw = self.lines[i]
            ending = raw[len(raw.rstrip("\r\n")) :]
            text = json.dumps(value, ensure_ascii=True) if key in ("decision", "title", "transcript") else f"{float(value):.3f}"
            self.lines[i] = f"{key} = {text}{ending}"
            entry.fields[key] = value

    def text(self) -> str:
        return "".join(self.lines)


# ── Runner ──────────────────────────────────────────────────────────────

Hook = Callable[["Runner", dict], Any]


def _no_context(runner: Runner, job: dict) -> dict:
    return {}


class Runner:
    def __init__(
        self,
        client: JobClient,
        agent_id: str | None = None,
        state_dir: Path = DEFAULT_STATE_DIR,
        clip_bin: str = "clip",
        heartbeat_s: float = DEFAULT_HEARTBEAT_S,
        timeout_s: float = DEFAULT_TIMEOUT_S,
        fetcher: Hook | None = None,
        uploader: Hook | None = None,
        context_for: Hook = _no_context,
        install_signal_handlers: bool = True,
    ):
        self.client = client
        self.agent_id = agent_id
        self.state_dir = Path(state_dir)
        self.journal = Journal(self.state_dir)
        self.clips = ClipMap(self.state_dir)
        self.clip_bin = clip_bin
        self.heartbeat_s = min(float(heartbeat_s), 60.0)
        self.timeout_s = float(timeout_s)
        self.fetcher = fetcher or fetch_episode
        self.uploader = uploader or upload_output
        self.context_for = context_for
        self.install_signal_handlers = install_signal_handlers
        self._job: dict | None = None
        self._progress = 0.0
        self._started = 0.0
        self.reset_job_state()

    def reset_job_state(self) -> None:
        self.context: dict = {}
        self.local = True  # fail closed until the privacy mode is read
        self.content_free = False  # CLIP_CONTENT_FREE: clip >= content_free 2
        self.clip_version: tuple[int, ...] | None = None
        self.headline_capability = False
        self.project_path: str | None = None
        self.output: Path | None = None
        self.review_entry: dict = {}

    # 1. startup reclaim ------------------------------------------------

    def startup_reclaim(self, profile_ids: Iterable[str | None]) -> list[str]:
        """Fail every job this agent left claimed/running, and every journalled job."""
        orphans: dict[str, str] = {}
        for profile_id in profile_ids:
            for status in ("claimed", "running"):
                for job in self.client.list_jobs(profile_id, status):
                    if self.agent_id and job.get("claimed_by_agent_id") == self.agent_id:
                        orphans.setdefault(job["id"], "unknown")
        for entry in self.journal.read_all():
            job_id = entry.get("job_id")
            if job_id:
                orphans[job_id] = entry.get("step") or "unknown"

        failed = []
        for job_id, step in orphans.items():
            try:
                self.client.fail(job_id, f"runner restarted mid-job; last step: {step}", "RUNNER_RESTARTED")
            except JobToolError:
                pass  # job_closed / not_claimer: nothing left to reclaim
            self._cleanup_orphan(job_id)
            self.journal.clear(job_id)
            failed.append(job_id)
        return failed

    def _cleanup_orphan(self, job_id: str) -> None:
        entry = next((e for e in self.journal.read_all() if e.get("job_id") == job_id), {})
        key = re.sub(r"[^a-z0-9-]", "-", str(job_id).lower())
        if not _CODE_RE.fullmatch(job_id):
            raise ClipError("BAD_PAYLOAD", "cleanup")
        folder = self.state_dir / "tmp" / ("closing-" + key)
        if folder.exists():
            for name in ("closing.video", "closing.part"):
                (folder / name).unlink(missing_ok=True)
            folder.rmdir()
        tmp = self.state_dir / "tmp"
        (tmp / "headline-request.json").unlink(missing_ok=True)
        music = tmp / "music"
        if music.is_dir():
            (music / "track.audio").unlink(missing_ok=True)
            (music / "track.part").unlink(missing_ok=True)
            music.rmdir()
        profile = entry.get("profile_id")
        if isinstance(profile, str) and _CODE_RE.fullmatch(profile):
            name = ("burrow-" + profile + "-job-" + key)[:120]
            _remove_profile(self, name)
            (self.state_dir / "tmp" / (name + ".toml")).unlink(missing_ok=True)
        # A reply can carry a signed URL. Reclaim runs under the existing state lock.
        replies = self.state_dir / "replies"
        if replies.is_dir():
            for reply in replies.iterdir():
                if reply.is_file() and re.fullmatch(r"[0-9]+-[0-9]+-[a-z_]+\.json(?:\.tmp)?", reply.name):
                    reply.unlink()

    # 2. poll -----------------------------------------------------------

    @staticmethod
    def claim_order(jobs: Iterable[dict]) -> list[dict]:
        queued = [j for j in jobs if j.get("status", "queued") == "queued"]
        return sorted(queued, key=lambda j: (j.get("inserted_at") or "", j.get("id") or ""))

    def poll_once(self, profile_ids: Iterable[str | None]) -> dict | None:
        """Claim the oldest queued job that nobody else wins, run it; None when idle."""
        queued: list[dict] = []
        for profile_id in profile_ids:
            queued.extend(self.client.list_jobs(profile_id, "queued"))
        for job in self.claim_order(queued):
            try:
                claimed = self.client.claim(job["id"])
            except AlreadyClaimed:
                continue
            return self.run_job(claimed or job)
        return None

    # 3-5. dispatch, progress, finish -----------------------------------

    def run_job(self, job: dict, context: dict | None = None) -> dict:
        job_id = job["id"]
        kind = job.get("kind") or (job.get("payload") or {}).get("kind")
        self._job, self._progress, self._started = job, 0.0, time.monotonic()
        self.reset_job_state()
        self.journal.write(job, "claimed")
        previous = self._install_handlers()
        terminal_sent = False
        outcome: dict = {"job_id": job_id, "kind": kind}
        try:
            try:
                self.context = dict(context if context is not None else self.context_for(self, job) or {})
                handler = HANDLERS.get(kind)
                if handler is None:
                    raise ClipError("UNKNOWN_KIND", "dispatch")
                result = handler(self, job)
                self.journal.write(job, "complete")
                self.client.complete(job_id, finish_result(result, local=self.local))
                terminal_sent = True
                outcome.update(status="done")
            except ClipError as exc:
                code, message = exc.code, str(exc)
            except JobToolError as exc:
                code, message = exc.code.upper(), "job tool refused the result"
            except RunnerInterrupted as exc:
                code, message = exc.code, f"runner stopped by signal during {self._step()}"
            except Exception as exc:
                code, message = "RUNNER_EXCEPTION", f"{type(exc).__name__} during {self._step()}"
            if not terminal_sent:
                self.client.fail(job_id, message, code)
                terminal_sent = True
                outcome.update(status="failed", code=code)
        finally:
            self._restore_handlers(previous)
            if terminal_sent:
                self.journal.clear(job_id)
            self._job = None
        return outcome

    def _step(self) -> str:
        entries = [e for e in self.journal.read_all() if self._job and e.get("job_id") == self._job["id"]]
        return entries[0].get("step", "unknown") if entries else "unknown"

    def _install_handlers(self):
        if not self.install_signal_handlers:
            return None

        def raise_interrupt(signum, _frame):
            raise RunnerInterrupted(signum)

        try:
            return {s: signal.signal(s, raise_interrupt) for s in (signal.SIGTERM, signal.SIGINT)}
        except ValueError:  # not the main thread
            return None

    @staticmethod
    def _restore_handlers(previous) -> None:
        for s, h in (previous or {}).items():
            signal.signal(s, h)

    def report(self, fraction: float) -> None:
        """Progress at a step boundary (also used by the heartbeat)."""
        if self._job is None:
            return
        self._progress = max(self._progress, min(max(fraction, 0.0), 0.99))
        eta = None
        elapsed = time.monotonic() - self._started
        if self._progress > 0.0:
            eta = round(elapsed * (1.0 - self._progress) / self._progress)
        try:
            self.client.progress(self._job["id"], round(self._progress, 3), eta)
        except JobToolError:
            pass  # a refused progress must not abort a render

    def heartbeat(self) -> None:
        self.report(self._progress)

    def clip(
        self,
        step: str,
        args: list[str],
        fraction: float | None = None,
        env: dict | None = None,
        raw: bool = False,
    ) -> Any:
        """Run one `clip` command: journal first, heartbeat while it runs, parse --json.

        Local privacy mode (and every call before the mode is known) adds
        CLIP_NO_CONTENT=1. stderr is discarded; stdout is parsed, never printed.
        """
        job = self._job
        if job is not None:
            self.journal.write(job, step)
        proc_env = dict(os.environ)
        proc_env.pop("CLIP_RUNNER_TOKEN", None)  # clip never needs the agent token
        for key in ("BURROW_TOKEN", "BURROW_API_TOKEN", "CF_ACCESS_CLIENT_ID", "CF_ACCESS_CLIENT_SECRET"):
            proc_env.pop(key, None)
        proc_env.pop("CLIP_NO_CONTENT", None)
        proc_env["CLIP_NO_CONTENT"] = "1"
        proc_env.update(env or {})
        deadline = time.monotonic() + self.timeout_s
        try:
            proc = subprocess.Popen(
                [self.clip_bin, *args],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL,
                env=proc_env,
                text=True,
                umask=0o077,
            )
        except FileNotFoundError as exc:
            raise ClipError("CLIP_NOT_INSTALLED", step) from exc
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    proc.kill()
                    proc.communicate()
                    raise ClipError("CLIP_TIMEOUT", step)
                try:
                    stdout, _ = proc.communicate(timeout=min(self.heartbeat_s, remaining))
                    break
                except subprocess.TimeoutExpired:
                    self.heartbeat()
        except BaseException:
            if proc.poll() is None:
                proc.kill()
                with contextlib.suppress(Exception):
                    proc.communicate(timeout=5)
            raise
        if proc.returncode != 0:
            raise ClipError(clip_error_code(stdout, proc.returncode), step, f"exit {proc.returncode}")
        if fraction is not None:
            self.report(fraction)
        return stdout if raw else _parse_json(stdout)

    def project_name(self, job: dict) -> str:
        """The clip project NAME for a Burrow clip (clip keeps projects under its clips folder)."""
        key = job.get("clip_id") or (job.get("payload") or {}).get("clip_id") or job["id"]
        if not _CODE_RE.match(key):
            raise ClipError("BAD_PAYLOAD", "dispatch")
        name = "burrow-" + re.sub(r"[^a-z0-9-]", "-", key.lower())
        return name[:120]

    def tmp_dir(self) -> Path:
        d = self.state_dir / "tmp"
        d.mkdir(mode=0o700, parents=True, exist_ok=True)
        d.chmod(0o700)
        return d


def finish_result(result: dict | None, local: bool = False) -> dict:
    """Only ClipJobs.result_keys; source_label defaults to the clip tool.

    Local privacy mode: title, caption, speaker and episode_code are null and
    nothing else but ids, numbers and the source label survives.
    """
    out = {k: v for k, v in (result or {}).items() if k in RESULT_KEYS}
    if local:
        out = {k: v for k, v in out.items() if k not in META_KEYS and k != "platforms"}
        out.update(dict.fromkeys(META_KEYS))
    out.setdefault("source_label", SOURCE_LABEL)
    return out


# ── Episode fetch and upload (the helper's only non-clip I/O) ─────────────


def _download(url: str, dest: Path, step: str) -> None:
    tmp = dest.with_suffix(dest.suffix + ".part")
    try:
        with urllib.request.urlopen(url, timeout=120) as resp, tmp.open("wb") as fh:
            shutil.copyfileobj(resp, fh, 1 << 20)
    except urllib.error.HTTPError as exc:
        tmp.unlink(missing_ok=True)
        raise ClipError(f"FETCH_HTTP_{exc.code}", step) from None
    except (urllib.error.URLError, OSError, ValueError):
        tmp.unlink(missing_ok=True)
        raise ClipError("FETCH_FAILED", step) from None
    os.replace(tmp, dest)


def fetch_episode(runner: Runner, job: dict) -> str:
    """The episode as a local file named by id/hash (never by title).

    context.episode_path (a file the agent already has), else context.episode_url
    (a signed download URL for payload.episode.source_file_id), else
    payload.episode.source_url via yt-dlp (or a direct media URL). Cached under
    <state>/episodes so a re-render does not fetch again.
    """
    payload = job.get("payload") or {}
    episode = payload.get("episode") or {}
    ctx = runner.context
    if ctx.get("episode_path"):
        p = Path(ctx["episode_path"]).expanduser()
        if not p.is_file():
            raise ClipError("SOURCE_MISSING", "fetch")
        return str(p)
    file_id = episode.get("source_file_id")
    url = episode.get("source_url")
    if file_id:
        key = "file-" + re.sub(r"[^A-Za-z0-9-]", "", str(file_id))[:64]
    elif url:
        key = "url-" + hashlib.sha256(str(url).encode()).hexdigest()[:24]
    else:
        raise ClipError("SOURCE_UNAVAILABLE", "fetch")
    folder = runner.state_dir / "episodes"
    folder.mkdir(parents=True, exist_ok=True)
    cached = sorted(p for p in folder.glob(key + ".*") if not p.name.endswith(".part"))
    if cached:
        return str(cached[0])
    runner.journal.write(job, "fetch")
    if file_id:
        if not ctx.get("episode_url"):
            raise ClipError("SOURCE_FILE_NO_DOWNLOAD", "fetch")
        dest = folder / f"{key}.mp4"
        _download(ctx["episode_url"], dest, "fetch")
        return str(dest)
    ytdlp = os.environ.get("CLIP_RUNNER_YTDLP") or shutil.which("yt-dlp")
    if ytdlp:
        proc = subprocess.run(
            [
                ytdlp,
                "--quiet",
                "--no-progress",
                "--no-playlist",
                "-f",
                "mp4/best",
                "-o",
                str(folder / f"{key}.%(ext)s"),
                url,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            check=False,
            timeout=runner.timeout_s,
        )
        got = sorted(p for p in folder.glob(key + ".*") if not p.name.endswith(".part"))
        if proc.returncode != 0 or not got:
            raise ClipError(f"FETCH_YTDLP_EXIT_{proc.returncode}", "fetch")
        return str(got[0])
    ext = Path(urllib.parse.urlparse(str(url)).path).suffix.lower()
    if ext in (".mp4", ".mov", ".m4v", ".mkv", ".webm") and str(url).startswith(("http://", "https://")):
        dest = folder / f"{key}{ext}"
        _download(str(url), dest, "fetch")
        return str(dest)
    raise ClipError("SOURCE_NEEDS_YTDLP", "fetch")


def upload_output(runner: Runner, job: dict) -> str:
    """Presigned upload of runner.output into the Burrow profile's project Files.

    1. request file_add (byte_size) through the agent; 2. POST the bytes with the
    agent bearer token (env, never logged) to the base URL; 3. check the hash.
    """
    path = runner.output
    if path is None or not path.is_file():
        raise ClipError("OUTPUT_MISSING", "upload")
    project_id = runner.context.get("project_id")
    token = os.environ.get("CLIP_RUNNER_TOKEN")
    base = (os.environ.get("CLIP_RUNNER_BASE_URL") or "").rstrip("/")
    secure = base.startswith("https://") or base.startswith("http://127.0.0.1")
    if not project_id or not token or not secure:
        raise ClipError("UPLOAD_UNAVAILABLE", "upload")
    size = path.stat().st_size
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    sha = digest.hexdigest()
    payload = job.get("payload") or {}
    clip_key = re.sub(r"[^A-Za-z0-9-]", "", str(job.get("clip_id") or payload.get("clip_id") or job["id"]))
    rev = payload.get("expected_rev")
    filename = f"clip-{clip_key}-r{rev}.mp4" if isinstance(rev, int) else f"clip-{clip_key}.mp4"
    runner.journal.write(job, "file_add")
    reply = runner.client.request(
        "file_add",
        {"project_id": project_id, "filename": filename, "content_type": "video/mp4", "byte_size": size},
        wait=runner.heartbeat,
    )
    upload_url = reply.get("upload_url")
    file_id = reply.get("id") or reply.get("file_id")
    if not upload_url or not file_id:
        raise ClipError("UPLOAD_NO_URL", "file_add")
    url = upload_url if "://" in upload_url else base + upload_url
    if not url.startswith(base + "/"):
        raise ClipError("UPLOAD_HOST_MISMATCH", "upload")  # the token goes to the base URL only
    runner.journal.write(job, "upload")
    with path.open("rb") as fh:
        req = urllib.request.Request(
            url,
            data=fh,
            method="POST",
            headers={
                "Content-Type": "video/mp4",
                "Content-Length": str(size),
                "Authorization": f"Bearer {token}",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=600) as resp:
                body = resp.read()
        except urllib.error.HTTPError as exc:
            raise ClipError(f"UPLOAD_HTTP_{exc.code}", "upload") from None
        except (urllib.error.URLError, OSError):
            raise ClipError("UPLOAD_FAILED", "upload") from None
    try:
        doc = json.loads(body or b"{}")
    except ValueError:
        doc = {}
    got = doc.get("content_hash") if isinstance(doc, dict) else None
    if got and got.lower() != sha:
        raise ClipError("UPLOAD_HASH_MISMATCH", "upload")
    runner.report(0.97)
    return str(doc.get("id") or file_id) if isinstance(doc, dict) else str(file_id)


# ── Preflight, privacy, profiles ─────────────────────────────────────────


def _preflight(runner: Runner) -> None:
    info = runner.clip("version", ["version", "--json"])
    version = parse_version(info.get("version"))
    if version is None:
        raise ClipError("CLIP_VERSION_UNKNOWN", "version")
    if version < MIN_CLIP_VERSION:
        raise ClipError("CLIP_TOO_OLD", "version", ".".join(map(str, version)))
    runner.clip_version = version
    runner.headline_capability = type(info.get("headline_review")) is int and info["headline_review"] == 1
    cf = info.get("content_free")
    runner.content_free = isinstance(cf, int) and not isinstance(cf, bool) and cf >= MIN_CONTENT_FREE
    doctor = runner.clip("doctor", ["doctor", "--json"], fraction=0.05)
    code = None
    if doctor.get("ok") is False:
        code = doctor.get("code") or (doctor.get("error") or {}).get("code") or "CLIP_DOCTOR"
    summary = doctor.get("summary") if isinstance(doctor.get("summary"), dict) else {}
    if code is None and isinstance(summary.get("fix"), int) and summary["fix"] > 0:
        failing = [c.get("check") for c in doctor.get("checks") or [] if c.get("status") == "fix"]
        names = ",".join(n for n in failing if isinstance(n, str) and _CODE_RE.match(n))
        raise ClipError("CLIP_DOCTOR_FIX", "doctor", names)
    if code is not None:
        raise ClipError(code if _CODE_RE.match(str(code)) else "CLIP_DOCTOR", "doctor")


def _is_local(mode: Any, inferred: Any) -> bool:
    """preflight.sh semantics: only an explicit "cloud" counts as cloud; a mode
    inferred from the AI backend, or anything unreadable, is local."""
    return not (mode == "cloud" and inferred in (False, 0, "false", "0", None))


def _project_info(runner: Runner, project: str, fraction: float) -> dict:
    info = runner.clip("project_info", ["project", "info", "--json", project], fraction=fraction)
    path = info.get("path")
    if not isinstance(path, str) or not Path(path).is_dir():
        raise ClipError("PROJECT_NOT_FOUND", "project_info")
    runner.local = _is_local(info.get("privacy_mode"), info.get("privacy_mode_inferred"))
    runner.project_path = path
    return info


def _profile_privacy(runner: Runner, profile: str) -> None:
    """No project yet: the mode the profile would process with (clip config get)."""
    mode = _last_line(
        runner.clip("config_get", ["config", "get", "effective_privacy_mode", "--profile", profile], raw=True)
    )
    explicit = _last_line(
        runner.clip("config_get", ["config", "get", "privacy.mode", "--profile", profile], raw=True)
    )
    runner.local = _is_local(mode, explicit not in ("local", "cloud"))


def _check_profile_name(name: Any) -> str:
    if not isinstance(name, str) or not _PROFILE_RE.match(name) or name == BASE_PROFILE:
        raise ClipError("BAD_PAYLOAD", "dispatch")
    return name


def _toml_value(v: Any) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return json.dumps(v)
    raise ValueError("unsupported look value")


def profile_toml(extends: str, mapped: dict) -> str:
    """A user profile: `extends` plus the mapped clip keys ("captions.size_frac" -> [captions] size_frac)."""
    sections: dict[str, dict] = {}
    for key, value in sorted((mapped or {}).items()):
        if not _LOOK_KEY_RE.match(str(key)):
            raise ClipError("LOOK_KEY_INVALID", "profile")
        section, name = key.split(".", 1)
        try:
            _toml_value(value)
        except ValueError:
            raise ClipError("LOOK_VALUE_INVALID", "profile") from None
        sections.setdefault(section, {})[name] = value
    out = [f"extends = {json.dumps(extends)}", ""]
    for section, values in sections.items():
        out.append(f"[{section}]")
        out += [f"{k} = {_toml_value(v)}" for k, v in values.items()]
        out.append("")
    text = "\n".join(out)
    tomllib.loads(text)  # must parse
    return text


def _overrides(payload: dict) -> dict:
    co = payload.get("clip_overrides") or {}
    unmapped = co.get("unmapped") or []
    if unmapped:
        keys = ",".join(k for k in unmapped if isinstance(k, str) and _CODE_RE.match(k))
        warn("LOOK_KEYS_UNMAPPED", keys)
    mapped = co.get("mapped") or {}
    return mapped if isinstance(mapped, dict) else {}


def _import_profile(runner: Runner, name: str, extends: str, mapped: dict, step: str) -> None:
    src = runner.tmp_dir() / f"{name}.toml"
    with open(src, "w", opener=lambda p, flags: os.open(p, flags, 0o600)) as fh:
        fh.write(profile_toml(extends, mapped))
    src.chmod(0o600)
    try:
        runner.clip(step, ["profile", "import", str(src), "--name", name, "--force", "--yes"])
    finally:
        src.unlink(missing_ok=True)


def _ensure_user_profile(runner: Runner, profile: str) -> None:
    """burrow-<profile id> exists before a render (a profile that never saved a default)."""
    try:
        runner.clip("profile_path", ["profile", "path", profile], raw=True)
        return
    except ClipError:
        pass
    _import_profile(runner, profile, BASE_PROFILE, {}, "profile_import")


def _remove_profile(runner: Runner, name: str, required: bool = False) -> None:
    """Delete a per-job derived profile (clip has no `profile delete`): resolve its file with
    `clip profile path` and unlink it only if it is that user profile, never a built-in."""
    if "-job-" not in name or not name.startswith("burrow-"):
        raise ValueError("only derived profiles are removed")
    try:
        out = runner.clip("profile_remove", ["profile", "path", name], raw=True)
    except ClipError:
        if required:
            raise ClipError("PROFILE_CLEANUP_FAILED", "profile_cleanup") from None
        return  # never created
    path = Path(_last_line(out))
    if path.name != f"{name}.toml" or "clip_agent" in path.parts or path.stem == BASE_PROFILE:
        raise ClipError("PROFILE_CLEANUP_FAILED", "profile_cleanup")
    path.unlink(missing_ok=True)


@contextlib.contextmanager
def derived_profile(runner: Runner, job: dict, base: str, mapped: dict):
    """`burrow-<profile id>-job-<job id>` extending the user profile, for this render only.
    Removed afterwards on every path (success, failure, signal)."""
    if not mapped:
        yield None
        return
    job_key = re.sub(r"[^a-z0-9-]", "-", str(job["id"]).lower())
    name = f"{base}-job-{job_key}"[:120]
    created = False
    try:
        _import_profile(runner, name, base, mapped, "profile_derive")
        created = True
        yield name
    finally:
        try:
            _remove_profile(runner, name, required=created)
        except Exception:
            raise ClipError("PROFILE_CLEANUP_FAILED", "profile_cleanup") from None


# ── review.toml + render ────────────────────────────────────────────────


def _edit_review(runner: Runner, job: dict, project: Path, tool_id: str | None) -> str:
    """Edit only the target review entry through supported fields; preserve its base hashes."""
    payload = job.get("payload") or {}
    path = project / "review.toml"
    try:
        review = ReviewFile(path.read_text())
    except OSError:
        raise ClipError("REVIEW_MISSING", "review_edit") from None
    in_s, out_s = payload.get("in_s"), payload.get("out_s")
    entry = review.by_id(tool_id) if tool_id else None
    if entry is None and tool_id and (payload.get("fix") or payload.get("appearance")):
        raise ClipError("BASE_CANDIDATE_MISSING", "review_edit")
    if entry is None:
        if not isinstance(in_s, (int, float)) or not isinstance(out_s, (int, float)):
            raise ClipError("BAD_PAYLOAD", "review_edit")
        entry = review.best_overlap(float(in_s), float(out_s))
    if entry is None:
        raise ClipError("NO_CANDIDATE", "review_edit")
    fix = payload.get("fix") or {}
    operation = fix.get("operation")
    if operation == "alternate_cut":
        eligible = [e for e in review.entries if e.alternate and e.fields.get("id") != tool_id
                    and e.start is not None and e.end is not None and e.end > e.start]
        if not eligible:
            raise ClipError("NO_ALTERNATE", "review_edit")
        entry = eligible[0]
        in_s, out_s = entry.start, entry.end
    elif entry.alternate:
        raise ClipError("CANDIDATE_NOT_CUT", "review_edit")
    if fix:
        if operation not in ("nudge", "caption_word", "regenerate_headline", "alternate_cut"):
            raise ClipError("UNSUPPORTED_FIX", "review_edit")
        if any(not entry.fields.get(k) for k in ("edl", "captions", "packaging")):
            raise ClipError("REVIEW_CONTRACT_UNSUPPORTED", "review_edit")

    values: dict[str, Any] = {"decision": "approve"}
    if isinstance(in_s, (int, float)):
        values["start"] = float(in_s)
    if isinstance(out_s, (int, float)):
        values["end"] = float(out_s)
    if operation == "caption_word":
        correction = fix.get("caption_fixes") or {}
        text = entry.fields.get("transcript") or entry.fields.get("said")
        if not isinstance(text, str) or text.endswith("…"):
            raise ClipError("CAPTION_CONTRACT_UNSUPPORTED", "review_edit")
        words = text.split()
        pos = correction.get("position")
        if type(pos) is not int or pos < 0 or pos >= len(words) or words[pos] != correction.get("original"):
            raise ClipError("STALE_CAPTION_WORD", "review_edit")
        replacement = correction.get("replacement")
        if not isinstance(replacement, str) or not replacement or len(replacement.split()) != 1:
            raise ClipError("BAD_CAPTION_WORD", "review_edit")
        words[pos] = replacement
        values["transcript"] = " ".join(words)
    review.set_fields(entry, **values)
    runner.journal.write(job, "review_edit")
    tmp = path.with_suffix(".toml.tmp")
    tmp.write_text(review.text())
    os.replace(tmp, path)
    runner.review_entry = {
        "id": entry.fields.get("id"),
        "file_stem": entry.file_stem,
        "title": entry.fields.get("title"),
        "start": entry.start,
        "end": entry.end,
        "alternate": entry.alternate,
    }
    return str(entry.fields["id"])


def _find_output(runner: Runner, project: Path) -> Path:
    final = project / "final"
    stem = runner.review_entry.get("file_stem")
    if stem and (final / f"{stem}.mp4").is_file():
        return final / f"{stem}.mp4"
    videos = [p for p in final.glob("*.mp4") if not p.stem.endswith("_clean")] if final.is_dir() else []
    if not videos:
        raise ClipError("OUTPUT_MISSING", "finalize")
    return max(videos, key=lambda p: p.stat().st_mtime)


def _headline_intent(job: dict) -> str | None:
    payload = job.get("payload") or {}
    explicit = payload.get("headline")
    if explicit is not None:
        if not isinstance(explicit, dict) or explicit.get("consumer") not in ("edit", "episode", "regenerate"):
            raise ClipError("HEADLINE_REQUEST_UNSUPPORTED", "headline")
        return explicit["consumer"]
    if (payload.get("fix") or {}).get("operation") == "regenerate_headline":
        return "regenerate"
    return "episode" if job.get("kind") == "new_clip" else None


def _headline_request(runner: Runner, job: dict, consumer: str) -> dict:
    if not runner.headline_capability:
        raise ClipError("HEADLINE_CLI_UNSUPPORTED", "headline")
    payload = job.get("payload") or {}
    options = payload.get("headline") or {}
    if options.get("export_text"):
        raise ClipError("HEADLINE_PRIVACY_EXPORT_REFUSED", "headline")
    voice = runner.context.get("headline_voice")
    if not isinstance(voice, dict) or not all(isinstance(voice.get(k), str) and voice[k].strip()
                                             for k in ("revision", "direction")):
        raise ClipError("HEADLINE_VOICE_MISSING", "headline")
    base = payload.get("base_render_id")
    if consumer != "episode":
        if not isinstance(base, str) or not base:
            raise ClipError("HEADLINE_BASE_MISSING", "headline")
        if base != runner.context.get("base_render_id"):
            raise ClipError("HEADLINE_BASE_STALE", "headline")
    source_id = payload.get("source_id") or (payload.get("episode") or {}).get("source_file_id")
    if source_id is None:
        url = (payload.get("episode") or {}).get("source_url")
        if isinstance(url, str) and url:
            source_id = "url-" + hashlib.sha256(url.encode()).hexdigest()
    if not isinstance(source_id, str) or not source_id:
        raise ClipError("HEADLINE_SOURCE_MISSING", "headline")
    requested = options.get("requested_headline")
    if consumer == "edit" and (not isinstance(requested, str) or not requested.strip()):
        raise ClipError("HEADLINE_EMPTY", "headline")
    if consumer != "edit" and requested is not None:
        raise ClipError("HEADLINE_REQUEST_UNSUPPORTED", "headline")
    return {"version": 1, "consumer": consumer, "candidate_id": runner.review_entry["id"],
            "source": {"id": source_id, "start": runner.review_entry["start"],
                       "end": runner.review_entry["end"]},
            "voice": voice, "base_render_id": base,
            "requested_headline": requested, "export_text": False}


def _headline_receipt(receipt: dict, request: dict, status: str) -> None:
    expected = {"version": 1, "candidate_id": request["candidate_id"],
                "source_id": request["source"]["id"], "start": request["source"]["start"],
                "end": request["source"]["end"], "voice_revision": request["voice"]["revision"],
                "base_render_id": request["base_render_id"], "status": status, "backed": True}
    if (not isinstance(receipt, dict) or type(receipt.get("version")) is not int
            or receipt.get("backed") is not True or receipt != expected):
        raise ClipError("HEADLINE_OUTPUT_UNSUPPORTED", "headline")


def _apply_headline(runner: Runner, job: dict, project: Path, profile: str, consumer: str) -> dict:
    request = _headline_request(runner, job, consumer)
    path = runner.tmp_dir() / "headline-request.json"
    # O_EXCL avoids symlink following; a crash-left file is safely replaced by
    # unlinking only this private request under the existing runner lock.
    path.unlink(missing_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(request, stream)
        args = ["hooks", "prepare-review", str(project), "--request", str(path), "--profile", profile]
        prepared = runner.clip("headline_prepare", args, fraction=0.75)
        _headline_receipt(prepared, request, "prepared")
        entry = ReviewFile((project / "review.toml").read_text()).by_id(request["candidate_id"])
        if not entry or not isinstance(entry.fields.get("headline"), str) or not entry.fields["headline"].strip():
            raise ClipError("HEADLINE_OUTPUT_UNSUPPORTED", "headline")
        if consumer == "edit" and entry.fields["headline"] != " ".join(request["requested_headline"].split()):
            raise ClipError("HEADLINE_APPLIED_MISMATCH", "headline")
        runner.clip("headline_apply", ["review", str(project), "--apply", "--profile", profile], fraction=0.78)
        receipt = runner.clip("headline_verify", [*args, "--check-applied"], fraction=0.8)
        _headline_receipt(receipt, request, "applied")
        return receipt
    finally:
        path.unlink(missing_ok=True)


@contextlib.contextmanager
def music_profile(runner: Runner, job: dict, base: str, mapped: dict):
    """Resolve only the selected persisted asset, into a private disposable profile.
    URLs never enter clip argv/environment, logs, context or durable runner state.
    """
    music = (job.get("payload") or {}).get("music")
    mapped = dict(mapped)
    if music is None:  # legacy jobs retain their previous behavior
        yield mapped
        return
    enabled = music.get("enabled") is True
    gain = music.get("level_db")
    if type(gain) not in (int, float) or not -60 <= gain <= 0:
        raise ClipError("MUSIC_GAIN_INVALID", "music")
    try:
        supported = _last_line(runner.clip("music_capability", ["config", "get", "music.enabled", "--profile", base], raw=True)).lower() in ("true", "false")
    except ClipError:
        supported = False
    if not supported:
        if enabled:
            raise ClipError("MUSIC_CLI_UNSUPPORTED", "music")
        yield {k: v for k, v in mapped.items() if not k.startswith("music.")}
        return
    mapped.update({"music.enabled": enabled, "music.level_db": gain, "music.path": ""})
    if not enabled:
        yield mapped
        return
    source = runner.client.request("social_clip_job_source", {"job_id": job["id"], "asset": "music"}, wait=runner.heartbeat)
    if (not isinstance(source, dict) or source.get("file_id") != music.get("file_id") or
        source.get("project_id") != runner.context.get("project_id") or
        source.get("content_type") not in ("audio/mpeg", "audio/mp3", "audio/wav", "audio/x-wav", "audio/mp4", "audio/ogg", "audio/flac") or
        type(source.get("byte_size")) is not int or not 0 < source["byte_size"] <= 25 * 1024 * 1024):
        raise ClipError("MUSIC_ASSET_INVALID", "music")
    url = source.get("url")
    if not isinstance(url, str) or urllib.parse.urlsplit(url).scheme not in ("http", "https"):
        raise ClipError("MUSIC_URL_INVALID", "music")
    folder = runner.tmp_dir() / "music"
    folder.mkdir(mode=0o700, exist_ok=True)
    folder.chmod(0o700)
    path = folder / "track.audio"
    part = folder / "track.part"
    try:
        try:
            with urllib.request.urlopen(url, timeout=120) as response, part.open("wb") as output:
                part.chmod(0o600)
                remaining = source["byte_size"]
                while chunk := response.read(min(1 << 20, remaining + 1)):
                    remaining -= len(chunk)
                    if remaining < 0:
                        raise ClipError("MUSIC_DOWNLOAD_SIZE", "music")
                    output.write(chunk)
                if remaining != 0:
                    raise ClipError("MUSIC_DOWNLOAD_SIZE", "music")
            os.replace(part, path)
        except (urllib.error.URLError, OSError, ValueError):
            raise ClipError("MUSIC_DOWNLOAD_FAILED", "music") from None
        mapped["music.path"] = str(path)
        yield mapped
    finally:
        path.unlink(missing_ok=True)
        part.unlink(missing_ok=True)
        folder.rmdir()



class _MediaRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        _media_url(newurl)
        # Build a fresh credential-free request rather than forwarding headers.
        return urllib.request.Request(newurl)


def _media_url(url):
    if not isinstance(url, str):
        raise ClipError("CLOSING_URL_INVALID", "closing_video")
    try:
        u = urllib.parse.urlsplit(url)
        if u.scheme not in ("http", "https") or not u.hostname or u.username or u.password:
            raise ValueError()
        if u.scheme == "http" and u.hostname not in ("127.0.0.1", "localhost", "::1"):
            raise ValueError()
    except ValueError:
        raise ClipError("CLOSING_URL_INVALID", "closing_video") from None
    return url


@contextlib.contextmanager
def closing_profile(runner: Runner, job: dict, base: str, mapped: dict):
    """Pinned video only, one disposable profile, never a rendered output as source.
    The server contract owns the byte cap; it must match this protocol revision.
    Absent legacy contracts mean disabled, explicitly clearing inherited outro.
    """
    closing = (job.get("payload") or {}).get("closing_video")
    if closing is not None and (not isinstance(closing, dict) or
            type(closing.get("enabled")) is not bool or closing.get("audio") not in ("keep", "mute")):
        raise ClipError("CLOSING_CONTRACT_INVALID", "closing_video")
    closing = closing or {"enabled": False, "audio": "mute"}
    mapped = {k: v for k, v in mapped.items() if not k.startswith("outro.")}
    enabled = closing["enabled"]
    if enabled and ((closing.get("profile_id") is not None and closing["profile_id"] != job.get("profile_id")) or
            (runner.context.get("org_id") is not None and closing.get("org_id") != runner.context["org_id"])):
        raise ClipError("CLOSING_ASSET_INVALID", "closing_video")
    try:
        supported = _last_line(runner.clip("closing_capability", ["config", "get", "outro.audio", "--profile", base], raw=True)) in ("keep", "mute")
    except ClipError:
        supported = False
    if not supported:
        if enabled:
            raise ClipError("CLOSING_CLI_UNSUPPORTED", "closing_video")
        yield mapped
        return
    try:
        runner.clip("closing_path_capability", ["config", "get", "outro.path", "--profile", base], raw=True)
    except ClipError:
        raise ClipError("CLOSING_CLI_UNSUPPORTED", "closing_video") from None
    mapped.update({"outro.path": "", "outro.audio": closing["audio"]})
    if not enabled:
        yield mapped
        return
    source = runner.client.request("social_clip_job_source", {"job_id": job["id"], "asset": "closing_video"}, wait=runner.heartbeat)
    cap = source.get("max_bytes") if isinstance(source, dict) else None
    if (not isinstance(source, dict) or type(cap) is not int or cap <= 0 or
        source.get("file_id") != closing.get("file_id") or not closing.get("file_id") or
        source.get("project_id") != runner.context.get("project_id") or
        source.get("project_id") != closing.get("project_id") or
        source.get("content_type") != closing.get("content_type") or
        source.get("content_type") not in ("video/mp4", "video/quicktime", "video/webm") or
        type(source.get("byte_size")) is not int or not 0 < source["byte_size"] <= cap or
        source.get("byte_size") != closing.get("byte_size") or
        not isinstance(source.get("content_hash"), str) or
        not re.fullmatch(r"[0-9a-f]{64}", source["content_hash"]) or
        source.get("content_hash") != closing.get("content_hash")):
        raise ClipError("CLOSING_ASSET_INVALID", "closing_video")
    url = _media_url(source.get("url"))
    key = re.sub(r"[^a-z0-9-]", "-", str(job["id"]).lower())
    folder = runner.tmp_dir() / ("closing-" + key)
    folder.mkdir(mode=0o700, exist_ok=True)
    folder.chmod(0o700)
    path, part = folder / "closing.video", folder / "closing.part"
    try:
        try:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _MediaRedirect())
            with opener.open(url, timeout=120) as response, open(part, "wb", opener=lambda p, flags: os.open(p, flags | os.O_NOFOLLOW, 0o600)) as output:
                part.chmod(0o600)
                remaining = source["byte_size"]
                digest = hashlib.sha256()
                while chunk := response.read(min(1 << 20, remaining + 1)):
                    remaining -= len(chunk)
                    if remaining < 0:
                        raise ClipError("CLOSING_DOWNLOAD_SIZE", "closing_video")
                    digest.update(chunk)
                    output.write(chunk)
                    runner.heartbeat()
                if remaining != 0:
                    raise ClipError("CLOSING_DOWNLOAD_SIZE", "closing_video")
                if digest.hexdigest() != source["content_hash"]:
                    raise ClipError("CLOSING_HASH_MISMATCH", "closing_video")
            os.replace(part, path)
        except (urllib.error.URLError, OSError, ValueError):
            raise ClipError("CLOSING_DOWNLOAD_FAILED", "closing_video") from None
        # Real-video probing already happened twice in Core; the supported CLI's
        # finish_for decodes/probes again before rendering and fails closed.
        mapped["outro.path"] = str(path)
        yield mapped
    finally:
        try:
            path.unlink(missing_ok=True)
            part.unlink(missing_ok=True)
            folder.rmdir()
        except OSError:
            raise ClipError("CLOSING_CLEANUP_FAILED", "closing_cleanup") from None

def _render(runner: Runner, job: dict, project: Path, tool_id: str | None, regenerate: bool) -> dict:
    payload = job.get("payload") or {}
    base = _check_profile_name(payload.get("clip_user_profile"))
    runner.clip("review", ["review", str(project), "--overwrite"], fraction=0.55)
    tool_id = _edit_review(runner, job, project, tool_id)
    clip_id = job.get("clip_id") or payload.get("clip_id")
    runner.clips.put(
        clip_id,
        {
            "project": project.name,
            "path": str(project),
            "tool_clip_id": tool_id,
            "profile_id": job.get("profile_id"),
        },
    )
    consumer = _headline_intent(job)
    appearance = payload.get("appearance") is True
    mapped = dict(_overrides(payload))
    explicit_style = ((payload.get("look") or {}).get("cap") or {}).get("style")
    if explicit_style is not None:
        mapped["captions.style"] = explicit_style
    if consumer:
        mapped["captions.hook_title"] = True
        style = mapped.get("captions.style")
        if style is None:
            style = _last_line(runner.clip("caption_style", ["config", "get", "captions.style", "--profile", base], raw=True))
        if style not in ("none", *CAPTION_STYLES):
            raise ClipError("HEADLINE_CAPTION_STYLE_UNSUPPORTED", "headline")
        mapped["captions.style"] = "phrase-pop" if style == "none" else style
    if appearance or "captions.style" in mapped:
        _qualify_caption_style(runner, mapped.get("captions.style"))
    receipt = None
    with music_profile(runner, job, base, mapped) as mapped, closing_profile(runner, job, base, mapped) as mapped, derived_profile(runner, job, base, mapped) as look_profile:
        profile_args = ["--profile", look_profile or base] if consumer or appearance or look_profile else []
        runner.clip("review_apply", ["review", str(project), "--apply", *profile_args], fraction=0.6)
        if payload.get("fix") or consumer or appearance:
            alternate = runner.review_entry.get("alternate")
            if alternate:
                video = runner.fetcher(runner, job)
                runner.clip("process", ["process", str(video), "--project", project.name,
                            "--profile", base, "--resume"], fraction=0.65)
            runner.clip("review", ["review", str(project), "--overwrite", *profile_args], fraction=0.7)
            refreshed = ReviewFile((project / "review.toml").read_text())
            applied = refreshed.by_id(tool_id)
            # A trim may change the tool's safe title overlay. Approve the newly
            # exported target/base once; never forge its hashes or bypass the gate.
            if applied and applied.fields.get("decision") == "pending" and applied.file_stem:
                refreshed.set_fields(applied, decision="approve")
                (project / "review.toml").write_text(refreshed.text())
                runner.clip("review_apply", ["review", str(project), "--apply", *profile_args], fraction=0.72)
                runner.clip("review", ["review", str(project), "--overwrite", *profile_args], fraction=0.74)
                applied = ReviewFile((project / "review.toml").read_text()).by_id(tool_id)
            if not applied or applied.fields.get("decision") != "approve" or not applied.file_stem:
                raise ClipError("REVIEW_NOT_APPLIED", "review_apply")
            runner.review_entry.update(start=applied.start, end=applied.end,
                                      file_stem=applied.file_stem, title=applied.fields.get("title"))
        if consumer:
            receipt = _apply_headline(runner, job, project, look_profile or base, consumer)
        render_started = time.time_ns()
        args = ["finalize", str(project)]
        if look_profile:
            args += ["--profile", look_profile]
        if consumer or appearance or "captions.style" in mapped:
            # Explicit CLI style overrides a saved process-time --captions none.
            args += ["--captions", mapped["captions.style"]]
        if regenerate or consumer:
            args.append("--regenerate")
        runner.clip("finalize", args, fraction=0.85)
    runner.output = _find_output(runner, project)
    if consumer or appearance or mapped.get("captions.style") in DYNAMIC_CAPTION_STYLES:
        stem = runner.review_entry.get("file_stem")
        expected_output = project / "final" / f"{stem}.mp4"
        if runner.output != expected_output or runner.output.stat().st_mtime_ns < render_started:
            raise ClipError("APPEARANCE_RENDER_MISSING" if appearance else
                            "HEADLINE_RENDER_MISSING" if consumer else "CAPTION_RENDER_MISSING", "finalize")
    file_id = runner.uploader(runner, job)
    result: dict[str, Any] = {"file_id": file_id, "candidate_id": tool_id}
    if receipt and payload.get("episode_job_id"):
        result["headline_applied"] = True
    if receipt:
        # Content-free receipt remains local; existing completion schema stays compatible.
        runner.clips.put(clip_id, {**runner.clips.get(clip_id), "headline_receipt": receipt})
    if (payload.get("fix") or {}).get("operation") == "alternate_cut":
        result["alternate_id"] = tool_id
    start, end = runner.review_entry.get("start"), runner.review_entry.get("end")
    if isinstance(start, float) and isinstance(end, float) and end > start:
        if not (payload.get("closing_video") or {}).get("enabled"):
            result["duration_s"] = round(end - start, 3)
        # Enabled closing totals come only from Core's uploaded-file probe.
        if payload.get("fix"):
            result.update(actual_in_s=start, actual_out_s=end)
    if not consumer and not runner.local and (payload.get("fix") or not payload.get("title")) and isinstance(runner.review_entry.get("title"), str):
        result["title"] = runner.review_entry["title"][:200]
    return result


def _process(runner: Runner, job: dict, fraction: float) -> Path:
    payload = job.get("payload") or {}
    profile = _check_profile_name(payload.get("clip_user_profile"))
    _ensure_user_profile(runner, profile)
    _profile_privacy(runner, profile)
    video = runner.fetcher(runner, job)
    runner.report(0.1)
    name = runner.project_name(job)
    runner.clip(
        "process", ["process", str(video), "--project", name, "--profile", profile], fraction=fraction
    )
    _project_info(runner, name, fraction + 0.02)  # the authoritative privacy mode from here on
    return Path(runner.project_path or "")


def _check_rev(runner: Runner, job: dict, bump: int) -> None:
    """Burrow bumps rev on a re-render's complete: expected_rev must be current rev + bump."""
    expected = (job.get("payload") or {}).get("expected_rev")
    current = runner.context.get("clip_rev")
    if bump and not isinstance(current, int):
        raise ClipError("REV_UNKNOWN", "dispatch")
    next_rev = runner.context.get("clip_next_rev", current + bump if isinstance(current, int) else None) if bump else current
    if isinstance(current, int) and isinstance(expected, int) and (next_rev != expected or (bump and expected <= current)):
        raise ClipError("REV_MISMATCH", "dispatch", f"expected {expected}, clip at {current}")


# ── Per-kind handlers ───────────────────────────────────────────────────


def handle_new_clip(runner: Runner, job: dict) -> dict:
    _check_rev(runner, job, 0)
    _preflight(runner)
    payload = job.get("payload") or {}
    if payload.get("episode_job_id"):
        mapping = runner.clips.get(job.get("clip_id") or "")
        if not mapping or not Path(mapping.get("path", "")).is_dir():
            raise ClipError("EPISODE_PROJECT_MISSING", "process")
        _project_info(runner, mapping["path"], 0.45)
        project = Path(mapping["path"])
        return _render(runner, job, project, payload.get("candidate_id"), regenerate=True)
    project = _process(runner, job, 0.45)
    return _render(runner, job, project, None, regenerate=False)


def handle_rerender(runner: Runner, job: dict) -> dict:
    """Re-render and trim (a trim is a rerender with new in_s/out_s and no look change)."""
    _check_rev(runner, job, 1)
    _preflight(runner)
    payload = job.get("payload") or {}
    _check_profile_name(payload.get("clip_user_profile"))
    mapping = runner.clips.get(job.get("clip_id") or payload.get("clip_id") or "")
    tool_id = None
    if mapping and mapping.get("path") and Path(mapping["path"]).is_dir():
        _project_info(runner, mapping["path"], 0.1)
        project = Path(runner.project_path or mapping["path"])
        tool_id = mapping.get("tool_clip_id")
    else:
        # Appearance needs the original project's applied headline/transcript edits.
        # Never fall back to the submitted, already captioned render as source.
        if payload.get("appearance"):
            raise ClipError("APPEARANCE_PROJECT_MISSING", "project_info")
        project = _process(runner, job, 0.45)  # mapping lost: re-process from the episode
    tool_id = payload.get("candidate_id") or tool_id
    return _render(runner, job, project, tool_id, regenerate=True)


class _ConfirmedChildClient:
    """Wait for each child completion before allowing the parent to finish."""
    def __init__(self, parent):
        self.parent = parent
    def __getattr__(self, name):
        return getattr(self.parent.client, name)
    def progress(self, job_id, progress, eta_s=None):
        self.parent.client.progress(job_id, progress, eta_s)
        self.parent.heartbeat()
    def complete(self, job_id, result):
        self.parent.client.request("social_clip_job_complete", {"job_id": job_id, **result},
                                   wait=self.parent.heartbeat)
    def fail(self, job_id, error, code):
        self.parent.client.request("social_clip_job_fail", {"job_id": job_id, "error": error, "code": code},
                                   wait=self.parent.heartbeat)


def handle_episode(runner: Runner, job: dict) -> dict:
    """Process once; persist stable picks, then reuse the canonical headline/render handler.

    Generated headline text never leaves the tool. MCP carries ids/bounds and
    an applied receipt only. A partial failure preserves completed children.
    """
    _preflight(runner)
    source = runner.client.request("social_clip_job_source", {"job_id": job["id"]}, wait=runner.heartbeat)
    if not isinstance(source.get("url"), str):
        raise ClipError("SOURCE_FILE_NO_DOWNLOAD", "fetch")
    runner.context["episode_url"] = source["url"]
    key = "episode:" + job["id"]
    cached = runner.clips.get(key)
    if cached and Path(cached.get("path", "")).is_dir():
        _project_info(runner, cached["path"], 0.3)
        project = Path(cached["path"])
    else:
        project = _process(runner, job, 0.35)
        runner.clips.put(key, {"path": str(project)})
    runner.clip("proposal_review", ["review", str(project), "--overwrite"], fraction=0.4)
    review = ReviewFile((project / "review.toml").read_text())
    picks = [{"candidate_id": e.fields["id"], "in_s": e.start, "out_s": e.end}
             for e in review.entries if not e.alternate and e.file_stem and e.fields.get("decision") != "reject"]
    planned = runner.client.request("social_clip_job_progress", {
        "job_id": job["id"], "progress": 0.4, "picks": picks}, wait=runner.heartbeat)
    children = planned.get("jobs")
    if not isinstance(children, list) or len(children) != len(picks):
        raise ClipError("EPISODE_PLAN_INVALID", "proposal")
    for child in children:
        if child.get("status") == "done":
            continue
        child_id = child.get("id")
        pay = child.get("payload") or {}
        if pay.get("episode_job_id") != job["id"] or pay.get("candidate_id") not in {p["candidate_id"] for p in picks}:
            raise ClipError("EPISODE_PLAN_INVALID", "proposal")
        runner.clips.put(child["clip_id"], {"path": str(project), "tool_clip_id": pay["candidate_id"]})
        reply = runner.client.request("social_clip_job_claim", {"job_id": child_id}, wait=runner.heartbeat)
        claimed = reply.get("job")
        if not isinstance(claimed, dict) or claimed.get("id") != child_id:
            raise ClipError("EPISODE_PLAN_INVALID", "claim")
        context = {**runner.context, "clip_rev": 1}
        worker = Runner(_ConfirmedChildClient(runner), agent_id=runner.agent_id, state_dir=runner.state_dir,
                        clip_bin=runner.clip_bin, heartbeat_s=runner.heartbeat_s,
                        timeout_s=runner.timeout_s, fetcher=runner.fetcher, uploader=runner.uploader,
                        install_signal_handlers=runner.install_signal_handlers)
        outcome = worker.run_job(claimed, context)
        if outcome.get("status") != "done":
            raise ClipError("EPISODE_CHILD_FAILED", "render")
    # Do not expose generated text or source download URL in the parent result.
    return {}


def handle_save_default(runner: Runner, job: dict) -> dict:
    payload = job.get("payload") or {}
    profile = _check_profile_name(payload.get("clip_user_profile"))
    if profile == payload.get("base_profile"):
        raise ClipError("BAD_PAYLOAD", "dispatch")
    mapped = _overrides(payload)
    _preflight(runner)
    if "captions.style" in mapped:
        _qualify_caption_style(runner, mapped["captions.style"])
    _import_profile(runner, profile, BASE_PROFILE, mapped, "profile_import")
    runner.report(0.6)
    runner.clip("profile_use", ["profile", "use", profile], fraction=0.9)
    return {}


HANDLERS: dict[str, Callable[[Runner, dict], dict]] = {
    "episode": handle_episode,
    "new_clip": handle_new_clip,
    "rerender": handle_rerender,
    "save_default": handle_save_default,
}


# ── CLI ─────────────────────────────────────────────────────────────────


def _stdin_json() -> dict:
    data = sys.stdin.read()
    doc = json.loads(data) if data.strip() else {}
    if not isinstance(doc, dict):
        raise SystemExit("stdin must be a JSON object")
    return doc


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="clip_runner")
    ap.add_argument("--state-dir", type=Path, default=DEFAULT_STATE_DIR)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("version")
    rc = sub.add_parser("reclaim")
    rc.add_argument("--agent-id", required=True)
    sub.add_parser("order")
    rn = sub.add_parser("run")
    rn.add_argument("--heartbeat-s", type=float, default=DEFAULT_HEARTBEAT_S)
    rn.add_argument("--timeout-s", type=float, default=DEFAULT_TIMEOUT_S)
    rn.add_argument("--reply-timeout-s", type=float, default=DEFAULT_REPLY_TIMEOUT_S)
    rn.add_argument("--clip-bin", default=os.environ.get("CLIP_BIN", "clip"))
    args = ap.parse_args(argv)
    state_dir = args.state_dir.expanduser()

    if args.cmd == "version":
        print(json.dumps({"version": VERSION}))
        return 0

    if args.cmd == "order":
        jobs = _stdin_json().get("jobs") or []
        print(json.dumps({"claim_order": [j["id"] for j in Runner.claim_order(jobs)]}))
        return 0

    with runner_lock(state_dir) as held:
        if not held:
            print(json.dumps({"busy": True}))
            return EXIT_BUSY
        if args.cmd == "reclaim":
            client = OutboxClient(snapshot=_stdin_json().get("jobs") or [])
            Runner(client, agent_id=args.agent_id, state_dir=state_dir).startup_reclaim([None])
            return 0
        doc = _stdin_json()
        job = doc.get("job")
        if not isinstance(job, dict) or not job.get("id"):
            raise SystemExit('stdin must be {"job": {...}, "context": {...}}')
        context = doc.get("context") if isinstance(doc.get("context"), dict) else {}
        client = OutboxClient(
            outbox=state_dir / "outbox" / f"{job['id']}.jsonl",
            reply_dir=state_dir / "replies",
            reply_timeout_s=args.reply_timeout_s,
        )
        runner = Runner(
            client,
            state_dir=state_dir,
            clip_bin=args.clip_bin,
            heartbeat_s=args.heartbeat_s,
            timeout_s=args.timeout_s,
        )
        outcome = runner.run_job(job, context)
        return 0 if outcome.get("status") == "done" else 1


if __name__ == "__main__":
    sys.exit(main())
````

### `tests/fake_clip.py`

````python
#!/usr/bin/env python3
"""Fake `clip` for tests. Installed on PATH as `clip`.

Emulates the parts of htc-clip-tool 0.9's CLI the runner uses (argv shapes as in
clip_agent/cli.py): version/doctor --json, config get, project info --json,
process --project NAME, review [--overwrite|--apply], finalize, profile
path|import|use. Projects live in $FAKE_CLIP_HOME/clips/<name>, user profiles in
$FAKE_CLIP_HOME/profiles, the built-in how-to-computer in $FAKE_CLIP_HOME/builtin.

FAKE_CLIP_LOG     JSONL file; each call appends {"argv", "env" (CLIP_* vars), and for
                  review/apply/import the file text seen}
FAKE_CLIP_SCRIPT  JSON file: {"<key>": {"stdout": ..., "exit": n, "sleep": s}} where <key>
                  is review_apply | review | project_info | config_get | profile_<sub> | argv[0].
                  A non-zero exit prints stdout and exits with no side effects.
FAKE_PRIVACY      cloud (default) | local; FAKE_PRIVACY_INFERRED=1 marks it inferred
FAKE_CLIP_VERSION default 0.9.3; FAKE_CONTENT_FREE default 2
"""

import json
import os
import shutil
import sys
import time
import tomllib
from pathlib import Path

BUILTIN = ("how-to-computer", "how-to-computer-local", "podcast", "podcast-local")

REVIEW_FIXTURE = """# clip-agent review for project 'NAME'.
# For each clip set decision = "approve" or "reject" ("pending" = undecided).

[[clip]]
id = "c1aaaaaaaa"
title = "Secret Title One"
decision = "pending"
start = 100.000
end = 130.000
# file: 01_secret-title-one.mp4 · rank 1 · 30.0s · story
# says: secret transcript words one
# transcript = "corrected caption text (optional)"
edl = "none"   # no edit list — leave as is
captions = "1111111111111111"   # the captions as listed — leave as is
packaging = "aaaaaaaaaaaaaaaa"   # the packaging shown above — leave as is
note = ""

[[clip]]
id = "c2bbbbbbbb"
title = "Secret Title Two"
decision = "pending"
start = 300.000
end = 345.000
# file: 02_secret-title-two.mp4 · rank 2 · 45.0s · insight
# says: secret transcript words two
# transcript = "corrected caption text (optional)"
edl = "none"   # no edit list — leave as is
captions = "2222222222222222"   # the captions as listed — leave as is
packaging = "bbbbbbbbbbbbbbbb"   # the packaging shown above — leave as is
note = ""

[[clip]]
id = "c3cccccccc"
title = "Secret Title Three"
decision = "reject"
start = 500.000
end = 540.000
# file: 03_secret-title-three.mp4 · rank 3 · 40.0s · story
edl = "none"   # no edit list — leave as is
captions = "3333333333333333"   # the captions as listed — leave as is
packaging = "cccccccccccccccc"   # the packaging shown above — leave as is
note = ""

# ==============================================================================
# ALTERNATES — proposed but NOT cut (beyond the clip count, or left out by the re-rank).
# ==============================================================================

[[clip]]
id = "a1dddddddd"
title = "Secret Alternate"
decision = "pending"
start = 10.000
end = 40.000
# file: (not cut) · rank 4 · 30.0s · story
edl = "none"   # no edit list — leave as is
captions = "4444444444444444"   # the captions as listed — leave as is
packaging = "dddddddddddddddd"   # the packaging shown above — leave as is
note = ""
"""


def key(argv):
    if not argv:
        return ""
    if argv[0] == "review":
        return "review_apply" if "--apply" in argv else "review"
    if argv[0] in ("project", "profile", "config") and len(argv) > 1:
        return f"{argv[0]}_{argv[1]}"
    return argv[0]


def home():
    return Path(os.environ.get("FAKE_CLIP_HOME", "/nonexistent-fake-clip-home"))


def opt(argv, name):
    return argv[argv.index(name) + 1] if name in argv and argv.index(name) + 1 < len(argv) else None


def project_dir(ref):
    return Path(ref) if "/" in ref else home() / "clips" / ref


def profile_file(name):
    if name in BUILTIN:
        return home() / "builtin" / f"{name}.toml"
    return home() / "profiles" / f"{name}.toml"


def die(code="FAKE_ERROR", status=1):
    print(json.dumps({"ok": False, "error": {"code": code}}))
    sys.exit(status)


def emulate(argv, extra):
    k = key(argv)
    privacy = os.environ.get("FAKE_PRIVACY", "cloud")
    if k == "version":
        return {
            "version": os.environ.get("FAKE_CLIP_VERSION", "0.9.3"),
            "content_free": int(os.environ.get("FAKE_CONTENT_FREE", "2")),
            "python": "3.12",
            "headline_review": int(os.environ.get("FAKE_HEADLINE_CAPABILITY", "1")),
        }
    if k == "hooks":
        request_path = Path(opt(argv, "--request"))
        request = json.loads(request_path.read_text())
        extra["headline_request"] = request
        extra["request_mode"] = request_path.stat().st_mode & 0o777
        d = project_dir(argv[2])
        path = d / "review.toml"
        if "--check-applied" not in argv:
            title = request.get("requested_headline") or ({"c1aaaaaaaa": "The demo finally worked", "c2bbbbbbbb": "We fixed the wrong button", "c3cccccccc": "The tiny bug won again"}.get(request["candidate_id"]) if os.environ.get("FAKE_EPISODE_THREE") else "secret transcript words two")
            if os.environ.get("FAKE_HEADLINE_UNBACKED"):
                die("HEADLINE_UNBACKED")
            text = path.read_text()
            rows = text.split("[[clip]]")
            for i, row in enumerate(rows):
                if f'id = "{request["candidate_id"]}"' in row:
                    import re
                    row = re.sub(r"(?m)^headline = .*\n", "", row)
                    rows[i] = row + "\nheadline = " + json.dumps(title) + "\n"
            path.write_text("[[clip]]".join(rows))
        else:
            applied = tomllib.loads((d / "applied.toml").read_text())
            target = next(c for c in applied["clip"] if c["id"] == request["candidate_id"])
            if "headline" not in target:
                die("HEADLINE_OUTPUT_UNSUPPORTED")
        return {"version": 1, "candidate_id": request["candidate_id"],
                "source_id": request["source"]["id"], "start": request["source"]["start"],
                "end": request["source"]["end"], "voice_revision": request["voice"]["revision"],
                "base_render_id": request["base_render_id"], "backed": True,
                "status": "applied" if "--check-applied" in argv else "prepared"}
    if k == "doctor":
        return {
            "checks": [{"check": "ffmpeg", "status": "pass", "message": "ok"}],
            "summary": {"pass": 1, "warn": 0, "fix": 0},
        }
    if k == "config_get":
        if argv[2] == "outro.audio":
            return os.environ.get("FAKE_OUTRO_AUDIO", "unsupported")
        if argv[2] == "music.enabled":
            return os.environ.get("FAKE_MUSIC_ENABLED", "false")
        if argv[2] == "captions.style":
            return os.environ.get("FAKE_CAPTION_STYLE", "phrase-pop")
        if argv[2] == "effective_privacy_mode":
            return privacy
        return os.environ.get("FAKE_PRIVACY_EXPLICIT", privacy)
    if k == "process":
        name = opt(argv, "--project")
        d = home() / "clips" / name
        d.mkdir(parents=True, exist_ok=True)
        state = d / "applied.toml"
        if state.exists():
            text = state.read_text().replace('# file: (not cut)', '# file: 04_secret-title-a1dddddddd.mp4')
            state.write_text(text)
        (d / "project.json").write_text(json.dumps({"profile": opt(argv, "--profile")}))
        return "Processed."
    if k == "project_info":
        d = project_dir(argv[-1])
        if not (d / "project.json").exists():
            die("PROJECT_NOT_FOUND")
        prof = json.loads((d / "project.json").read_text()).get("profile")
        return {
            "name": d.name,
            "path": str(d),
            "profile": prof,
            "privacy_mode": privacy,
            "privacy_mode_inferred": os.environ.get("FAKE_PRIVACY_INFERRED") == "1",
            "candidates": {"pending": 3, "alternate": 1, "total": 4},
            "require_approval": True,
        }
    if k == "review":
        d = project_dir(argv[1])
        path = d / "review.toml"
        if path.exists() and "--overwrite" not in argv:
            die("REVIEW_EXISTS")
        state = d / "applied.toml"
        text = state.read_text() if state.exists() else REVIEW_FIXTURE.replace("NAME", d.name)
        if os.environ.get("FAKE_EPISODE_THREE"):
            text = text.replace('decision = "reject"', 'decision = "pending"')
        if os.environ.get("FAKE_EPISODE_ZERO"):
            text = "# no picks\n"
        path.write_text(text)
        extra["written"] = text
        return f"Review file: {path}"
    if k == "review_apply":
        path = project_dir(argv[1]) / "review.toml"
        text = path.read_text()
        tomllib.loads(text)  # clip parses it
        (path.parent / "applied.toml").write_text(text)
        extra["applied"] = text
        return "Applied review: 1 approved"
    if k == "finalize" and os.environ.get("FAKE_SKIP_RENDER"):
        return "Nothing rendered"
    if k == "finalize":
        d = project_dir(argv[1])
        doc = tomllib.loads((d / "review.toml").read_text())
        final = d / "final"
        final.mkdir(exist_ok=True)
        n = 0
        for i, c in enumerate(doc.get("clip", []), 1):
            if c.get("decision") == "approve":
                stem = f"0{i}_secret-title-{c['id']}"
                stem = {1: "01_secret-title-one", 2: "02_secret-title-two", 3: "03_secret-title-three"}.get(
                    i, stem
                )
                (final / f"{stem}.mp4").write_bytes(
                    b"VIDEO:" + c["id"].encode() + b":" + str(c["start"]).encode()
                )
                (final / f"{stem}_clean.mp4").write_bytes(b"CLEAN")
                (final / f"{stem}.srt").write_text("1\nsecret caption\n")
                n += 1
        return f"Wrote {3 * n} files to final/:"
    if k == "profile_path":
        p = profile_file(argv[2])
        if not p.exists():
            die("PROFILE_NOT_FOUND")
        return str(p)
    if k == "profile_import":
        src, name = Path(argv[2]), opt(argv, "--name")
        if name in BUILTIN:
            die("BUILTIN_PROFILE")
        text = src.read_text()
        doc = tomllib.loads(text)
        if not profile_file(doc.get("extends", "")).exists():
            die("EXTENDS_NOT_FOUND")
        target = home() / "profiles" / f"{name}.toml"
        if target.exists() and "--force" not in argv:
            die("PROFILE_EXISTS")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, target)
        extra["imported"] = text
        return f'Imported profile "{name}"'
    if k == "profile_use":
        if not profile_file(argv[2]).exists():
            die("PROFILE_NOT_FOUND")
        return f'Using profile "{argv[2]}"'
    return {"ok": True}


def main():
    argv = sys.argv[1:]
    script = {}
    path = os.environ.get("FAKE_CLIP_SCRIPT")
    if path and os.path.exists(path):
        with open(path) as fh:
            script = json.load(fh)
    spec = script.get(key(argv), {})
    extra = {}
    log = os.environ.get("FAKE_CLIP_LOG")

    def write_log():
        if log:
            env = {k: v for k, v in os.environ.items() if k.startswith(("CLIP_", "FAKE_", "BURROW_", "CF_ACCESS_"))}
            with open(log, "a") as fh:
                fh.write(json.dumps({"argv": argv, "env": env, "pid": os.getpid(), **extra}) + "\n")

    if spec.get("sleep"):
        time.sleep(spec["sleep"])
    if spec.get("exit"):
        write_log()
        out = spec.get("stdout", {"ok": False})
        print(out if isinstance(out, str) else json.dumps(out))
        sys.exit(spec["exit"])
    try:
        out = emulate(argv, extra)
    except SystemExit:
        write_log()
        raise
    write_log()
    out = spec.get("stdout", out)
    print(out if isinstance(out, str) else json.dumps(out))
    sys.stdout.flush()


if __name__ == "__main__":
    main()
````

### `tests/conftest.py`

````python
import json
import os
import stat
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import clip_runner

AGENT = "agent-self"
OTHER = "agent-other"
PROFILE = "profile-1"


class FakeJobClient:
    """In-memory job list with ClipJobs' semantics: conditional claim, claimer-only writes."""

    def __init__(self, agent_id=AGENT, jobs=(), lose_claims=()):
        self.agent_id = agent_id
        self.jobs = {j["id"]: dict(j) for j in jobs}
        self.lose_claims = set(lose_claims)  # another runner wins these
        self.calls = []
        self.replies = {}

    def request(self, tool, args, wait=None):
        self.calls.append(("request", tool, dict(args)))
        reply = self.replies.get(tool, {"id": "file-777", "upload_url": "/chat/attachments/upload/tok"})
        if isinstance(reply, Exception):
            raise reply
        return dict(reply)

    def _open_mine(self, job_id):
        job = self.jobs.get(job_id)
        if job is None:
            raise clip_runner.JobToolError("not_found")
        if job.get("claimed_by_agent_id") != self.agent_id:
            raise clip_runner.JobToolError("not_claimer")
        if job["status"] not in ("claimed", "running"):
            raise clip_runner.JobToolError("job_closed")
        return job

    def list_jobs(self, profile_id, status):
        self.calls.append(("list", profile_id, status))
        rows = [j for j in self.jobs.values() if j["status"] == status]
        if profile_id is not None:
            rows = [j for j in rows if j["profile_id"] == profile_id]
        return [dict(j) for j in sorted(rows, key=lambda j: j["inserted_at"])]

    def claim(self, job_id):
        self.calls.append(("claim", job_id))
        job = self.jobs[job_id]
        if job_id in self.lose_claims:
            job.update(status="claimed", claimed_by_agent_id=OTHER)
        if job["status"] != "queued":
            raise clip_runner.AlreadyClaimed()
        job.update(status="claimed", claimed_by_agent_id=self.agent_id)
        return dict(job)

    def progress(self, job_id, progress, eta_s=None):
        self.calls.append(("progress", job_id, progress, eta_s))
        job = self._open_mine(job_id)
        assert 0 <= progress <= 1
        assert eta_s is None or eta_s >= 0
        job.update(status="running", progress=progress)

    def complete(self, job_id, result):
        self.calls.append(("complete", job_id, dict(result)))
        job = self._open_mine(job_id)
        job.update(status="done", result=result)

    def fail(self, job_id, error, code):
        self.calls.append(("fail", job_id, error, code))
        job = self._open_mine(job_id)
        job.update(status="failed", error=f"{code}: {error}")

    def named(self, name):
        return [c for c in self.calls if c[0] == name]


def make_job(job_id, kind="new_clip", status="queued", claimed_by=None, inserted_at=None, **payload):
    clip_id = None if kind == "save_default" else f"clip-{job_id}"
    body = {
        "kind": kind,
        "clip_id": clip_id,
        "profile_id": PROFILE,
        "clip_user_profile": f"burrow-{PROFILE}",
        "base_profile": "how-to-computer",
        "in_s": 10.0,
        "out_s": 40.0,
        "look_delta": {},
        "expected_rev": 2 if kind == "rerender" else 1,
        "clip_overrides": {"mapped": {}, "unmapped": []},
        "episode": {"source_url": None, "source_file_id": "file-episode-1", "transcript_file_id": None},
    }
    body.update(payload)
    return {
        "id": job_id,
        "profile_id": PROFILE,
        "clip_id": clip_id,
        "kind": kind,
        "status": status,
        "payload": body,
        "claimed_by_agent_id": claimed_by,
        "inserted_at": inserted_at or f"2026-10-23T00:00:{job_id[-2:]}Z",
    }


@pytest.fixture
def shim(tmp_path, monkeypatch):
    """`clip` on PATH -> fake_clip.py; returns a controller."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    wrapper = bin_dir / "clip"
    wrapper.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{ROOT / "tests" / "fake_clip.py"}" "$@"\n')
    wrapper.chmod(wrapper.stat().st_mode | stat.S_IEXEC)
    log = tmp_path / "clip_calls.jsonl"
    script = tmp_path / "clip_script.json"
    monkeypatch.setenv("PATH", f"{bin_dir}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("FAKE_CLIP_LOG", str(log))
    monkeypatch.setenv("FAKE_CLIP_SCRIPT", str(script))
    clip_home = tmp_path / "cliphome"
    (clip_home / "builtin").mkdir(parents=True)
    (clip_home / "profiles").mkdir()
    (clip_home / "builtin" / "how-to-computer.toml").write_text(
        'extends = "podcast"\n[captions]\npreset = "htc"\n'
    )
    (clip_home / "builtin" / "podcast.toml").write_text('[privacy]\nmode = "cloud"\n')
    monkeypatch.setenv("FAKE_CLIP_HOME", str(clip_home))
    for var in ("FAKE_PRIVACY", "FAKE_PRIVACY_INFERRED", "FAKE_PRIVACY_EXPLICIT", "CLIP_NO_CONTENT"):
        monkeypatch.delenv(var, raising=False)

    class Shim:
        def script(self, **spec):
            script.write_text(json.dumps(spec))

        def calls(self):
            if not log.exists():
                return []
            return [json.loads(line) for line in log.read_text().splitlines()]

        def argvs(self):
            return [c["argv"] for c in self.calls()]

        home = clip_home

    return Shim()


@pytest.fixture
def state_dir(tmp_path):
    return tmp_path / "state"


def default_context(runner, job):
    payload = job.get("payload") or {}
    rev = payload.get("expected_rev")
    if isinstance(rev, int) and (job.get("kind") or payload.get("kind")) == "rerender":
        rev -= 1
    return {"clip_rev": rev, "project_id": "project-files-1",
            "headline_voice": {"revision": "fixture-8", "direction": "Comedy and positivity; incomplete."},
            "base_render_id": payload.get("base_render_id")}


def make_runner(client, state_dir, **kw):
    kw.setdefault("fetcher", lambda r, j: "/episodes/ep.mp4")
    kw.setdefault("uploader", lambda r, j: "file-123")
    kw.setdefault("context_for", default_context)
    return clip_runner.Runner(client, agent_id=client.agent_id, state_dir=state_dir, **kw)
````

### `tests/test_runner.py`

````python
import itertools
import json
import os
import signal
import subprocess
import sys
import time

import pytest
from conftest import AGENT, OTHER, PROFILE, ROOT, FakeJobClient, make_job, make_runner

import clip_runner


def journal_files(state_dir):
    d = state_dir / "jobs"
    return sorted(p.name for p in d.glob("*.json")) if d.exists() else []


# ── poll / claim race ────────────────────────────────────────────────────


def test_claim_race_already_claimed_is_skipped_silently(shim, state_dir):
    client = FakeJobClient(
        jobs=[make_job("job-01", "rerender"), make_job("job-02", "rerender")],
        lose_claims={"job-01"},
    )
    outcome = make_runner(client, state_dir).poll_once([PROFILE])

    assert outcome == {"job_id": "job-02", "kind": "rerender", "status": "done"}
    assert [c[1] for c in client.named("claim")] == ["job-01", "job-02"]
    touched = {c[1] for c in client.calls if c[0] in ("progress", "complete", "fail")}
    assert touched == {"job-02"}
    assert client.jobs["job-01"]["claimed_by_agent_id"] == OTHER
    assert client.jobs["job-01"]["status"] == "claimed"


def test_poll_claims_oldest_first_and_idles_when_empty(shim, state_dir):
    client = FakeJobClient(
        jobs=[
            make_job("job-09", "rerender", inserted_at="2026-10-23T09:00:00Z"),
            make_job("job-03", "rerender", inserted_at="2026-10-23T03:00:00Z"),
        ]
    )
    runner = make_runner(client, state_dir)
    assert runner.poll_once([PROFILE])["job_id"] == "job-03"
    assert runner.poll_once([PROFILE])["job_id"] == "job-09"
    assert runner.poll_once([PROFILE]) is None


def test_poll_returns_none_when_every_claim_is_lost(shim, state_dir):
    client = FakeJobClient(jobs=[make_job("job-01")], lose_claims={"job-01"})
    assert make_runner(client, state_dir).poll_once([PROFILE]) is None
    assert shim.calls() == []


# ── dispatch per kind ─────────────────────────────────────────────────────


P = f"burrow-{PROFILE}"


def _process_argv(state_dir, name):
    return [
        ["profile", "path", P],
        ["profile", "import", str(state_dir / "tmp" / f"{P}.toml"), "--name", P, "--force", "--yes"],
        ["config", "get", "effective_privacy_mode", "--profile", P],
        ["config", "get", "privacy.mode", "--profile", P],
        ["process", "/episodes/ep.mp4", "--project", name, "--profile", P],
        ["project", "info", "--json", name],
    ]


# Stage 2 (0.2.0) replaced the stage-1 placeholder sequences: the real clip CLI takes
# --project NAME (not a dir), has no --json on process/review/finalize, and needs
# review.toml created (`review --overwrite`) before it is edited and applied.
EXPECTED_ARGV = {
    "new_clip": lambda proj, sd: [
        ["version", "--json"], ["doctor", "--json"],
        *_process_argv(sd, "burrow-clip-job-01"),
        ["review", proj, "--overwrite"],
        ["config", "get", "captions.style", "--profile", P],
        ["config", "get", "outro.audio", "--profile", P],
        ["profile", "import", str(sd / "tmp" / f"{P}-job-job-01.toml"), "--name", f"{P}-job-job-01", "--force", "--yes"],
        ["review", proj, "--apply", "--profile", f"{P}-job-job-01"], ["review", proj, "--overwrite", "--profile", f"{P}-job-job-01"],
        ["hooks", "prepare-review", proj, "--request", str(sd / "tmp" / "headline-request.json"), "--profile", f"{P}-job-job-01"],
        ["review", proj, "--apply", "--profile", f"{P}-job-job-01"],
        ["hooks", "prepare-review", proj, "--request", str(sd / "tmp" / "headline-request.json"), "--profile", f"{P}-job-job-01", "--check-applied"],
        ["finalize", proj, "--profile", f"{P}-job-job-01", "--captions", "phrase-pop", "--regenerate"],
        ["profile", "path", f"{P}-job-job-01"],
    ],
    "rerender": lambda proj, sd: [
        ["version", "--json"],
        ["doctor", "--json"],
        *_process_argv(sd, "burrow-clip-job-01"),
        ["review", proj, "--overwrite"],
        ["config", "get", "outro.audio", "--profile", P],
        ["review", proj, "--apply"],
        ["finalize", proj, "--regenerate"],
    ],
    "save_default": lambda proj, sd: [
        ["version", "--json"],
        ["doctor", "--json"],
        ["profile", "import", str(sd / "tmp" / f"{P}.toml"), "--name", P, "--force", "--yes"],
        ["profile", "use", P],
    ],
}


@pytest.mark.parametrize("kind", ["new_clip", "rerender", "save_default"])
def test_each_kind_is_dispatched_and_completed(shim, state_dir, kind):
    job = make_job("job-01", kind)
    client = FakeJobClient(jobs=[job])
    outcome = make_runner(client, state_dir).poll_once([PROFILE])

    assert outcome["status"] == "done"
    proj = str(shim.home / "clips" / "burrow-clip-job-01")
    assert shim.argvs() == EXPECTED_ARGV[kind](proj, state_dir)

    [complete] = client.named("complete")
    result = complete[2]
    assert set(result) <= set(clip_runner.RESULT_KEYS)
    assert result["source_label"] == "htc-clip-tool"
    if kind == "save_default":
        assert "file_id" not in result
        # privacy mode never read for a profile-only job: fail closed (local), meta keys null
        assert all(result[k] is None for k in clip_runner.META_KEYS)
    else:
        # cloud mode (the fake's default): the tool's title may come back (payload had none);
        # make_job's 10..40 overlaps only the alternate, so the nearest CUT clip (c1) is chosen
        assert result == {
            "file_id": "file-123",
            "duration_s": 30.0,
            **({"title": "Secret Title One"} if kind == "rerender" else {}),
            "candidate_id": "c1aaaaaaaa",
            "source_label": "htc-clip-tool",
        }
    assert client.named("fail") == []
    assert client.jobs["job-01"]["status"] == "done"
    assert journal_files(state_dir) == []
    # progress at step boundaries, monotonic, within 0..1
    progress = [c[2] for c in client.named("progress")]
    assert progress and progress == sorted(progress) and all(0 <= p < 1 for p in progress)


def test_trim_is_a_rerender_not_its_own_kind(shim, state_dir):
    job = make_job("job-01", "rerender", in_s=12.0, out_s=33.0, look_delta={})
    client = FakeJobClient(jobs=[job])
    assert make_runner(client, state_dir).poll_once([PROFILE])["status"] == "done"
    assert "trim" not in clip_runner.HANDLERS


def test_unknown_kind_fails_without_running_clip(shim, state_dir):
    job = make_job("job-01", "trim")
    client = FakeJobClient(jobs=[job])
    outcome = make_runner(client, state_dir).poll_once([PROFILE])

    assert outcome["status"] == "failed" and outcome["code"] == "UNKNOWN_KIND"
    assert client.named("fail")[0][3] == "UNKNOWN_KIND"
    assert shim.calls() == []
    assert journal_files(state_dir) == []


def test_save_default_never_targets_the_built_in_profile(shim, state_dir):
    job = make_job("job-01", "save_default", clip_user_profile="how-to-computer")
    client = FakeJobClient(jobs=[job])
    outcome = make_runner(client, state_dir).poll_once([PROFILE])
    assert outcome["code"] == "BAD_PAYLOAD"
    assert shim.calls() == []


def test_complete_sends_only_result_keys():
    assert clip_runner.finish_result({"file_id": "f", "transcript": "x", "picks": [], "title": None}) == {
        "file_id": "f",
        "title": None,
        "source_label": "htc-clip-tool",
    }


# ── startup reclaim ───────────────────────────────────────────────────────


def test_startup_reclaim_fails_own_orphans_and_ignores_other_agents(state_dir):
    client = FakeJobClient(
        jobs=[
            make_job("job-01", status="claimed", claimed_by=AGENT),
            make_job("job-02", status="running", claimed_by=AGENT),
            make_job("job-03", status="claimed", claimed_by=OTHER),
            make_job("job-04", status="running", claimed_by=OTHER),
            make_job("job-05", status="queued"),
            make_job("job-06", status="done", claimed_by=AGENT),
        ]
    )
    journal = clip_runner.Journal(state_dir)
    journal.write(client.jobs["job-02"], "finalize")

    failed = make_runner(client, state_dir).startup_reclaim([PROFILE])

    assert sorted(failed) == ["job-01", "job-02"]
    fails = {c[1]: c for c in client.named("fail")}
    assert set(fails) == {"job-01", "job-02"}
    assert all(c[3] == "RUNNER_RESTARTED" for c in fails.values())
    assert fails["job-02"][2].endswith("last step: finalize")
    assert client.jobs["job-03"]["status"] == "claimed"
    assert client.jobs["job-04"]["status"] == "running"
    assert client.jobs["job-05"]["status"] == "queued"
    assert {("list", PROFILE, "claimed"), ("list", PROFILE, "running")} <= set(client.calls)
    assert journal_files(state_dir) == []


def test_startup_reclaim_fails_journalled_job_and_tolerates_closed(state_dir):
    # job-07 is journalled but already closed server-side: fail is refused, journal still cleared
    closed = make_job("job-07", status="failed", claimed_by=AGENT)
    client = FakeJobClient(jobs=[closed])
    clip_runner.Journal(state_dir).write(closed, "process")
    assert make_runner(client, state_dir).startup_reclaim([PROFILE]) == ["job-07"]
    assert client.named("fail")[0][3] == "RUNNER_RESTARTED"
    assert journal_files(state_dir) == []


# ── failure paths ─────────────────────────────────────────────────────────


def test_crash_mid_finalize_fails_with_clip_error_code_and_clears_journal(shim, state_dir):
    shim.script(
        finalize={
            "exit": 3,
            "stdout": {"ok": False, "title": "Secret Episode Title", "error": {"code": "FFMPEG_FAILED"}},
        }
    )
    client = FakeJobClient(jobs=[make_job("job-01", "rerender")])
    outcome = make_runner(client, state_dir).poll_once([PROFILE])

    assert outcome == {"job_id": "job-01", "kind": "rerender", "status": "failed", "code": "FFMPEG_FAILED"}
    [fail] = client.named("fail")
    assert fail[3] == "FFMPEG_FAILED"
    assert "Secret" not in fail[2] and "finalize" in fail[2]
    assert client.named("complete") == []
    assert client.jobs["job-01"]["status"] == "failed"
    assert journal_files(state_dir) == []


def test_non_zero_exit_without_json_code_uses_exit_code(shim, state_dir):
    shim.script(review_apply={"exit": 4, "stdout": "not json"})
    client = FakeJobClient(jobs=[make_job("job-01", "rerender")])
    assert make_runner(client, state_dir).poll_once([PROFILE])["code"] == "CLIP_EXIT_4"


def test_doctor_not_ok_fails_with_its_code(shim, state_dir):
    shim.script(doctor={"stdout": {"ok": False, "code": "NO_FFMPEG"}})
    client = FakeJobClient(jobs=[make_job("job-01", "save_default")])
    assert make_runner(client, state_dir).poll_once([PROFILE])["code"] == "NO_FFMPEG"


def test_timeout_kills_command_and_fails(shim, state_dir):
    shim.script(finalize={"sleep": 5})
    client = FakeJobClient(jobs=[make_job("job-01", "rerender")])
    start = time.monotonic()
    outcome = make_runner(client, state_dir, timeout_s=0.5, heartbeat_s=0.2).poll_once([PROFILE])
    assert outcome["code"] == "CLIP_TIMEOUT"
    assert time.monotonic() - start < 4


def test_python_exception_in_a_step_still_ends_failed(shim, state_dir):
    def boom(runner, job):
        raise RuntimeError("Secret Episode Title")

    client = FakeJobClient(jobs=[make_job("job-01", "new_clip")])
    outcome = make_runner(client, state_dir, uploader=boom).poll_once([PROFILE])
    assert outcome["code"] == "RUNNER_EXCEPTION"
    [fail] = client.named("fail")
    assert "Secret" not in fail[2] and "RuntimeError" in fail[2]
    assert journal_files(state_dir) == []


def test_refused_complete_becomes_a_fail_with_the_tool_code(shim, state_dir):
    class Refusing(FakeJobClient):
        def complete(self, job_id, result):
            self.calls.append(("complete", job_id, result))
            raise clip_runner.JobToolError("file_not_in_project")

    client = Refusing(jobs=[make_job("job-01", "rerender")])
    assert make_runner(client, state_dir).poll_once([PROFILE])["code"] == "FILE_NOT_IN_PROJECT"
    assert client.jobs["job-01"]["status"] == "failed"


def test_journal_survives_when_the_fail_call_itself_errors(shim, state_dir):
    class Down(FakeJobClient):
        def fail(self, job_id, error, code):
            raise ConnectionError("tool unreachable")

    shim.script(finalize={"exit": 2})
    client = Down(jobs=[make_job("job-01", "rerender")])
    with pytest.raises(ConnectionError):
        make_runner(client, state_dir).poll_once([PROFILE])
    assert journal_files(state_dir) == ["job-01.json"]  # next startup reclaim fails it


def test_journal_is_written_before_each_clip_command(shim, state_dir):
    seen = []

    class Watching(FakeJobClient):
        def progress(self, job_id, progress, eta_s=None):
            seen.append(json.loads((state_dir / "jobs" / f"{job_id}.json").read_text())["step"])
            super().progress(job_id, progress, eta_s)

    client = Watching(jobs=[make_job("job-01", "rerender")])
    make_runner(client, state_dir).poll_once([PROFILE])
    assert seen == ["doctor", "config_get", "process", "project_info", "review", "review_apply", "finalize"]


# ── heartbeat ─────────────────────────────────────────────────────────────


def test_heartbeat_fires_during_a_long_command(shim, state_dir):
    shim.script(finalize={"sleep": 1.3})
    client = FakeJobClient(jobs=[make_job("job-01", "rerender")])
    marks = []
    orig = client.progress

    def progress(job_id, progress, eta_s=None):
        marks.append(time.monotonic())
        orig(job_id, progress, eta_s)

    client.progress = progress
    outcome = make_runner(client, state_dir, heartbeat_s=0.2).poll_once([PROFILE])
    assert outcome["status"] == "done"
    gaps = [b - a for a, b in itertools.pairwise(marks)]
    assert len(marks) >= 8  # 4 boundaries + >= 4 heartbeats during the 1.3s finalize
    assert max(gaps) < 0.6


def test_heartbeat_interval_is_capped_at_60s():
    assert clip_runner.Runner(FakeJobClient(), heartbeat_s=600).heartbeat_s == 60.0


# ── CLI (the agent-facing surface) ──────────────────────────────────────


def cli(state_dir, *args, stdin=None, env=None):
    return subprocess.run(
        [sys.executable, str(ROOT / "clip_runner.py"), "--state-dir", str(state_dir), *args],
        input=json.dumps(stdin) if stdin is not None else "",
        capture_output=True,
        check=False,
        text=True,
        env=env,
        timeout=30,
    )


def lines(stdout):
    return [json.loads(line) for line in stdout.splitlines() if line.strip()]


def test_cli_order_is_oldest_queued_first(state_dir):
    jobs = [
        make_job("job-09", inserted_at="2026-10-23T09:00:00Z"),
        make_job("job-03", inserted_at="2026-10-23T03:00:00Z"),
        make_job("job-05", status="claimed", claimed_by=OTHER),
    ]
    out = cli(state_dir, "order", stdin={"jobs": jobs})
    assert json.loads(out.stdout) == {"claim_order": ["job-03", "job-09"]}


def test_cli_run_emits_progress_then_one_terminal_call(shim, state_dir):
    job = make_job("job-01", "save_default", status="claimed", claimed_by=AGENT)
    out = cli(state_dir, "run", stdin={"job": job}, env=dict(os.environ))
    calls = lines(out.stdout)
    assert out.returncode == 0
    assert [c["tool"] for c in calls[:-1]] == ["social_clip_job_progress"] * (len(calls) - 1)
    assert calls[-1] == {
        "tool": "social_clip_job_complete",
        "args": {
            "job_id": "job-01",
            "source_label": "htc-clip-tool",
            "title": None,
            "caption": None,
            "speaker": None,
            "episode_code": None,
        },
    }
    outbox = (state_dir / "outbox" / "job-01.jsonl").read_text().splitlines()
    assert [json.loads(x) for x in outbox] == calls


def episode(tmp_path):
    p = tmp_path / "episode.mp4"
    p.write_bytes(b"EPISODE")
    return p


def wait_for_step(state_dir, job_id, step, timeout=10):
    path = state_dir / "jobs" / f"{job_id}.json"
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if json.loads(path.read_text())["step"] == step:
                return
        except (OSError, ValueError):
            pass
        time.sleep(0.05)
    raise AssertionError(f"never reached {step}")


def spawn_run(state_dir, job, episode):
    proc = subprocess.Popen(
        [sys.executable, str(ROOT / "clip_runner.py"), "--state-dir", str(state_dir), "run"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )
    context = {"clip_rev": 1, "project_id": "project-files-1", "episode_path": str(episode)}
    proc.stdin.write(json.dumps({"job": job, "context": context}))
    proc.stdin.close()
    return proc


def test_cli_sigterm_mid_finalize_fails_job_and_clears_journal(shim, state_dir, tmp_path):
    shim.script(finalize={"sleep": 30})
    job = make_job("job-01", "rerender", status="claimed", claimed_by=AGENT)
    proc = spawn_run(state_dir, job, episode(tmp_path))
    wait_for_step(state_dir, "job-01", "finalize")
    time.sleep(0.3)
    proc.send_signal(signal.SIGTERM)
    stdout = proc.stdout.read()
    assert proc.wait(timeout=10) == 1
    last = lines(stdout)[-1]
    assert last["tool"] == "social_clip_job_fail"
    assert last["args"]["code"] == "RUNNER_SIGTERM"
    assert "finalize" in last["args"]["error"]
    assert journal_files(state_dir) == []


def test_cli_sigkill_mid_finalize_is_failed_by_next_startup_reclaim(shim, state_dir, tmp_path):
    shim.script(finalize={"sleep": 30})
    job = make_job("job-01", "rerender", status="claimed", claimed_by=AGENT)
    proc = spawn_run(state_dir, job, episode(tmp_path))
    wait_for_step(state_dir, "job-01", "finalize")
    proc.kill()
    proc.wait(timeout=10)
    assert journal_files(state_dir) == ["job-01.json"]

    server_view = [dict(job, status="running"), make_job("job-02", status="claimed", claimed_by=OTHER)]
    out = cli(state_dir, "reclaim", "--agent-id", AGENT, stdin={"jobs": server_view})
    assert out.returncode == 0
    assert lines(out.stdout) == [
        {
            "tool": "social_clip_job_fail",
            "args": {
                "job_id": "job-01",
                "code": "RUNNER_RESTARTED",
                "error": "runner restarted mid-job; last step: finalize",
            },
        }
    ]
    assert journal_files(state_dir) == []


def test_cli_reclaim_refuses_while_a_run_holds_the_lock(shim, state_dir, tmp_path):
    shim.script(finalize={"sleep": 30})
    job = make_job("job-01", "rerender", status="claimed", claimed_by=AGENT)
    proc = spawn_run(state_dir, job, episode(tmp_path))
    try:
        wait_for_step(state_dir, "job-01", "finalize")
        out = cli(state_dir, "reclaim", "--agent-id", AGENT, stdin={"jobs": [dict(job, status="running")]})
        assert out.returncode == clip_runner.EXIT_BUSY
        assert json.loads(out.stdout) == {"busy": True}
        assert journal_files(state_dir) == ["job-01.json"]
    finally:
        proc.send_signal(signal.SIGTERM)
        proc.wait(timeout=10)
````

### `tests/test_stage2.py`

````python
"""Stage 2: per-kind clip sequences, review.toml edit, looks, upload and privacy."""

import hashlib
import http.server
import json
import os
import subprocess
import sys
import threading
import time
from typing import ClassVar

import pytest
from conftest import AGENT, PROFILE, ROOT, FakeJobClient, make_job, make_runner

import clip_runner

P = f"burrow-{PROFILE}"
LOOK = {"captions.size_frac": 0.07, "captions.primary_color": "#FFEE00", "captions.hook_title": True}
SECRET_WORDS = ("Secret", "secret", "01_", "02_", "final/", "review.toml", ".srt", "transcript")


def proj(shim, clip="clip-job-01"):
    return shim.home / "clips" / f"burrow-{clip}"


def run(client, state_dir, **kw):
    return make_runner(client, state_dir, **kw).poll_once([PROFILE])


def first_new_clip(shim, state_dir, **payload):
    """A done new_clip for clip-job-01 (leaves the clip mapping in state.json)."""
    payload.setdefault("in_s", 305.0)
    payload.setdefault("out_s", 340.0)
    client = FakeJobClient(jobs=[make_job("job-01", "new_clip", **payload)])
    assert run(client, state_dir)["status"] == "done"
    return client


def rerender_job(job_id="job-02", **payload):
    job = make_job(job_id, "rerender", **payload)
    job["clip_id"] = job["payload"]["clip_id"] = "clip-job-01"
    return job


def logged(shim, key):
    return [c for c in shim.calls() if key in c]


# ── exact argv per kind ─────────────────────────────────────────────────


def test_rerender_reuses_the_mapped_project(shim, state_dir):
    first_new_clip(shim, state_dir)
    n = len(shim.calls())
    client = FakeJobClient(jobs=[rerender_job(in_s=306.0, out_s=338.0)])
    assert run(client, state_dir)["status"] == "done"
    d = str(proj(shim))
    assert shim.argvs()[n:] == [
        ["version", "--json"],
        ["doctor", "--json"],
        ["project", "info", "--json", d],
        ["review", d, "--overwrite"],
        ["config", "get", "outro.audio", "--profile", P],
        ["review", d, "--apply"],
        ["finalize", d, "--regenerate"],
    ]
    mapping = json.loads((state_dir / "state.json").read_text())["clips"]["clip-job-01"]
    assert mapping == {
        "path": d,
        "profile_id": PROFILE,
        "project": "burrow-clip-job-01",
        "tool_clip_id": "c2bbbbbbbb",
    }


def test_look_change_renders_through_a_derived_profile_then_removes_it(shim, state_dir):
    first_new_clip(shim, state_dir)
    n = len(shim.calls())
    job = rerender_job(clip_overrides={"mapped": LOOK, "unmapped": []})
    client = FakeJobClient(jobs=[job])
    assert run(client, state_dir)["status"] == "done"
    d = str(proj(shim))
    derived = f"{P}-job-job-02"
    assert shim.argvs()[n:] == [
        ["version", "--json"],
        ["doctor", "--json"],
        ["project", "info", "--json", d],
        ["review", d, "--overwrite"],
        ["config", "get", "outro.audio", "--profile", P],
        [
            "profile",
            "import",
            str(state_dir / "tmp" / f"{derived}.toml"),
            "--name",
            derived,
            "--force",
            "--yes",
        ],
        ["review", d, "--apply", "--profile", derived],
        ["finalize", d, "--profile", derived, "--regenerate"],
        ["profile", "path", derived],
    ]
    imp = logged(shim, "imported")[-1]  # [0] is the bare user profile the first new_clip made
    assert imp["imported"] == (
        f'extends = "{P}"\n\n[captions]\nhook_title = true\nprimary_color = "#FFEE00"\nsize_frac = 0.07\n'
    )
    assert not (shim.home / "profiles" / f"{derived}.toml").exists()
    assert not (state_dir / "tmp" / f"{derived}.toml").exists()
    assert (shim.home / "profiles" / f"{P}.toml").exists()  # the user profile itself stays


def test_derived_profile_is_removed_when_finalize_fails(shim, state_dir):
    first_new_clip(shim, state_dir)
    shim.script(finalize={"exit": 2, "stdout": {"ok": False, "error": {"code": "RENDER_FAILED"}}})
    client = FakeJobClient(jobs=[rerender_job(clip_overrides={"mapped": LOOK, "unmapped": []})])
    outcome = run(client, state_dir)
    assert outcome["code"] == "RENDER_FAILED"
    derived = f"{P}-job-job-02"
    assert ["profile", "path", derived] == shim.argvs()[-1]
    assert not (shim.home / "profiles" / f"{derived}.toml").exists()


def test_derived_profile_is_removed_on_sigterm(shim, state_dir, tmp_path):
    first_new_clip(shim, state_dir)
    shim.script(finalize={"sleep": 30})
    job = rerender_job(clip_overrides={"mapped": LOOK, "unmapped": []}, expected_rev=2)
    job.update(status="claimed", claimed_by_agent_id=AGENT)
    proc = subprocess.Popen(
        [sys.executable, str(ROOT / "clip_runner.py"), "--state-dir", str(state_dir), "run"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )
    proc.stdin.write(json.dumps({"job": job, "context": {"clip_rev": 1, "project_id": "p", "headline_voice": {"revision": "fixture-8", "direction": "Comedy; incomplete."}}}))
    proc.stdin.close()
    derived = shim.home / "profiles" / f"{P}-job-job-02.toml"
    deadline = time.monotonic() + 10
    while not any(c["argv"][0] == "finalize" for c in shim.calls()[2:]) or not derived.exists():
        assert time.monotonic() < deadline
        time.sleep(0.05)
    time.sleep(0.3)
    proc.terminate()
    out = proc.stdout.read()
    assert proc.wait(timeout=10) == 1
    assert json.loads(out.splitlines()[-1])["args"]["code"] == "RUNNER_SIGTERM"
    assert not derived.exists()


def test_rerender_without_a_mapping_reprocesses_from_the_episode(shim, state_dir):
    client = FakeJobClient(jobs=[rerender_job()])
    assert run(client, state_dir)["status"] == "done"
    assert [a[0] for a in shim.argvs()].count("process") == 1


def test_save_default_imports_the_user_profile_over_how_to_computer(shim, state_dir, capsys):
    job = make_job("job-01", "save_default", clip_overrides={"mapped": LOOK, "unmapped": ["cap.hl", "music"]})
    client = FakeJobClient(jobs=[job])
    assert run(client, state_dir)["status"] == "done"
    [imp] = logged(shim, "imported")
    assert imp["imported"].startswith('extends = "how-to-computer"\n')
    assert "size_frac = 0.07" in imp["imported"]
    assert shim.argvs()[-1] == ["profile", "use", P]
    assert "LOOK_KEYS_UNMAPPED cap.hl,music" in capsys.readouterr().err
    [complete] = client.named("complete")
    assert "file_id" not in complete[2]


# ── review.toml: only start/end/decision of the target ──────────────────


def test_review_edit_touches_only_the_target_clip(shim, state_dir):
    first_new_clip(shim, state_dir, in_s=302.5, out_s=341.25)
    written = logged(shim, "written")[0]["written"]
    applied = logged(shim, "applied")[0]["applied"]
    before, after = written.splitlines(keepends=True), applied.splitlines(keepends=True)
    assert len(before) == len(after)
    changed = {i: (b, a) for i, (b, a) in enumerate(zip(before, after, strict=True)) if b != a}
    assert sorted(a for _, a in changed.values()) == sorted(
        ['decision = "approve"\n', "end = 341.250\n", "start = 302.500\n"]
    )
    c2 = before.index('id = "c2bbbbbbbb"\n')
    next_clip = before.index("[[clip]]\n", c2)
    assert all(c2 < i < next_clip for i in changed)


def test_best_overlap_ignores_alternates_and_keeps_crlf():
    from fake_clip import REVIEW_FIXTURE

    review = clip_runner.ReviewFile(REVIEW_FIXTURE.replace("\n", "\r\n"))
    assert [e.fields["id"] for e in review.entries] == [
        "c1aaaaaaaa",
        "c2bbbbbbbb",
        "c3cccccccc",
        "a1dddddddd",
    ]
    assert review.entries[3].alternate and not review.entries[2].alternate
    assert review.best_overlap(12.0, 38.0).fields["id"] == "c1aaaaaaaa"  # alternate overlaps, never chosen
    assert review.best_overlap(510.0, 560.0).fields["id"] == "c3cccccccc"
    entry = review.by_id("c3cccccccc")
    review.set_fields(entry, start=505, end=545.5, decision="approve")
    out = review.text()
    assert "start = 505.000\r\n" in out and "end = 545.500\r\n" in out
    assert out.count('\r\ndecision = "approve"\r\n') == 1
    with pytest.raises(ValueError):
        review.set_fields(entry, packaging="x")


def test_trim_keeps_the_mapped_tool_clip_even_without_overlap(shim, state_dir):
    first_new_clip(shim, state_dir)  # maps c2
    client = FakeJobClient(jobs=[rerender_job(in_s=600.0, out_s=640.0)])
    assert run(client, state_dir)["status"] == "done"
    applied = logged(shim, "applied")[-1]["applied"]
    block = applied[applied.index('id = "c2bbbbbbbb"') :]
    assert block.split("[[clip]]")[0].count("start = 600.000") == 1


# ── built-in profile is never written ───────────────────────────────────


def test_built_in_profile_is_never_opened_for_write(shim, state_dir):
    builtin = shim.home / "builtin" / "how-to-computer.toml"
    before = builtin.read_bytes()
    writes = []

    def hook(event, args):
        if event == "open" and args and isinstance(args[0], (str, bytes, os.PathLike)):
            mode = args[1] if len(args) > 1 and isinstance(args[1], str) else ""
            flags = args[2] if len(args) > 2 and isinstance(args[2], int) else 0
            if any(m in mode for m in "wax+") or flags & (os.O_WRONLY | os.O_RDWR):
                writes.append(os.fsdecode(args[0]))

    sys.addaudithook(hook)
    first_new_clip(shim, state_dir)
    for job in (
        rerender_job(clip_overrides={"mapped": LOOK, "unmapped": []}),
        make_job("job-03", "save_default", clip_overrides={"mapped": LOOK, "unmapped": []}),
    ):
        assert run(FakeJobClient(jobs=[job]), state_dir)["status"] == "done"
    assert writes, "audit hook saw nothing"
    assert not [w for w in writes if "how-to-computer" in w or str(shim.home / "builtin") in w]
    assert builtin.read_bytes() == before
    assert "how-to-computer" not in {a[a.index("--name") + 1] for a in shim.argvs() if "--name" in a}


def test_derived_profile_removal_refuses_a_built_in_path(shim, state_dir):
    runner = make_runner(FakeJobClient(), state_dir)
    shim.script(profile_path={"stdout": str(shim.home / "builtin" / "how-to-computer.toml")})
    clip_runner._remove_profile(runner, f"{P}-job-x")
    assert (shim.home / "builtin" / "how-to-computer.toml").exists()
    with pytest.raises(ValueError):
        clip_runner._remove_profile(runner, "how-to-computer")


def test_no_picks_json_is_ever_written(shim, state_dir, tmp_path):
    first_new_clip(shim, state_dir)
    assert not [p for p in tmp_path.rglob("*") if "pick" in p.name.lower()]


# ── privacy ─────────────────────────────────────────────────────────────


@pytest.mark.parametrize("privacy,inferred", [("local", "0"), ("cloud", "1")])
def test_local_mode_is_content_free_end_to_end(shim, state_dir, monkeypatch, privacy, inferred):
    monkeypatch.setenv("FAKE_PRIVACY", privacy)
    monkeypatch.setenv("FAKE_PRIVACY_INFERRED", inferred)  # an inferred cloud counts as local
    if inferred == "1":
        monkeypatch.setenv("FAKE_PRIVACY_EXPLICIT", "None")
    client = first_new_clip(shim, state_dir)
    assert all(c["env"].get("CLIP_NO_CONTENT") == "1" for c in shim.calls())
    [complete] = client.named("complete")
    result = complete[2]
    assert {k: result[k] for k in clip_runner.META_KEYS} == dict.fromkeys(clip_runner.META_KEYS)
    assert set(result) == {*clip_runner.META_KEYS, "file_id", "duration_s", "source_label", "candidate_id"}
    blob = json.dumps(client.calls)
    assert not [w for w in SECRET_WORDS if w in blob]

    shim.script(
        finalize={"exit": 3, "stdout": {"ok": False, "title": "Secret T", "error": {"code": "X_FAIL"}}}
    )
    client = FakeJobClient(jobs=[rerender_job()])
    assert run(client, state_dir)["code"] == "X_FAIL"
    assert all(c["env"].get("CLIP_NO_CONTENT") == "1" for c in shim.calls())
    [fail] = client.named("fail")
    assert not [w for w in SECRET_WORDS if w in json.dumps(fail)]
    assert not [k for k in clip_runner.META_KEYS if k in json.dumps(fail)]


def test_cloud_mode_also_keeps_no_content(shim, state_dir):
    first_new_clip(shim, state_dir)
    by_cmd = {tuple(c["argv"][:2]): c["env"].get("CLIP_NO_CONTENT") for c in shim.calls()}
    assert by_cmd[("version", "--json")] == "1"  # before the mode is known: fail closed
    assert by_cmd[("config", "get")] == "1"
    assert by_cmd[("process", "/episodes/ep.mp4")] == "1"
    assert by_cmd[("finalize", str(proj(shim)))] == "1"


def test_a_payload_title_is_not_overwritten_in_cloud_mode(shim, state_dir):
    client = first_new_clip(shim, state_dir, title="Human Title")
    assert "title" not in client.named("complete")[0][2]


def test_finish_result_local_nulls_meta():
    assert clip_runner.finish_result({"file_id": "f", "title": "T", "speaker": "S"}, local=True) == {
        "file_id": "f",
        "title": None,
        "caption": None,
        "speaker": None,
        "episode_code": None,
        "source_label": "htc-clip-tool",
    }


# ── rev, preflight ──────────────────────────────────────────────────────


def test_expected_rev_mismatch_fails_before_any_clip_command(shim, state_dir):
    client = FakeJobClient(jobs=[rerender_job("job-03", expected_rev=5)])
    n = len(shim.calls())
    outcome = run(client, state_dir, context_for=lambda r, j: {"clip_rev": 3, "project_id": "p"})
    assert outcome["code"] == "REV_MISMATCH"
    assert len(shim.calls()) == n
    assert client.named("fail")[0][2] == "dispatch failed (expected 5, clip at 3)"


def test_rerender_without_the_clip_rev_fails(shim, state_dir):
    client = FakeJobClient(jobs=[rerender_job()])
    assert run(client, state_dir, context_for=lambda r, j: {})["code"] == "REV_UNKNOWN"
    assert shim.calls() == []


def test_new_clip_checks_rev_against_the_current_rev(shim, state_dir):
    client = FakeJobClient(jobs=[make_job("job-01", "new_clip", expected_rev=2)])
    assert run(client, state_dir)["status"] == "done"  # default context echoes it
    client = FakeJobClient(jobs=[make_job("job-02", "new_clip", expected_rev=2)])
    assert run(client, state_dir, context_for=lambda r, j: {"clip_rev": 1})["code"] == "REV_MISMATCH"


@pytest.mark.parametrize(
    "version,code", [("0.8.9", "CLIP_TOO_OLD"), ("garbage", "CLIP_VERSION_UNKNOWN"), ("0.9.0", None)]
)
def test_version_gate(shim, state_dir, monkeypatch, version, code):
    monkeypatch.setenv("FAKE_CLIP_VERSION", version)
    outcome = run(FakeJobClient(jobs=[make_job("job-01", "save_default")]), state_dir)
    assert outcome.get("code") == code


def test_content_free_capability_is_recorded(shim, state_dir, monkeypatch):
    seen = {}

    def upload(runner, job):
        seen["cf"] = runner.content_free
        return "file-1"

    first = make_runner(FakeJobClient(jobs=[make_job("job-01")]), state_dir, uploader=upload)
    first.poll_once([PROFILE])
    assert seen["cf"] is True
    monkeypatch.setenv("FAKE_CONTENT_FREE", "1")
    make_runner(FakeJobClient(jobs=[make_job("job-02")]), state_dir, uploader=upload).poll_once([PROFILE])
    assert seen["cf"] is False


def test_doctor_fix_fails_with_the_check_names(shim, state_dir):
    shim.script(
        doctor={
            "stdout": {
                "checks": [{"check": "whisper_model", "status": "fix", "message": "Secret"}],
                "summary": {"pass": 0, "warn": 0, "fix": 1},
            }
        }
    )
    client = FakeJobClient(jobs=[make_job("job-01", "save_default")])
    assert run(client, state_dir)["code"] == "CLIP_DOCTOR_FIX"
    assert client.named("fail")[0][2] == "doctor failed (whisper_model)"


# ── fetch ───────────────────────────────────────────────────────────────


def test_fetch_prefers_the_agents_local_copy_then_fails_closed(tmp_path, state_dir):
    runner = clip_runner.Runner(FakeJobClient(), state_dir=state_dir)
    job = make_job("job-01")
    ep = tmp_path / "ep.mp4"
    ep.write_bytes(b"x")
    runner.context = {"episode_path": str(ep), "headline_voice": {"revision": "fixture-8", "direction": "Comedy; incomplete."}}
    assert clip_runner.fetch_episode(runner, job) == str(ep)
    runner.context = {}
    with pytest.raises(clip_runner.ClipError) as err:
        clip_runner.fetch_episode(runner, job)
    assert err.value.code == "SOURCE_FILE_NO_DOWNLOAD"


def test_fetch_source_url_with_ytdlp_is_cached_and_named_by_hash(tmp_path, state_dir, monkeypatch):
    fake = tmp_path / "yt-dlp"
    count = tmp_path / "count"
    fake.write_text(
        "#!/bin/sh\n"
        f'echo x >> "{count}"\n'
        'while [ "$1" != "-o" ]; do shift; done\n'
        'out=$(echo "$2" | sed "s/%(ext)s/mp4/")\n'
        'echo VIDEO > "$out"\n'
    )
    fake.chmod(0o755)
    monkeypatch.setenv("CLIP_RUNNER_YTDLP", str(fake))
    runner = clip_runner.Runner(FakeJobClient(), state_dir=state_dir)
    job = make_job(
        "job-01", episode={"source_url": "https://video.example/watch?v=Secret", "source_file_id": None}
    )
    runner._job = job
    first = clip_runner.fetch_episode(runner, job)
    second = clip_runner.fetch_episode(runner, job)
    assert first == second and first.endswith(".mp4") and "Secret" not in first
    assert count.read_text().count("x") == 1


# ── upload ──────────────────────────────────────────────────────────────


class Upload(http.server.BaseHTTPRequestHandler):
    seen: ClassVar[list] = []
    reply_hash = None

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        Upload.seen.append(
            {
                "path": self.path,
                "auth": self.headers["Authorization"],
                "type": self.headers["Content-Type"],
                "body": body,
            }
        )
        doc = {
            "id": "file-777",
            "state": "ready",
            "content_hash": Upload.reply_hash or hashlib.sha256(body).hexdigest(),
        }
        data = json.dumps(doc).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


@pytest.fixture
def upload_server(monkeypatch):
    Upload.seen, Upload.reply_hash = [], None
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upload)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    monkeypatch.setenv("CLIP_RUNNER_BASE_URL", base)
    monkeypatch.setenv("CLIP_RUNNER_TOKEN", "tok-not-a-real-secret")
    yield base
    server.shutdown()


def test_upload_requests_file_add_then_posts_with_the_bearer(shim, state_dir, upload_server):
    client = FakeJobClient(jobs=[make_job("job-01", in_s=305.0, out_s=340.0)])
    assert run(client, state_dir, uploader=clip_runner.upload_output)["status"] == "done"
    [req] = client.named("request")
    video = (proj(shim) / "final" / "02_secret-title-two.mp4").read_bytes()
    assert req == (
        "request",
        "file_add",
        {
            "project_id": "project-files-1",
            "filename": "clip-clip-job-01-r1.mp4",
            "content_type": "video/mp4",
            "byte_size": len(video),
        },
    )
    [post] = Upload.seen
    assert post == {
        "path": "/chat/attachments/upload/tok",
        "auth": "Bearer tok-not-a-real-secret",
        "type": "video/mp4",
        "body": video,
    }
    assert client.named("complete")[0][2]["file_id"] == "file-777"
    assert "tok-not-a-real-secret" not in json.dumps(client.calls)
    assert not [c for c in shim.calls() if "CLIP_RUNNER_TOKEN" in c["env"]]


def test_upload_hash_mismatch_fails(shim, state_dir, upload_server):
    Upload.reply_hash = "0" * 64
    client = FakeJobClient(jobs=[make_job("job-01")])
    assert run(client, state_dir, uploader=clip_runner.upload_output)["code"] == "UPLOAD_HASH_MISMATCH"


def test_upload_never_sends_the_token_to_another_host(shim, state_dir, upload_server):
    client = FakeJobClient(jobs=[make_job("job-01")])
    client.replies["file_add"] = {"id": "f", "upload_url": "https://elsewhere.example/upload/x"}
    assert run(client, state_dir, uploader=clip_runner.upload_output)["code"] == "UPLOAD_HOST_MISMATCH"
    assert Upload.seen == []


def test_upload_without_token_is_unavailable(shim, state_dir, monkeypatch):
    monkeypatch.delenv("CLIP_RUNNER_TOKEN", raising=False)
    client = FakeJobClient(jobs=[make_job("job-01")])
    assert run(client, state_dir, uploader=clip_runner.upload_output)["code"] == "UPLOAD_UNAVAILABLE"


def test_cli_run_end_to_end_with_reply_file(shim, state_dir, tmp_path, upload_server):
    """The agent protocol: forward lines; answer a reply_file line with the tool result."""
    ep = tmp_path / "episode.mp4"
    ep.write_bytes(b"EPISODE")
    job = make_job("job-01", "new_clip", status="claimed", claimed_by=AGENT, in_s=305.0, out_s=340.0)
    proc = subprocess.Popen(
        [
            sys.executable,
            str(ROOT / "clip_runner.py"),
            "--state-dir",
            str(state_dir),
            "run",
            "--reply-timeout-s",
            "20",
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        env=dict(os.environ),
    )
    context = {"clip_rev": 1, "project_id": "project-files-1", "episode_path": str(ep), "headline_voice": {"revision": "fixture-8", "direction": "Comedy; incomplete."}}
    proc.stdin.write(json.dumps({"job": job, "context": context}))
    proc.stdin.close()
    lines = []
    for raw in proc.stdout:
        line = json.loads(raw)
        lines.append(line)
        if "reply_file" in line:
            assert line["tool"] == "file_add"
            tmp = line["reply_file"] + ".tmp"
            with open(tmp, "w") as fh:
                json.dump(
                    {"id": "file-777", "upload_url": "/chat/attachments/upload/tok", "state": "pending"}, fh
                )
            os.replace(tmp, line["reply_file"])
    assert proc.wait(timeout=30) == 0
    tools = [ln["tool"] for ln in lines]
    assert tools[-1] == "social_clip_job_complete" and "file_add" in tools
    assert set(tools[:-1]) == {"social_clip_job_progress", "file_add"}
    assert lines[-1]["args"]["file_id"] == "file-777"
    assert "tok-not-a-real-secret" not in json.dumps(lines)
````



### `tests/test_fixes.py`

````python
import tomllib

import pytest
from conftest import FakeJobClient
from test_stage2 import first_new_clip, logged, rerender_job, run

import clip_runner


@pytest.mark.parametrize('edge,delta,a,b', [('start',-1,304,340),('start',1,306,340),('end',-1,305,339),('end',1,305,341)])
def test_nudge(shim,state_dir,edge,delta,a,b):
    first_new_clip(shim,state_dir)
    client=FakeJobClient(jobs=[rerender_job(in_s=a,out_s=b,fix={'operation':'nudge','edge':edge,'delta_s':delta})])
    assert run(client,state_dir)['status']=='done'
    applied=tomllib.loads(logged(shim,'applied')[-1]['applied'])
    target=next(c for c in applied['clip'] if c['id']=='c2bbbbbbbb')
    assert (target['start'],target['end'])==(a,b)
    result=client.named('complete')[0][2]
    assert (result['actual_in_s'],result['actual_out_s'])==(a,b)
    assert target['packaging']=='bbbbbbbbbbbbbbbb'
    assert target['captions']=='2222222222222222'


def test_caption_one_position_only_and_local_privacy(shim,state_dir,monkeypatch):
    monkeypatch.setenv('FAKE_PRIVACY','local')
    monkeypatch.setenv('CLIP_RUNNER_TOKEN','secret-agent-token')
    first_new_clip(shim,state_dir)
    client=FakeJobClient(jobs=[rerender_job(in_s=305,out_s=340,fix={'operation':'caption_word','caption_fixes':{'position':2,'original':'words','replacement':'terms'}})])
    assert run(client,state_dir)['status']=='done'
    text=logged(shim,'applied')[-1]['applied']
    rows=tomllib.loads(text)['clip']
    assert rows[1]['transcript']=='secret transcript terms two'
    assert 'transcript' not in rows[0]
    assert all(c['env'].get('CLIP_NO_CONTENT')=='1' for c in shim.calls())
    assert all('CLIP_RUNNER_TOKEN' not in c['env'] for c in shim.calls())
    result=client.named('complete')[0][2]
    assert all(result[k] is None for k in clip_runner.META_KEYS)
    assert 'secret transcript' not in str(result)


def test_stale_word_no_apply_or_complete(shim,state_dir):
    first_new_clip(shim,state_dir)
    before=len(logged(shim,'applied'))
    client=FakeJobClient(jobs=[rerender_job(fix={'operation':'caption_word','caption_fixes':{'position':2,'original':'wrong','replacement':'terms'}})])
    assert run(client,state_dir)['code']=='STALE_CAPTION_WORD'
    assert len(logged(shim,'applied'))==before
    assert not client.named('complete')


def test_alternate_is_promoted_then_cut_before_finalize(shim,state_dir):
    first_new_clip(shim,state_dir)
    before=len(shim.argvs())
    client=FakeJobClient(jobs=[rerender_job(fix={'operation':'alternate_cut'})])
    assert run(client,state_dir)['status']=='done'
    calls=shim.argvs()[before:]
    apply=next(i for i,a in enumerate(calls) if a[0]=='review' and '--apply' in a)
    process=next(i for i,a in enumerate(calls) if a[0]=='process')
    final=next(i for i,a in enumerate(calls) if a[0]=='finalize')
    assert apply<process<final
    assert '--resume' in calls[process]
    result=client.named('complete')[0][2]
    assert result['candidate_id']==result['alternate_id']=='a1dddddddd'
    assert (result['actual_in_s'],result['actual_out_s'])==(10,40)


def test_missing_headline_hook_is_actionable_failure_not_intent_success(shim,state_dir):
    first_new_clip(shim,state_dir)
    import os
    os.environ["FAKE_HEADLINE_CAPABILITY"]="0"
    client=FakeJobClient(jobs=[rerender_job(base_render_id='base-1',fix={'operation':'regenerate_headline'})])
    assert run(client,state_dir)['code']=='HEADLINE_CLI_UNSUPPORTED'
    assert not client.named('complete')
    os.environ.pop('FAKE_HEADLINE_CAPABILITY',None)


def test_missing_review_contract_rejected(shim,state_dir):
    from fake_clip import REVIEW_FIXTURE
    review=clip_runner.ReviewFile(REVIEW_FIXTURE)
    entry=review.by_id('c2bbbbbbbb')
    with pytest.raises(ValueError):
        review.set_fields(entry,captions='fake-hash')


def test_caption_truncated_excerpt_fails_before_apply(shim,state_dir,monkeypatch):
    first_new_clip(shim,state_dir)
    original=clip_runner.ReviewFile
    class Truncated(original):
        def __init__(self,text):
            super().__init__(text)
            self.by_id('c2bbbbbbbb').fields['said']='secret transcript…'
    monkeypatch.setattr(clip_runner,'ReviewFile',Truncated)
    client=FakeJobClient(jobs=[rerender_job(fix={'operation':'caption_word','caption_fixes':{'position':0,'original':'secret','replacement':'public'}})])
    assert run(client,state_dir)['code']=='CAPTION_CONTRACT_UNSUPPORTED'
    assert not client.named('complete')


def test_missing_base_hash_fails_before_apply(shim,state_dir,monkeypatch):
    first_new_clip(shim,state_dir)
    original=clip_runner.ReviewFile
    class OldContract(original):
        def __init__(self,text):
            super().__init__(text)
            self.by_id('c2bbbbbbbb').fields.pop('packaging',None)
    monkeypatch.setattr(clip_runner,'ReviewFile',OldContract)
    client=FakeJobClient(jobs=[rerender_job(fix={'operation':'nudge'})])
    assert run(client,state_dir)['code']=='REVIEW_CONTRACT_UNSUPPORTED'
    assert not client.named('complete')


def test_base_candidate_is_never_silently_substituted(shim,state_dir):
    first_new_clip(shim,state_dir)
    client=FakeJobClient(jobs=[rerender_job(candidate_id='missing',fix={'operation':'nudge'})])
    assert run(client,state_dir)['code']=='BASE_CANDIDATE_MISSING'
    assert not client.named('complete')
````


## Shared headline boundary — contract headline-review/1 (stage 1 artifact)

The single interface for episode automation (01a17e37-97c2), regenerate fixes (01a17e37-836f), and human edits is now defined in the upstream extension artifact:
https://github.com/GetBurrowing/core/tree/61690d6d40b75c65d0038deb844c57defe1b35c0/docs/integrations/clip-headlines

Pinned upstream: JackEFoster/htc-clip-tool 58960577337d5682761e1538ff4365d4ba0b4e18. Patch SHA256: 9a128ddb62c3d72da10a0c91ee813ac7a7e2a0409a7e81e82994f0d18581660f.

**Integrated in helper 0.4.0 above.** A compatible installed tool is mandatory; the pinned upstream patch remains reviewable source, not an upstream merge or a production rollout. This skill is the one canonical runner; no second core runner is authorized.

- Require `clip version --json` capability `headline_review: 1`; 0.9.0 alone is insufficient. Unsupported builds fail HEADLINE_CLI_UNSUPPORTED, never silently ignore the headline.
- Local private request JSON: `version:1`, `consumer:episode|regenerate|edit`, candidate_id, source:{id,start,end}, voice:{revision,direction}, base_render_id (required for regenerate/edit), requested_headline (edit only), export_text:false. Source/bounds/base map to the existing immutable job snapshot under its existing lock; real ids and voice snapshots are runtime configuration, never core defaults.
- The live HTC master bible section sec-bible was read at revision8. Entertainment/comedy/positivity is supplied; most voice rules remain owed and earlier call material unratified. Keep that incompleteness in the runtime snapshot. Missing voice fails HEADLINE_VOICE_MISSING. No invented ratification.
- First apply the desired bounds through normal tool-local render approval and refresh review from applied state; use actual snapped bounds. Enable captions.hook_title through a derived USER profile, never the built-in how-to-computer profile.
- `CLIP_NO_CONTENT=1 clip hooks prepare-review PROJECT --request FILE --profile USER_PROFILE` calls the existing hooks.generate_variants policy for generation (normal quote checking/rotation and configured selection.title_hint voice direction); human edits bypass generation. It prepares only the selected explicit `headline` review.toml field. Unapplied review edits are preserved by refusal. It returns only a content-free `prepared` receipt.
- Run `clip review PROJECT --apply --profile USER_PROFILE`, then the same prepare-review command with `--check-applied`. Verification checks the fully applied review digest and actual hook_title_for text against the explicit headline, with ordinary approval status; it returns `applied`, never render success. Missing/empty/unbacked/mismatched headlines fail visibly. The supported headline field replaces stale title variants and participates in normal packaging approval and render invalidation.
- Then run `clip finalize PROJECT --profile USER_PROFILE --regenerate`; complete/upload only after a fresh render exists. Preserve previous files, other edits, idempotency and temporary-profile cleanup. Never write picks JSON or internal project state outside tool-owned review application.
- Requests/transcript/generated text stay local. CLI receipts contain only version, ids, bounds, voice_revision, backed and prepared/applied status, even for cloud projects. Local text export is refused. Retain CLIP_NO_CONTENT=1 and strip the Burrow token from children; existing local model provenance preflight/network guard remain required. Unexpected errors collapse to HEADLINE_PREPARE_FAILED without provider text.
- Tool-local review approval grants render permission only. No Burrow post approval, scheduling or publishing is authorized. No timeline, keyframe or canvas editor.

This reuses the existing hook generation policy, model and budget rather than adding a parallel model/prompt experiment. Future policy tuning belongs to established project eval conventions; the voice snapshot revision is available as a data variant key.

Evidence at definition: isolated upstream patch apply plus contract/review/hooks fixtures89 passed; contract24 passed; full source/test Ruff passed. Dropping headline forwarding made the unchanged exact review.toml assertion fail; restoration passed. Full upstream regressions and live generation/render availability must be reported separately, never inferred from fixtures. Stage2 real installed CLI video-frame proof is recorded above; it does not establish a production deployment or live model availability.



### `tests/test_headlines.py`

````python
import json
import os
import tomllib

import pytest
from conftest import FakeJobClient, default_context
from test_stage2 import first_new_clip, logged, proj, rerender_job, run

EXACT = 'two words secret transcript'


def edit_job(**kwargs):
    return rerender_job(base_render_id='render-fixture-1',
                        headline={'consumer': 'edit', 'requested_headline': EXACT}, **kwargs)


def test_new_pick_generates_automatically_and_exact_review_field(shim, state_dir):
    client = first_new_clip(shim, state_dir)
    prepared = logged(shim, 'headline_request')[0]
    assert prepared['headline_request']['consumer'] == 'episode'
    assert prepared['headline_request']['requested_headline'] is None
    target = next(c for c in tomllib.loads(logged(shim, 'applied')[-1]['applied'])['clip']
                  if c['id'] == 'c2bbbbbbbb')
    # Independent literal: deleting headline forwarding MUST fail here.
    assert target['headline'] == 'secret transcript words two'
    assert target['packaging'] == 'bbbbbbbbbbbbbbbb'
    assert prepared['request_mode'] == 0o600
    assert not list((state_dir / 'tmp').glob('headline-request*'))
    assert not list((shim.home / 'profiles').glob('*-job-*'))
    result = client.named('complete')[0][2]
    assert EXACT not in json.dumps(result)
    assert json.loads((state_dir / 'state.json').read_text())['clips']['clip-job-01']['headline_receipt']['status'] == 'applied'


def test_edit_exact_text_ordering_and_stale_variant_is_not_success(shim, state_dir):
    first_new_clip(shim, state_dir)
    n = len(shim.calls())
    client = FakeJobClient(jobs=[edit_job()])
    assert run(client, state_dir)['status'] == 'done'
    calls = shim.calls()[n:]
    prepare = next(i for i, c in enumerate(calls) if c['argv'][:2] == ['hooks', 'prepare-review'])
    apply = next(i for i, c in enumerate(calls) if i > prepare and '--apply' in c['argv'])
    verify = next(i for i, c in enumerate(calls) if '--check-applied' in c['argv'])
    final = next(i for i, c in enumerate(calls) if c['argv'][0] == 'finalize')
    assert prepare < apply < verify < final
    assert calls[prepare]['headline_request']['consumer'] == 'edit'
    assert calls[prepare]['headline_request']['requested_headline'] == 'two words secret transcript'
    target = next(c for c in tomllib.loads(calls[apply]['applied'])['clip'] if c['id'] == 'c2bbbbbbbb')
    assert target['headline'] == 'two words secret transcript'
    assert '--regenerate' in calls[final]['argv']
    assert all(c['env'].get('CLIP_NO_CONTENT') == '1' for c in calls)
    assert all('CLIP_RUNNER_TOKEN' not in c['env'] for c in calls)


def test_regenerate_uses_same_generation_boundary(shim, state_dir):
    first_new_clip(shim, state_dir)
    client = FakeJobClient(jobs=[rerender_job(base_render_id='render-fixture-1',fix={'operation':'regenerate_headline'})])
    assert run(client, state_dir)['status'] == 'done'
    request = logged(shim, 'headline_request')[-1]['headline_request']
    assert request['consumer'] == 'regenerate'
    assert request['requested_headline'] is None
    assert request['base_render_id'] == 'render-fixture-1'


@pytest.mark.parametrize('change,expected', [
    ({'headline_voice': None}, 'HEADLINE_VOICE_MISSING'),
    ({'base_render_id': 'newer-render'}, 'HEADLINE_BASE_STALE'),
])
def test_missing_voice_or_stale_base_never_completes(shim, state_dir, change, expected):
    first_new_clip(shim, state_dir)
    n = len(shim.calls())
    client = FakeJobClient(jobs=[edit_job()])
    def context(runner, job):
        return {**default_context(runner, job), **change}
    assert run(client, state_dir, context_for=context)['code'] == expected
    assert not client.named('complete')
    assert not any(c['argv'][0] == 'finalize' for c in shim.calls()[n:])
    assert not list((shim.home / 'profiles').glob('*-job-*'))


def test_empty_and_export_requests_fail(shim, state_dir):
    first_new_clip(shim, state_dir)
    for headline, code in [({'consumer':'edit','requested_headline':' '},'HEADLINE_EMPTY'),
                           ({'consumer':'edit','requested_headline':EXACT,'export_text':True},'HEADLINE_PRIVACY_EXPORT_REFUSED')]:
        client = FakeJobClient(jobs=[rerender_job(base_render_id='base-1',headline=headline)])
        assert run(client, state_dir)['code'] == code
        assert not client.named('complete')


def test_unsupported_receipt_does_not_finalize_or_leak(shim, state_dir):
    first_new_clip(shim, state_dir)
    shim.script(hooks={'stdout': {'status':'prepared','applied_headline':'private text'}})
    n=len(shim.calls())
    client=FakeJobClient(jobs=[edit_job()])
    assert run(client,state_dir)['code']=='HEADLINE_OUTPUT_UNSUPPORTED'
    assert not client.named('complete')
    assert 'private text' not in json.dumps(client.calls)
    assert not any(c['argv'][0]=='finalize' for c in shim.calls()[n:])
    assert not list((state_dir/'tmp').glob('headline-request*'))


def test_unbacked_edit_failure_has_no_completion_or_text(shim,state_dir,monkeypatch):
    first_new_clip(shim,state_dir)
    monkeypatch.setenv('FAKE_HEADLINE_UNBACKED','1')
    client=FakeJobClient(jobs=[edit_job()])
    assert run(client,state_dir)['code']=='HEADLINE_UNBACKED'
    assert not client.named('complete')
    assert EXACT not in json.dumps(client.calls)


def test_stale_existing_video_cannot_claim_render_success(shim,state_dir,monkeypatch):
    first_new_clip(shim,state_dir)
    video=proj(shim)/'final'/'02_secret-title-two.mp4'
    os.utime(video,ns=(1,1))
    monkeypatch.setenv('FAKE_SKIP_RENDER','1')
    client=FakeJobClient(jobs=[edit_job()])
    assert run(client,state_dir)['code']=='HEADLINE_RENDER_MISSING'
    assert not client.named('complete')


def test_request_forwards_exact_independent_headline_literal(state_dir):
    from types import SimpleNamespace

    import clip_runner
    runner = SimpleNamespace(headline_capability=True, tmp_dir=lambda: state_dir,
                             context={'base_render_id':'render-fixture-1','headline_voice':{'revision':'fixture-8','direction':'Comedy; incomplete.'}},
                             review_entry={'id':'c2bbbbbbbb','start':305.,'end':340.})
    request = clip_runner._headline_request(runner,edit_job(),'edit')
    assert request['requested_headline'] == 'two words secret transcript'


@pytest.mark.parametrize('style,expected', [('karaoke','karaoke'),('none','phrase-pop')])
def test_headline_enables_captions_without_overwriting_style(shim,state_dir,monkeypatch,style,expected):
    monkeypatch.setenv('FAKE_CAPTION_STYLE',style)
    first_new_clip(shim,state_dir)
    profile=tomllib.loads(logged(shim,'imported')[-1]['imported'])
    assert profile['captions']['style']==expected
    assert profile['captions']['hook_title'] is True
    final=next(c for c in reversed(shim.argvs()) if c[0]=='finalize')
    assert final[final.index('--captions')+1]==expected
````


### `tests/test_episode.py`

````python
import json
import tomllib

from conftest import PROFILE, FakeJobClient, make_job, make_runner
from test_stage2 import logged


class EpisodeClient(FakeJobClient):
    def request(self, tool, args, wait=None):
        self.calls.append(('request', tool, dict(args)))
        if tool == 'social_clip_job_source':
            return {'url': 'https://files.invalid/private-signed-token'}
        if tool == 'social_clip_job_progress' and 'picks' in args:
            if not hasattr(self, 'children'):
                self.children = []
                for i, pick in enumerate(args['picks']):
                    child = make_job(f'child-{i}', 'new_clip', **pick,
                                     episode_job_id=args['job_id'], headline={'consumer': 'episode'})
                    self.jobs[child['id']] = child
                    self.children.append(child['id'])
            return {'jobs': [dict(self.jobs[k]) for k in self.children]}
        if tool == 'social_clip_job_claim':
            return {'job': self.claim(args['job_id'])}
        if tool == 'social_clip_job_complete':
            self.complete(args['job_id'], {k: v for k, v in args.items() if k != 'job_id'})
            return {'job': dict(self.jobs[args['job_id']])}
        if tool == 'social_clip_job_fail':
            self.fail(args['job_id'], args['error'], args['code'])
            return {'job': dict(self.jobs[args['job_id']])}
        return super().request(tool, args, wait)


def episode():
    job = make_job('episode-parent', 'episode')
    job['clip_id'] = None
    job['payload']['clip_id'] = None
    return job


def test_process_once_then_every_pick_uses_shared_headline_and_fresh_render(shim, state_dir):
    client = EpisodeClient(jobs=[episode()])
    result = make_runner(client, state_dir).poll_once([PROFILE])
    assert result['status'] == 'done', result
    picks = next(c[2]['picks'] for c in client.calls if c[:2] == ('request', 'social_clip_job_progress'))
    assert picks == [{'candidate_id': 'c1aaaaaaaa', 'in_s': 100.0, 'out_s': 130.0},
                     {'candidate_id': 'c2bbbbbbbb', 'in_s': 300.0, 'out_s': 345.0}]
    assert all(set(p) == {'candidate_id', 'in_s', 'out_s'} for p in picks)
    argv = shim.argvs()
    assert sum(a[0] == 'process' for a in argv) == 1
    assert sum(a[0] == 'finalize' for a in argv) == len(picks)
    completed = client.named('complete')
    assert len(completed) == len(picks) + 1
    assert completed[-1][1] == 'episode-parent'
    assert all(c[2]['headline_applied'] is True for c in completed[:-1])
    assert all(client.jobs[k]['status'] == 'done' for k in client.children)
    # Independently authored generated headline literal; never MCP-exported.
    applications = [tomllib.loads(c['applied']) for c in logged(shim, 'applied')]
    assert any(c.get('headline') == 'secret transcript words two' for app in applications for c in app['clip'])
    assert 'secret transcript' not in json.dumps(client.calls)
    assert 'private-signed-token' not in json.dumps(client.calls)
    assert all(c['env'].get('CLIP_NO_CONTENT') == '1' for c in shim.calls())
    assert all('CLIP_RUNNER_TOKEN' not in c['env'] for c in shim.calls())
    assert not any('publish' in str(c[:2]) or 'approve' in str(c[:2]) for c in client.calls)


def test_missing_headline_hook_fails_parent_without_false_child_success(shim, state_dir, monkeypatch):
    monkeypatch.setenv('FAKE_HEADLINE_CAPABILITY', '0')
    client = EpisodeClient(jobs=[episode()])
    result = make_runner(client, state_dir).poll_once([PROFILE])
    assert result['status'] == 'failed'
    assert client.jobs['episode-parent']['status'] == 'failed'
    assert not client.named('complete')


def test_zero_picks_completes_only_parent(shim, state_dir, monkeypatch):
    monkeypatch.setenv('FAKE_EPISODE_ZERO', '1')
    client = EpisodeClient(jobs=[episode()])
    result = make_runner(client, state_dir).poll_once([PROFILE])
    assert result['status'] == 'done'
    assert client.children == []
    assert [c[1] for c in client.named('complete')] == ['episode-parent']
    assert not any(a[0] == 'finalize' for a in shim.argvs())


def test_partial_render_failure_preserves_first_child_and_fails_parent(shim, state_dir):
    import clip_runner
    client = EpisodeClient(jobs=[episode()])
    def upload(runner, job):
        if job['id'] == 'child-1':
            raise clip_runner.ClipError('UPLOAD_FIXTURE_FAILED', 'upload')
        return 'file-success-first'
    result = make_runner(client, state_dir, uploader=upload).poll_once([PROFILE])
    assert result['code'] == 'EPISODE_CHILD_FAILED'
    assert client.jobs['child-0']['status'] == 'done'
    assert client.jobs['child-1']['status'] == 'failed'
    assert client.jobs['episode-parent']['status'] == 'failed'
    assert [c[1] for c in client.named('complete')] == ['child-0']


def test_three_picks_have_exact_review_headlines_before_each_render(shim, state_dir, monkeypatch):
    monkeypatch.setenv('FAKE_EPISODE_THREE', '1')
    client = EpisodeClient(jobs=[episode()])
    result = make_runner(client, state_dir).poll_once([PROFILE])
    applications = [tomllib.loads(c['applied']) for c in logged(shim, 'applied')]
    # Independent exact literals: omission of helper headline forwarding fails
    # this assertion even if a permissive fake marks child completion done.
    applied_headlines = {c['id']: c.get('headline') for app in applications for c in app['clip']}
    assert applied_headlines == {
        'c1aaaaaaaa': 'The demo finally worked',
        'c2bbbbbbbb': 'We fixed the wrong button',
        'c3cccccccc': 'The tiny bug won again',
        'a1dddddddd': None,
    }
    assert result['status'] == 'done', result
    argv = shim.argvs()
    assert sum(a[0] == 'process' for a in argv) == 1
    assert sum(a[0] == 'finalize' for a in argv) == 3
    calls = shim.calls()
    # Every finalize must follow prepare, apply and applied verification.
    last_final = -1
    for final, call in enumerate(calls):
        if call['argv'][0] != 'finalize':
            continue
        window = calls[last_final + 1:final]
        prepared = next(i for i, c in enumerate(window) if c['argv'][:2] == ['hooks', 'prepare-review'] and '--check-applied' not in c['argv'])
        applied = next(i for i, c in enumerate(window) if i > prepared and '--apply' in c['argv'])
        verified = next(i for i, c in enumerate(window) if '--check-applied' in c['argv'])
        assert prepared < applied < verified
        last_final = final
    assert len(client.named('complete')) == 4
    assert all(c[2]['headline_applied'] is True for c in client.named('complete')[:-1])
    assert not any('publish' in str(c[:2]) or 'approve' in str(c[:2]) or 'schedule' in str(c[:2]) for c in client.calls)
````


### `tests/test_appearance.py`

````python
"""Independent explicit-style contract, privacy and missing-original guard."""
import json
import pytest
from conftest import FakeJobClient
from test_stage2 import first_new_clip, logged, rerender_job, run

@pytest.mark.parametrize('style', ['plain', 'phrase-pop', 'karaoke'])
def test_appearance_explicit_style_wins_and_keeps_original_project(shim,state_dir,style):
    first_new_clip(shim,state_dir)
    n=len(shim.calls())
    job=rerender_job(appearance=True,base_render_id='render-base',candidate_id='c2bbbbbbbb',
        clip_overrides={'mapped':{'captions.style':style},'unmapped':[]})
    client=FakeJobClient(jobs=[job])
    assert run(client,state_dir)['status']=='done'
    calls=shim.calls()[n:]
    final=next(c['argv'] for c in calls if c['argv'][0]=='finalize')
    assert final[final.index('--captions')+1]==style
    assert '--regenerate' in final
    assert '--profile' in final
    assert not any(c['argv'][0]=='process' for c in calls)
    assert not any(c['argv'][:2]==['hooks','prepare-review'] for c in calls)
    assert all(c['env'].get('CLIP_NO_CONTENT')=='1' for c in calls)
    assert all('CLIP_RUNNER_TOKEN' not in c['env'] for c in calls)
    assert not list((shim.home/'profiles').glob('*-job-*'))
    assert 'secret transcript' not in json.dumps(client.named('complete'))

def test_appearance_missing_original_project_never_reprocesses_submitted_media(shim,state_dir):
    client=FakeJobClient(jobs=[rerender_job(appearance=True,clip_overrides={'mapped':{'captions.style':'plain'},'unmapped':[]})])
    assert run(client,state_dir)['status']=='failed'
    assert client.named('fail')[0][3]=='APPEARANCE_PROJECT_MISSING'
    assert not any(c['argv'][0] in ('process','finalize') for c in shim.calls())

def test_appearance_missing_exact_candidate_is_not_replaced_by_best_overlap(shim,state_dir):
    first_new_clip(shim,state_dir)
    job=rerender_job(appearance=True,candidate_id='missing',clip_overrides={'mapped':{'captions.style':'plain'},'unmapped':[]})
    client=FakeJobClient(jobs=[job])
    assert run(client,state_dir)['status']=='failed'
    assert client.named('fail')[0][3]=='BASE_CANDIDATE_MISSING'


def test_deleted_current_revision_uses_authoritative_next_revision(shim, state_dir):
    first_new_clip(shim, state_dir)
    job = rerender_job(expected_rev=3, appearance=True, candidate_id='c2bbbbbbbb', clip_overrides={'mapped': {'captions.style': 'plain'}, 'unmapped': []})
    context = {'clip_rev': 1, 'clip_next_rev': 3, 'project_id': 'project-files-1'}
    assert run(FakeJobClient(jobs=[job]), state_dir, context_for=lambda r, j: context)['status'] == 'done'
    stale = rerender_job(expected_rev=2, appearance=True)
    assert run(FakeJobClient(jobs=[stale]), state_dir, context_for=lambda r, j: context)['code'] == 'REV_MISMATCH'
````



### `tests/test_music.py`

````python
"""Exact persisted song/gain, private download and cleanup on every path."""
import json,http.server,threading
from pathlib import Path
import pytest
from conftest import FakeJobClient
from test_stage2 import first_new_clip,rerender_job,run

@pytest.fixture
def song_server():
 class Handler(http.server.BaseHTTPRequestHandler):
  def do_GET(self):
   self.send_response(200);self.end_headers();self.wfile.write(b'RIFF0000WAVEtest-audio')
  def log_message(self,*a):pass
 server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
 threading.Thread(target=server.serve_forever,daemon=True).start()
 yield 'http://127.0.0.1:'+str(server.server_address[1])+'/signed-secret-token'
 server.shutdown();server.server_close()

def music_job(enabled=True,gain=-18):
 return rerender_job(appearance=True,candidate_id='c2bbbbbbbb',
   music={'enabled':enabled,'file_id':'song-id','level_db':gain},
   clip_overrides={'mapped':{'captions.style':'plain'},'unmapped':[]})

def client_for(job,url):
 c=FakeJobClient(jobs=[job]);c.replies['social_clip_job_source']={'file_id':'song-id','project_id':'project-files-1','url':url,'content_type':'audio/wav','byte_size':22}
 return c

@pytest.mark.parametrize('gain',[-60,-18,0])
def test_exact_music_profile_private_download_and_cleanup(shim,state_dir,song_server,gain,monkeypatch):
 first_new_clip(shim,state_dir)
 c=client_for(music_job(gain=gain),song_server)
 # correct byte size is checked independently against the actual HTTP fixture.
 c.replies['social_clip_job_source']['byte_size']=len(b'RIFF0000WAVEtest-audio')
 for key in ('BURROW_TOKEN','BURROW_API_TOKEN','CF_ACCESS_CLIENT_ID','CF_ACCESS_CLIENT_SECRET'):
  monkeypatch.setenv(key,'secret-burrow-token')
 result=run(c,state_dir)
 assert result['status']=='done'
 imports=[x for x in shim.calls() if x['argv'][:2]==['profile','import']]
 text=imports[-1]['imported']
 assert '[music]' in text and 'enabled = true' in text and f'level_db = {gain}' in text
 assert 'audio.target_lufs' not in text
 assert 'track.audio' in text
 assert not list(state_dir.rglob('track.audio')) and not list(state_dir.rglob('track.part'))
 assert not list((shim.home/'profiles').glob('*-job-*'))
 assert c.named('request')[0][1:] == ('social_clip_job_source',{'job_id':'job-02','asset':'music'})
 for path in state_dir.rglob('*.json'):
  assert 'signed-secret-token' not in path.read_text() and 'secret-burrow-token' not in path.read_text()
 assert 'signed-secret-token' not in json.dumps(shim.calls())
 assert all(not any(k.startswith(('BURROW_','CF_ACCESS_')) for k in x['env']) for x in shim.calls())

@pytest.mark.parametrize('change,code',[
 ({'file_id':'foreign'},'MUSIC_ASSET_INVALID'),
 ({'project_id':'foreign'},'MUSIC_ASSET_INVALID'),
 ({'content_type':'video/mp4'},'MUSIC_ASSET_INVALID'),
 ({'byte_size':999999999},'MUSIC_ASSET_INVALID'),
 ({'byte_size':3},'MUSIC_DOWNLOAD_SIZE'),
 ({'url':'file:///etc/passwd'},'MUSIC_URL_INVALID'),
 ({'url':'http://127.0.0.1:1/private-token'},'MUSIC_DOWNLOAD_FAILED'),
])
def test_bad_asset_and_download_fail_safely(shim,state_dir,song_server,change,code):
 first_new_clip(shim,state_dir)
 c=client_for(music_job(),song_server);c.replies['social_clip_job_source'].update(change)
 r=run(c,state_dir)
 assert r['status']=='failed' and r['code']==code
 assert not list(state_dir.rglob('track.audio')) and not list(state_dir.rglob('track.part'))
 assert not list((shim.home/'profiles').glob('*-job-*'))
 assert 'private-token' not in json.dumps(c.named('fail'))

def test_mute_preserves_gain_without_downloading_and_unsupported_cli_fails(shim,state_dir,song_server,monkeypatch):
 first_new_clip(shim,state_dir)
 c=client_for(music_job(False,-42),song_server)
 assert run(c,state_dir)['status']=='done'
 assert not c.named('request')
 assert 'enabled = false' in [x for x in shim.calls() if x['argv'][:2]==['profile','import']][-1]['imported']
 monkeypatch.setenv('FAKE_MUSIC_ENABLED','cloud')
 c=client_for(music_job(),song_server)
 assert run(c,state_dir)['code']=='MUSIC_CLI_UNSUPPORTED'
 assert not c.named('request')

def test_render_failure_cleans_music_and_profile(shim,state_dir,song_server):
 first_new_clip(shim,state_dir)
 shim.script(finalize={'exit':1})
 c=client_for(music_job(),song_server);c.replies['social_clip_job_source']['byte_size']=len(b'RIFF0000WAVEtest-audio')
 assert run(c,state_dir)['status']=='failed'
 assert not list(state_dir.rglob('track.audio')) and not list((shim.home/'profiles').glob('*-job-*'))
````


### `tests/test_closing_video.py`

````python
"""Protocol tests only. Real frame/audio evidence is in the repository harness."""

import hashlib
import http.server
import json
import signal
import threading
from pathlib import Path

import clip_runner
import pytest
from conftest import FakeJobClient, make_runner
from test_stage2 import first_new_clip, rerender_job, run

VIDEO = b"\x00\x00\x00\x18ftypmp42-protocol-fixture"
HASH = hashlib.sha256(VIDEO).hexdigest()


@pytest.fixture
def video_server():
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append((self.path, dict(self.headers)))
            if self.path == "/redirect":
                self.send_response(302)
                self.send_header("Location", "/signed-private-video")
                self.end_headers()
                return
            if self.path == "/bad-redirect":
                self.send_response(302)
                self.send_header("Location", "file:///etc/passwd")
                self.end_headers()
                return
            self.send_response(200)
            self.end_headers()
            self.wfile.write(VIDEO)

        def log_message(self, *a):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield "http://127.0.0.1:" + str(server.server_address[1]), requests
    server.shutdown()
    server.server_close()


def contract(**kw):
    return dict(
        enabled=True,
        file_id="closing-A",
        audio="keep",
        project_id="project-files-1",
        content_hash=HASH,
        content_type="video/mp4",
        byte_size=len(VIDEO),
        **kw,
    )


def client(job, source_url, **changes):
    c = FakeJobClient(jobs=[job])
    d = dict(contract())
    d.pop("enabled")
    d.pop("audio")
    d.update(url=source_url, max_bytes=209715200)
    d.update(changes)
    c.replies["social_clip_job_source"] = d
    return c


def job(**changes):
    closing = contract()
    closing.update(changes)
    return rerender_job(closing_video=closing, candidate_id="c2bbbbbbbb")


def clean(state_dir, shim):
    assert not list(state_dir.rglob("closing.video"))
    assert not list(state_dir.rglob("closing.part"))
    assert not list((shim.home / "profiles").glob("*-job-*"))


@pytest.mark.parametrize("audio", ["keep", "mute"])
def test_private_exact_asset_profile_and_cleanup(
    shim, state_dir, video_server, monkeypatch, audio
):
    first_new_clip(shim, state_dir)
    monkeypatch.setenv("FAKE_OUTRO_AUDIO", "mute")
    for key in (
        "CLIP_RUNNER_TOKEN",
        "BURROW_TOKEN",
        "BURROW_API_TOKEN",
        "CF_ACCESS_CLIENT_ID",
        "CF_ACCESS_CLIENT_SECRET",
    ):
        monkeypatch.setenv(key, "secret-burrow-token")
    url, requests = video_server
    c = client(job(audio=audio), url + "/redirect")
    assert run(c, state_dir)["status"] == "done"
    assert c.named("request") == [
        (
            "request",
            "social_clip_job_source",
            {"job_id": "job-02", "asset": "closing_video"},
        )
    ]
    imports = [x for x in shim.calls() if x["argv"][:2] == ["profile", "import"]]
    text = imports[-1]["imported"]
    assert (
        "[outro]" in text and f'audio = "{audio}"' in text and "closing.video" in text
    )
    complete = c.named("complete")[-1][-1]
    assert "duration_s" not in complete
    assert requests and all(
        not any(
            k.lower()
            in ("authorization", "cf-access-client-id", "cf-access-client-secret")
            for k in h
        )
        for _, h in requests
    )
    assert all("secret-burrow-token" not in json.dumps(x["env"]) for x in shim.calls())
    for p in state_dir.rglob("*.json"):
        assert (
            "signed-private" not in p.read_text()
            and "secret-burrow-token" not in p.read_text()
        )
    assert "signed-private" not in json.dumps(shim.calls())
    clean(state_dir, shim)


@pytest.mark.parametrize(
    "change,code",
    [
        ({"file_id": "foreign"}, "CLOSING_ASSET_INVALID"),
        ({"project_id": "foreign"}, "CLOSING_ASSET_INVALID"),
        ({"content_type": "audio/wav"}, "CLOSING_ASSET_INVALID"),
        ({"byte_size": 0}, "CLOSING_ASSET_INVALID"),
        ({"byte_size": 209715201}, "CLOSING_ASSET_INVALID"),
        ({"content_hash": "0" * 64}, "CLOSING_ASSET_INVALID"),
        ({"max_bytes": 0}, "CLOSING_ASSET_INVALID"),
        ({"url": "file:///etc/passwd"}, "CLOSING_URL_INVALID"),
        ({"url": "https://user:password@example.com/media"}, "CLOSING_URL_INVALID"),
        ({"url": "http://example.com/media"}, "CLOSING_URL_INVALID"),
        ({"url": "http://127.0.0.1:1/private-token"}, "CLOSING_DOWNLOAD_FAILED"),
    ],
)
def test_reject_identity_contract_and_download_errors(
    shim, state_dir, video_server, monkeypatch, change, code
):
    first_new_clip(shim, state_dir)
    monkeypatch.setenv("FAKE_OUTRO_AUDIO", "mute")
    url, _ = video_server
    c = client(job(), url + "/signed-private-video", **change)
    result = run(c, state_dir)
    assert result["status"] == "failed" and result["code"] == code
    clean(state_dir, shim)
    assert not c.named("complete")
    assert "private-token" not in json.dumps(c.named("fail"))


@pytest.mark.parametrize(
    "size,hash_value,code",
    [
        (len(VIDEO) - 1, HASH, "CLOSING_DOWNLOAD_SIZE"),
        (len(VIDEO) + 1, HASH, "CLOSING_DOWNLOAD_SIZE"),
        (len(VIDEO), "0" * 64, "CLOSING_HASH_MISMATCH"),
    ],
)
def test_streamed_bytes_and_hash_enforced(
    shim, state_dir, video_server, monkeypatch, size, hash_value, code
):
    first_new_clip(shim, state_dir)
    monkeypatch.setenv("FAKE_OUTRO_AUDIO", "mute")
    url, _ = video_server
    j = job(byte_size=size, content_hash=hash_value)
    c = client(
        j, url + "/signed-private-video", byte_size=size, content_hash=hash_value
    )
    assert run(c, state_dir)["code"] == code
    clean(state_dir, shim)


@pytest.mark.parametrize("legacy", [False, True])
def test_disabled_or_legacy_clears_inherited_path_without_download(
    shim, state_dir, monkeypatch, legacy
):
    first_new_clip(shim, state_dir)
    monkeypatch.setenv("FAKE_OUTRO_AUDIO", "keep")
    j = rerender_job() if legacy else job(enabled=False)
    c = FakeJobClient(jobs=[j])
    assert run(c, state_dir)["status"] == "done"
    assert not c.named("request")
    text = [
        x["imported"] for x in shim.calls() if x["argv"][:2] == ["profile", "import"]
    ][-1]
    assert "[outro]" in text and 'path = ""' in text
    clean(state_dir, shim)


def test_unsupported_cli_enabled_fails_disabled_succeeds(shim, state_dir, video_server):
    first_new_clip(shim, state_dir)
    url, _ = video_server
    c = client(job(), url)
    assert run(c, state_dir)["code"] == "CLOSING_CLI_UNSUPPORTED"
    assert not c.named("request")
    c = FakeJobClient(jobs=[job(enabled=False)])
    assert run(c, state_dir)["status"] == "done"


@pytest.mark.parametrize("audio", ["bad", None, True])
def test_invalid_audio_contract(shim, state_dir, audio):
    first_new_clip(shim, state_dir)
    c = FakeJobClient(jobs=[job(audio=audio)])
    assert run(c, state_dir)["code"] == "CLOSING_CONTRACT_INVALID"


def test_render_failure_and_sigterm_clean(shim, state_dir, video_server, monkeypatch):
    first_new_clip(shim, state_dir)
    monkeypatch.setenv("FAKE_OUTRO_AUDIO", "mute")
    url, _ = video_server
    shim.script(finalize={"exit": 1})
    c = client(job(), url)
    assert run(c, state_dir)["status"] == "failed"
    clean(state_dir, shim)
    shim.script()
    c = client(job(), url)
    r = make_runner(c, state_dir)
    original = r.clip

    def interrupted(step, *a, **kw):
        if step == "finalize":
            raise clip_runner.RunnerInterrupted(signal.SIGTERM)
        return original(step, *a, **kw)

    r.clip = interrupted
    assert r.poll_once(["profile-1"])["code"] == "RUNNER_SIGTERM"
    clean(state_dir, shim)


def test_restart_reclaims_orphan_bytes_profiles_and_replies(shim, state_dir):
    first_new_clip(shim, state_dir)
    j = job()
    j.update(status="running", claimed_by_agent_id="agent-self")
    c = FakeJobClient(jobs=[j])
    r = make_runner(c, state_dir)
    r.journal.write(j, "finalize")
    folder = r.tmp_dir() / "closing-job-02"
    folder.mkdir()
    (folder / "closing.video").write_bytes(VIDEO)
    (folder / "closing.part").write_bytes(b"partial")
    (shim.home / "profiles" / "burrow-profile-1-job-job-02.toml").write_text(
        'extends="how-to-computer"'
    )
    replies = state_dir / "replies"
    replies.mkdir()
    (replies / "12-1-social_clip_job_source.json").write_text('{"url":"private"}')
    assert r.startup_reclaim(["profile-1"]) == ["job-02"]
    clean(state_dir, shim)
    assert not list(replies.iterdir())


def test_single_profile_combines_look_music_and_closing(
    shim, state_dir, video_server, monkeypatch
):
    first_new_clip(shim, state_dir)
    monkeypatch.setenv("FAKE_OUTRO_AUDIO", "mute")
    url, _ = video_server
    j = job()
    j["payload"].update(
        music={"enabled": False, "file_id": "song", "level_db": -18},
        clip_overrides={"mapped": {"captions.style": "plain"}, "unmapped": []},
    )
    c = client(j, url)
    before = len([x for x in shim.calls() if x["argv"][:2] == ["profile", "import"]])
    assert run(c, state_dir)["status"] == "done"
    imports = [x for x in shim.calls() if x["argv"][:2] == ["profile", "import"]][
        before:
    ]
    assert len(imports) == 1
    assert all(
        section in imports[0]["imported"]
        for section in ("[music]", "[captions]", "[outro]")
    )
    clean(state_dir, shim)


def test_private_modes_while_live(shim, state_dir, video_server, monkeypatch):
    first_new_clip(shim, state_dir)
    monkeypatch.setenv("FAKE_OUTRO_AUDIO", "mute")
    url, _ = video_server
    j = job()
    c = client(j, url)
    r = make_runner(c, state_dir)
    r._job = j
    r.context = {"project_id": "project-files-1"}
    with clip_runner.closing_profile(r, j, "burrow-profile-1", {}) as mapped:
        video = Path(mapped["outro.path"])
        assert video.stat().st_mode & 0o777 == 0o600
        assert video.parent.stat().st_mode & 0o777 == 0o700
        with clip_runner.derived_profile(r, j, "burrow-profile-1", mapped) as profile:
            assert (
                shim.home / "profiles" / (profile + ".toml")
            ).stat().st_mode & 0o777 == 0o600
    clean(state_dir, shim)


@pytest.mark.parametrize(
    "change", [{"profile_id": "foreign-profile"}, {"org_id": "foreign-org"}]
)
def test_pinned_profile_and_org_match_current_context(
    shim, state_dir, video_server, monkeypatch, change
):
    first_new_clip(shim, state_dir)
    monkeypatch.setenv("FAKE_OUTRO_AUDIO", "mute")
    url, _ = video_server
    j = job(**change)
    c = client(j, url)
    r = make_runner(c, state_dir)
    r._job = j
    r.context = {"project_id": "project-files-1", "org_id": "org-current"}
    with (
        pytest.raises(clip_runner.ClipError, match="closing_video") as err,
        clip_runner.closing_profile(r, j, "burrow-profile-1", {}),
    ):
        pass
    assert err.value.code == "CLOSING_ASSET_INVALID"
    assert not c.named("request")


def test_cleanup_failure_cannot_upload_or_complete(
    shim, state_dir, video_server, monkeypatch
):
    first_new_clip(shim, state_dir)
    monkeypatch.setenv("FAKE_OUTRO_AUDIO", "mute")
    url, _ = video_server
    c = client(job(), url)
    unlink = Path.unlink

    def fail_cleanup(path, *a, **kw):
        if path.name == "closing.video":
            raise PermissionError("private pathname must not leak")
        return unlink(path, *a, **kw)

    monkeypatch.setattr(Path, "unlink", fail_cleanup)
    assert run(c, state_dir)["code"] == "CLOSING_CLEANUP_FAILED"
    assert not c.named("complete")
    assert "private pathname" not in json.dumps(c.named("fail"))


def test_restart_cleans_headline_and_music_partial(shim, state_dir):
    first_new_clip(shim, state_dir)
    j = job()
    j.update(status="running", claimed_by_agent_id="agent-self")
    c = FakeJobClient(jobs=[j])
    r = make_runner(c, state_dir)
    r.journal.write(j, "finalize")
    tmp = r.tmp_dir()
    (tmp / "headline-request.json").write_text("private")
    music = tmp / "music"
    music.mkdir()
    (music / "track.part").write_bytes(b"partial")
    r.startup_reclaim(["profile-1"])
    assert not (tmp / "headline-request.json").exists() and not music.exists()


def test_reply_timeout_removes_private_partial(shim, state_dir):
    import io

    replies = state_dir / "replies"
    client = clip_runner.OutboxClient(
        out=io.StringIO(), reply_dir=replies, reply_timeout_s=0
    )
    emit = client._emit

    def partial(tool, args, extra):
        path = Path(extra["reply_file"])
        path.with_suffix(".json.tmp").write_text('{"url":"private-signed-value"}')
        emit(tool, args, extra)

    client._emit = partial
    with pytest.raises(clip_runner.ClipError) as err:
        client.request(
            "social_clip_job_source", {"job_id": "job-02", "asset": "closing_video"}
        )
    assert err.value.code == "REPLY_TIMEOUT"
    assert replies.stat().st_mode & 0o777 == 0o700
    assert not list(replies.iterdir())


def test_episode_children_each_resolve_their_pinned_closing(
    shim, state_dir, video_server, monkeypatch
):
    from test_episode import EpisodeClient, episode

    monkeypatch.setenv("FAKE_OUTRO_AUDIO", "mute")
    url, _ = video_server
    source = client(job(), url).replies["social_clip_job_source"]

    class ClosingEpisodeClient(EpisodeClient):
        def request(self, tool, args, wait=None):
            if (
                tool == "social_clip_job_source"
                and args.get("asset") == "closing_video"
            ):
                self.calls.append(("request", tool, dict(args)))
                return dict(source)
            reply = super().request(tool, args, wait)
            if tool == "social_clip_job_progress" and "picks" in args:
                for child in reply["jobs"]:
                    child["payload"]["closing_video"] = contract()
            return reply

    parent = episode()
    parent["payload"]["closing_video"] = contract()
    c = ClosingEpisodeClient(jobs=[parent])
    assert make_runner(c, state_dir).poll_once(["profile-1"])["status"] == "done"
    assert [
        call[2]["job_id"]
        for call in c.calls
        if call[:2] == ("request", "social_clip_job_source")
        and call[2].get("asset") == "closing_video"
    ] == ["child-0", "child-1"]
    imports = [
        x["imported"]
        for x in shim.calls()
        if x["argv"][:2] == ["profile", "import"] and "[outro]" in x["imported"]
    ]
    assert len(imports) == 2 and all(
        'audio = "keep"' in x and "closing.video" in x for x in imports
    )
    assert sum(a[0] == "process" for a in shim.argvs()) == 1
    clean(state_dir, shim)
````

### `tests/test_dynamic_styles.py`

````python
"""Literal style/capability forwarding tests across existing helper protocol."""

import json
import pytest
from conftest import FakeJobClient
from test_stage2 import first_new_clip, rerender_job, run

CAPABILITY = {
    "version": "0.9.0",
    "headline_review": 1,
    "content_free": 2,
    "caption_treatments": 1,
    "caption_styles": [
        "none",
        "plain",
        "phrase-pop",
        "karaoke",
        "type-on",
        "focus-word",
        "editorial-punch",
    ],
    "caption_renderer": {
        "sha256": "25595724985663807fb7f9976cdabf9f2d4a04c1bb98df73fd92b47b7e056141",
        "temporal_sha256": "385f5e446c09bd06bb5fb11aaa4228fa95e47fa808e1c1d750bf6633d039aee7",
    },
}


def caption_job(style, appearance=True):
    return rerender_job(
        appearance=appearance,
        base_render_id="render-base",
        candidate_id="c2bbbbbbbb",
        look={"cap": {"style": style}},
        clip_overrides={"mapped": {}, "unmapped": []},
    )


@pytest.mark.parametrize("style", ["type-on", "focus-word", "editorial-punch"])
def test_dynamic_style_overrides_saved_none_in_profile_and_finalize(
    shim, state_dir, style, monkeypatch
):
    first_new_clip(shim, state_dir)
    monkeypatch.setenv("FAKE_CAPTION_STYLE", "none")
    shim.script(version={"stdout": CAPABILITY})
    n = len(shim.calls())
    client = FakeJobClient(jobs=[caption_job(style)])
    assert run(client, state_dir)["status"] == "done"
    calls = shim.calls()[n:]
    final = next(c["argv"] for c in calls if c["argv"][0] == "finalize")
    assert final[final.index("--captions") + 1] == style
    imports = [c for c in calls if c["argv"][:2] == ["profile", "import"]]
    assert any(f'style = "{style}"' in c.get("imported", "") for c in imports)
    assert not any(c["argv"][0] == "process" for c in calls)
    assert not list((shim.home / "profiles").glob("*-job-*"))
    assert all(c["env"].get("CLIP_NO_CONTENT") == "1" for c in calls)
    assert all("CLIP_RUNNER_TOKEN" not in c["env"] for c in calls)
    assert "secret transcript" not in json.dumps(client.calls)


@pytest.mark.parametrize(
    "change",
    [
        "missing",
        "palette-only",
        "wrong-source",
        "wrong-temporal",
        "boolean",
        "malformed",
    ],
)
def test_unqualified_exact_cli_fails_before_upload(shim, state_dir, change):
    first_new_clip(shim, state_dir)
    info = json.loads(json.dumps(CAPABILITY))
    if change == "missing":
        info.pop("caption_treatments")
    elif change == "palette-only":
        info["caption_styles"].remove("focus-word")
    elif change == "wrong-source":
        info["caption_renderer"]["sha256"] = "0" * 64
    elif change == "wrong-temporal":
        info["caption_renderer"]["temporal_sha256"] = "0" * 64
    elif change == "boolean":
        info["caption_treatments"] = True
    else:
        info["caption_renderer"] = "invalid"
    shim.script(version={"stdout": info})
    n = len(shim.calls())
    client = FakeJobClient(jobs=[caption_job("type-on")])
    assert run(client, state_dir)["code"] == "CAPTION_CLI_UNSUPPORTED"
    assert not any(c["argv"][0] == "finalize" for c in shim.calls()[n:])
    assert not client.named("complete")
    assert not any(c[0] == "request" and c[1] == "file_add" for c in client.calls)
    assert not list((shim.home / "profiles").glob("*-job-*"))


def test_unknown_style_is_not_silently_replaced(shim, state_dir):
    first_new_clip(shim, state_dir)
    assert (
        run(FakeJobClient(jobs=[caption_job("palette")]), state_dir)["code"]
        == "CAPTION_STYLE_UNSUPPORTED"
    )


@pytest.mark.parametrize("style", ["type-on", "focus-word", "editorial-punch"])
def test_new_clip_immutable_style_survives_headline_and_empty_delta(
    shim, state_dir, style
):
    shim.script(version={"stdout": CAPABILITY})
    client = first_new_clip(shim, state_dir, look={"cap": {"style": style}})
    final = next(
        c["argv"] for c in reversed(shim.calls()) if c["argv"][0] == "finalize"
    )
    assert final[final.index("--captions") + 1] == style
    assert client.named("complete")


def test_dynamic_finalize_failure_cleans_combined_profile(shim, state_dir):
    first_new_clip(shim, state_dir)
    shim.script(version={"stdout": CAPABILITY}, finalize={"exit": 3})
    client = FakeJobClient(jobs=[caption_job("editorial-punch")])
    assert run(client, state_dir)["status"] == "failed"
    assert not client.named("complete")
    assert not list((shim.home / "profiles").glob("*-job-*"))
    assert not list((state_dir / "tmp").glob("profile*"))


def test_dynamic_generic_rerender_cannot_upload_stale_previous_output(shim, state_dir):
    first_new_clip(shim, state_dir)
    shim.script(version={"stdout": CAPABILITY}, finalize={"exit": 0})
    # A successful CLI command that writes no new output is not rendering success.
    import os

    os.environ["FAKE_SKIP_RENDER"] = "1"
    try:
        client = FakeJobClient(jobs=[caption_job("focus-word", appearance=False)])
        assert run(client, state_dir)["code"] == "CAPTION_RENDER_MISSING"
        assert not client.named("complete")
        assert not any(c[0] == "request" and c[1] == "file_add" for c in client.calls)
        assert not list((shim.home / "profiles").glob("*-job-*"))
    finally:
        os.environ.pop("FAKE_SKIP_RENDER", None)
````
