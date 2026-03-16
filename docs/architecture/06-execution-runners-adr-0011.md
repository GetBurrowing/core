# Architecture: Execution Runners & Context Plane (ADR 0011)

> For the decision record see
> `docs/decisions/0011-execution-runners-context-plane-and-run-control.md`

---

## Overview

The context plane is a three-layer in-process substrate that gives AI runners
a structured, versioned view of the task they are executing and a reliable
handshake mechanism to confirm they have processed updates.

```
┌────────────────────────────────────────────────────────┐
│  Platform.Application                                   │
│                                                         │
│  ┌─────────────────┐   ┌─────────────────────────────┐ │
│  │ Context.Supervisor│  │  Execution.RunSupervisor    │ │
│  │  └ Cache (ETS)  │  │   └ RunServer (per run)      │ │
│  └────────┬────────┘  └──────────┬──────────────────┘ │
│           │PubSub                 │subscribes           │
│           └───────────Platform.PubSub─────────────────┘ │
└────────────────────────────────────────────────────────┘
```

---

## Module Map

```
apps/platform/lib/platform/
├── context.ex                    # Public API (ensure_session, snapshot, put_item, ack, ...)
└── context/
    ├── session.ex                # %Session{} + %Scope{} value structs, scope_key/1
    ├── item.ex                   # %Item{} value struct + Item.Kind (kinds + eviction_scope)
    ├── delta.ex                  # %Delta{} versioned mutation descriptor
    ├── cache.ex                  # GenServer owning ETS tables; all writes serialised here
    ├── supervisor.ex             # one_for_one: [Cache]
    └── eviction_policy.ex        # lifecycle hooks: run_terminated, task_closed, ...

apps/platform/lib/platform/
├── execution.ex                  # Public API (start_run, get_snapshot, push_context, ack_context, ...)
└── execution/
    ├── run.ex                    # %Run{} value struct (status + ctx tracking fields)
    ├── run_server.ex             # per-run GenServer; SLA timers, transitions, PubSub relay
    ├── run_supervisor.ex         # DynamicSupervisor for RunServer processes
    └── context_session.ex        # bridge: Run ↔ Platform.Context (open, snapshot, push, ack, close)
```

---

## ETS Layout

```
:ctx_sessions  — {scope_key} → %Session{}
:ctx_items     — {scope_key, item_key} → %Item{}
:ctx_deltas    — {scope_key, version} → %Delta{}
:ctx_acks      — {scope_key, run_id} → acked_version (integer)
```

All tables are `:public` for O(1) reads without a GenServer hop.  Writes go
through `Cache` to keep the monotonic version counter atomic.

---

## Scope Key Convention

```
Scope              Cache key
──────────────────────────────────
project only       "proj-id"
project + epic     "proj-id/epic-id"
project + epic + task   "proj-id/epic-id/task-id"
full run scope     "proj-id/epic-id/task-id/run-id"
task only (no project/epic)  "task-id"
task + run         "task-id/run-id"
```

Nil segments are omitted.  The narrowest scope (run) inherits items from all
ancestor scopes when `ContextSession.snapshot/1` is called.

---

## Write Flow (put_item)

```
caller
  │  Cache.put_item(scope_key, key, value, opts)
  ▼
Cache (GenServer)
  1. :ets.lookup sessions — fail fast if session missing
  2. Session.bump_version → new monotonic version
  3. :ets.insert sessions (updated version)
  4. Item.new(key, value, version, opts)
  5. :ets.insert items
  6. Build %Delta{puts: ...} stamped with version
  7. :ets.insert deltas
  8. Phoenix.PubSub.broadcast("ctx:<scope_key>", {:context_delta, delta})
  → {:ok, new_version}
```

---

## RunServer Lifecycle

```
RunServer.init/1
  ContextSession.open(run)          # ensure_session for project/epic/task/run
  PubSub.subscribe("ctx:<key>")

handle_info({:context_delta, _})
  ContextSession.require_current(run)   # bump required_version to current
  cancel_stale_timer + start_stale_timer(stale_timeout_ms)

handle_info(:stale_timeout)
  run.ctx_status = :stale
  broadcast(:run_ctx_status_changed, run_id, :stale)
  start_dead_timer(dead_timeout_ms)

handle_info(:dead_timeout)
  run.ctx_status = :dead
  broadcast(:run_ctx_status_changed, run_id, :dead)

handle_call({:ack_context, version})
  ContextSession.ack(run, version)
  cancel_stale_timer
  run.ctx_status = :current | :stale (recomputed)

handle_call({:transition, :completed | :failed | :cancelled})
  cancel timers
  EvictionPolicy.run_terminated(%{...})   # promote artifacts + evict run session
```

---

## Eviction Rules

| Kind              | Eviction Scope | Promoted on run end? |
|-------------------|----------------|----------------------|
| `:generic`        | `:run`         | No                   |
| `:env_var`        | `:run`         | No                   |
| `:runner_hint`    | `:run`         | No                   |
| `:system_event`   | `:run`         | No                   |
| `:artifact_ref`   | `:run`         | **Yes → task scope** |
| `:task_description` | `:task`      | N/A                  |
| `:task_metadata`  | `:task`        | N/A                  |
| `:epic_context`   | `:epic`        | N/A                  |
| `:project_config` | `:project`     | N/A                  |

---

## Runner Contract (downstream handoff)

### Local runners (same BEAM node)

```elixir
# 1. Platform starts run
{:ok, run} = Platform.Execution.start_run(task_id, project_id: pid, epic_id: eid)

# 2. Runner gets snapshot
{:ok, %{items: items, version: v, required_version: req}} =
  Platform.Execution.get_snapshot(run.id)

# 3. Ack immediately after loading
{:ok, _run} = Platform.Execution.ack_context(run.id, v)

# 4. Push results
{:ok, _v} = Platform.Execution.push_context(run.id,
  %{"artifact:output" => "s3://..."}, kind: :artifact_ref)

# 5. Complete
{:ok, _run} = Platform.Execution.transition(run.id, :completed)
```

### Remote / Docker runners (`suite-runnerd` seam)

The Docker provider keeps `RunServer` as the control-plane source of truth and
uses a thin companion client/service seam for the host-level container actions.
The BEAM side owns run status, stale/dead classification, and context delivery;
`suite-runnerd` only owns the container lifecycle mechanics.

Planned control surface:

```
POST /api/runs                → spawn container for run
GET  /api/runs/:id            → describe provider/container state
POST /api/runs/:id/stop       → graceful stop request
POST /api/runs/:id/kill       → forced kill

GET  /api/runs/:id/context           → snapshot
POST /api/runs/:id/context/ack       → ack_context
POST /api/runs/:id/context/push      → push_context
POST /api/runs/:id/transition        → transition
```

This split prevents a second orchestration plane: liveness, terminal
transitions, and future Tasks/UI state continue to flow through
`Platform.Execution`, while the service boundary is narrow enough to swap the
transport later if needed.

Authentication: existing Vault-backed token supply.

### Tasks UI (LiveView)

Subscribe to:
- `"ctx:<task_id>"` — for task-scoped context changes (item editor)
- `"execution:runs:<task_id>"` — for run status + ctx_status transitions

---

## Delta Catch-up

Runners that reconnect can catch up from a known version:

```elixir
{:ok, deltas} = Platform.Context.latest_delta(scope, last_known_version)
```

Deltas are kept up to 200 entries per scope.  Beyond that limit runners must
request a full snapshot.

---

## Local Provider — Credential Leasing and Push Path

The `Platform.Execution.LocalRunner` provider (Stage 1–3) has been extended
with leased credentials and a GitHub proof-of-life push path (Stage 4).

### Credential Leasing

```elixir
# Lease a GitHub credential for a run
{:ok, lease} = Platform.Execution.CredentialLease.lease(:github,
  run_id: run.id,
  github_token: token,
  author_name: "Suite Bot",
  author_email: "bot@suite.local"
)

# Inject into a spawned process
{:ok, run} = Platform.Execution.spawn_provider(run.id, LocalRunner,
  command: "/bin/sh",
  args: ["-c", "git push origin HEAD"],
  credential_lease: lease
)
```

Lease kinds: `:github`, `:model`, `:custom`.

### GitHub Push Path

```elixir
# After spawn: set up a worktree and push
{:ok, wt} = LocalWorkspace.setup_git_worktree(workspace, repo_path, branch: "run/abc123")

# … make changes …

:ok = LocalWorkspace.push_branch(wt, run.id,
  message: "proof-of-life: run abc123",
  lease: github_lease
)
```

### RunServer Provider API

```elixir
# Attach a provider and spawn
{:ok, run} = Platform.Execution.spawn_provider(run_id, LocalRunner, command: "/bin/sh", args: [...])

# Stop / kill
{:ok, _} = Platform.Execution.request_stop(run_id)
{:ok, _} = Platform.Execution.force_stop(run_id)
```

Runner exit is reported via `{:runner_exited, run_id, %{exit_code, exit_state}}` messages
and transitions the run to `:completed`, `:cancelled`, or `:failed` deterministically.

---

## Docker Provider — Container Run Control and Fast Kill Semantics

`Platform.Execution.DockerRunner` is the second first-party `Runner` implementation.
It wraps `SuiteRunnerdClient` and keeps `RunServer` as the single control-plane
source of truth.

### Updated module map

```
apps/platform/lib/platform/
└── execution/
    ├── docker_runner.ex         # Docker-backed Runner behaviour impl
    └── suite_runnerd_client.ex  # HTTP transport boundary for suite-runnerd
```

### Spawn flow

```
RunServer.spawn_provider(run_id, DockerRunner, command: ..., credential_lease: lease)
  → DockerRunner.spawn_run/2
      LocalWorkspace.ensure_workspace/2     # allocate per-run dir
      resolve_command/2                     # command / args from opts or run.meta
      build_spawn_payload/6                 # security + mount + env
      SuiteRunnerdClient.spawn_run/3        # POST /api/runs
  → {:ok, provider_ref}                     # stored on Run.runner_ref
```

### Two-phase stop/kill

```
DockerRunner.stop_with_escalation/2
  → request_stop/2      # POST /api/runs/:id/stop (SIGTERM / docker stop)
  → poll describe_run/2 every 500ms
       ↳ if :exited/:killed/:stopped → :ok
       ↳ if timeout (default 10s)   → force_stop/2  (POST /api/runs/:id/kill)
       ↳ if describe error          → force_stop/2  (defensive)
```

### Security payload (hardening defaults)

```
security: %{
  user: "runner",           # non-root UID 1000
  no_new_privileges: true,  # blocks setuid escalation
  capability_drop: ["ALL"], # all capabilities dropped
  capability_add: [],       # opt-in via :capability_add
  no_docker_socket: true    # Docker socket never mounted
}
```

### Host worktree mount

```
mount: %{
  type: "bind",
  host_source: "<workspace_root>/<run_id>",
  container_target: "/workspace",  # override: :container_workspace_path
  workspace_root: "<root>",
  read_only: false
}
```

### suite-runnerd HTTP contract

```
POST /api/runs                  → spawn container; returns {container_id, status, image}
GET  /api/runs/:id              → describe; returns {status, exit_code, health, ...}
POST /api/runs/:id/stop         → graceful stop (SIGTERM / docker stop)
POST /api/runs/:id/kill         → forced kill (SIGKILL / docker kill)
```

The `:id` segment is the container ID when available; falls back to the run ID
so `suite-runnerd` can index either way.

---

## Follow-up Seams — Runner Image Posture and Proof-of-Life

The following items are deferred pending a concrete `suite-runnerd` binary.

### Runner image requirements

| Requirement | Notes |
|---|---|
| Non-root user `runner` (UID 1000) | Must be created in the Dockerfile |
| Read-only root filesystem | Only `/workspace` (bind) and `/tmp` (tmpfs) writable |
| Seccomp profile | Curated alongside `no-new-privileges` |
| Agent binaries | `git`, `gh`, Codex or Claude Code in `PATH` |
| Image signing | Registry must enforce Cosign / Notation verification |

### suite-runnerd binary (next task)

- Scaffold as Go or Elixir release
- Accepts POST `/api/runs` with the BEAM-generated payload
- Calls `docker run` with the security and mount fields applied
- Returns container ID and initial status
- Handles SIGTERM → SIGKILL escalation on the Docker side

### Proof-of-life integration test

A sign-of-life end-to-end test should:

1. Start a real Docker container with the runner image
2. Mount a per-run worktree at `/workspace`
3. Run `codex` or `claude --print` against a trivial prompt
4. Assert the runner creates a commit and pushes a branch to GitHub

The Tasks UI will surface the pushed branch SHA as an artifact in the task
detail panel once this handoff path is wired through `EvictionPolicy` and
the run context.

---

## Artifact + Destination Substrate — Handoff Notes

### What was built

`Platform.Artifacts` is a shared domain that decouples artifact _registration_
from artifact _publication_. Both Tasks/Execution flows and chat/canvas surfaces
write through the same contract.

```
apps/platform/lib/platform/
├── artifacts.ex                      # Public API
└── artifacts/
    ├── artifact.ex                   # %Artifact{} value struct + validation
    ├── destination.ex                # @behaviour for destination modules
    ├── destinations.ex               # Built-in destination registry (github, docker_registry, …)
    ├── publication.ex                # %Publication{} append-only attempt record
    └── store.ex                      # ETS-backed GenServer; one write path, cheap reads
```

`Platform.Execution.register_artifact/2` is the execution-facing entry point.
It merges run scope (project/epic/task/run ids) into the artifact attrs before
delegating to `Platform.Artifacts`.

### Consumer contracts

#### Tasks UI

Artifact refs are mirrored into the run's context session under the key
`"artifact:#{artifact.id}"` with `kind: :artifact_ref`. A LiveView component
can subscribe to `Platform.Artifacts.task_topic(task_id)` and render the
`:artifact_registered`, `:artifact_published`, and `:artifact_publication_failed`
events without polling.

Each event payload is a hydrated `%Artifact{}` with `latest_publication` already
populated. The UI does not need to re-fetch; just update local state on receipt.

**Do not** read raw ETS tables from LiveView. Use `Platform.Artifacts.list_artifacts/1`
and `Platform.Artifacts.list_publications/1` when building the initial page state.

#### Chat / Canvas surfaces

Register artifacts through `Platform.Artifacts.register_artifact/1` directly.
Pass `source: :canvas` or `source: :chat` and omit `run_id` when there is no
active execution run.

Context mirroring (`sync_context_ref`) is skipped for non-run artifacts, so
chat/canvas callers do not need a context session; PubSub broadcast still fires.

#### Adding a new destination

1. Add the id atom to `@valid_destinations` in `Platform.Artifacts.Publication`.
2. Create `defmodule Platform.Artifacts.Destinations.MyTarget` implementing
   `@behaviour Platform.Artifacts.Destination` (`id/0` and `publish/2`).
3. Register the module in the `@builtin` map in `Platform.Artifacts.Destinations`.
4. The publication attempt/result history is recorded automatically; the new
   destination does not touch `Platform.Artifacts.Store` directly.

#### Publication attempt history

All publish attempts are stored in `@publication_table` (ETS) via
`Store.begin_publication` / `Store.finish_publication`. The table is append-only
by design: finished publications overwrite the same ETS key (same id), but
`next_attempt_number` monotonically increments the `:attempt` field.

`Platform.Artifacts.list_publications/1` returns attempts sorted by attempt
number (ascending). UI surfaces that want to show "last known status" should
use `artifact.latest_publication` from the hydrated struct.

### What is NOT yet wired

- Postgres persistence: the store is in-process ETS only. A follow-up task
  should add `Platform.Repo` writes to `Artifacts.Store` callbacks.
- Real destination adapters: `GitHub`, `DockerRegistry`, `GoogleDrive`, and
  `PreviewRoute` all return `{:error, {:unconfigured_destination, id()}}` until
  their concrete push logic is implemented.
- Deck artifact kind: `:deck` is in `@valid_kinds` but no destination handles
  deck-specific payloads yet.

---

## Future Work

- **suite-runnerd binary:** implement the companion service that executes
  `docker run` from the BEAM-generated spawn payload
- **Runner image:** non-root base image with agent binaries, published to a
  verified registry
- **Proof-of-life integration test:** end-to-end Docker runner → GitHub branch push
- **Vault credential leasing:** replace config-backed `CredentialLease` with
  short-lived GitHub App installation tokens from `Platform.Vault`
- **GitHub push verification:** record the pushed branch HEAD SHA as an
  artifact ref in the run's context session via `Platform.Artifacts`
- **Postgres persistence:** async write of artifact + publication rows for
  audit/replay; replace ETS store with a Repo-backed write path
- **Distributed context:** pg_pubsub adapter for multi-node deployments
- **HTTP runner protocol:** thin adapter wrapping the Execution public API
- **Context compaction:** summarise long item histories via an LLM pass before
  handing to runners
