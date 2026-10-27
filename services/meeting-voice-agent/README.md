# meeting-voice-agent

A dedicated meeting voice runtime built on the public
[`livekit-agents`](https://pypi.org/project/livekit-agents/) SDK — the same
base audivia is built on. It is a standalone Python service, wholly additive
to Core: Core has no barge-in/interruption handling anywhere (confirmed —
no `getUserMedia`/`MediaRecorder`/`AudioContext` outside
`meeting_push_to_talk.js`, which is human push-to-talk, not agent
interruption), so barge-in lives entirely inside this service at the audio
level. This stage ships the runtime only — no LiveView/JS/Elixir changes.

Out of scope here (see the task plan): Core's existing brain/mouth split,
`Platform.Agents.Voice`, the existing hosted-TTS voice worker, and any other
agent's ability to speak in meetings are untouched.

Stage 2 (Elixir, `apps/platform/lib/mix/tasks/platform/seed_meeting_voice_agent.ex`)
registers a "Meeting Assistant" persona and its voice runtime using only
already-shipped Core mechanisms. Stage 3 (this stage) wires THIS service to
the real, live test-host/wave endpoints and to Core's real MCP tool surface using
that registration — see "MCP tool surface" below.

## Runtime shape

`AgentSession` (see `src/meeting_voice_agent/session.py`) is built with:

- **VAD**: Silero, thresholds from `AgentConfig.vad`.
- **Turn detection**: `livekit-plugins-turn-detector`'s English or
  Multilingual model (or none, for VAD-only endpointing), selected and
  thresholded from `AgentConfig.turn_detector`.
- **Barge-in**: `allow_interruptions=True` by default, with
  `min_interruption_duration` set to a short, bounded window (default
  `0.3s`) — once VAD sees that much overlapping speech, the SDK stops TTS
  playback. **AEC warmup note** (task 01a0d4a0 stage 4 round 2, confirmed on
  Dalton's live test-host run): the `livekit-agents` SDK's acoustic echo
  cancellation disables interruption handling for roughly the first 3
  seconds of every agent turn while AEC warms up on the newly-started
  playback — this is expected SDK behavior, not a misconfiguration of
  `min_interruption_duration`/`allow_interruptions` here, and is not
  something to "fix" in this service. Dalton's live barge-in case still
  passed (585ms from interruption to silence) because the interruption
  landed after that warmup window; a barge-in attempted inside the first ~3s
  of a turn should be expected not to register, and that is a property of
  the SDK's AEC, not this config.
- **Preemptive generation**: `preemptive_generation=True` by default, so the
  session may start an LLM completion before end-of-turn is confirmed. The
  actual triggering decision this stage owns and unit-tests is in
  `src/meeting_voice_agent/preemptive.py` (`should_start_preemptive_generation`)
  — a pure function over turn-detector probability, silence duration, and
  interim transcript length, driven by the same config the session uses.
- **Join identity** (task 01a1117f): `request_fnc` in `agent.py` accepts
  every job. When Core's dispatch metadata carries `agent_identity`, the
  worker joins under it. That value is `agent:<agent uuid>`, and the worker
  also sets the participant name from `agent_name` and the
  `suite.agent_id` attribute from `agent_id`. The shape matters:
  `agent:<uuid>` is what Core's `Platform.Meetings.parse_identity/1` casts to
  an agent foreign key, so the worker lands on the agent's own invite row
  instead of becoming an extra "Unknown participant". It is also the key
  MeetingLive uses for agent tiles. `agent:<slug>` would match neither. The
  agent is never inferred from `MVA_WORKER_AGENT_NAME`, because several
  agents can share one worker name. When `agent_identity` is missing (an
  older Core, or a manually started job), `accept_arguments` returns `{}`
  and the SDK default identity `agent-<job id>` is kept. That is the
  pre-change behaviour, and Core folds it onto the invite row.

## Backends — all config, nothing hard-coded

Every backend is an OpenAI-compatible client (`livekit-plugins-openai`)
pointed at a `base_url` + `model` from `AgentConfig` (`src/meeting_voice_agent/config.py`):

| Backend | `base_url` | Default model | Env prefix |
|---|---|---|---|
| STT | `MVA_STT_BASE_URL`, required (no default) | `faster-distil-whisper-small.en` | `MVA_STT_*` |
| TTS | `MVA_TTS_BASE_URL`, required (no default) | `kokoro` (Kokoro-82M), voice `af_heart` | `MVA_TTS_*` |
| LLM | `MVA_LLM_BASE_URL`, required (no default) | `qwen3.5-9b` (thinking off), fallback `granite4.1-8b` | `MVA_LLM_*` |

The LLM model name is the declared experiment surface, alongside the VAD and
turn-detector thresholds — none of them are hard-coded outside `config.py`.
`MVA_LLM_THINKING=true` flips qwen3.5's `chat_template_kwargs.enable_thinking`;
`MVA_LLM_EXTRA_BODY_JSON` overrides the request body extras entirely if a
different backend needs a different toggle shape.

See `config.py` for the full list of env vars (VAD thresholds, endpointing
delays, interruption window, turn-detector model/threshold, agent name and
instructions). Every one has a documented default and every one is
overridable.

**The backend URLs have no default (task 01a14b9e).** `MVA_STT_BASE_URL`,
`MVA_TTS_BASE_URL` and `MVA_LLM_BASE_URL` name one deployment's hosts, so,
like `MVA_MCP_BASE_URL`, an unset or empty value fails config loading with a
`ConfigError` naming the variable.

## MCP tool surface (task 01a0d4a0 stage 3)

`src/meeting_voice_agent/mcp_tools.py` connects the agent to Core's real
`/mcp` endpoint using `livekit-agents`' own MCP support
(`livekit.agents.llm.mcp.MCPServerHTTP` / `MCPToolset` — installed via the
`livekit-agents[mcp]` extra), authenticated as the "meeting-assistant" voice
runtime stage 2 registered (`MVA_MCP_BASE_URL`, `MVA_MCP_AUTH_TOKEN`).

- **No client-side bundle duplication.** Core's
  `Platform.Federation.ToolAuthorization` already enforces the runtime's
  `tool_profile` server-side, fail-closed. This service does not keep its
  own copy of that list; it just connects and calls whatever Core's
  `MCPToolset.setup()` lists, which is provably the same set `authorize/2`
  would allow.
  **Round 2 fix (task 01a0d4a0 stage 4):** Dalton's live test-host run found this
  persona could still call `mail_draft_create` — a prod write tool —
  because `mail_draft_create`/`mail_draft_update` used to live INSIDE the
  `messaging` bundle, so any runtime holding `messaging` (this one included)
  got mail-drafting for free. Core's `Platform.Federation.ToolSurface` now
  splits mail drafting into its own `mail` bundle; this persona's
  `tool_profile` was never granted (and still isn't granted) `mail`, so
  `mail_draft_create` is refused for this runtime regardless of whether
  Core's Mail module is enabled. See
  `apps/platform/test/platform/federation/seed_meeting_voice_agent_test.exs`'s
  `"does NOT allow mail_draft_create even with the Mail module enabled"`
  regression test.
  **Round 3 fix (task 01a0d4a0 stage 5 item 5):** Dalton's third live test-host
  run found the seed still granting `memory` and `space` — every memory
  write tool, plus `space_create`/`space_leave`/`dm_create` — none of which
  this single-purpose voice persona has any business calling.
  `mix platform.seed_meeting_voice_agent`'s `tool_profile` is now just
  `messaging context_read` (down from `space messaging context_read
  memory`) — see that task's moduledoc for why neither dropped bundle can be
  narrowed any finer than an outright drop (authorization is per-bundle, not
  per-tool-name).
- **MCP base URL must be the public host, and it is required.**
  `MVA_MCP_BASE_URL` has no default (task 01a116de): any default would name
  one particular Burrow install, so an unset or empty value fails config
  loading with an error naming the variable. Set it to your deployment's
  public MCP URL (e.g. `https://suite.example.com/mcp`), not an in-cluster
  `:4000` URL — Dalton's test-host run found the service pointed at the latter,
  which Core redirects, and the MCP client correctly refuses to follow a
  redirect rather than silently re-POSTing.
- **`build_tool_surface(config, room_name)`** (in `agent.py`) is what
  `entrypoint` hands to `MeetingVoiceAgent(config, tools=...)`: the live
  `MCPToolset` plus one local wrapper tool, `post_to_meeting_chat`.
- **`post_to_meeting_chat`** is the hand-off-to-text behavior VOICE.md
  describes: for a long/multi-part/out-of-scope answer, give a brief spoken
  acknowledgement and call this tool instead of speaking at length. It does
  NOT add a new Core tool — it forwards straight into Core's existing
  `send_media` (from the `messaging` bundle), with `space_id` taken from the
  LiveKit job's own metadata when the worker was dispatched via
  `Platform.Meetings` (task 01a0d4a0 stage 5 item 3), falling back to
  deriving it from the LiveKit room name via Core's existing
  `"space-<uuid>"` room-naming convention
  (`Platform.Meetings.room_name_for_space/1`) only when no job metadata is
  available (e.g. a manually-started dev worker) — so the model only ever
  supplies the text. `send_media`'s own Core-side implementation refuses a
  call with no `file_path`/`file_paths`/`file_base64` even when `content` is
  set (see the docstring on `build_meeting_chat_handoff_tool`), so the
  wrapper base64-encodes `content` and sends it as `file_base64`; the
  message's visible text in the space is still the full `content`, not just
  the attachment.
  **Round 3 fix (task 01a0d4a0 stage 5 item 1):** this used to write
  `content` to a temp file INSIDE this worker's own container and pass that
  local path to Core's `send_media` in `file_path`. Dalton's third live test-host
  run found that `:enoent`s in real deployment — the worker and Core run on
  different hosts, so a path only this process can read means nothing to
  Core's process; it only ever worked in stage 3's own dev setup because
  both processes happened to share one host there. Core's `send_media` tool
  now also accepts `file_base64` (`Platform.Chat.AttachmentStorage.persist_binary_upload/3`,
  no temp file on Core's side either), which is cross-host safe by
  construction — bytes travel in the tool call itself, never a path.
  **Round 2 fix:** Dalton's live test-host run found the model flailing across
  THREE tools for one out-of-scope question (`post_to_meeting_chat`, then a
  prod-write `mail_draft_create` attempt, then `space_list`), each with a
  long spoken turn. `AgentConfig`'s default `instructions` (`config.py`) now
  name `post_to_meeting_chat` explicitly, require calling it exactly once
  after one short spoken acknowledgement, and forbid substituting a
  different tool (mail especially) if it errors — see
  `test_default_instructions_commit_to_one_handoff_tool_deterministically`
  in `tests/test_config.py`. `mail_draft_create` is also no longer reachable
  at all for this persona regardless of prompt (see the `tool_profile`
  fix above) — this is defense in depth on the prompt layer, not the only
  layer.
  **Round 3 prompt fix (task 01a0d4a0 stage 5 item 4):** the round-2 prompt
  still handed off a trivial "2 plus 2" question in 3 of 7 asks, retried the
  hand-off despite "never retry", and hallucinated a call to a nonexistent
  `meeting_say` tool in prod (refused) — see `config.py`'s `instructions`
  comment for the full breakdown. The default prompt now anchors "simple
  question" with concrete examples (arithmetic, yes/no, one-sentence
  lookup), names the complete granted toolset explicitly so there's no
  reason to guess at a tool name, and states that one `post_to_meeting_chat`
  call — success or failure — is the entire action with nothing left to
  retry.

## Latency harness (task 01a0d4a0 stage 4)

A small, repeatable first-audio-latency measurement harness, split into two
modules on purpose:

- **`src/meeting_voice_agent/latency_harness.py`** — pure logic only:
  `LatencySample`, `compute_latency_ms`, `aggregate_samples` (min/median/
  mean/p95 over repeated runs), JSONL persistence (`dump_samples_jsonl` /
  `load_samples_jsonl`, append-only so results accumulate across re-runs as
  thresholds or the model switch change), and `format_report`. No network,
  no `livekit` import. Unit-tested against fixture data in
  `tests/test_latency_harness.py` (16 tests) — this is stage 4's `test_pass`
  validation. `format_report` deliberately never emits a pass/fail verdict
  and never invents its own threshold: it reports the measured number and
  cites Brosnan's 31 December voice-latency deadline as the reference point
  only, exactly as the stage requires. A guard test
  (`test_report_never_asserts_pass_or_fail`) keeps that property from
  regressing silently.
- **`src/meeting_voice_agent/latency_harness_live.py`** — the part that
  actually touches a real LiveKit room: mints a join token, connects as a
  synthetic human participant, publishes a short WAV fixture as the "human
  speaks one short simple question" action, subscribes to the target agent's
  published audio track, and times the first frame received after the
  question finishes playing. Run it directly once LiveKit/wave/test-host are
  reachable:

  ```bash
  meeting-voice-latency-harness \
    --livekit-url wss://your-livekit-host \
    --api-key ... --api-secret ... \
    --room space-<meeting-chat-space-uuid> \
    --audio-fixture ./fixtures/short-question.wav \
    --runs 5 --out latency_results.jsonl
  ```

  It has no unit tests of its own, for the same reason
  `tests/live/test_wave_llm_live.py` doesn't: it cannot be exercised without
  a real LiveKit server and real audio, and mocking those away would defeat
  the point of a live latency measurement. Its energy-gate math
  (`is_audio_frame_loud`/`samples_dbfs`) and tool-call enrichment
  (`sample_with_tool_call`) live in the pure `latency_harness.py` instead,
  specifically so they ARE unit-tested.

  **Round 2 fixes (task 01a0d4a0 stage 4), from Dalton's live test-host run:**

  1. **Energy gate.** The old harness reported a ~7ms median because it
     counted the agent's silent keepalive frames (sent every ~20ms
     regardless of whether it's speaking) as "first audio". "First audio
     frame" is now gated on measured signal energy
     (`latency_harness.is_audio_frame_loud`, default -45 dBFS — Dalton's
     working value, overridable via `--energy-gate-dbfs`), not mere frame
     arrival.
  2. **Session lifecycle.** The old harness reconnected (a fresh
     `rtc.Room()`, connect, disconnect) once per run inside `--runs N`.
     Disconnecting the synthetic human participant between runs drops them
     from the room, and `AgentSession` tracks its linked participant — once
     they leave, the session pauses ("speech scheduling is paused"), so only
     run 1 of N was ever answered for real. `_main_async` now connects ONCE
     for the whole `--runs N` batch and reuses that connection across every
     run (`_run_measurement`), publishing/unpublishing a fresh mic track per
     run rather than reconnecting the participant. `measure_once` remains as
     a single-run convenience wrapper for callers that want one isolated
     measurement.
  3. **Tool-call latency.** `LatencySample.tool_call` used to be hard-coded
     `False` — nothing ever told the harness a tool call happened.
     `src/meeting_voice_agent/tool_telemetry.py` is the fix's worker-side
     half: it publishes a small JSON data message on the room's data channel
     (topic `mva.tool_call`) every time the `AgentSession` finishes executing
     a batch of function tools (wired in `agent.py`'s `entrypoint` via
     `attach_tool_call_telemetry`). The harness's `ToolCallCollector`
     subscribes to the same topic and, when it observes one during a run's
     timing window, calls `sample_with_tool_call` to record `tool_call=True`
     plus which tool(s) fired and (using the harness's OWN monotonic clock at
     receipt time, never the worker's embedded wall-clock timestamp, which is
     a different process's clock) how long after speech end the first one
     arrived.

**Status as of this round's execution:** same sandbox, same network gap as
stage 3/4 round 1 — no route to Dalton's LAN and no LiveKit credentials here,
so none of the three fixes above could be re-run live from this sandbox. All
three are unit-tested at the seam (`tests/test_latency_harness.py`'s energy-
gate/tool-call tests, `tests/test_tool_telemetry.py`'s publish/parse tests)
and the full suite + lint are clean, but the actual live e2e behavior each
fixes — a real test-host room, a real agent, real audio — is UNVERIFIED LIVE as of
this round. Dalton (who already has the harness environment set up on test-host)
needs to re-run the same harness command against the new commit to confirm
these for real; see the task's execution space
(`01a0d4d2-22d5-7001-b66a-04e3b16d7470`) for the exact ask.

## Voice brain routing (task 01a17b10 stage 4)

The local model is the mouth; the install's Burrow agent is the brain.

- **`MVA_ROUTING`** maps each turn class to a variant, as data:
  `ack=local,turn_taking=local,substantive=burrow` is the default, and every
  class can be set to `local` or `burrow` (a JSON object also works). An
  unknown class or variant fails config loading.
- **Classification** (`routing.LocalClassifier`): the mouth model on
  `MVA_LLM_*` labels each committed turn `ack`, `turn_taking` or
  `substantive`. If that endpoint errors or takes longer than
  `MVA_CLASSIFIER_TIMEOUT_S` (1.5 s), rules decide instead, so an unreachable
  mouth host never blocks a routed answer. A question of five or more words
  the rules call substantive stays substantive whatever the model says.
- **A `burrow` turn** (`MeetingVoiceAgent.llm_node`): the mouth speaks
  `MVA_ROUTED_ACK_TEXT` at once, then Core's `voice_ask_agent` posts the
  question in the meeting chat with an `@[Burrow]` mention, so Burrow is
  dispatched the ordinary way. `voice_ask_poll` long-polls Burrow's
  cumulative `suite_reply_chunk` text, and each complete clause is handed to
  TTS with a flush as it arrives. Barge-in cancels `llm_node`, which closes
  the stream and stops polling. If no answer text arrives within
  `MVA_ROUTED_ANSWER_TIMEOUT_S` (20 s), or Core refuses the ask, the mouth
  says `MVA_ROUTED_NO_ANSWER_TEXT` and nothing else.
- **Provenance**: Core's poll reply names `answered_by` (Burrow's agent id,
  never this persona's) and `variant`; the worker logs it and publishes it on
  the room's `mva.routing` data topic, and Burrow's reply is its own message
  in the meeting chat. Burrow must be on the meeting space's roster
  (`voice_ask_agent` returns `agent_not_in_space` otherwise).
- The persona's runtime needs the `voice_ask` bundle
  (`mix platform.seed_meeting_voice_agent` grants it).

### Routing harness

`meeting-voice-routing-harness` runs against any OpenAI-compatible mouth
named by `MVA_LLM_BASE_URL` / `MVA_LLM_MODEL`:

```bash
# mouth candidates: ack latency (classify + first reply token) p50/p90 and
# turn-class correctness over the scripted set (12 questions, 4 acks, 4 turn-taking)
MVA_LLM_BASE_URL=http://<mouth-host>:<port>/v1 MVA_LLM_MODEL=<alias> \
  uv run meeting-voice-routing-harness mouth --label <name>

# time to first substantive word (first TTS audio of the answer, not the ack)
uv run meeting-voice-routing-harness ttfsw --substantive local            # before
uv run meeting-voice-routing-harness ttfsw --substantive burrow           # after, real Core path
uv run meeting-voice-routing-harness ttfsw --substantive burrow --brain claude-cli  # after, model stand-in
```

The real Core path needs `MVA_MCP_BASE_URL`, `MVA_MCP_AUTH_TOKEN` (the voice
persona's runtime token) and `MVA_HARNESS_SPACE_ID` (a space Burrow is in).
TTS is `MVA_TTS_BASE_URL` when set, else macOS `say`; the report names it.
`--out FILE` appends the JSON results.

## Known gap: Core cannot invite this service into a real meeting (dual-agent case)

Dalton's live test-host run found the dual-agent regression e2e case could not be
run at all: "Core never dispatches to your service (it has no runtime socket
or `meeting_join` handling), so it can't be invited into a real meeting."
Investigated for this round — **this is a real, structural integration gap,
not merely a sandbox/network limitation**, and it would exist even against a
fully reachable, always-running deployment of this exact service:

- Stage 2's `mix platform.seed_meeting_voice_agent` registers the Meeting
  Assistant's voice runtime via `Platform.Federation.register_voice_runtime/3`,
  which hard-codes `transport: "websocket"` and mints a token meant to
  authenticate `PlatformWeb.RuntimeSocket` — the SAME generic runtime-channel
  protocol an OpenClaw/`claude_channel` text-dispatch brain speaks.
- `Platform.Meetings.resolve_voice_target/1` (`apps/platform/lib/platform/meetings.ex`)
  only treats a voice-capable runtime as reachable when
  `Platform.Federation.RuntimePresence.online?/1` is true — and that presence
  table is populated *exclusively* by `PlatformWeb.RuntimeChannel` join/
  terminate events (see `runtime_presence.ex`'s moduledoc: "Called from
  RuntimeChannel join/terminate to maintain online state"). Nothing else
  marks a runtime online — not an MCP HTTP call, not a LiveKit connection.
- This service (`agent.py`) never opens a connection to
  `PlatformWeb.RuntimeSocket`/`RuntimeChannel` — it only connects outbound to
  LiveKit (for the room/audio) and to Core's `/mcp` HTTP endpoint (bearer-
  token tool calls). Its `livekit-agents` worker model is LiveKit dispatching
  jobs TO a registered worker by `agent_name`, which is a different
  invitation mechanism entirely from Core's own `agent_runtimes`/
  `RuntimeChannel` push protocol.

So `resolve_voice_target/1` will report `{:error, :voice_runtime_offline}` for
the Meeting Assistant regardless of how this Python service is run, because
nothing in it ever performs the one action (`RuntimeChannel` join) that would
flip `RuntimePresence.online?/1` to `true` — this is not a case of "the
sandbox can't keep a process running to prove it," the missing code path is
identifiable and named above.

Closing this gap is a genuine architecture decision, not a bug fix, and
neither option is a small patch:

1. Teach this Python service to ALSO open and maintain a
   `PlatformWeb.RuntimeSocket` connection (join, declare
   `client_info.features: ["meeting_voice"]`, handle an inbound
   `meeting_join` push by then driving the existing LiveKit connect/join
   path), duplicating a persistent-connection protocol inside a worker model
   built around short-lived per-job processes; or
2. Change Core's invite path for a `kind: "native"` livekit-agents-backed
   voice runtime to route through LiveKit's own Agent Dispatch API directly
   (naming this worker's `agent_name`) instead of through
   `resolve_voice_target/1`'s `RuntimeChannel`-presence check, since LiveKit
   itself already knows how to reach this exact worker.

Not attempted in this round: it is out of scope for "fix the bugs Dalton's
run surfaced," it cannot be tested from this sandbox regardless (same
network gap), and picking between the two options above is a call for
whoever owns `Platform.Meetings`' invite path next, not something to guess at
under a bug-fix pass. **Dalton: this needs a decision between the two
options above before the dual-agent regression case can ever be run for
real** — it is not something a future re-run on test-host can shake loose on its
own; the code path to make either option "online" simply does not exist yet.

**Decision made and implemented (task 01a0d4a0, Option 2).** Core's invite
path now routes a `meeting_join` for a runtime that declares an explicit,
opt-in `metadata["client_info"]["livekit_agent_name"]` through LiveKit's own
`AgentDispatchService/CreateDispatch` Twirp RPC
(`Platform.Meetings.create_livekit_agent_dispatch/3`), naming this worker's
registered `agent_name` directly, instead of requiring
`resolve_voice_target/1`'s `RuntimeChannel`-presence check to pass. This is
consulted only as a fallback — `dispatch_meeting_join/3` and `invite_agent/3`
try the existing `RuntimeChannel` path first and fall to LiveKit Agent
Dispatch only on `:voice_runtime_offline` — so `resolve_voice_target/1` and
`say/4` are unchanged, and every runtime that never declares this key (every
agent before this task) keeps its exact prior behaviour.
`mix platform.seed_meeting_voice_agent` now stamps this worker's
`agent_name` (`"meeting-voice-agent"`, `agent.py`'s
`WorkerOptions(agent_name: config.worker_agent_name)` default) onto the
Meeting Assistant's voice runtime, so the dual-agent regression case above
can now actually reach this service in a real meeting. See
`Platform.Meetings.LivekitAgentDispatchTest` for the coverage, including the
regression pin that a runtime without this key is unaffected.

## Live integration tests (task 01a0d4a0 stage 3)

`tests/` (this directory) stays exactly as stage 1 left it: fully mocked,
zero network. `tests/live/` is new — genuinely live round trips against real
infra, marked `@pytest.mark.live_infra` and excluded from the default run
(`pyproject.toml`'s `addopts = "-m 'not live_infra'"`):

```bash
pytest                    # stage 1 + stage 3 unit tests — no network, always run
pytest -m live_infra      # stage 3's live round trips — see tests/live/README.md
```

`tests/live/test_mcp_live.py` (Core's `/mcp`) is NOT LAN-gated — Core runs
locally (`mix phx.server` against a local Postgres) or at its real deployed
URL, so this one was run for real while building this stage: both tests
passed against a local `mix phx.server` seeded via
`mix platform.seed_meeting_voice_agent`, confirming a real `space_create`
call round-trips through Core's actual `ToolAuthorization` + `ToolSurface`,
and that `post_to_meeting_chat` really posts into the derived space (read
back via a real `space_get_context`).

`tests/live/test_wave_llm_live.py` and `tests/live/test_rig_speech_live.py`
target `192.0.2.11:8090` and `test-host:8081` — LAN addresses on
Dalton's/test-host's physical network. They were run (not skipped by assumption)
while building this stage and every attempt timed out at the TCP level, so
they're not reachable from wherever this happened to run; each test
`pytest.skip()`s with the exact URL/error rather than failing when that's
the case, since unreachable-from-here is an infra fact, not a code defect.
Point `MVA_LLM_BASE_URL` / `MVA_STT_BASE_URL` / `MVA_TTS_BASE_URL` at
wherever they actually are reachable from to run them for real.

## Running

```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"

# Point at your own test-host/wave deployment, or leave the defaults.
export LIVEKIT_URL=wss://your-livekit-host
export LIVEKIT_API_KEY=...
export LIVEKIT_API_SECRET=...

python -m meeting_voice_agent.agent start
```

## Tests and lint

- **Tests**: `pytest` (unit tests only — every livekit-agents plugin
  constructor and the `AgentSession` itself are mocked; no live network
  calls, no real model load, no LiveKit connection). Run from this directory:

  ```bash
  pip install -e ".[dev]"
  pytest
  ```

  Covers: VAD/turn-detector wiring (`test_backends.py`, `test_session.py`),
  preemptive-generation triggering logic (`test_preemptive.py`), the
  STT/LLM/TTS backend seams and the LLM model switch
  (`test_backends.py`), config parsing/validation (`test_config.py`),
  worker/entrypoint wiring (`test_agent.py`), and the MCP tool surface +
  chat hand-off wrapper seams (`test_mcp_tools.py`). See "Live integration
  tests" above for the real, network-backed confirmation of this same
  wiring against wave/test-host/Core.

- **Lint**: [ruff](https://docs.astral.sh/ruff/), configured in
  `pyproject.toml`.

  ```bash
  ruff check .
  ruff format --check .
  ```

## Layout

```
services/meeting-voice-agent/
├── pyproject.toml            # deps, ruff config, pytest config
├── README.md
├── src/meeting_voice_agent/
│   ├── config.py              # AgentConfig: every env var, every default
│   ├── backends.py            # STT/TTS/LLM/VAD/turn-detector factories
│   ├── mcp_tools.py           # MCP toolset + post_to_meeting_chat hand-off
│   ├── preemptive.py          # preemptive-generation triggering policy
│   ├── session.py             # builds the AgentSession
│   ├── persona.py             # MeetingVoiceAgent(Agent)
│   ├── agent.py                # entrypoint + worker main + build_tool_surface
│   ├── tool_telemetry.py      # publishes tool-call events for the live harness (stage 4 round 2)
│   ├── latency_harness.py     # pure timing/aggregation/energy-gate logic (stage 4)
│   └── latency_harness_live.py # joins a real room, times first audio frame
└── tests/
    ├── conftest.py
    ├── test_config.py
    ├── test_backends.py
    ├── test_session.py
    ├── test_preemptive.py
    ├── test_agent.py
    ├── test_mcp_tools.py      # MCP + hand-off seam tests, no network
    ├── test_tool_telemetry.py # publish/parse seam tests, no network (stage 4 round 2)
    ├── test_latency_harness.py # fixture-driven, no network (stage 4)
    └── live/                  # live_infra: real wave/test-host/Core round trips
        ├── README.md
        ├── conftest.py
        ├── test_wave_llm_live.py
        ├── test_rig_speech_live.py
        └── test_mcp_live.py
```
