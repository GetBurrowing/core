# ADR 0011 — Execution Runners: Context Plane and Run Control

**Status:** Accepted  
**Date:** 2026-03-15  
**Epic:** Tasks + Execution  

---

## Context

The Startup Suite needs to run AI agent tasks reliably and reproducibly.  A
runner (local process, Docker container, or remote worker) needs a structured
way to:

1. Receive the full context of the task it is about to execute
2. Receive incremental context updates while running
3. Confirm (acknowledge) that it has processed each update
4. Have its staleness detected and signalled when it falls behind

Existing designs (Agent Orchestration, Chat, Vault) introduced shared primitives
(ETS, PubSub, OTP supervision) but no unified "context plane" contract that
runner implementations can rely on.

---

## Decision

We introduce a **runner-facing context plane** built on three layers:

### Layer 1 — Context Domain (`Platform.Context`)

An ETS-backed hot cache that stores context state as scoped sessions.

**Scope hierarchy:** `project_id / epic_id / task_id / run_id`  
(all optional; the cache key is the slash-joined non-nil segments)

**ETS tables:**

| Table            | Key                       | Value                |
|------------------|---------------------------|----------------------|
| `:ctx_sessions`  | `scope_key`               | `%Session{}`         |
| `:ctx_items`     | `{scope_key, item_key}`   | `%Item{}`            |
| `:ctx_deltas`    | `{scope_key, version}`    | `%Delta{}`           |
| `:ctx_acks`      | `{scope_key, run_id}`     | `acked_version`      |

**Versioning:** Every mutation produces a new monotonically-increasing integer
version.  The `required_version` field on `%Session{}` is the version runners
must acknowledge before their run is considered current.

**PubSub fanout:** Every mutation broadcasts `{:context_delta, delta}` to
`"ctx:<scope_key>"` so all interested processes (RunServer, UI LiveViews, etc.)
receive updates without polling.

**Item kinds:** Defined in `Platform.Context.Item.Kind`. Each kind has an
*eviction scope* (:run, :task, :epic, or :project) that drives the eviction
policy.

### Layer 2 — Execution Domain (`Platform.Execution`)

Manages the lifecycle of a single run.

**`Platform.Execution.Run`** — value struct tracking run status, context
version tracking (`ctx_required_version`, `ctx_acked_version`, `ctx_status`).

**`Platform.Execution.RunServer`** — supervised OTP process (one per active
run) that:
- Opens the context session on start
- Subscribes to `"ctx:<scope_key>"` for delta notifications
- On each delta: bumps `required_version` and starts a stale SLA timer
- On ack: clears the stale timer, updates `ctx_status = :current`
- On stale timeout: marks `ctx_status = :stale`, starts dead timer
- On dead timeout: marks `ctx_status = :dead`
- On terminal transition: triggers `EvictionPolicy.run_terminated/1`

**`Platform.Execution.ContextSession`** — bridge between `Run` and
`Platform.Context`. Handles ancestor session creation, snapshot assembly,
item push, and ack recording.

### Layer 3 — Eviction Policy (`Platform.Context.EvictionPolicy`)

Deterministic, lifecycle-driven eviction:

| Hook                         | Action                                              |
|------------------------------|-----------------------------------------------------|
| `run_terminated/1`           | Promote `:artifact_ref` items → task session; evict run session |
| `task_closed/1`              | Evict task session                                  |
| `epic_closed/1`              | Evict epic session                                  |
| `project_closed/1`           | Evict project session                               |

Items are never silently discarded mid-run.  The only data loss is the
intentional eviction of run-scoped items on run end (artifacts are promoted).

---

## Context Plane API Contract (for runners)

Runners interact with the context plane via `Platform.Execution`:

```elixir
# 1. Platform starts a run (runner receives run_id out-of-band)
{:ok, run} = Platform.Execution.start_run(task_id, project_id: "p", epic_id: "e")

# 2. Runner requests its initial snapshot
{:ok, snapshot} = Platform.Execution.get_snapshot(run.id)
# snapshot = %{items: [...], version: n, required_version: n}

# 3. Runner acknowledges the snapshot
{:ok, run} = Platform.Execution.ack_context(run.id, snapshot.version)

# 4. Runner pushes results / intermediate state
{:ok, new_version} = Platform.Execution.push_context(run.id, %{
  "artifact:output" => "s3://bucket/path"
}, kind: :artifact_ref)

# 5. Runner signals completion
{:ok, run} = Platform.Execution.transition(run.id, :running)
# ... work ...
{:ok, run} = Platform.Execution.transition(run.id, :completed)
```

For remote runners, a thin HTTP adapter (future) will proxy these calls.

---

## Staleness and Dead Detection

```
required_version set →┐
                       │ stale_timeout_ms (default 30s)
                       ▼
                  ctx_status = :stale ──→ dead_timeout_ms (default 120s)
                                                          ▼
                                                  ctx_status = :dead
```

- Runners must call `ack_context/2` within `stale_timeout_ms` of each delta.
- If a runner is `:dead`, the orchestrator may restart it or fail the run.
- `stale_timeout_ms` and `dead_timeout_ms` are configurable per run.

---

## Consequences

**Positive:**
- Deterministic, observable context handoff between platform and runners
- ETS O(1) reads without database round-trips for hot context
- PubSub fanout means reactive UI without polling
- Eviction policy prevents unbounded ETS growth
- Stale/dead detection lets orchestration recover from unresponsive runners

**Negative / Trade-offs:**
- ETS is in-process; a node crash loses unsaved context (acceptable in MVP —
  Postgres persistence can be layered in later)
- Delta history is capped at 200 entries per scope; runners that fall too far
  behind must request a full snapshot
- Context sessions are per-node; distributed multi-node support requires
  pg_pubsub or a distributed registry (future concern)

---

## Alternatives Considered

**Database-backed context:** Too slow for hot-path ack cycles.  Postgres will
be used for audit/history in a later pass.

**Agent ContextBroker reuse:** `Platform.Agents.ContextBroker` manages
agent-to-agent context inheritance (already shipped).  Reusing it for
runner-facing context would conflate two distinct contracts.

**gRPC/WebSocket runner protocol:** Deferred.  The MVP uses OTP directly;
HTTP/WS adapters will wrap this API for remote runners in a future task.

---

## References

- ADR 0007: Agent Runtime Architecture
- `Platform.Context.*` — context plane implementation
- `Platform.Execution.*` — run control implementation
- `docs/architecture/06-execution-runners-adr-0011.md`
