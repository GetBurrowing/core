# Root-cause: ghost-deleted tasks + `task_list` status-filter false positives

**Task:** `019e24ac-4a51-7db7-b6bc-42c3d4be5820`
**Stage 1 of 7 — reproduce & root-cause writeup (no code change beyond this doc)**
**Audited against:** `origin/main` @ `9a1d9bd4491520819f5bfb30caa063952fe59e79`
**Date:** 2026-05-14

---

## TL;DR — two *independent* bugs

The two observations filed in the parent ticket share a symptom vocabulary
("the engine's view of a task disagrees with reality") but **do not share a
root cause**. They live in different modules, different layers, and either
one could be fixed without touching the other.

| | Obs 1 — ghost-deleted tasks stay engine-alive | Obs 2 — `task_list` status filter false positives |
|---|---|---|
| Layer | Orchestration / context (`Platform.Tasks`, `TaskRouterWatcher`) | Federation MCP tool surface (`ToolSurface`) |
| Defect class | Missing `is_nil(deleted_at)` predicate + missing terminal status/transition + no synchronous router teardown | A `cond` whose branches are mutually exclusive — the status filter is *never applied* when `project_id` is also given |
| Underlying query correctness | The status check itself is fine; the *set of rows* selected is wrong (soft-deleted rows included) | `Tasks.list_tasks_by_status/1` is correct in isolation — it just never runs |
| Denormalization involved? | **No** — `tasks` is the single source of truth; no stale index, no denormalized status column | **No** — same; the filter dispatch logic simply skips the branch |

The parent ticket's speculation ("the same denormalization that lets a
deleted task stay in the queue could explain a list filter that doesn't
re-check current status") is **not supported by the code**. There is no
denormalized task-status index anywhere on the path. Obs 2 is a pure
control-flow bug in one `cond`; Obs 1 is a cluster of three missing guards in
a different subsystem. Reviewers can verify independence by noting that the
Obs 2 fix touches only `tool_surface.ex` + a new `Platform.Tasks.list_tasks/1`,
while the Obs 1 fixes touch `tasks.ex`, `tasks/task.ex`, and
`task_router_watcher.ex` — disjoint file sets.

---

## Observation 1 — ghost-deleted tasks remain alive in the engine

A task that has been "deleted" from the Suite UI (soft-deleted —
`deleted_at` stamped) keeps being dispatched by `TaskRouterWatcher`: every
reconcile cycle it re-qualifies as a should-run task, a `TaskRouter` is
started, no agent picks it up, and a `router stopped` event is emitted.
The two concrete zombies are `019df569-028c-704a-acb4-00b7d096f430` and
`019df569-6051-7fa9-a638-9bc88dcce694` — both `status: "planning"`,
`assignee_type: "agent"`, non-nil `assignee_id`, folded into Task 11 on
2026-05-09.

This is **three distinct defects** that together close every cleanup path:

### 1a. `soft_delete_task/1` never stops the router

`apps/platform/lib/platform/tasks.ex:210-226`

```elixir
def soft_delete_task(%Task{} = task) do
  if task.status in @restricted_delete_statuses do
    {:error, :restricted_status}
  else
    task
    |> Task.changeset(%{deleted_at: DateTime.utc_now()})
    |> Repo.update()
    |> case do
      {:ok, deleted} ->
        broadcast_board({:task_deleted, deleted})
        {:ok, deleted}
      error ->
        error
    end
  end
end
```

It stamps `deleted_at` and broadcasts `{:task_deleted, deleted}` — and
that is all. It does **not** call
`Platform.Orchestration.TaskRouterSupervisor.stop_assignment/1`
(`task_router_supervisor.ex:38`) and does **not** call
`Platform.Orchestration.RuntimeSupervision.abandon_current_lease_for_task/2`
(`runtime_supervision.ex:122`). Contrast with `maybe_finalize_transition/3`
at `tasks.ex:1103-1115`, which *does* tear down the lease + force-dispatch
when a task moves `in_progress → in_review`. The soft-delete path has no
equivalent synchronous teardown.

### 1b. `TaskRouterWatcher` re-selects soft-deleted tasks every reconcile

`apps/platform/lib/platform/orchestration/task_router_watcher.ex`

`@active_statuses` (line 40) is `~w(planning in_progress in_review deploying)`.
A soft-deleted task keeps its `status` — soft delete only touches
`deleted_at` — so a deleted `planning` task is still in `@active_statuses`.

`list_should_run_tasks/0` (lines 305-313):

```elixir
defp list_should_run_tasks do
  from(t in Task,
    where:
      t.assignee_type == "agent" and
        not is_nil(t.assignee_id) and
        t.status in @active_statuses
  )
  |> Repo.all()
end
```

There is **no `is_nil(t.deleted_at)` predicate**. A soft-deleted
`planning` task with an agent assignee matches this query on every
reconcile. `should_run?/1` (lines 130-134) has the identical gap:

```elixir
def should_run?(%{assignee_type: "agent", assignee_id: aid, status: status})
    when not is_nil(aid) and status in @active_statuses,
    do: true

def should_run?(_), do: false
```

— it pattern-matches `assignee_type`, `assignee_id`, `status` but never
inspects `deleted_at`. So even the orphan-router sweep
(`reconcile`, lines 271-302), which stops routers for tasks that "no longer
qualify," will *re-start* the router next cycle because the task still
qualifies. The task is permanently engine-alive.

### 1c. No agent-reachable terminal status for a non-started task

`apps/platform/lib/platform/tasks/task.ex:8`

```elixir
@statuses ~w(backlog planning in_progress in_review deploying done blocked stack_pending)
```

`apps/platform/lib/platform/tasks.ex:62-76` — `@valid_task_transitions`:

```elixir
"backlog"       => ~w(planning blocked in_progress stack_pending),
"planning"      => ~w(in_progress blocked backlog),
"in_progress"   => ~w(in_review deploying blocked done stack_pending),
...
"done"          => ~w(planning),
"stack_pending" => ~w(in_progress blocked backlog)
```

There is **no `cancelled` status in `@statuses` at all**, and **no
transition** from `planning` (or any active state) to a terminal "abandoned"
state. The only terminal status is `done`, reachable solely from
`in_progress`/`in_review`/`deploying`. So an agent trying to clean up a
ghost `planning` task is genuinely stuck:

- `task_complete` → `transition_task_status(task, "done")` → `planning` is
  not in `done`'s allowed set → `{:error, :invalid_transition}` →
  `"Cannot transition task from 'planning' to 'done'"`
  (`tool_surface.ex:2208-2220`).
- `task_update(status: "cancelled")` → `transition_task_status/2` → even if
  `cancelled` were an allowed transition target, the `Task.changeset`'s
  `validate_inclusion(:status, @statuses)` (`task.ex:79`) would reject it
  because `cancelled` is not in `@statuses`. → `{:error, :invalid_transition}`
  (the `transition_task_status/2` guard fails first anyway).
- `report_blocker` needs a `stage_id`; these tasks never had an approved
  plan, so no stage exists.
- UI cancel is unreachable — the task isn't rendered in the UI (it's
  soft-deleted), so there's no affordance.

Every documented cleanup path is closed. This is what the parent ticket
calls "the agent-facing path to clean up these zombies is currently closed."

#### Note on the "error copy references `cancelled`" claim

The parent ticket / plan text says the error copy "references `cancelled`
as if it already existed." Audited against `9a1d9bd`, that is **not quite
accurate** and worth recording so a later stage doesn't go hunting for copy
that isn't there:

- `task_complete`'s invalid-transition message
  (`tool_surface.ex:2214-2220`) says *"only in_progress and in_review can
  move to done"* — no mention of `cancelled`.
- `task_update`'s invalid-transition message (`tool_surface.ex:2312-2318`)
  is generic: *"Invalid status transition from 'X' to 'Y' … Check allowed
  transitions for the current status."*
- A repo-wide `grep "cancelled"` over `apps/platform/lib/` finds matches
  **only** in the unrelated *Execution `Run`* state machine
  (`execution/run.ex`, `execution/run_server.ex`, `agents/*`,
  `control_center/helpers.ex`) — a completely separate status enum for run
  processes, not tasks.

So Stage 3's job is to *introduce* `cancelled` into the Task domain (it does
not exist there at all today) and to *update* the error copy so it points
agents at the new transition — not to "stop referencing something that
already exists." The substance of the plan is right; only the framing of
the copy change should be read as "add helpful copy," not "remove a stale
reference."

### Obs 1 — fix surface (for later stages, not done here)

- Stage 3: add `cancelled` to `Task.@statuses`; keep it soft-deletable
  (`@deletable_statuses`); add `backlog|planning|in_progress|blocked|stack_pending → cancelled`
  to `@valid_task_transitions`, with `"cancelled" => []`.
- Stage 4: add `is_nil(t.deleted_at)` to both `list_should_run_tasks/0` and
  `should_run?/1`; make `soft_delete_task/1` and the cancel path call
  `stop_assignment/1` + `abandon_current_lease_for_task/2` synchronously.
- Stage 5: one-off idempotent Mix task to drive the two known zombies to
  `cancelled` + stop their routers.

---

## Observation 2 — `task_list` status filter returns false positives

`mcp__suite__task_list(project_id: "...", status: "planning")` returns tasks
whose actual `status` is `done`. The parent ticket measured a 67%
false-positive rate (4 of 6 returned tasks were `done`).

### Root cause: a mutually-exclusive `cond` in the MCP handler

`apps/platform/lib/platform/federation/tool_surface.ex:2234-2251`

```elixir
def execute("task_list", args, _context) do
  tasks =
    cond do
      project_id = Map.get(args, "project_id") ->
        Tasks.list_tasks_by_project(project_id)

      epic_id = Map.get(args, "epic_id") ->
        Tasks.list_tasks_by_epic(epic_id)

      status = Map.get(args, "status") ->
        Tasks.list_tasks_by_status(status)

      true ->
        Tasks.list_all_tasks()
    end

  {:ok, Enum.map(tasks, &serialize_task/1)}
end
```

`cond` evaluates branches top-to-bottom and runs **exactly one**. When the
caller passes *both* `project_id` and `status`, the first branch
(`project_id`) truthy-matches, `list_tasks_by_project/1` runs, and the
`status` branch is **never reached**. The status argument is silently
dropped. The result is "every non-deleted task in the project, regardless
of status" — which is exactly the observed false-positive set: the 4 `done`
tasks are real members of the project, they're just not `planning`.

### The underlying query is *correct* — it just never runs

`apps/platform/lib/platform/tasks.ex:318-324`

```elixir
def list_tasks_by_status(status) do
  Task
  |> where([t], t.status == ^status)
  |> where([t], is_nil(t.deleted_at))
  |> order_by([t], desc: t.inserted_at)
  |> Repo.all()
end
```

This filters on the **task-side `t.status`** column directly — there is no
join to a plan, no denormalized index, no staleness. The parent ticket's
three speculated causes ("stale denormalized index," "filter joining on
plan-side status," "only matching initial-load status") are all **ruled
out**: the query is right, it simply isn't invoked when `project_id` is
also present. `list_tasks_by_project/1` (lines 302-308) and
`list_tasks_by_epic/1` (lines 310-316) likewise correctly scope
`is_nil(t.deleted_at)` — none of the three single-filter helpers is buggy
on its own.

### Obs 2 — fix surface (for later stages, not done here)

- Stage 2: add `Platform.Tasks.list_tasks/1` taking `opts` (`project_id`,
  `epic_id`, `status`) and composing one query — base `Task` with
  `is_nil(t.deleted_at)`, then `maybe_filter_project/2`,
  `maybe_filter_epic/2`, and a new `maybe_filter_status/2`. Point the
  `task_list` MCP handler at it. The private `maybe_filter_*` helpers
  already exist at `tasks.ex:791-795` (project + epic); only status is new.
  Legacy single-filter functions stay (or delegate) — no behavior change
  for existing callers.

---

## Independence — explicit verification

1. **Disjoint code.** Obs 1 fixes live in `tasks.ex` (transitions,
   soft-delete teardown), `tasks/task.ex` (status enum), and
   `task_router_watcher.ex` (dispatch predicate). Obs 2's fix lives in
   `tool_surface.ex` (the handler) plus a new composable function in
   `tasks.ex`. The only shared file is `tasks.ex`, and the regions touched
   do not overlap (`@valid_task_transitions` / `soft_delete_task/1` vs. a
   new `list_tasks/1` near the existing `list_tasks_by_*` group).
2. **Disjoint mechanism.** Obs 1 is "the row is selected when it shouldn't
   be" + "no terminal state exists to move it out." Obs 2 is "the right
   query is never called." Neither failure mode can cause the other.
3. **No shared denormalization.** Both paths read `tasks.status` /
   `tasks.deleted_at` directly from Postgres. There is no cached or
   denormalized task-status structure anywhere on either path, so the
   parent ticket's "shared denormalization root cause" hypothesis is
   affirmatively false.
4. **Order-independent fixes.** Stage 2 (Obs 2) could ship before or after
   Stages 3-5 (Obs 1) with no interaction. They are bundled in one ticket
   only because they surfaced in the same 2026-05-13 cleanup attempt.

---

## Reproduction notes

Both observations are reproducible by inspection of `origin/main` @
`9a1d9bd` — no running BEAM required to confirm the defects (the `cond`
fall-through and the missing `where` predicate are statically evident).
The behavioral reproduction the parent ticket already performed:

- **Obs 1:** `task_get(019df569-028c-...)` returns `status: "planning"`;
  the UI returns "not found" (soft-deleted); ~every reconcile interval a
  `Task router stopped for task 019df569-...` event fires. `task_complete`,
  `task_update(status: "cancelled")`, `report_blocker`, and UI-cancel all
  fail as detailed in §1c.
- **Obs 2:** `task_list(project_id: "019d1357-...", status: "planning")`
  returned 6 tasks; per-task `task_get` showed only 2 were actually
  `planning` and 4 were `done`.

The Stage 7 task-level review will exercise the *fixed* behavior end-to-end
on a dev BEAM (seed project + planning/done tasks, drive `task_update` to
`cancelled`, soft-delete and check the orchestration Registry, etc.).
