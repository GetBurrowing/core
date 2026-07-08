# ADR 0043: Security Guard — periodic security-scan responsibility bundle

**Status:** Accepted (2026-07-08)

## Context

Several recent incidents share a shape: latent security debt caught late by a
human, not by any automation.

- **MEETING_GUEST_SIGNING_KEY** (task `019f2483`) — a required env key present
  in `.env.example` was never added to the production `secrets/*.env` file,
  which crash-looped `core-platform.service` on the first boot after the
  Meeting Guest feature landed. Nothing on the platform checked example-vs-
  secrets drift.
- **Phantom-fix chain** (`019f3312`) — a webhook-verification bug that took
  four rounds to actually land. The first two "fixes" were untested regex
  edits. A code-audit sweep flagging unverified webhook controllers would
  have caught the shape.
- **LiveKit key leak** (referenced in `project_livekit_leak.md`) — an API
  key was committed to a fixture file and pushed to the public repo. Only
  human review at PR time caught it. A pre-push git hook would have blocked
  the push.
- **Untracked secrets** across `~/.config/containers/systemd/` — a periodic
  audit found several `.container` units binding to `0.0.0.0` when they
  should have been Tailscale-only.

All four have the same remediation shape: a periodic scan that files a task
against Rowan (or a designated project) when a finding matches a known rubric.
None of them fits an ad-hoc LLM dispatch — they are deterministic pattern
matches and file reads. They want a scheduled sweeper, a stable rubric, and
tight dedup so the task board isn't buried.

## Decision

Introduce a **`security_guard` platform role** whose bundle contains four
responsibility keys, plus a dedicated `Platform.Security.Sweeper` GenServer
runtime that owns the scan cadence. The keys register through the standard
`Platform.Responsibilities` surface so admin-UI legibility + role assignment
work identically to every other role, but the **actual runtime is the
Sweeper, not the Router** — see rationale below.

The four responsibility keys:

- `security.cve_scan` — weekly, walks `mix.lock` / `package-lock.json` /
  `Cargo.lock` / container manifests; queries OSV.dev; files a task per
  critical/high CVE.
- `security.code_audit` — weekly, applies a YAML rubric of regex + AST
  probes against the platform's own source; files a task per finding
  (unparameterized SQL, hardcoded API keys, command injection shapes,
  unverified webhook controllers).
- `security.deploy_audit` — weekly, walks Traefik rules, container manifests,
  env-example-vs-secrets diffs, and TLS cert expiry; files a task per
  drift.
- `security.secret_leak` — daily, applies a gitleaks-shaped pattern library
  against the working tree (and optionally git history); a companion
  pre-push git hook blocks pushes containing the same patterns.

All four register as `trigger_kind: "event_topic"` bound to the topic
`platform.security.sweeper_only` — a topic **no publisher ever broadcasts
to**. The Router subscribes as usual (so no special-case in the Router
itself) but the subscription is a null seam. The Sweeper drives the actual
scans.

### Progressive-enhancement contract

The Sweeper's tick, for each key, first calls
`Platform.Roles.assignee_for(key)`. If the return is `nil` — no
`security_guard` role has been assigned — the Sweeper emits an unfilled-
responsibility telemetry event, logs a placeholder line, and returns without
invoking any scanner. Zero side effects. This is the load-bearing contract:
the security bundle SHIPS by default but does NOTHING until Rowan (or an
admin) explicitly assigns the role to an agent. Behaviour identical to every
other role in the platform's roster (Decision 2 from the M4 stack).

### Runtime design — why not Router?

The Router's cron path is
`Router.maybe_fire_cron` → `fire_trigger` → `dispatch_native` /
`dispatch_external`. Both `dispatch_native` (AgentResponder signal) and
`dispatch_external` (LLM call) route through non-deterministic runtimes.
Security scans are deterministic filesystem + HTTP work with a fixed output
contract — routing them through an LLM would burn tokens on lockfile
parsing and hallucinate CVE severity classification. Routing them through
AgentResponder would tie them to agent liveness for zero benefit.

Two alternatives were considered and rejected:

1. **Register with `trigger_kind: "cron"` at intended cadence, no-op in
   `handle_output/3`.** Rejected — the Router would still fire an
   unnecessary LLM call weekly per key. Wasteful and noisy in telemetry.

2. **Fork the Router with a `metadata[:native_scan] == true` early-return.**
   Rejected — churn on a hot-path module for a niche use case. The Router's
   invariants (fair scheduling, cost accounting, prompt-template resolution)
   don't fit the Sweeper's contract.

The chosen design — `event_topic` with a **null topic** the Sweeper never
subscribes to — keeps the row visible in the admin UI, keeps
`assignee_for/1` resolvable, and makes the Router a genuine no-op for these
keys. The Sweeper is the actual runtime; it reads
`metadata["cadence"]` (a cron expression) from each responsibility row and
schedules itself accordingly.

### Consolidation + dedup

`Platform.Security.FindingFiler` (stage 2 shim, stage 5 body):

- File a task per finding when count ≤ 10 per scanner run.
- File **one** consolidated digest task (severity-first markdown table)
  when count > 10, fingerprinted by ISO week so the weekly cron doesn't
  produce a new digest task each Monday when nothing has changed.
- Every finding carries a `metadata["security_fingerprint"]`. Before
  filing, the shim checks for an open task with the same fingerprint via
  `Platform.Tasks.list_tasks_by_metadata_key/2` — matches skip the insert.
  This is critical for a weekly-cron scanner that would otherwise flood
  the board with re-discovered CVEs.

## Consequences

**Positive**
- Uniform admin-UI surface: Control Center → Roles lists Security Guard
  next to Historian and Meeting Scribe.
- Progressive-enhancement default is safe: shipping the bundle turned on
  by default files zero tasks until an agent is assigned. Rowan can flip
  the switch when he has an agent to answer for it.
- Deterministic runtime keeps token spend at zero for the platform-owned
  scans. Findings flow into the same task pipeline as everything else.
- The MEETING_GUEST_SIGNING_KEY class of miss becomes catchable
  automatically.

**Negative / cost**
- The `event_topic` + null-topic pattern is a mildly clever indirection.
  ADR + moduledoc + comments spell it out; new contributors will still
  need one round of "why is there a topic no one publishes to?"
- Scanner runtimes are new surface area (four modules + a Sweeper + a
  FindingFiler + a hook installer). Each adds a small maintenance load.
- OSV.dev queries add a weekly egress touch — anonymous, batched, no
  auth needed, but still a network dependency for the CVE scan.

**Non-goals**
- **Auto-patch.** Findings file tasks; humans decide whether to bump a
  dep. The scanner does not run `mix deps.update`.
- **CI-block.** The pre-push git hook is opt-in per developer (`mix
  security.install_hooks`). CI does not gate merges on scan results.
- **Container image scans.** Deferred — OSV.dev's container ecosystem
  coverage is uneven, and Trivy would introduce a whole subsystem. A
  follow-up ADR if we decide we need it.

## Alternatives considered

**Wire the security bundle to an external cron (Kubernetes CronJob, systemd
timer).** Rejected — the platform already owns a supervisor + a
responsibilities registry + a role picker. Adding a second scheduling plane
splits the operational model. The Sweeper GenServer reuses the existing
BEAM supervision tree.

**Skip the responsibility rows entirely; just ship a Sweeper.** Rejected —
losing the admin-UI + progressive-enhancement gate would leave no way to
opt in per-org or per-agent. The rows are cheap and give us the seam.

**Split into four separate roles (`cve_officer`, `code_auditor`, etc.).**
Rejected — a single Security Guard role captures the operational reality
(one person, or one agent, owns the security responsibility for the org).
Bundling avoids the "which agent runs which scan?" bookkeeping.

**Use gitleaks / Trivy / Semgrep as subprocess.** Rejected for the initial
scope — each is a separate dependency + upstream. The four scanners land as
first-class Elixir modules (regex + Finch for OSV + a small YAML rubric
loader). If a future scanner needs Semgrep-quality AST analysis we revisit;
today the platform-shape work is inside `apps/platform/lib/` and Elixir
patterns cover it well.

## Implementation surface

This ADR is landed alongside **stage 1** of the security-guard task
(`019f3e8e-4406-...`). Stage 1 ships only the declarative shell:

- New role key `security_guard` in `Platform.Roles.Role.@valid_keys`
- New CHECK-constraint migration mirroring the meeting-producer migration
  shape
- New seed migration re-invoking `Platform.Roles.Seeds.seed_defaults/0`
  scoped to `[only_keys: ["security_guard"]]`
- Extended `@default_roles` roster in `Platform.Roles.Seeds`
- Four new placeholder provider modules under
  `Platform.Responsibilities.Handlers.SecurityCveScan` /
  `SecurityCodeAudit` / `SecurityDeployAudit` / `SecuritySecretLeak`
- `Platform.Responsibilities.BuiltIns.providers/0` + the config-level
  provider list extended to include all four modules

Stage 2 lands `Platform.Security.Sweeper` + the `FindingFiler` shim + stub
scanner modules that prove the plumbing without invoking scanner logic.
Stages 3-5 land the individual scanner bodies. See the plan tree on task
`019f3e8e` for the full stage breakdown.

Nothing about the runtime is speculative — the design here is the same
GenServer-plus-progressive-enhancement pattern
`Platform.Meetings.SummarizerSweeper` uses (task `019f2566`). This ADR
records the design so the sibling stages can move without re-relitigating
the runtime choice.
