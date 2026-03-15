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

### Remote / Docker runners (future HTTP adapter)

The HTTP layer will expose thin wrappers:

```
GET  /api/runs/:id/context           → snapshot
POST /api/runs/:id/context/ack       → ack_context
POST /api/runs/:id/context/push      → push_context
POST /api/runs/:id/transition        → transition
```

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

## Future Work

- **Vault credential leasing:** replace config-backed `CredentialLease` with
  short-lived GitHub App installation tokens from `Platform.Vault`
- **GitHub push verification:** record the pushed branch HEAD SHA as an
  artifact ref in the run's context session
- **Postgres persistence:** async write of items + deltas for audit/replay
- **Distributed context:** pg_pubsub adapter for multi-node deployments
- **HTTP runner protocol:** thin adapter wrapping the Execution public API
- **Context compaction:** summarise long item histories via an LLM pass before
  handing to runners
