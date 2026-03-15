# ADR 0011: Execution Runners, Context Plane, and Deterministic Run Control

**Status:** Accepted  
**Date:** 2026-03-15  
**Deciders:** Rowan, Zip

---

## Context

Startup Suite needs a Tasks surface backed by an Execution domain that can do real work, not just track checklists.

The immediate goal is **proof of life**: move planning and implementation work into the suite itself so a task can be planned, executed inside the deployment runtime, monitored tightly, and shipped to real destinations like GitHub.

That execution model must work across the two practical deployment modes we care about:

1. **Local installs** — the platform runs directly on a machine and can execute local OS processes
2. **Docker installs** — the platform runs in containers and should execute work in isolated runner containers

At the same time, the system must leave room for the broader platform direction:

- artifacts may come from Tasks **or** from chat/canvas collaboration
- publication targets should be reusable across the suite (GitHub, Docker registry, Google Drive, preview routes, etc.)
- experimentation should later support ephemeral preview variants and A/B-style comparisons without requiring a permanent GitHub deploy for every trial

Rowan also wants two non-negotiable properties:

1. **Shared live context** — runners must be able to work from a centralized context store that evolves as chat, code, and execution events happen
2. **Very tight control** — the platform must know deterministically when a run is alive, stale, dead, or must stop, and a human must be able to kill a runner very quickly

---

## Decision

Adopt an **external runner model with a BEAM-owned context plane and deterministic run control**.

The platform owns orchestration, policy, context, liveness, and publication. Execution itself happens in controlled runners.

---

## Product Boundary

Startup Suite will officially support only two first-party execution providers in v1:

| Provider | Intended deployment | Model |
|----------|---------------------|-------|
| `local` | bare-metal / `mix` installs | spawn OS processes directly |
| `docker` | containerized installs | spawn short-lived runner containers |

This is the deliberate product boundary.

The platform will **not** attempt to solve arbitrary orchestration systems in v1 (Kubernetes, Nomad, ECS, generic schedulers, etc.). If demand appears later, those can be added behind the same runner behaviour as separate adapters.

---

## Execution Model

### The backend owns execution, but does not execute everything inside the app container

The platform is the control plane. It decides:

- what run to start
- which runner profile to use
- what context is visible
- what secrets are leased
- what deadlines and checkpoints apply
- when to stop, kill, or mark stale/dead

But the actual coding or artifact generation work runs in a **runner**.

### Docker installs

For Docker deployments, the preferred model is:

- `suite-app` — Phoenix application and control plane
- `suite-runnerd` — small companion service with container spawn/kill authority
- ephemeral runner container per run

The main application container should not be treated as the general-purpose execution sandbox.

### Local installs

For non-containerized deployments, the platform may execute local processes directly through the same runner contract.

---

## Shared Context Plane

Runners **must** be able to participate in a live shared context system.

That requirement is accepted.

However, the contract is **not direct ETS access**.

### Canonical model

The platform exposes a **Context Plane** owned by Elixir. That context plane is the shared substrate for Tasks, chat/canvas collaboration, and future experiment flows.

Runners connect to the context plane as scoped clients.

### Internal implementation model

| Layer | Role |
|------|------|
| Postgres | durable event log and recoverable state |
| ETS | hot working set / fast cache |
| PubSub | live fanout to UI and active runners |
| GenServers / reducers | scope management, versioning, promotion, eviction |

### Important rule

**ETS is working memory, not the public network API and not the durable source of truth.**

Runners need access to the same evolving context model the BEAM is using, but through a scoped protocol, not by joining the node and mutating ETS directly.

---

## Context Session Contract

Each run gets a scoped **context session**.

A context session includes:

- `project_id`
- `epic_id`
- `task_id`
- `run_id`
- granted capabilities
- current context snapshot
- current context version
- delta stream for updates

The runner must be able to:

1. receive an initial snapshot
2. acknowledge the current required context version
3. receive deltas as chat/code/execution events occur
4. publish observations back into the context plane
5. request refreshed context for a specific phase or scope

### Initial v1 context item kinds

- `decision`
- `constraint`
- `instruction`
- `chat_excerpt`
- `workspace_fact`
- `run_observation`

### Initial v1 context scopes

- project
- epic
- task
- run

---

## Event-Reduced Context

Context is not treated as a bag of notes. It is reduced from events.

Examples:

- `chat.message_added`
- `task.plan_approved`
- `task.requirement_changed`
- `run.phase_changed`
- `run.checkpoint_recorded`
- `run.observation_recorded`
- `run.test_failed`
- `run.test_passed`
- `artifact.created`
- `artifact.published`
- `human.feedback_added`
- `context.item_pinned`
- `context.item_evicted`

Reducers build the active context views that tasks and runners consume.

This allows context to evolve automatically as work progresses.

---

## Deterministic Promotion and Eviction

Context promotion and eviction should be mechanical, not model-driven.

Examples of deterministic rules:

- run-local context expires when the run ends unless explicitly promoted
- task-local context evicts on task completion unless pinned upward
- superseded decisions are hidden once replaced
- code observations tied to an older branch SHA are invalidated after a newer checkpoint
- unresolved failures stay pinned until explicitly cleared by a later success event
- short-lived chat excerpts decay unless promoted by plan approval, review, or artifact references

This keeps the context story rich without becoming an unbounded pile of stale notes.

---

## Runner Protocol

A compliant runner must support these platform interactions:

- `connect`
- `snapshot`
- `delta`
- `ack`
- `heartbeat`
- `checkpoint`
- `observe`
- `complete`
- `fail`
- `request_stop`
- `force_stop`

The runner is not considered fully healthy unless it is participating in the context protocol.

---

## Deterministic Run Monitoring

Every active run gets a BEAM-owned process (`RunServer`) under supervision.

The control model is:

- one OTP process per active run
- explicit state transitions
- explicit timers for liveness and progress deadlines
- append-only event history
- PubSub fanout for UI and operators

### Core run states

- `queued`
- `starting`
- `booting`
- `running`
- `stopping`
- `kill_requested`
- `completed`
- `failed`
- `cancelled`
- `killed`
- `stale`
- `dead`

### Definitions

**Alive**
- heartbeats are on time
- required context version has been acknowledged inside SLA
- expected checkpoints or observations are still arriving

**Stale**
- the runner is still alive
- but it has not made required forward progress in time, or has failed to acknowledge required context changes in time

**Dead**
- heartbeat lease expired
- wrapper process exited unexpectedly
- runner container/process is gone or irrecoverably detached

These states must be computed from platform-owned timers and events, not from hopeful interpretation of log text.

---

## Fast Stop / Kill Semantics

The platform must support **very fast human intervention**.

Stopping a run is a first-class control path, not a polite suggestion.

### Required behaviour

1. When a user requests stop, the `RunServer` records the stop request immediately and transitions the run to `stopping`
2. The stop request is sent to the runner immediately
3. The runner wrapper must immediately forward the stop to the child execution process (for example Codex or Claude Code)
4. A short kill grace timer starts at once
5. If the runner has not acknowledged exit before the grace deadline, the platform escalates to `force_stop`
6. Force stop maps to the strongest supported mechanism for the provider:
   - local: process kill
   - docker: container kill
7. After force stop, the run transitions to `killed` when exit is confirmed; if confirmation cannot be obtained within the configured deadline, it transitions to `dead`

### Default expectation

The UX expectation is:

- stop request visible immediately
- graceful stop attempted immediately
- hard kill escalation after a short default grace window (approximately 3 seconds)

The exact grace window is configurable per runner profile, but **fast stop is the default posture**.

The system must prefer a deterministic stop over a vague "it should wind down soon" experience.

---

## Security Model

### Workspace mounting

Runner execution may use a host-mounted workspace, but the mount should be:

- a dedicated workspace root or per-run worktree
- not an unrestricted mount of the entire host environment
- writable only where needed
- durable outside the container so failed runs do not lose work

### Runner hardening

Default Docker runner posture:

- non-root user
- drop Linux capabilities
- `no-new-privileges`
- no privileged mode
- no Docker socket inside the runner
- short-lived leased secrets
- explicit outbound integration allowlist where practical

### Credential model

Runner credentials are leased from the platform/Vault for the scope and lifetime of the run. They are not treated as permanently ambient container state.

---

## Artifacts and Destinations

Tasks do not directly "know GitHub" or "know Google Drive".

Instead:

- a run produces one or more **artifacts**
- the platform publishes artifacts to **destinations**

This same substrate is used whether the artifact comes from a task, a validation flow, or a chat/canvas collaboration.

Examples of destinations:

- GitHub branch / PR
- Docker registry
- Google Drive folder
- ephemeral preview route
- future storage or deployment targets

This keeps execution generic and makes publication reusable across the suite.

---

## Open Source Deployment Story

The public open-source story is intentionally simple:

### Mode A — Local

- install Startup Suite directly on a machine
- use the `local` runner provider
- runs execute as local OS processes

### Mode B — Docker

- run Startup Suite in Docker
- add the companion `runnerd` service
- use the `docker` runner provider
- runs execute as short-lived isolated containers

This is the supported contract for v1.

---

## Consequences

### Positive

- keeps the product boundary realistic and supportable
- allows Docker installs to execute in a runtime similar to deployment reality
- preserves a live shared context plane across chat, tasks, and future experiments
- gives deterministic liveness and stale/dead detection using OTP timers and explicit checkpoints
- enables fast human kill control without waiting on model goodwill
- keeps publication reusable across tasks and collaborative artifact generation

### Negative

- requires building a runner protocol instead of relying on direct process access inside the web app
- introduces a companion service for Docker installs
- requires explicit context reduction/promotion/eviction logic rather than ad hoc prompt assembly
- does not support every orchestrator permutation in v1

---

## Non-Goals

This ADR does **not** fully define:

- the complete Tasks UX
- the full experimentation / preview-route system
- every future publication destination
- a Kubernetes or generic scheduler adapter
- direct BEAM-cluster membership for external runners

Those can follow later without changing the core decision.

---

## Provider and UI Handoff Notes

### Local provider expectations

- Return a provider ref that at minimum identifies the wrapper process and child OS pid.
- `request_stop` must immediately forward a graceful signal/termination request to the child process.
- `force_stop` must map to the strongest local kill path and must be safe to call even if graceful stop already ran.
- Heartbeats, checkpoints, context acks, and exit confirmation must be emitted by the wrapper, not inferred from log text.

### Docker provider expectations

- Return a provider ref that identifies both the runnerd-side run handle and the container id once known.
- `request_stop` must flow through `runnerd` immediately to container stop semantics with the configured short grace period.
- `force_stop` must map to container kill and remain idempotent if the container is already exiting.
- Container liveness/exit must be reported back explicitly so `RunServer` can distinguish `killed` from `dead`.

### Tasks UI expectations

- Treat `Platform.Execution.describe_run/1` as the control-plane source of truth for run state.
- Show runner profile, phase, last heartbeat, last progress, and required/acknowledged context version on the run detail view.
- Surface `stopping` and `kill_requested` as immediate operator-visible states rather than waiting for final exit.
- Keep explicit stop and kill controls separate in the UI even though stop auto-escalates quickly by default.

## Follow-Up Work

1. Scaffold `Platform.Execution` as a first-class domain
2. Add runner behaviour and first-party provider contract (`local`, `docker`)
3. Add per-run OTP lifecycle management (`RunServer` + supervisor + registry)
4. Add context session structs and runner-facing context protocol primitives
5. Encode heartbeat, checkpoint, stale, dead, stop, and force-kill semantics in code
6. Add a minimal Tasks sign-of-life path: create run → start runner → stream state → stop/kill deterministically
7. Add artifact/destination contracts so code output and chat/canvas output can share the same publication model
8. Add Docker companion service design/docs for `runnerd`
