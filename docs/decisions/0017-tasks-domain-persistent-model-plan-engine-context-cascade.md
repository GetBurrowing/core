# ADR 0017 — Tasks Domain: Persistent Model, Plan Engine, and Context Cascade

**Status:** Proposed  
**Date:** 2026-03-20  
**Epic:** Tasks + Execution  

---

## Context

The platform has a mature execution runtime (ADR 0011) with an ETS-backed context
plane, run control, runner providers, and artifact management. However, there is
no persistent task model — tasks only "exist" while an active run or context
session is alive in ETS. The current `Platform.Tasks` module is a thin read-side
that discovers tasks from runtime state.

To deliver a kanban-style observability surface and support the full plan →
execute → validate → deploy lifecycle, we need:

1. Persistent Postgres-backed models for the project/epic/task/plan hierarchy
2. A deterministic plan engine that drives stage progression without LLM involvement
3. Context cascade that hydrates ETS from the persistent hierarchy at run start
4. A feedback channel that bridges Chat into run context
5. Config-driven deployment targets at the project level

### Design Principles

- **Deterministic automation over LLM delegation.** Status transitions, stage
  progression, validation gating, context assembly, deploy resolution, and
  artifact promotion are all mechanical — no LLM reasoning needed.
- **LLMs at the edges only.** Plan generation from task descriptions, code
  generation/modification, code review (judgment calls), and feedback
  interpretation are where LLMs add genuine value.
- **Static context enrichment.** Each hierarchy level pushes its config and
  description into the ETS context plane. A run's snapshot inherits from all
  ancestor scopes. The executor knows *why* it's doing what it's doing because
  the hierarchy told it — not because an LLM inferred it.
- **ETS for runtime coordination, Postgres for persistence.** ETS context
  sessions are the hot path for run-time state. Postgres is the durable store
  for task/plan/project data and audit history.

---

## Decision

### 1. Persistent Models (Postgres)

#### Projects

```elixir
%Platform.Tasks.Project{
  id: Ecto.UUID,
  workspace_id: Ecto.UUID,  # future: links to Platform.Workspaces
  name: :string,
  description: :string,
  repo_url: :string,         # e.g. "https://github.com/org/repo"
  tech_stack: :map,          # e.g. %{"language" => "elixir", "framework" => "phoenix"}
  deploy_targets: [:map],    # list of deploy target configs (see § Deploy Targets)
  metadata: :map,            # extensible project-level config
  inserted_at: :utc_datetime_usec,
  updated_at: :utc_datetime_usec
}
```

#### Epics

```elixir
%Platform.Tasks.Epic{
  id: Ecto.UUID,
  project_id: Ecto.UUID,    # belongs_to Project
  name: :string,
  description: :string,
  acceptance_criteria: :string,
  status: :string,           # "open" | "in_progress" | "closed"
  metadata: :map,            # ADR refs, constraints, etc.
  inserted_at: :utc_datetime_usec,
  updated_at: :utc_datetime_usec
}
```

#### Tasks

```elixir
%Platform.Tasks.Task{
  id: Ecto.UUID,
  epic_id: Ecto.UUID,       # belongs_to Epic (optional)
  project_id: Ecto.UUID,    # belongs_to Project
  title: :string,
  description: :string,
  status: :string,           # "backlog" | "in_progress" | "in_review" | "done"
  priority: :integer,        # 0 = lowest
  position: :integer,        # ordering within status column
  assignee_type: :string,    # "user" | "agent" | nil
  assignee_id: Ecto.UUID,
  dependencies: [:string],   # list of task IDs this depends on
  metadata: :map,
  inserted_at: :utc_datetime_usec,
  updated_at: :utc_datetime_usec
}
```

#### Plans

```elixir
%Platform.Tasks.Plan{
  id: Ecto.UUID,
  task_id: Ecto.UUID,        # belongs_to Task
  status: :string,           # "draft" | "pending_review" | "approved" | "rejected" | "executing" | "completed"
  version: :integer,         # incremented on re-plan
  created_by: :string,       # "agent:<id>" | "user:<id>"
  metadata: :map,
  inserted_at: :utc_datetime_usec,
  updated_at: :utc_datetime_usec
}
```

#### Stages

```elixir
%Platform.Tasks.Stage{
  id: Ecto.UUID,
  plan_id: Ecto.UUID,        # belongs_to Plan
  position: :integer,        # execution order
  title: :string,
  description: :string,
  status: :string,           # "pending" | "running" | "passed" | "failed" | "skipped"
  expected_artifacts: [:string],  # artifact kinds expected from this stage
  metadata: :map,
  inserted_at: :utc_datetime_usec,
  updated_at: :utc_datetime_usec
}
```

#### Validations

```elixir
%Platform.Tasks.Validation{
  id: Ecto.UUID,
  stage_id: Ecto.UUID,       # belongs_to Stage
  type: :string,             # "ci_check" | "lint_pass" | "type_check" | "test_pass" | "code_review" | "manual_approval"
  status: :string,           # "pending" | "running" | "passed" | "failed" | "skipped"
  config: :map,              # type-specific config (e.g. CI job name, lint command)
  result: :map,              # output from validation run
  evaluated_by: :string,     # "system" | "agent:<id>" | "user:<id>"
  evaluated_at: :utc_datetime_usec,
  inserted_at: :utc_datetime_usec,
  updated_at: :utc_datetime_usec
}
```

### 2. Plan Engine (Deterministic)

The plan engine is a pure state machine — no LLM calls.

#### Stage Progression

```
pending ──[start_stage]──► running
running ──[all validations passed]──► passed
running ──[any validation failed]──► failed
failed ──[retry]──► running
any ──[skip]──► skipped
```

Transitions are driven by `Platform.Tasks.PlanEngine`:

```elixir
Platform.Tasks.PlanEngine.advance(plan_id)
# Checks current stage's validations. If all passed, moves to next stage.
# If any failed, marks stage as failed. If no next stage, completes plan.

Platform.Tasks.PlanEngine.evaluate_validation(validation_id, result)
# Records result for a validation. If this was the last pending validation
# for the stage, triggers advance/1 automatically.
```

#### Validation Type Registry

Each validation type has a deterministic evaluation path:

| Type | Evaluation | Deterministic? |
|------|-----------|----------------|
| `ci_check` | Poll CI status via GitHub API | Yes |
| `lint_pass` | Check runner exit code | Yes |
| `type_check` | Check runner exit code | Yes |
| `test_pass` | Check runner exit code + parse results | Yes |
| `code_review` | Delegate to LLM agent | No — LLM boundary |
| `manual_approval` | Wait for human gate in Review domain | No — human gate |

The engine does not care *how* a validation result arrives. It only cares
that `evaluate_validation/2` is called with a pass/fail result. This keeps
the engine deterministic while allowing heterogeneous validation sources.

### 3. Context Cascade (Hydration)

When a run starts for a task, the persistent hierarchy is hydrated into ETS:

```elixir
Platform.Tasks.ContextHydrator.hydrate_for_run(task, run) do
  # 1. Load task's project → push project config into project-scoped ETS session
  #    Items: repo_url, tech_stack, deploy_targets, project description
  
  # 2. Load task's epic (if any) → push into epic-scoped ETS session
  #    Items: epic goals, acceptance criteria, constraints
  
  # 3. Push task description, requirements, dependencies into task-scoped ETS session
  
  # 4. Load approved plan + stages → push into task-scoped ETS session
  #    Items: stage descriptions, validation criteria, expected artifacts
  
  # 5. Run's ContextSession.snapshot/1 inherits all ancestor scopes automatically
end
```

This is a one-time, deterministic data load at run start. No LLM involvement.
The runner receives a fully assembled context snapshot that includes everything
from the project down to the current stage's validation criteria.

### 4. Feedback Channel

Feedback from any source is a context push into the run scope:

```elixir
# From Chat surface
Platform.Tasks.Feedback.push(run_id, %{
  source: :chat,
  author: "user:alex",
  content: "Use postgres instead of sqlite",
  timestamp: DateTime.utc_now()
})

# From UI review
Platform.Tasks.Feedback.push(run_id, %{
  source: :review,
  author: "user:alex",
  content: "Approved with changes: add error handling",
  timestamp: DateTime.utc_now()
})
```

This writes a context item with `kind: :feedback` into the run's ETS session.
The runner receives it as a delta via PubSub. Stale/dead detection applies —
the runner must ack the feedback.

### 5. Deploy Targets (Config-Driven)

Deploy targets are stored on the Project model:

```elixir
deploy_targets: [
  %{
    "name" => "production",
    "type" => "docker_compose",
    "config" => %{
      "host" => "deploy@192.0.2.12",
      "stack_path" => "~/docker/stacks/my-app",
      "image_registry" => "ghcr.io/org/repo",
      "watchtower" => true,
      "env_file" => ".env.production"
    }
  },
  %{
    "name" => "staging",
    "type" => "fly",
    "config" => %{
      "app" => "my-app-staging",
      "region" => "ord"
    }
  }
]
```

At run start, the active deploy target config is pushed into the project-scoped
ETS session. The deployer stage reads it from the context snapshot and resolves
it into runner env vars via `Platform.Execution.CredentialLease`.

No LLM reasoning about deployment — it's pure config resolution.

### 6. Tasks Surface (Kanban Board)

The LiveView kanban board at `/tasks`:

- Four columns: Backlog, In Progress, In Review, Done
- Task cards show: title, assignee, priority badge, active run indicator, current stage progress bar
- Drag-to-reorder within and across columns (status change on drop)
- Project filter/switcher in header
- Task detail panel: description, plan stages with validation status, artifact list, feedback thread, run history
- Real-time updates via PubSub (no polling)

Subscribes to:
- `"tasks:project:<project_id>"` — task status changes, new tasks
- `"execution:runs:<task_id>"` — run status for active tasks
- `"ctx:<task_id>"` — context changes (feedback, stage progression)
- `Platform.Artifacts.task_topic(task_id)` — artifact events

---

## Migration Plan

### Phase 1: Persistent Models + Basic CRUD
- Ecto schemas, migrations, changesets for Project, Epic, Task, Plan, Stage, Validation
- `Platform.Tasks` context module with CRUD operations
- Seeds for development

### Phase 2: Plan Engine
- `Platform.Tasks.PlanEngine` — stage state machine, validation evaluation, auto-advance
- `Platform.Tasks.ValidationRegistry` — typed validation definitions
- Unit tests for all state transitions

### Phase 3: Context Hydrator
- `Platform.Tasks.ContextHydrator` — loads persistent hierarchy into ETS at run start
- Integration with existing `Platform.Execution.start_run/2`
- Tests verifying snapshot contains full hierarchy data

### Phase 4: Feedback Channel
- `Platform.Tasks.Feedback` — push feedback as context items
- Bridge from Chat surface messages tagged with task context

### Phase 5: Kanban Surface
- `PlatformWeb.TasksLive` — kanban board with real-time updates
- Wire into Burrow shell at `/tasks` route
- Task detail panel with plan/stage/validation/artifact views

### Phase 6: Deploy Target Resolution
- Config-driven deploy target model on Project
- Context injection at run start
- Integration with CredentialLease for runner env

---

## Consequences

**Positive:**
- Persistent task model survives process restarts and node crashes
- Deterministic plan engine removes LLM from mechanical decisions
- Context cascade provides full static enrichment without inference
- Feedback channel enables human-in-the-loop during execution
- Config-driven deploy targets are simple to set up per project
- Clean separation: Postgres for persistence, ETS for runtime, PubSub for reactivity

**Negative / Trade-offs:**
- Adds database schema and migrations (more to manage)
- Context hydration adds a synchronous step at run start (acceptable — one-time load)
- Plan engine is rigid by design — custom validation types require code changes to the registry

**Guardrails:**
- Never put LLM calls in the plan engine or context hydrator
- Never bypass the validation registry for stage progression
- Keep deploy target config as plain data — no executable logic in the config
- Audit all status transitions via Platform.Audit telemetry events

---

## References

- ADR 0002: Platform Domain Boundaries (Tasks surface vs Execution domain)
- ADR 0005: Event Stream Architecture (audit telemetry for transitions)
- ADR 0009: Burrow Shell Architecture (kanban surface mounting)
- ADR 0011: Execution Runners (context plane, run control, artifacts)
- `Platform.Tasks` — existing thin read-side module
- `Platform.Context` — ETS context plane
- `Platform.Execution` — run lifecycle
- `Platform.Artifacts` — artifact registration and publication
