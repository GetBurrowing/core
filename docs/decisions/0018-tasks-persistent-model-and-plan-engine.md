# ADR 0018: Tasks — Persistent Model and Plan Engine

**Status:** Accepted  
**Date:** 2026-03-20  
**Related:** ADR 0002 (Domain Boundaries), ADR 0011 (Execution Runners), ADR 0006 (Vault)  
**Deciders:** Rowan Ellis  

## Context

ADR 0011 established the execution runtime — ETS context plane, RunServer, local and Docker runners, credential leasing, artifact promotion. ADR 0002 defined the naming boundary: Tasks is the product surface, Execution is the backend domain.

Today, tasks only "exist" while there's an active run or ETS context session. Once a run completes and ETS evicts, the task disappears. There's no persistent model, no project hierarchy, no plan engine, and no kanban surface.

The current external system (Tasky) fills this gap but has fundamental limitations:
- LLMs make mechanical decisions (status transitions, stage progression) that should be deterministic
- Context doesn't cascade through a hierarchy — each level must be manually specified
- Deploy configuration isn't project-scoped or config-driven
- Feedback during execution has no structured path from chat to runner

This ADR introduces the persistent data model, plan engine, and context enrichment system that bridges the gap between the Tasks surface and the Execution runtime.

## Core Principle

**Deterministic automation for mechanical tasks. LLMs only where judgment is genuinely needed.**

| Deterministic | LLM |
|---|---|
| Status transitions | Plan generation from task description |
| Stage progression (validation pass → next) | Code generation / modification |
| Context assembly and enrichment | Code review (judgment calls) |
| CI / lint / typecheck / test validation | Feedback interpretation |
| Deploy config resolution | Task description refinement |
| Artifact registration and promotion | |

## Decision

### 1. Persistent Model Hierarchy (Postgres)

```
Workspace (deploy credentials, team, global config)
  └─ Project (repo, deploy target config, tech stack)
      └─ Epic (goals, acceptance criteria, ADR refs)
          └─ Task (description, requirements, dependencies)
              └─ Plan (ordered stages, approval status)
                  └─ Stage (description, expected artifacts, validations)
                      └─ Validation (typed criteria, status, evidence)
```

Each level carries its own config and context that enriches everything below it.

#### Tables

**`workspaces`** — team container (extends existing Accounts)
- `id`, `name`, `slug`
- `config` (jsonb) — global deploy credentials ref, team defaults

**`projects`**
- `id`, `workspace_id`, `name`, `slug`
- `repo_url`, `default_branch`
- `tech_stack` (jsonb) — language, framework, build system
- `deploy_config` (jsonb) — array of deploy targets (see § Deploy Targets)
- `config` (jsonb) — project-level overrides

**`epics`**
- `id`, `project_id`, `name`, `description`
- `acceptance_criteria` (text)
- `status` — `open`, `in_progress`, `closed`

**`tasks`**
- `id`, `epic_id`, `project_id` (denormalized for query efficiency)
- `title`, `description`
- `status` — `backlog`, `planning`, `ready`, `in_progress`, `in_review`, `done`, `blocked`
- `priority` — `low`, `medium`, `high`, `critical`
- `assignee_type` + `assignee_id` — polymorphic (user or agent)
- `dependencies` (jsonb) — task ID refs
- `metadata` (jsonb)

**`plans`**
- `id`, `task_id`
- `status` — `draft`, `pending_review`, `approved`, `rejected`, `superseded`
- `version` — integer, auto-increment per task
- `approved_by`, `approved_at`

**`stages`**
- `id`, `plan_id`
- `position` — integer, ordered within plan
- `name`, `description`
- `status` — `pending`, `running`, `passed`, `failed`, `skipped`
- `expected_artifacts` (jsonb) — what this stage should produce
- `started_at`, `completed_at`

**`validations`**
- `id`, `stage_id`
- `kind` — `ci_check`, `lint_pass`, `type_check`, `test_pass`, `code_review`, `manual_approval`
- `status` — `pending`, `running`, `passed`, `failed`
- `evidence` (jsonb) — CI logs, review comments, test output
- `evaluated_by` — system, agent ID, or user ID
- `evaluated_at`

### 2. Context Enrichment (Deterministic)

When a run starts for a task, the system assembles a context snapshot by walking the hierarchy. Each level pushes items into the ETS context plane at the appropriate scope:

```elixir
# Deterministic — no LLM involved
def populate_run_context(run, task) do
  project = Repo.preload(task, :project).project
  epic = task.epic && Repo.preload(task, :epic).epic

  # Project-scoped context
  Context.push(run.project_scope, :project_config, %{
    repo_url: project.repo_url,
    default_branch: project.default_branch,
    tech_stack: project.tech_stack,
    deploy_config: project.deploy_config
  })

  # Epic-scoped context (if present)
  if epic do
    Context.push(run.epic_scope, :epic_goals, %{
      name: epic.name,
      acceptance_criteria: epic.acceptance_criteria
    })
  end

  # Task-scoped context
  Context.push(run.task_scope, :task_definition, %{
    title: task.title,
    description: task.description,
    dependencies: task.dependencies
  })

  # Plan-scoped context
  plan = Tasks.current_plan(task)
  if plan do
    stages = Tasks.list_stages(plan)
    Context.push(run.task_scope, :plan_stages, %{
      stages: Enum.map(stages, &stage_summary/1),
      current_stage: current_stage(stages)
    })
  end
end
```

The runner's `ContextSession.snapshot/1` inherits from ancestor scopes (per ADR 0011), so the executor receives the fully assembled context without a single LLM call.

### 3. Plan Engine (Deterministic State Machine)

The plan engine manages stage lifecycle as a pure state machine. No LLM decides when a stage progresses.

#### Stage State Machine

```
pending → running → passed
                  → failed → running (retry)
                           → skipped (manual override)
```

#### Validation Registry

Each validation kind maps to a deterministic checker or a delegated evaluator:

| Kind | Evaluator | Deterministic? |
|------|-----------|----------------|
| `ci_check` | Poll GitHub Actions / CI status | ✅ |
| `lint_pass` | Run linter, check exit code | ✅ |
| `type_check` | Run type checker, check exit code | ✅ |
| `test_pass` | Run test suite, check exit code | ✅ |
| `code_review` | Delegate to LLM agent | ❌ (LLM boundary) |
| `manual_approval` | Wait for human gate via Review domain | ❌ (human gate) |

#### Stage Progression

```elixir
def check_stage_progression(stage) do
  validations = list_validations(stage)

  cond do
    Enum.all?(validations, &(&1.status == "passed")) ->
      transition_stage(stage, :passed)
      advance_to_next_stage(stage.plan_id)

    Enum.any?(validations, &(&1.status == "failed")) ->
      transition_stage(stage, :failed)

    true ->
      :noop  # Still waiting on pending validations
  end
end
```

This is a pure function of validation states — no LLM reasoning.

### 4. Feedback Channel (Chat → Run Context)

Messages from the chat surface tagged as feedback are pushed into the run context:

```elixir
# In Chat surface, user sends feedback while a task is running
def push_feedback(space_id, task_id, content, author) do
  run = Execution.active_run_for_task(task_id)

  if run do
    Context.push(run.task_scope, :feedback, %{
      content: content,
      author: author,
      source: :chat,
      space_id: space_id,
      timestamp: DateTime.utc_now()
    })
  end
end
```

The runner's RunServer picks up the delta via PubSub. The runner acks it and adjusts. No special protocol — just the existing context plane machinery from ADR 0011.

### 5. Deploy Target Resolution (Config-Driven)

Deploy targets are project-level config, not LLM-generated:

```elixir
%{
  "deploy_targets" => [
    %{
      "name" => "production",
      "type" => "docker_compose",
      "config" => %{
        "host" => "dev@192.0.2.234",
        "stack_path" => "~/docker/stacks/my-app",
        "image_registry" => "ghcr.io/org/repo",
        "watchtower" => true
      }
    }
  ]
}
```

At run time, the deploy target config is pushed into the project-scoped ETS session. The deployer stage reads it from the context snapshot. It's just config.

Future deploy types: `:fly`, `:k8s`, `:static`, `:cloudflare_pages`. Each is a struct with typed fields — the deployer runner reads the type and dispatches accordingly.

### 6. Agent Execution Contract

When a task is assigned to an agent — whether local (built-in) or federated (external runtime) — the agent is responsible for execution. The platform does not dictate *how* an agent executes, only the *reporting contract*.

#### The contract

An executing agent MUST:
1. **Ack context snapshots** — call `ack_context(run_id, version)` within the stale SLA window (per ADR 0011)
2. **Push progress** — push context items (`:stage_progress`, `:artifact_ref`, `:status_update`) as work proceeds
3. **Report stage completion** — push validation evidence when a stage's work is done, so the deterministic plan engine can evaluate and progress

An executing agent MAY:
- Spawn subprocesses (Codex, Claude Code, custom tooling)
- Use any model, tool, or execution strategy it chooses
- Take as long as it needs (subject to stale/dead detection)

The platform WILL:
- Provide the full context snapshot at run start (project config, epic goals, task description, plan stages, deploy targets — the full hierarchy)
- Push feedback deltas in real-time via PubSub (chat messages, human reviewer notes)
- Evaluate validation criteria deterministically when the agent pushes evidence
- Progress stages automatically when validations pass
- Detect stale/dead agents and surface the state to the UI

#### Local agents (built-in runtime)

For built-in agents, the platform spawns execution directly. The proof-of-life path (ADR 0011) delegates to a local Codex subprocess via `LocalRunner`. The agent process:
- Receives the context snapshot
- Spawns Codex/Claude Code in a git worktree
- Pushes artifacts (branch refs, file changes) back through the context bus
- Reports stage completion

#### Federated agents (external runtime)

For federated agents, the platform dispatches an attention signal via the RuntimeChannel (ADR 0014). The external runtime is a black box — it can run whatever it wants. The only requirement is reporting back through the context bus:

```elixir
# Federated agent pushes progress via RuntimeChannel
channel.push("context_push", %{
  run_id: run_id,
  items: [
    %{kind: "stage_progress", data: %{stage_id: stage_id, percent: 75}},
    %{kind: "artifact_ref", data: %{type: "branch", ref: "feat/my-feature"}}
  ]
})

# Federated agent acks context
channel.push("context_ack", %{run_id: run_id, version: snapshot_version})
```

RuntimeChannel translates these into `Platform.Execution` calls. The plan engine and validation registry work identically regardless of whether the agent is local or federated — they only see context items and validation evidence, not the agent's implementation.

#### Why this matters

This separation means:
- The plan engine never needs to know what kind of agent is running
- Adding a new agent type (remote HTTP runner, MCP agent, custom provider) requires zero changes to the plan engine, validation system, or task status transitions
- Progress reporting is the universal interface — not agent implementation details

### 7. Task Status Transitions (Deterministic)

Task status transitions are driven by events, not LLM decisions:

| Event | Transition |
|-------|-----------|
| Plan approved | `ready` → (awaits execution trigger) |
| Run started | → `in_progress` |
| All stages passed | → `in_review` |
| Code review passed + manual approval (if required) | → `done` |
| Any stage failed | → `blocked` (or stays `in_progress` for retry) |
| Plan rejected | → `planning` |

### 7. Kanban Surface (LiveView)

The Tasks surface at `/tasks`:
- Column-per-status kanban board
- Cards show: title, assignee, run status indicator, current stage, stage progress bar
- Project filter/switcher
- Task detail: description, plan with stage progress, validation results, feedback thread, artifact list, run history
- Real-time updates via PubSub (run status changes, stage completions, validation results)
- Drag-to-reorder within columns, drag-to-transition between columns

## LLM Boundary

Only these operations involve an LLM:

1. **Plan generation** — Task description → ordered stages with validation criteria. Invoked explicitly (user clicks "Generate Plan" or agent proposes).
2. **Code generation** — Runner executes agent in a stage. The agent writes code.
3. **Code review** — `code_review` validation delegates to an LLM agent for judgment.
4. **Feedback interpretation** — (future) Summarize chat feedback into actionable context items.

Everything else is mechanical.

## Migration Strategy

### Phase 1: Persistent Models
- Migrations for projects, epics, tasks, plans, stages, validations
- `Platform.Tasks` context module with CRUD, query functions, status transitions
- Seed data from existing Tasky projects (optional import)

### Phase 2: Plan Engine
- Stage state machine in `Platform.Tasks.PlanEngine`
- Validation registry with deterministic checkers
- Stage progression logic
- Plan approval flow via Review domain

### Phase 3: Context Enrichment
- `Platform.Tasks.ContextPopulator` — walks hierarchy, pushes to ETS
- Integration with `Platform.Execution.ContextSession`
- Deploy target resolution from project config

### Phase 4: Kanban Surface
- `/tasks` LiveView with kanban board
- Real-time PubSub subscriptions
- Task detail panel with plan/stage/validation views
- Chat feedback integration

### Phase 5: Chat Integration
- Feedback push from chat to run context
- Task mention/reference in chat messages
- Run status notifications in chat spaces

## Consequences

### Positive
- Tasks persist beyond run lifecycle — full project history in Postgres
- Deterministic automation eliminates LLM unreliability for mechanical decisions
- Hierarchical context enrichment means runners get full context without manual specification
- Config-driven deploy targets are simple to set up per project
- Plan engine makes execution predictable and observable
- Chat feedback provides a natural human-in-the-loop mechanism

### Negative
- More Postgres tables and migrations to maintain
- Plan engine adds complexity to the execution flow
- Two sources of truth during migration (ETS for runtime, Postgres for persistence) — but this is by design, not a bug

### Not Addressed
- Multi-tenant workspace isolation (deferred)
- Distributed context plane (deferred, per ADR 0011)
- GitHub Actions integration for CI validation (future)
- Tasky data migration tooling (future)

## References

- ADR 0002: Platform Domain Boundaries
- ADR 0011: Execution Runners, Context Plane, Run Control
- ADR 0006: Secure Credential Vault
- `Platform.Context.*` — ETS context plane
- `Platform.Execution.*` — run control
- `Platform.Artifacts.*` — artifact lifecycle
- `output/tasks-architecture.mmd` — architecture diagram
