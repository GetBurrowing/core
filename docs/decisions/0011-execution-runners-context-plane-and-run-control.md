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

## Local Provider — Credential Leasing and GitHub Push Path (Stage 4)

The local provider seam introduced in Stage 1–3 has been extended with:

### `Platform.Execution.CredentialLease`

Short-lived, scoped credential tokens that the control plane issues per-run.
Three lease kinds are supported:

| Kind       | Env vars injected                                        |
|------------|----------------------------------------------------------|
| `:github`  | `GITHUB_TOKEN`, `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_*` |
| `:model`   | `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` (provider-specific) |
| `:custom`  | Arbitrary key → value map converted to env vars         |

MVP reads credentials from application config and process env; Vault-backed
issuance is tracked as a follow-up (see § Future Work).

Leases have a configurable TTL (default 2 hours), can be revoked explicitly,
and expose `valid?/1` for runtime validity checks.  `to_env/1` converts a
lease to an OS env-var map for injection into child processes.

### `LocalWorkspace.setup_git_worktree/3`

Sets up a durable git worktree under the per-run workspace path from a
source repository. Used by the GitHub push path to keep run-specific branches
isolated from the main workspace.

### `LocalWorkspace.push_branch/3`

Stages all changes, commits, and pushes the current branch to a remote. The
optional `:lease` opt injects GitHub credentials via env. Designed for the
proof-of-life GitHub push flow: the local runner can push a deterministic
branch after each run without storing long-lived credentials.

### `LocalRunner.spawn_run/2` — credential injection

`spawn_run/2` now accepts `:credential_lease` in opts. The lease is converted
to env vars and injected into the child process at spawn time.

### RunServer provider extensions

`RunServer` now supports:
- `spawn_provider/3` — attach a `Runner` module and start the underlying process
- `request_stop/1` and `force_stop/1` — delegate to the runner provider
- `{:runner_exited, run_id, %{exit_code, exit_state}}` message handler —
  receives exit notifications from `LocalProcessWrapper` and transitions the
  run to `:completed`, `:cancelled`, or `:failed` deterministically.

---

## Docker Provider — Container Run Control and Fast Kill Semantics (Stages 2–3)

The Docker-backed provider established in Stage 1 is now fully functional.
`Platform.Execution.DockerRunner` implements the `Runner` behaviour and delegates
all container mechanics to the `suite-runnerd` companion service through
`SuiteRunnerdClient`.

### Spawn payload

`spawn_run/2` builds a structured payload forwarded to `suite-runnerd`:

| Field | Description |
|-------|-------------|
| `run_id` / `task_id` / `project_id` / `epic_id` | Run identity |
| `workspace_root` / `workspace_path` | Per-run workspace paths |
| `command` / `args` / `env` | Entrypoint and credential env vars |
| `security` | Non-root user, no-new-privileges, capability drop, no Docker socket |
| `mount` | Host-to-container bind mount for the per-run worktree |
| `meta` | Arbitrary run metadata forwarded to the service |

### Security posture (defaults)

Every container is spawned with the following hardening applied by default:

```elixir
%{
  user: "runner",           # non-root, UID 1000 in the image
  no_new_privileges: true,  # blocks setuid/setgid escalation
  capability_drop: ["ALL"], # drop all capabilities; add back only what's needed
  capability_add: [],       # empty by default; opt-in per task
  no_docker_socket: true    # socket never mounted into runner container
}
```

The `:runner_user` and `:capability_add` opts allow per-spawn overrides.
`suite-runnerd` is responsible for translating these into `docker run` flags.

### Host-mounted worktree

The per-run workspace path is bind-mounted into the container at `/workspace`:

```elixir
%{
  type: "bind",
  host_source: "<workspace_root>/<run_id>",
  container_target: "/workspace",   # override via :container_workspace_path
  workspace_root: "<root>",
  read_only: false
}
```

The container's working directory is `/workspace` by convention.  Runners
write branches and artifacts here; the host sees the changes directly without
needing a shared volume daemon.

### Fast stop/kill escalation

`DockerRunner.stop_with_escalation/2` provides two-phase termination:

1. **Graceful stop** — calls `request_stop/2` (forwards to `POST /api/runs/:id/stop`)
2. **Poll loop** — describes the run every 500 ms until it reports a terminal status
   (`:exited`, `:dead`, `:stopped`, `:killed`) or the timeout elapses
3. **Hard kill** — if still running after `escalation_timeout_ms` (default 10 s),
   calls `force_stop/2` (forwards to `POST /api/runs/:id/kill`)

Returns `:ok` once confirmed stopped or killed.  If the describe call fails the
runner is assumed gone and `force_stop` is called defensively.

### Describe metadata

`describe_run/2` merges the stored provider ref with `suite-runnerd`'s response.
The merged map exposes:

| Key | Type | Notes |
|-----|------|-------|
| `:status` | atom | `:starting` \| `:running` \| `:exited` \| `:killed` \| `:stopped` |
| `:exit_code` | integer \| nil | Process exit code |
| `:container_id` | string | Docker short ID |
| `:image` | string | Image reference |
| `:stop_mode` | atom \| nil | `:graceful` \| `:kill` |
| `:started_at` | string \| nil | ISO8601 |
| `:finished_at` | string \| nil | ISO8601 |
| `:exit_message` | string \| nil | Stderr tail from container |
| `:health` | atom \| nil | `:healthy` \| `:degraded` \| `:unknown` |
| `:workspace_path` | string | Run workspace path on host |
| `:workspace_root` | string | Workspace root on host |

---

## Docker Provider — Follow-Up Notes (Stage 4)

The following seams are intentionally deferred and documented here for
subsequent tasks.

### Runner image hardening

The BEAM side sends a security payload but cannot enforce it — enforcement is
the responsibility of `suite-runnerd`.  Outstanding items for the runner image:

- **Non-root user creation**: the image must include `useradd -m -u 1000 runner`
  (or equivalent) so the container starts as UID 1000.
- **Seccomp profile**: apply a curated seccomp profile alongside `no-new-privileges`
  to further reduce the syscall surface.
- **Read-only root filesystem**: mount the container root as read-only; only
  `/workspace` (bind mount) and `/tmp` (tmpfs) should be writable.
- **Image signing**: runners should pull from a registry that enforces image
  signature verification (Cosign / Notation).

### Docker socket exclusion

`no_docker_socket: true` is forwarded in the spawn payload but `suite-runnerd`
must act on it.  The `docker run` command must **not** include
`-v /var/run/docker.sock:/var/run/docker.sock`.  If a future task requires
in-container Docker builds, the recommended path is:

1. A rootless Docker-in-Docker (DinD) sidecar with an explicitly scoped socket
2. A remote Buildkit daemon with a token-scoped connection

### Proof-of-life handoff

Sign-of-life for Docker runners means a runner container can:

1. Accept an entrypoint (e.g. `codex` or `claude`) via the spawn command
2. Clone or access the per-run worktree at `/workspace`
3. Push a branch to GitHub using the injected `GITHUB_TOKEN`

This requires:
- A concrete `suite-runnerd` service (current task delivers the BEAM seam only)
- A base runner image with `git`, `gh`, and the target agent binary installed
- An integration test that spawns a real container and asserts the branch appears on GitHub

The Tasks UI proof-of-life flow (run status → branch link in task detail) will
build on top of this once the `suite-runnerd` binary exists.

### suite-runnerd service

`SuiteRunnerdClient` defines the HTTP contract but no server-side implementation
exists yet.  The next task should:

- Scaffold a `suite-runnerd` binary (Go or Elixir release) that handles
  `POST /api/runs`, `GET /api/runs/:id`, `POST /api/runs/:id/stop|kill`
- Translate the spawn payload into a `docker run` invocation using the
  security and mount fields
- Return the container ID and initial status in the spawn response
- Handle the SIGTERM → SIGKILL escalation on the container side

---

## Future Work

- **Vault credential leasing:** replace config-backed `CredentialLease` with
  short-lived GitHub App installation tokens from `Platform.Vault`
- **Model credential rotation:** lease provider API keys with per-run TTL so
  compromised runs cannot use tokens indefinitely
- **GitHub push verification:** after push, resolve the branch HEAD SHA and
  record it in the run's context as an artifact ref for downstream consumers
- **Postgres persistence:** async write of items + deltas for audit/replay
- **Distributed context:** pg_pubsub adapter for multi-node deployments
- **HTTP runner protocol:** thin adapter wrapping the Execution public API
- **Context compaction:** summarise long item histories via an LLM pass before
  handing to runners
- **suite-runnerd binary:** implement the companion service that translates the
  BEAM spawn payload into concrete `docker run` invocations
- **Runner image:** build and publish a base runner image with non-root posture,
  git, gh CLI, and agent binaries (Codex / Claude Code)
- **Proof-of-life integration test:** end-to-end test that spawns a real runner
  container, runs a branch push, and verifies the result via GitHub API

---

## References

- ADR 0007: Agent Runtime Architecture
- `Platform.Context.*` — context plane implementation
- `Platform.Execution.*` — run control implementation
- `Platform.Execution.DockerRunner` — Docker-backed runner provider
- `Platform.Execution.SuiteRunnerdClient` — HTTP client for suite-runnerd
- `Platform.Execution.CredentialLease` — per-run credential leasing
- `Platform.Execution.LocalWorkspace` — workspace + git push path
- `docs/architecture/06-execution-runners-adr-0011.md`
