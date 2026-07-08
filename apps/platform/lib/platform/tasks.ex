defmodule Platform.Tasks do
  @moduledoc """
  Persistent context for the Tasks domain.

  Manages the full hierarchy: Projects → Epics → Tasks → Plans → Stages →
  Validations, backed by Postgres. Also preserves the original ETS-based
  read-side for backward compatibility with the proof-of-life flow.

  ## Proof-of-life run

  `launch_proof_run/2` wires together the execution/context/artifact planes for
  an end-to-end proof that the product plumbing works. See
  `Platform.Execution.ProofRun` for the full orchestration details.
  """

  import Ecto.Query

  require Logger

  alias Platform.{Artifacts, Context, Execution}
  alias Platform.Context.Session
  alias Platform.Execution.Run
  alias Platform.Orchestration.{RuntimeSupervision, TaskRouterSupervisor, TaskRouterWatcher}
  alias Platform.Repo

  alias Platform.Tasks.{Epic, Plan, PlanEngine, Project, ReviewRequest, Stage, Task, Validation}

  # ── Legacy summary/detail structs (backward compat) ──────────────────────

  defmodule Summary do
    @moduledoc false
    defstruct task_id: nil,
              run_count: 0,
              active_run_count: 0,
              artifact_count: 0,
              latest_run: nil,
              latest_activity_at: nil,
              context_version: nil,
              context_status: :empty,
              proof_branch: nil,
              proof_verification: nil,
              proof_pushed: false
  end

  defmodule Detail do
    @moduledoc false
    defstruct summary: nil,
              runs: [],
              artifacts: [],
              context_session: nil,
              context_items: [],
              recent_deltas: []
  end

  @type summary :: %Summary{}
  @type detail :: %Detail{}

  # ── Valid status transitions (ADR 0018 §7, ADR 0029) ─────────────────────
  #
  # Per ADR 0029, plan approval is the start signal — there is no separate
  # `ready` gate. A task in `planning` whose plan reaches `approved`
  # transitions deterministically into `in_progress` via `approve_plan/2`.

  @valid_task_transitions %{
    "backlog" => ~w(planning blocked in_progress stack_pending cancelled),
    "planning" => ~w(in_progress blocked backlog cancelled),
    "in_progress" => ~w(in_review deploying blocked done stack_pending cancelled),
    # ADR 0041 (task 019e2be4): `done` is reachable from `in_review` for stack
    # members whose terminal transition is the rollup-PR merge fan-out — they
    # never own a per-task deploy stage, so they jump in_review → done. Solo
    # tasks still ride in_review → deploying → done because the engine auto-
    # injects a per-task deploy stage for them; this widening is safe because
    # the automated pipeline only emits in_review → done from the stack
    # rollup-PR webhook fan-out path.
    "in_review" => ~w(deploying in_progress blocked done),
    "deploying" => ~w(done in_progress blocked),
    "blocked" => ~w(backlog planning in_progress in_review deploying cancelled),
    "done" => ~w(planning),
    # ADR 0041 stack lifecycle: `stack_pending` is the "deps not yet rollup-merged"
    # waiting state. The dispatcher (TaskRouterWatcher) intentionally does NOT
    # treat `stack_pending` as active — see `@active_statuses` there. A
    # `stack_pending` task is promoted to `in_progress` only via the in-stack
    # unblock sweep (`Stacks.try_promote/1`), never directly by the dispatcher.
    "stack_pending" => ~w(in_progress blocked backlog cancelled),
    # Task 019e24ac stage 3: `cancelled` is an agent-reachable terminal status
    # for fold/supersede. No outbound transitions — once an agent or operator
    # cancels a task, it stays cancelled. To revive, create a new task.
    "cancelled" => []
  }

  # ── Projects ─────────────────────────────────────────────────────────────

  @doc """
  PubSub topic for project lifecycle signals (e.g. `{:project_created, project}`).

  Long-lived subscribers (`Platform.Meetings.MeetingNotifier` and friends)
  subscribe to this topic at boot so projects created post-boot trigger a
  dynamic subscribe to the new project's downstream topics. The pre-existing
  `Platform.Meetings.project_meetings_meta_topic/0` only fires on first
  meeting creation, which is too late for subscribers that need to attach
  before any meeting exists.
  """
  @spec projects_lifecycle_topic() :: String.t()
  def projects_lifecycle_topic, do: "projects:lifecycle"

  @doc """
  Subscribe the calling process to the project lifecycle topic.
  """
  @spec subscribe_to_projects_lifecycle() :: :ok | {:error, term()}
  def subscribe_to_projects_lifecycle do
    Phoenix.PubSub.subscribe(Platform.PubSub, projects_lifecycle_topic())
  end

  @doc """
  Creates a project.

  Per ADR 0042, every project must belong to an org. When `attrs` does not
  carry `:org_id` / `"org_id"`, the project is attached to the root Fabrikam org
  so legacy callers (and tests pre-dating the topology change) continue to
  work without an explicit assignment.

  On successful insert broadcasts `{:project_created, project}` on
  `projects_lifecycle_topic/0` so long-lived subscribers can attach to the
  new project's downstream topics dynamically.
  """
  def create_project(attrs) do
    case %Project{}
         |> Project.changeset(default_org_id(attrs))
         |> Repo.insert() do
      {:ok, project} = ok ->
        Phoenix.PubSub.broadcast(
          Platform.PubSub,
          projects_lifecycle_topic(),
          {:project_created, project}
        )

        ok

      error ->
        error
    end
  end

  defp default_org_id(attrs) do
    cond do
      Map.has_key?(attrs, :org_id) or Map.has_key?(attrs, "org_id") ->
        attrs

      is_map(attrs) and not is_struct(attrs) ->
        case Platform.Tenancy.get_org_by_slug("fabrikam") do
          %Platform.Tenancy.Org{id: id} -> Map.put(attrs, :org_id, id)
          nil -> attrs
        end

      true ->
        attrs
    end
  end

  def update_project(%Project{} = project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  def get_project(id), do: Repo.get(Project, id)

  def get_project_by_slug(slug) do
    Repo.get_by(Project, slug: slug)
  end

  @doc """
  List projects, optionally filtered by org.

  ## Options

    * `:org_id` — only return projects belonging to this org (ADR-0042).
      Omit / `nil` → returns every project.
    * `:preload` — Ecto preload spec (atom or list) applied to the result.
      Stage 5 of ADR-0042 uses `preload: :org` so the sidebar group-by-org
      template can read `project.org.slug` without a per-row Repo hit.
  """
  def list_projects(opts \\ []) do
    org_id = Keyword.get(opts, :org_id)
    preload = Keyword.get(opts, :preload, [])

    Project
    |> maybe_filter_projects_org(org_id)
    |> order_by([p], asc: p.name)
    |> Repo.all()
    |> Repo.preload(preload)
  end

  defp maybe_filter_projects_org(query, nil), do: query

  defp maybe_filter_projects_org(query, org_id) when is_binary(org_id) do
    where(query, [p], p.org_id == ^org_id)
  end

  # ── Epics ────────────────────────────────────────────────────────────────

  def create_epic(attrs) do
    %Epic{}
    |> Epic.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, epic} ->
        broadcast_board({:epic_created, epic})
        {:ok, epic}

      error ->
        error
    end
  end

  def update_epic(%Epic{} = epic, attrs) do
    epic
    |> Epic.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        broadcast_board({:epic_updated, updated})
        {:ok, updated}

      error ->
        error
    end
  end

  def get_epic(id), do: Repo.get(Epic, id)

  def list_epics(project_id) do
    Epic
    |> where([e], e.project_id == ^project_id)
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
  end

  @doc "List epics for the dropdown — scoped to project if given, otherwise all."
  def list_epics_for_project(nil) do
    Epic
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
  end

  def list_epics_for_project(project_id), do: list_epics(project_id)

  @doc "Return %{epic_id => %{total: n, done: n}} for a list of epic IDs in one query."
  def epic_task_counts(epic_ids) when is_list(epic_ids) do
    Task
    |> where([t], t.epic_id in ^epic_ids)
    |> where([t], is_nil(t.deleted_at))
    |> group_by([t], t.epic_id)
    |> select(
      [t],
      {t.epic_id, count(t.id), fragment("count(*) filter (where ? = 'done')", t.status)}
    )
    |> Repo.all()
    |> Map.new(fn {epic_id, total, done} -> {epic_id, %{total: total, done: done}} end)
  end

  # ── Tasks (persistent) ──────────────────────────────────────────────────

  def create_task(attrs) do
    %Task{}
    |> Task.changeset(attrs)
    |> Repo.insert()
  end

  def update_task(%Task{} = task, attrs) do
    task
    |> Task.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        preloaded = Repo.preload(updated, [:project, :epic, :sponsor, plans: :stages])
        broadcast_board({:task_updated, preloaded})
        maybe_sweep_stack_after_update(task, updated)
        {:ok, updated}

      error ->
        error
    end
  end

  # ADR 0041 stack-internal dep sweep. When a stack member's
  # `metadata["merged_into_rollup_at"]` transitions from nil/absent to a
  # value, promote any `stack_pending` members whose deps just cleared.
  #
  # This is a separate code path from the existing done-threshold sweep
  # (`sweep_unblocked_dependents/1` below): different source-task status
  # (any, vs. `done`), different candidate-task status (`stack_pending`
  # vs. `blocked`), different threshold (rollup-merge vs. `done`). They
  # do not overlap.
  defp maybe_sweep_stack_after_update(%Task{} = before, %Task{stack_id: stack_id} = after_task)
       when is_binary(stack_id) do
    before_stamp = stamp(before.metadata)
    after_stamp = stamp(after_task.metadata)

    if is_nil(before_stamp) and not is_nil(after_stamp) do
      Platform.Tasks.Stacks.sweep_stack_dependents(after_task)
    end

    :ok
  end

  defp maybe_sweep_stack_after_update(_before, _after_task), do: :ok

  defp stamp(%{} = metadata), do: Map.get(metadata, "merged_into_rollup_at")
  defp stamp(_), do: nil

  # ── Soft delete ─────────────────────────────────────────────────────────

  @restricted_delete_statuses ~w(in_progress in_review deploying)

  @doc """
  Soft-delete a task by setting `deleted_at`.

  Refuses to delete tasks whose status is in_progress, in_review, or deploying.
  Returns `{:ok, task}` or `{:error, :restricted_status}`.
  """
  def soft_delete_task(%Task{} = task) do
    if task.status in @restricted_delete_statuses do
      {:error, :restricted_status}
    else
      task
      |> Task.changeset(%{deleted_at: DateTime.utc_now()})
      |> Repo.update()
      |> case do
        {:ok, deleted} ->
          # Stage 4: tear down router + lease synchronously so a
          # soft-deleted task leaves the dispatch queue immediately
          # instead of waiting on the 5-minute reconcile sweep. Mirrors
          # the pattern used by `maybe_finalize_transition/3` for the
          # in_progress→in_review hand-off below.
          TaskRouterSupervisor.stop_assignment(deleted.id)
          RuntimeSupervision.abandon_current_lease_for_task(deleted.id, "execution")

          broadcast_board({:task_deleted, deleted})
          {:ok, deleted}

        error ->
          error
      end
    end
  end

  @doc """
  Get a task record from Postgres (no ETS merge).

  Preloads `:sponsor` so MCP callers (`task_get`, `task_update`,
  `task_attach_canvas` per ADR 0042) see the sponsor without a follow-up
  query. Extending here rather than at each caller keeps the sweep
  centralized.
  """
  def get_task_record(id) do
    case Repo.get(Task, id) do
      nil -> nil
      %Task{} = task -> Repo.preload(task, :sponsor)
    end
  end

  # ── Dependency helpers (canonical readers) ──────────────────────────────
  #
  # The JSONB shape is `[%{"task_id" => uuid, "kind" => "blocks"}, ...]`.
  # These helpers are the single canonical reader so the shape isn't
  # reinterpreted in five places (gate, sweep, UI, MCP tool, etc.).

  @doc """
  Return the dependency task ids for a task.

  Accepts a `%Task{}` struct or a task id string. Returns `[]` for unknown
  ids or tasks with no deps. Always returns the raw string ids exactly as
  stored — no UUID normalization.
  """
  @spec dependency_task_ids(Task.t() | String.t()) :: [String.t()]
  def dependency_task_ids(%Task{dependencies: deps}) when is_list(deps) do
    deps
    |> Enum.map(& &1["task_id"])
    |> Enum.reject(&is_nil/1)
  end

  def dependency_task_ids(%Task{}), do: []

  def dependency_task_ids(id) when is_binary(id) do
    case get_task_record(id) do
      %Task{} = task -> dependency_task_ids(task)
      nil -> []
    end
  end

  @doc """
  Return the subset of a task's dependencies whose status is not `"done"`.

  Accepts a `%Task{}` struct or a task id string. Self-references and
  unknown ids (declared as deps but absent from the DB) are silently
  dropped.

  Returns `[%{id, title, status}]` — a thin shape suitable for surfacing
  in UI / blocker messages without leaking the full Task schema.
  """
  @spec unmet_dependencies(Task.t() | String.t()) :: [
          %{id: String.t(), title: String.t(), status: String.t()}
        ]
  def unmet_dependencies(%Task{} = task) do
    ids =
      task
      |> dependency_task_ids()
      |> Enum.reject(&(&1 == task.id))
      |> Enum.uniq()

    case ids do
      [] ->
        []

      ids ->
        Repo.all(
          from(t in Task,
            where: t.id in ^ids,
            select: %{id: t.id, title: t.title, status: t.status}
          )
        )
        |> Enum.reject(&(&1.status == "done"))
    end
  end

  def unmet_dependencies(id) when is_binary(id) do
    case get_task_record(id) do
      %Task{} = task -> unmet_dependencies(task)
      nil -> []
    end
  end

  # ── Dependency edge helpers (atomic JSONB read-modify-write) ────────────
  #
  # `add_dependency/3` and `remove_dependency/3` are the canonical edge-level
  # mutators for the `task.dependencies` JSONB column. They take a `%Task{}`
  # struct (or task id), a target task id, and an optional `kind` (default
  # `"blocks"`), and append/remove the matching `%{"task_id", "kind"}` entry.
  # The new list is written via `update_task/2` so the existing changeset
  # (`validate_dependencies/1` in `Platform.Tasks.Task`) and the
  # `{:task_updated, task}` board broadcast both run.
  #
  # These helpers are stack-agnostic: no DAG validation, no membership
  # checks, no cross-stack guard. The DAG/stack-scoped semantics are layered
  # on top in `Platform.Tasks.Stacks` inside a `Repo.transaction` so they can
  # roll back cleanly. See ADR 0041.

  @doc """
  Append a dependency edge `(target_task_id, kind)` to `task.dependencies`.

  Accepts a `%Task{}` struct or a task id string. `kind` defaults to
  `"blocks"`. Returns `{:ok, updated_task}` on success.

  Errors:
    * `{:error, :task_not_found}` — given task id has no record
    * `{:error, :self_edge}` — `target_task_id` equals the task's own id
    * `{:error, :duplicate_edge}` — the same `(target_task_id, kind)` pair
      already exists on the task

  This is a pure single-row update against the dependencies JSONB list. It
  performs no DAG validation, no membership check, and no cross-stack guard
  — those are layered on top by `Platform.Tasks.Stacks` for the in-stack
  MCP tools.
  """
  @spec add_dependency(Task.t() | String.t(), String.t(), String.t()) ::
          {:ok, Task.t()}
          | {:error, :task_not_found | :self_edge | :duplicate_edge | Ecto.Changeset.t()}
  def add_dependency(task_or_id, target_task_id, kind \\ "blocks")

  def add_dependency(%Task{} = task, target_task_id, kind)
      when is_binary(target_task_id) and is_binary(kind) do
    cond do
      target_task_id == task.id ->
        {:error, :self_edge}

      edge_present?(task.dependencies, target_task_id, kind) ->
        {:error, :duplicate_edge}

      true ->
        new_deps = (task.dependencies || []) ++ [%{"task_id" => target_task_id, "kind" => kind}]
        update_task(task, %{dependencies: new_deps})
    end
  end

  def add_dependency(id, target_task_id, kind) when is_binary(id) do
    case get_task_record(id) do
      %Task{} = task -> add_dependency(task, target_task_id, kind)
      nil -> {:error, :task_not_found}
    end
  end

  @doc """
  Remove the dependency edge `(target_task_id, kind)` from `task.dependencies`.

  Accepts a `%Task{}` struct or a task id string. `kind` defaults to
  `"blocks"`. Returns `{:ok, updated_task}` on success.

  Errors:
    * `{:error, :task_not_found}` — given task id has no record
    * `{:error, :not_an_edge}` — no entry matching `(target_task_id, kind)`
      exists on the task; callers can disambiguate this from a successful
      idempotent removal

  Like `add_dependency/3`, this is stack-agnostic — no DAG validation, no
  membership checks. Cycle detection on removal is unnecessary, but the
  Stacks-layer wrapper still runs `validate_dag/1` defensively.
  """
  @spec remove_dependency(Task.t() | String.t(), String.t(), String.t()) ::
          {:ok, Task.t()}
          | {:error, :task_not_found | :not_an_edge | Ecto.Changeset.t()}
  def remove_dependency(task_or_id, target_task_id, kind \\ "blocks")

  def remove_dependency(%Task{} = task, target_task_id, kind)
      when is_binary(target_task_id) and is_binary(kind) do
    deps = task.dependencies || []

    if edge_present?(deps, target_task_id, kind) do
      new_deps =
        Enum.reject(deps, fn dep ->
          dep["task_id"] == target_task_id and dep["kind"] == kind
        end)

      update_task(task, %{dependencies: new_deps})
    else
      {:error, :not_an_edge}
    end
  end

  def remove_dependency(id, target_task_id, kind) when is_binary(id) do
    case get_task_record(id) do
      %Task{} = task -> remove_dependency(task, target_task_id, kind)
      nil -> {:error, :task_not_found}
    end
  end

  defp edge_present?(deps, target_task_id, kind) when is_list(deps) do
    Enum.any?(deps, fn dep ->
      dep["task_id"] == target_task_id and dep["kind"] == kind
    end)
  end

  defp edge_present?(_deps, _target_task_id, _kind), do: false

  def list_tasks_by_project(project_id) do
    Task
    |> where([t], t.project_id == ^project_id)
    |> where([t], is_nil(t.deleted_at))
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
  end

  def list_tasks_by_epic(epic_id) do
    Task
    |> where([t], t.epic_id == ^epic_id)
    |> where([t], is_nil(t.deleted_at))
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
  end

  def list_tasks_by_status(status) do
    Task
    |> where([t], t.status == ^status)
    |> where([t], is_nil(t.deleted_at))
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
  end

  @doc """
  List non-deleted tasks, AND-composing whatever filters are supplied.

  Takes an opts keyword list and applies each present filter together in a
  single query — unlike the legacy single-purpose `list_tasks_by_*`
  helpers, which can only express one filter at a time. This is the
  composable entry point the `task_list` MCP handler uses so that, e.g.,
  `project_id` + `status` together returns only matching-status tasks in
  that project (no false positives).

  ## Options

    * `:project_id` — scope to a project
    * `:epic_id` — scope to an epic
    * `:status` — scope to a task-side status (`t.status`)

  Unrecognized or `nil` options are ignored. With an empty list, returns all
  non-deleted tasks (equivalent to `list_tasks_by_*` with no filter).

  Note: this is `list_tasks/1` — distinct from the legacy ETS-based
  `list_tasks/0` read-side below. It is defined without a default argument
  on purpose so it does not collide with that arity-0 function.
  """
  @spec list_tasks(keyword()) :: [Task.t()]
  def list_tasks(opts) when is_list(opts) do
    project_id = Keyword.get(opts, :project_id)
    epic_id = Keyword.get(opts, :epic_id)
    status = Keyword.get(opts, :status)

    Task
    |> where([t], is_nil(t.deleted_at))
    |> maybe_filter_project(project_id)
    |> maybe_filter_epic(epic_id)
    |> maybe_filter_status(status)
    |> order_by([t], desc: t.inserted_at)
    # Preload :sponsor so the MCP `task_list` envelope carries the
    # human-shepherd shape without an N+1 (ADR 0042). Matches the
    # get_task_record/1 preload so both call paths see the same fields.
    |> preload(:sponsor)
    |> Repo.all()
  end

  @doc """
  Returns tasks whose `updated_at` falls within the given window.

  Used by the Historian's activity digest to surface tasks that changed
  status, gained/lost assignees, or were otherwise touched in the window.
  Captures current state only — if a task transitioned multiple times
  within the window, only the latest status is observable.

  ## Options

    * `:window_end` — upper bound (exclusive); default `DateTime.utc_now/0`
  """
  @spec list_tasks_updated_since(DateTime.t(), keyword()) :: [Task.t()]
  def list_tasks_updated_since(%DateTime{} = window_start, opts \\ []) do
    window_end = Keyword.get(opts, :window_end, DateTime.utc_now())

    from(t in Task,
      where:
        t.updated_at >= ^window_start and
          t.updated_at < ^window_end and
          is_nil(t.deleted_at),
      order_by: [asc: t.updated_at]
    )
    |> Repo.all()
  end

  @doc """
  Transition a task's status, enforcing valid transitions per ADR 0018 §7.
  """
  def transition_task_status(%Task{} = task, new_status) do
    allowed = Map.get(@valid_task_transitions, task.status, [])

    if new_status in allowed do
      task
      |> Task.changeset(%{status: new_status})
      |> Repo.update()
      |> case do
        {:ok, updated} = ok ->
          maybe_dispatch_teardown(updated, new_status)
          ok

        error ->
          error
      end
    else
      {:error, :invalid_transition}
    end
  end

  # Stage 4: cancellation is terminal (see @valid_task_transitions —
  # `cancelled` has no outbound edges). Tear down the running router and
  # any active execution lease synchronously so an agent that flips a
  # task to `cancelled` removes it from the dispatch queue immediately
  # instead of leaving a dangling router until the next reconcile sweep.
  #
  # Lives here (not just in `maybe_finalize_transition/3`) because the
  # MCP `task_update` tool calls `transition_task_status/2` directly,
  # bypassing `transition_task/2`. Both paths need the teardown.
  defp maybe_dispatch_teardown(%Task{} = task, "cancelled") do
    TaskRouterSupervisor.stop_assignment(task.id)
    RuntimeSupervision.abandon_current_lease_for_task(task.id, "execution")
    :ok
  end

  defp maybe_dispatch_teardown(_task, _new_status), do: :ok

  @doc """
  Resolve the effective deploy strategy for a task.

  Resolution order:
  1. `task.deploy_strategy` (task-level override)
  2. `project.deploy_config["default_strategy"]` (project default)
  3. `%{"type" => "manual"}` (system fallback)

  The task must have `:project` preloaded, or be loaded with project.
  """
  def resolve_deploy_strategy(%Task{} = task) do
    task = ensure_project_loaded(task)

    task.deploy_strategy ||
      get_in(task.project && task.project.deploy_config, ["default_strategy"]) ||
      %{"type" => "manual"}
  end

  @doc "Ensures the task has its project association loaded."
  def ensure_project_loaded(%Task{project: %Project{}} = task), do: task
  def ensure_project_loaded(%Task{} = task), do: Repo.preload(task, :project)

  # ── Plans ────────────────────────────────────────────────────────────────

  def create_plan(attrs) do
    case task_id_from(attrs) do
      nil ->
        do_create_plan(attrs)

      task_id ->
        case latest_plan(task_id) do
          %Plan{status: status} when status in ["draft", "pending_review"] ->
            {:error, :plan_pending_review}

          _ ->
            do_create_plan(attrs)
        end
    end
  end

  defp do_create_plan(attrs) do
    attrs = maybe_set_plan_version(attrs)

    %Plan{}
    |> Plan.changeset(attrs)
    |> Repo.insert()
  end

  defp task_id_from(%{task_id: id}) when is_binary(id), do: id
  defp task_id_from(%{"task_id" => id}) when is_binary(id), do: id
  defp task_id_from(_), do: nil

  def get_plan(id) do
    Plan
    |> Repo.get(id)
    |> Repo.preload(:stages)
  end

  @doc "Get the latest approved plan for a task."
  def current_plan(task_id) do
    Plan
    |> where([p], p.task_id == ^task_id and p.status in ["approved", "completed"])
    |> order_by([p], desc: p.version)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> nil
      plan -> Repo.preload(plan, stages: :validations)
    end
  end

  @doc "Returns the latest plan for a task regardless of status (draft, pending_review, etc.)."
  def latest_plan(task_id) do
    Plan
    |> where([p], p.task_id == ^task_id)
    |> order_by([p], desc: p.version)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> nil
      plan -> Repo.preload(plan, stages: :validations)
    end
  end

  def list_plans(task_id) do
    Plan
    |> where([p], p.task_id == ^task_id)
    |> order_by([p], asc: p.version)
    |> Repo.all()
  end

  def submit_plan_for_review(%Plan{status: "draft"} = plan) do
    case plan |> Plan.changeset(%{status: "pending_review"}) |> Repo.update() do
      {:ok, updated} ->
        broadcast_board({:plan_updated, updated})
        maybe_auto_approve(updated)

      error ->
        error
    end
  end

  def submit_plan_for_review(_plan), do: {:error, :invalid_transition}

  # Auto-approve branch (task 019f25f2 stage 2): if the parent task has the
  # opt-in `auto_approve_plan` flag set AND the precondition passes (plan has
  # stages, task has execution + review assignees), immediately funnel the
  # freshly-submitted plan through `approve_plan/3` with the `auto: true`
  # opts flag so it lands `approved` and stamps `auto_approved_at`. On skip
  # (precondition fails) we leave the plan in `pending_review` and log so
  # operators can tell why a flag-on task didn't auto-approve.
  defp maybe_auto_approve(%Plan{} = plan) do
    task = Repo.get!(Task, plan.task_id)

    if task.auto_approve_plan do
      case auto_approve_precondition(task, plan) do
        :ok ->
          case approve_plan(plan, "system:auto", auto: true) do
            {:ok, approved_plan} ->
              :telemetry.execute(
                [:platform, :plan, :auto_approved],
                %{count: 1},
                %{
                  task_id: task.id,
                  plan_id: approved_plan.id,
                  resource_type: "plan",
                  resource_id: approved_plan.id,
                  action: "auto_approved",
                  actor_type: "system"
                }
              )

              {:ok, approved_plan}

            {:error, reason} = err ->
              Logger.warning(
                "auto_approve_plan: approve_plan failed task_id=#{task.id} plan_id=#{plan.id} reason=#{inspect(reason)}"
              )

              err
          end

        {:skip, reason} ->
          Logger.warning(
            "auto_approve_plan skipped task_id=#{task.id} plan_id=#{plan.id} reason=#{reason}"
          )

          :telemetry.execute(
            [:platform, :plan, :auto_approve_skipped],
            %{count: 1},
            %{
              task_id: task.id,
              plan_id: plan.id,
              reason: reason,
              resource_type: "plan",
              resource_id: plan.id,
              action: "auto_approve_skipped",
              actor_type: "system"
            }
          )

          {:ok, plan}
      end
    else
      {:ok, plan}
    end
  end

  # Preconditions for auto-approve. Because plans don't carry per-stage
  # assignees (only the task carries per-phase assignees via
  # `phase_assignees`), the "agent assigned for all stages" check reduces to:
  # the plan has at least one stage, and the task has an assignee for both
  # the execution and review phases.
  @spec auto_approve_precondition(%Task{}, %Plan{}) :: :ok | {:skip, atom()}
  defp auto_approve_precondition(%Task{} = task, %Plan{} = plan) do
    stages = plan_stages(plan)

    cond do
      stages == [] ->
        {:skip, :empty_plan}

      match?({nil, _}, assignee_for_phase(task, "execution")) ->
        {:skip, :no_execution_assignee}

      match?({nil, _}, assignee_for_phase(task, "review")) ->
        {:skip, :no_review_assignee}

      true ->
        :ok
    end
  end

  # Return plan.stages, preloading from Repo if the association wasn't
  # loaded on the passed-in struct. Avoids requiring callers to preload.
  defp plan_stages(%Plan{stages: %Ecto.Association.NotLoaded{}} = plan) do
    plan |> Repo.preload(:stages) |> Map.get(:stages)
  end

  defp plan_stages(%Plan{stages: stages}) when is_list(stages), do: stages
  defp plan_stages(_), do: []

  def approve_plan(plan, approved_by, opts \\ [])

  def approve_plan(%Plan{status: "pending_review"} = plan, approved_by, opts) do
    now = DateTime.utc_now()
    auto? = Keyword.get(opts, :auto, false)

    approve_attrs =
      %{status: "approved", approved_by: approved_by, approved_at: now}
      |> then(fn attrs ->
        if auto?, do: Map.put(attrs, :auto_approved_at, now), else: attrs
      end)

    Repo.transaction(fn ->
      # Auto-supersede any older sibling plans that are still active
      # (`approved` or `completed`). Manual rejections (`rejected`) are
      # left untouched so the original `rejection_reason` is preserved.
      siblings =
        from(p in Plan,
          where:
            p.task_id == ^plan.task_id and p.id != ^plan.id and
              p.status in ["approved", "completed"]
        )
        |> Repo.all()

      superseded_siblings =
        Enum.map(siblings, fn sibling ->
          sibling
          |> Plan.changeset(%{
            status: "rejected",
            superseded_by_plan_id: plan.id,
            rejection_reason: "Superseded by plan v#{plan.version}"
          })
          |> Repo.update!()
        end)

      {:ok, updated_plan} =
        plan
        |> Plan.changeset(approve_attrs)
        |> Repo.update()

      task = Repo.get!(Task, updated_plan.task_id)

      previous_task = task

      {finalized_task, frozen_messages} =
        case task.status do
          status when status in ["planning", "backlog"] ->
            apply_dispatch_gate(task)

          _ ->
            {nil, []}
        end

      {updated_plan, previous_task, finalized_task, frozen_messages, superseded_siblings}
    end)
    |> case do
      {:ok, {updated, previous_task, finalized_task, frozen_messages, superseded_siblings}} ->
        # Broadcast supersedee transitions FIRST so observers fold v1 before
        # expanding v2 — preserves the "newer plan replaces older" UX order.
        Enum.each(superseded_siblings, fn sibling ->
          broadcast_board({:plan_updated, sibling})
        end)

        broadcast_board({:plan_updated, updated})

        if finalized_task do
          finalized_task =
            Repo.preload(finalized_task, [:project, :epic, :sponsor, plans: :stages])

          broadcast_board({:task_updated, finalized_task})
          maybe_finalize_transition(previous_task, finalized_task, finalized_task.status)
        end

        # Policy 2 freeze broadcast — post-commit so subscribers never see a
        # stale event for a transaction that later rolled back.
        Platform.Chat.FreezePolicy.broadcast_frozen(frozen_messages, %{
          reason: :task_in_progress,
          task_id: finalized_task && finalized_task.id
        })

        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def approve_plan(_plan, _approved_by, _opts), do: {:error, :invalid_transition}

  # Decide whether the just-approved task can move into execution or has to
  # park in `blocked` until its dependencies finish. Returns `{task, frozen}`
  # where `task` is the post-write struct and `frozen` is the list of
  # messages frozen by Policy 2 (empty unless the task moved into
  # `:in_progress`). Broadcasting `frozen` is the caller's responsibility
  # — it should fire post-commit to avoid stale events on rollback.
  defp apply_dispatch_gate(%Task{} = task) do
    case unmet_dependencies(task) do
      [] ->
        {:ok, updated} = transition_task_status(task, "in_progress")

        case Platform.Chat.FreezePolicy.freeze_messages_for_task(updated) do
          {:ok, frozen} ->
            {updated, frozen}

          {:error, reason} ->
            Repo.rollback(reason)
        end

      unmet ->
        {:ok, blocked} = transition_task_status(task, "blocked")
        existing_metadata = blocked.metadata || %{}

        merged_metadata =
          Map.put(existing_metadata, "unmet_dependencies", Enum.map(unmet, & &1.id))

        {:ok, with_metadata} = update_task(blocked, %{metadata: merged_metadata})
        {with_metadata, []}
    end
  end

  @doc """
  Reject a plan, optionally persisting a free-text reason.

  Accepts plans in `pending_review` (the original planning-rejection flow)
  as well as `approved` / `completed` (the reopen-with-feedback flow added
  in task 019dfad1, where a done task gets reopened and its current active
  plan is retroactively marked rejected with the reviewer's feedback).

  The 2-arity form delegates with `reason: nil`.
  """
  def reject_plan(%Plan{} = plan, rejected_by), do: reject_plan(plan, rejected_by, nil)

  def reject_plan(%Plan{status: status} = plan, _rejected_by, reason)
      when status in ["pending_review", "approved", "completed"] do
    attrs =
      case reason do
        nil -> %{status: "rejected"}
        r -> %{status: "rejected", rejection_reason: r}
      end

    case plan |> Plan.changeset(attrs) |> Repo.update() do
      {:ok, updated} ->
        broadcast_board({:plan_updated, updated})
        {:ok, updated}

      error ->
        error
    end
  end

  def reject_plan(_plan, _rejected_by, _reason), do: {:error, :invalid_transition}

  @doc """
  Reopen a `done` task and capture the reviewer's feedback on the plan that
  was just delivered.

  Atomic: marks the most-recent active plan (`approved` or `completed`) as
  rejected with `reason` persisted to its `rejection_reason`, then transitions
  the task `done → planning`. Both updates are wrapped in a single
  `Repo.transaction/1`; if either step fails the whole reopen aborts.

  Refusal cases:
    * `{:error, :not_done}` — task is not currently in `done`
    * `{:error, :reason_required}` — `reason` is nil or blank/whitespace
    * `{:error, :no_plan}` — defensive invariant; a done task should always
      have an active plan, but if somehow none is found we abort rather than
      silently leave the task in a half-reopened state

  On success returns `{:ok, task}` with the task preloaded for board
  refresh, and broadcasts `{:task_updated, task}` + `{:plan_updated, plan}`
  on the board topic.
  """
  @spec reopen_with_feedback(String.t(), String.t() | nil, String.t()) ::
          {:ok, Task.t()}
          | {:error, :not_done | :reason_required | :no_plan | term()}
  def reopen_with_feedback(task_id, reason, by_user_id) when is_binary(task_id) do
    cond do
      is_nil(reason) or String.trim(reason) == "" ->
        {:error, :reason_required}

      true ->
        Repo.transaction(fn ->
          case Repo.get(Task, task_id) do
            nil ->
              Repo.rollback(:not_found)

            %Task{status: status} when status != "done" ->
              Repo.rollback(:not_done)

            %Task{} = task ->
              case latest_active_plan(task.id) do
                nil ->
                  Repo.rollback(:no_plan)

                %Plan{} = plan ->
                  case reject_plan(plan, by_user_id, reason) do
                    {:ok, rejected_plan} ->
                      case task
                           |> Task.changeset(%{status: "planning"})
                           |> Repo.update() do
                        {:ok, updated_task} ->
                          {updated_task, rejected_plan}

                        {:error, changeset} ->
                          Repo.rollback(changeset)
                      end

                    {:error, reason} ->
                      Repo.rollback(reason)
                  end
              end
          end
        end)
        |> case do
          {:ok, {task, plan}} ->
            preloaded = Repo.preload(task, [:project, :epic, :sponsor, plans: :stages])
            broadcast_board({:task_updated, preloaded})
            broadcast_board({:plan_updated, plan})
            {:ok, preloaded}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Most-recent plan in an "active" state — approved or completed. Used by
  # reopen_with_feedback to find the plan the task was executing against.
  defp latest_active_plan(task_id) do
    Plan
    |> where([p], p.task_id == ^task_id and p.status in ["approved", "completed"])
    |> order_by([p], desc: p.version)
    |> limit(1)
    |> Repo.one()
  end

  # ── View predicates (UI badge logic — task 019e2c25) ────────────────────
  #
  # `needs_human_action?/1` and `needs_human_action?/2` answer the question
  # "does this task need a human to look at it right now?" used by the
  # member-row, mobile-card, and stack-detail badges. The predicate returns
  # `true` when any of the following is true:
  #
  #   1. The task's status is `in_review` — the dispatcher has parked it on
  #      a manual_approval gate awaiting reviewer disposition.
  #   2. The task has at least one pending `review_request` — a manual
  #      approval has been submitted and is waiting for items to be approved
  #      or rejected. (This is the per-task warning-badge case in the
  #      desktop board.)
  #   3. The task's latest plan is in `pending_review` — the "Plan Ready"
  #      case where a planner has submitted a plan that has not been
  #      approved yet. Mirrors `task_display_status/1` in `tasks_live.ex`.
  #
  # The 2-arity form takes a precomputed pending review count as the second
  # arg. Batch callers (the LV's stack detail panel) already compute counts
  # over a member list with `pending_review_counts/1` and should pass that
  # integer in to avoid an extra DB round-trip per row. The 1-arity form
  # exists for the no-batch call sites and queries the DB directly.
  #
  # Both forms read `task.status` and `task.plans` off the struct — the
  # caller is responsible for preloading `:plans` (which `list_all_tasks/1`,
  # `get_task_detail/1`, and `Stacks.members/1`-callers that subsequently
  # preload all do) before relying on the plan-pending-review branch.
  # When `:plans` is not loaded, that branch is skipped (status + count
  # branches still resolve correctly).

  @doc """
  Returns `true` when `task` needs a human to take action on it — either
  the task is sitting in `in_review`, has a pending review_request, or its
  latest plan is in `pending_review`.

  Use this for "needs feedback" badges. For batch callers that already have
  a precomputed pending-review count for the task, prefer
  `needs_human_action?/2` to avoid an extra DB query per task.
  """
  @spec needs_human_action?(Task.t()) :: boolean()
  def needs_human_action?(%Task{} = task) do
    needs_human_action?(task, pending_review_count_for_task(task.id))
  end

  @doc """
  Same as `needs_human_action?/1` but accepts an explicit
  `pending_review_count`. Used by batch UI call sites (e.g. the stack
  detail member rows) that already compute pending counts across a list of
  task ids and want to avoid one query per row.

  Pass `0` when you have no count and don't want a DB query — this skips
  the "pending review request" branch entirely. Pass `nil` to fall through
  to the 1-arity form's DB lookup.
  """
  @spec needs_human_action?(Task.t(), non_neg_integer() | nil) :: boolean()
  def needs_human_action?(%Task{} = task, nil), do: needs_human_action?(task)

  def needs_human_action?(%Task{} = task, pending_review_count)
      when is_integer(pending_review_count) and pending_review_count >= 0 do
    needs_human_action_reason(task, pending_review_count) != nil
  end

  @doc """
  Returns the *reason* `task` needs a human action, or `nil` when none of
  the trigger conditions apply.

  Possible reasons (precedence order):

    * `:review_request_pending` — there is at least one open review_request
      for the task. **Ranked above `:plan_pending_review`** because a live
      review request is the more actionable / urgent signal: it represents
      a human-targeted ask raised mid-stream (manual approval, feedback
      gate), whereas `:plan_pending_review` is the task's normal process
      state. When both apply, the contract says "ALSO show Needs review",
      so a single-reason predicate must surface the review-request label.
    * `:plan_pending_review` — the task's latest plan is in `pending_review`
      ("Plan ready" badge). Reported when no open review_request exists.
    * `:validation_failed` — the task is parked on `in_review` after a
      manual_approval gate (status-driven fallback that covers the common
      case).
    * `nil` — task does not currently need human attention.

  Mirrors the truthy branches of `needs_human_action?/2` but lets callers
  (badge label / data-action-reason) discriminate. Same preload
  expectations apply: the `:plan_pending_review` branch is skipped when
  `:plans` is not loaded.
  """
  @spec needs_human_action_reason(Task.t(), non_neg_integer() | nil) ::
          :plan_pending_review | :review_request_pending | :validation_failed | nil
  def needs_human_action_reason(%Task{} = task, nil) do
    needs_human_action_reason(task, pending_review_count_for_task(task.id))
  end

  def needs_human_action_reason(%Task{} = task, pending_review_count)
      when is_integer(pending_review_count) and pending_review_count >= 0 do
    cond do
      pending_review_count > 0 -> :review_request_pending
      plan_pending_review?(task) -> :plan_pending_review
      task.status == "in_review" -> :validation_failed
      true -> nil
    end
  end

  # Inspects `task.plans` for any plan in `pending_review`. Returns `false`
  # when `:plans` is not preloaded (rather than triggering a lazy query) so
  # the predicate stays cheap for callers that only care about status +
  # count.
  defp plan_pending_review?(%Task{plans: plans}) when is_list(plans) do
    Enum.any?(plans, &(&1.status == "pending_review"))
  end

  defp plan_pending_review?(_task), do: false

  # Counts pending review_requests for a single task. Used by the 1-arity
  # `needs_human_action?/1`. Batch callers should use the LV's
  # `pending_review_counts/1` helper instead.
  defp pending_review_count_for_task(task_id) do
    ReviewRequest
    |> where([rr], rr.task_id == ^task_id and rr.status == "pending")
    |> Repo.aggregate(:count, :id)
  end

  # ── Stages ───────────────────────────────────────────────────────────────

  def create_stage(attrs) do
    %Stage{}
    |> Stage.changeset(attrs)
    |> Repo.insert()
  end

  def list_stages(plan_id) do
    Stage
    |> where([s], s.plan_id == ^plan_id)
    |> order_by([s], asc: s.position)
    |> Repo.all()
  end

  @valid_stage_transitions %{
    "pending" => ~w(running skipped),
    "running" => ~w(passed failed),
    "failed" => ~w(running skipped),
    "passed" => [],
    "skipped" => []
  }

  def transition_stage(%Stage{} = stage, new_status) do
    allowed = Map.get(@valid_stage_transitions, stage.status, [])

    if new_status in allowed do
      now = DateTime.utc_now()

      extra =
        case new_status do
          "running" -> %{started_at: now}
          s when s in ~w(passed failed skipped) -> %{completed_at: now}
          _ -> %{}
        end

      stage
      |> Stage.changeset(Map.put(extra, :status, new_status))
      |> Repo.update()
    else
      {:error, :invalid_transition}
    end
  end

  # ── Validations ──────────────────────────────────────────────────────────

  def create_validation(attrs) do
    %Validation{}
    |> Validation.changeset(attrs)
    |> Repo.insert()
  end

  def list_validations(stage_id) do
    Validation
    |> where([v], v.stage_id == ^stage_id)
    |> order_by([v], asc: v.inserted_at)
    |> Repo.all()
  end

  def evaluate_validation(id, status, evidence) when status in ~w(passed failed) do
    case Repo.get(Validation, id) do
      nil ->
        {:error, :not_found}

      validation ->
        validation
        |> Validation.changeset(%{
          status: status,
          evidence: evidence,
          evaluated_at: DateTime.utc_now()
        })
        |> Repo.update()
    end
  end

  # ── Kanban board queries ─────────────────────────────────────────────────

  @board_topic "tasks:board"

  @doc "List all tasks with preloaded project and epic, ordered by insertion."
  def list_all_tasks(opts \\ []) do
    project_id = Keyword.get(opts, :project_id)
    epic_id = Keyword.get(opts, :epic_id)
    sponsor_user_id = Keyword.get(opts, :sponsor_user_id)

    Task
    |> where([t], is_nil(t.deleted_at))
    |> maybe_filter_project(project_id)
    |> maybe_filter_epic(epic_id)
    |> maybe_filter_sponsor(sponsor_user_id)
    |> order_by([t], desc: t.inserted_at)
    |> preload([:project, :epic, :sponsor, plans: :stages])
    |> Repo.all()
  end

  defp maybe_filter_project(query, nil), do: query
  defp maybe_filter_project(query, id), do: where(query, [t], t.project_id == ^id)

  defp maybe_filter_epic(query, nil), do: query
  defp maybe_filter_epic(query, id), do: where(query, [t], t.epic_id == ^id)

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [t], t.status == ^status)

  # Stage 2 of task 019f3f22 (ADR-0042 sponsor visibility): opt-in filter
  # to narrow the board to tasks the given user sponsors. `nil` is the
  # unfiltered passthrough — mirrors `maybe_filter_project/2`'s pattern
  # so `list_all_tasks/1` + `list_by_status/1` accept the opt uniformly.
  defp maybe_filter_sponsor(query, nil), do: query

  defp maybe_filter_sponsor(query, sponsor_user_id),
    do: where(query, [t], t.sponsor_user_id == ^sponsor_user_id)

  # ── Kanban column data shape ─────────────────────────────────────────────
  #
  # Stage 1 of the Tasks v2 plan (task 019e389c-1f65) introduces a 7-column
  # kanban with a dedicated Planning column slotted between Backlog and In
  # Progress, plus a dedicated Blocked column between In Progress and In
  # Review. The data layer lives here so the LiveView can consume a stable
  # shape — Stage 2 wires the .heex template over to it.
  #
  # Key ordering matches the visual column order.
  #
  # Status-to-bucket mapping (Marlowe's call 2026-05-19):
  #   - `:blocked` gets its own bucket so a human or AI agent can see and
  #     act on stuck work — keeping it visible is the whole point.
  #   - `:cancelled` folds into the `:done` bucket. Cancelled and done share
  #     the same "no further action required" semantic for the board, so
  #     they collapse into a single visual column instead of giving cancel
  #     its own.
  #   - `:stack_pending` continues to be excluded from the rendered shape;
  #     it represents pre-backlog stack queueing rather than active board
  #     state. Callers that need the wider set should use `list_all_tasks/1`.
  @kanban_status_keys [
    :backlog,
    :planning,
    :in_progress,
    :blocked,
    :in_review,
    :deploying,
    :done
  ]

  # Statuses fetched from the DB but routed to a different bucket on the way
  # in. Keep this list explicit so the bucketing rule survives future status
  # additions: anything not in @kanban_status_keys + this map is excluded.
  @status_bucket_overrides %{"cancelled" => :done}

  @doc """
  Group tasks into the 7 kanban-column buckets (Stage 1 of Tasks v2 plan).

  Returns a map with exactly these keys, in this order:

    * `:backlog`
    * `:planning`
    * `:in_progress`
    * `:blocked`
    * `:in_review`
    * `:deploying`
    * `:done`

  Every key is present even when its bucket is empty, so the rendering
  template can iterate the shape without nil-guards. Within each bucket,
  tasks are ordered by `updated_at` descending (most-recently-touched
  first), which matches how the existing board surfaces recency.

  ## Options

    * `:project_id` — narrow to a single project (same filter shape as
      `list_all_tasks/1`).
    * `:epic_id`    — narrow to a single epic.

  Status routing (per Marlowe 2026-05-19):

    * `:blocked` lands in its own `:blocked` bucket — visible so a human
      or AI agent can take action to unblock.
    * `:cancelled` is folded into the `:done` bucket — both share the
      "no further action required" semantic, so they collapse into one
      visual column.
    * `:stack_pending` is excluded entirely from the rendered shape; it
      represents pre-backlog stack queueing rather than active board
      state. Callers that need the wider set should reach for
      `list_all_tasks/1` instead.
  """
  @spec list_by_status(keyword()) :: %{atom() => [%Task{}]}
  def list_by_status(opts \\ []) do
    project_id = Keyword.get(opts, :project_id)
    epic_id = Keyword.get(opts, :epic_id)
    sponsor_user_id = Keyword.get(opts, :sponsor_user_id)

    # Statuses we actually pull from the DB: the 7 directly-bucketed ones
    # plus any whose tasks we fold into another bucket (e.g. cancelled →
    # done). Anything outside this set is excluded from the board shape.
    fetched_statuses =
      (Enum.map(@kanban_status_keys, &Atom.to_string/1) ++
         Map.keys(@status_bucket_overrides))
      |> Enum.uniq()

    tasks =
      Task
      |> where([t], is_nil(t.deleted_at))
      |> where([t], t.status in ^fetched_statuses)
      |> maybe_filter_project(project_id)
      |> maybe_filter_epic(epic_id)
      |> maybe_filter_sponsor(sponsor_user_id)
      |> order_by([t], desc: t.updated_at)
      # `plans: :stages` is required by the desktop kanban template,
      # which renders per-card plan progress (`<passed>/<total>` stage
      # counts) and the plan-pending-review badge. `list_all_tasks/1`
      # carries the same preload set; keep them aligned so callers can
      # swap between the two without surprise N+1s in the LV render.
      # `:sponsor` preloaded per ADR 0042 so the kanban card can render
      # the sponsor avatar/name without a per-card follow-up query.
      |> preload([:project, :epic, :sponsor, plans: :stages])
      |> Repo.all()

    empty = Map.new(@kanban_status_keys, &{&1, []})

    tasks
    |> Enum.reduce(empty, fn task, acc ->
      key = bucket_for_status(task.status)
      Map.update!(acc, key, &[task | &1])
    end)
    # The reduce above prepends, which reverses the DB order. Re-reverse so
    # each bucket ends up in `updated_at` desc order as documented.
    |> Map.new(fn {key, list} -> {key, Enum.reverse(list)} end)
  end

  # Map a raw status string to the kanban bucket it belongs in. Direct
  # statuses fall through to their matching atom; overrides (e.g.
  # "cancelled" → :done) are looked up first.
  defp bucket_for_status(status) when is_binary(status) do
    case Map.fetch(@status_bucket_overrides, status) do
      {:ok, bucket} -> bucket
      :error -> String.to_existing_atom(status)
    end
  end

  @doc """
  Returns the canonical ordered list of kanban-column status keys.

  Exposed so callers (LiveView, view helpers, future stages) can iterate
  the columns without re-declaring the order — single source of truth.
  """
  @spec kanban_status_keys() :: [atom()]
  def kanban_status_keys, do: @kanban_status_keys

  # ── Scope-filter rail (Stage 3 of Tasks v2 plan, 2026-05-19) ──────────────
  #
  # Five sub-org scopes — fabrikam, soylent, wayne_tech, sxi, paragon — match the
  # canonical scope list in `PlatformWeb.Components.ScopePill` (futureproof
  # seam for the MT/RBAC stack 019e3c49). Today, `tasks` has no `org_id`
  # column, so we can't bucket tasks per-org from the DB. The today-state
  # contract (per the Stage 3 dispatch + the MT/RBAC plan) is to fold every
  # task under `:fabrikam` and report 0 for the other four. Once `tasks.org_id`
  # lands the body of `count_by_scope/0` becomes a `group_by org_id` query;
  # the public API (a map keyed by the five scope atoms) stays unchanged so
  # the LiveView's scope-rail render isn't coupled to the data shape.
  @scope_keys [:fabrikam, :soylent, :wayne_tech, :sxi, :paragon]

  @doc """
  Returns the canonical list of scope atoms used by the scope-filter rail.

  Exposed so the LiveView (and future callers) iterate the rail in a single
  source of truth rather than re-declaring the order. Order mirrors
  `PlatformWeb.Components.ScopePill.scopes/0`.
  """
  @spec scope_keys() :: [atom()]
  def scope_keys, do: @scope_keys

  @doc """
  Count tasks per sub-org scope.

  Returns a map with exactly the five scope keys (`:fabrikam`, `:soylent`,
  `:wayne_tech`, `:sxi`, `:paragon`) populated as non-negative integers.

  ## Today-state (pre-MT/RBAC-on-Tasks)

  `tasks` has no `org_id` column yet, so the helper folds every non-deleted
  task under `:fabrikam` and returns 0 for the other four scopes. This keeps the
  scope rail rendering today without coupling the UI to a schema change.

  ## Future state (post-task-orgs)

  Once `tasks.org_id` lands, swap the body for a `group_by(t.org_id)`
  aggregate; the public return shape stays the same so the LiveView's
  scope-rail render is unaffected.
  """
  @spec count_by_scope() :: %{atom() => non_neg_integer()}
  def count_by_scope do
    total =
      Task
      |> where([t], is_nil(t.deleted_at))
      |> Repo.aggregate(:count)

    @scope_keys
    |> Map.new(fn key -> {key, 0} end)
    |> Map.put(:fabrikam, total)
  end

  @doc """
  Count tasks currently in progress for a given user.

  Used by the mobile bottom-nav (`PlatformWeb.Components.BottomNav`) to
  render the badge on the Tasks tab. v1 just counts in-progress tasks
  assigned to this user; clear-on-visit / unread-tracking is a future
  enhancement.

  Returns an integer (0 when no user_id, no matches, or query errors).
  """
  @spec count_in_progress_for_user(binary() | nil) :: non_neg_integer()
  def count_in_progress_for_user(nil), do: 0

  def count_in_progress_for_user(user_id) when is_binary(user_id) do
    Task
    |> where([t], is_nil(t.deleted_at))
    |> where([t], t.status == "in_progress")
    |> where([t], t.assignee_id == ^user_id)
    |> Repo.aggregate(:count)
  end

  @doc "Get a task with full detail: project, epic, plans with stages and validations."
  def get_task_detail(task_id) do
    Task
    |> where([t], t.id == ^task_id)
    |> where([t], is_nil(t.deleted_at))
    |> preload([:project, :epic, :stack, :sponsor, plans: [:superseded_by, stages: :validations]])
    |> Repo.one()
  end

  # Statuses that represent execution (work has begun on the plan). Per
  # ADR 0029 plan approval is the start signal; a task cannot enter any of
  # these without an `approved` plan to execute against.
  @execution_phase_statuses ~w(in_progress in_review deploying done)

  # Map task status → orchestration phase for per-phase assignee resolution.
  # Three phases: planning, execution, review (covers in_progress + deploying
  # + done because they all carry the implementer assignee; review is its
  # own validator handoff).
  @status_to_phase %{
    "backlog" => "planning",
    "planning" => "planning",
    "blocked" => "planning",
    "in_progress" => "execution",
    "deploying" => "execution",
    "done" => "execution",
    "in_review" => "review"
  }

  @doc """
  Maps a task's current status to its orchestration phase. The phase is the
  key used to look up the right assignee in `task.phase_assignees`.
  """
  @spec current_phase(%Task{} | String.t()) :: String.t()
  def current_phase(%Task{status: status}), do: current_phase(status)

  def current_phase(status) when is_binary(status),
    do: Map.get(@status_to_phase, status, "planning")

  @doc """
  Returns `{assignee_id, assignee_type}` for the given task in the given
  phase.

  Resolution order (task 019f25f2 corrective patch):

    1. `phase_assignees[phase]` — per-phase override (granular assignment)
    2. Top-level `assignee_id` / `assignee_type` — the coarse "task owner"
       who owns every phase by default
    3. `{nil, nil}` — no assignee configured

  This makes the field name honest: callers asking for the current owner
  of a phase get the right answer regardless of whether the task uses
  granular per-phase assignment or the simpler top-level assignment.
  """
  @spec assignee_for_phase(%Task{}, String.t()) :: {String.t() | nil, String.t() | nil}
  def assignee_for_phase(%Task{} = task, phase) when is_binary(phase) do
    case per_phase_assignee(task.phase_assignees, phase) do
      {nil, nil} -> top_level_assignee(task)
      pair -> pair
    end
  end

  def assignee_for_phase(_, _), do: {nil, nil}

  defp per_phase_assignee(pa, phase) when is_map(pa) do
    case Map.get(pa, phase) do
      %{"assignee_id" => id, "assignee_type" => type}
      when is_binary(id) and is_binary(type) ->
        {id, type}

      %{"assignee_id" => id} when is_binary(id) ->
        {id, "agent"}

      _ ->
        {nil, nil}
    end
  end

  defp per_phase_assignee(_, _), do: {nil, nil}

  defp top_level_assignee(%Task{assignee_id: id, assignee_type: type})
       when is_binary(id) and is_binary(type),
       do: {id, type}

  defp top_level_assignee(_), do: {nil, nil}

  @doc """
  Set per-phase assignees on a task. `attrs_by_phase` is a map keyed by
  phase ("planning" | "execution" | "review") with values
  `%{"assignee_id" => id, "assignee_type" => type}`. Pass `nil` for a phase
  to clear it.

  After writing, the task's top-level `assignee_id` / `assignee_type` are
  re-derived from `phase_assignees[current_phase(task)]` so existing read
  paths (TaskRouter dispatch, kanban thumbnail, etc.) pick up the right
  agent for the phase the task is currently in.

  Returns `{:ok, task}` or `{:error, changeset}`.
  """
  @spec set_phase_assignees(%Task{}, map()) :: {:ok, %Task{}} | {:error, Ecto.Changeset.t()}
  def set_phase_assignees(%Task{} = task, attrs_by_phase) when is_map(attrs_by_phase) do
    merged =
      task.phase_assignees
      |> Kernel.||(%{})
      |> Map.merge(stringify_phase_attrs(attrs_by_phase))

    {derived_id, derived_type} =
      assignee_for_phase(%{task | phase_assignees: merged}, current_phase(task))

    task
    |> Task.changeset(%{
      phase_assignees: merged,
      assignee_id: derived_id,
      assignee_type: derived_type
    })
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        broadcast_board(
          {:task_updated, Repo.preload(updated, [:project, :epic, :sponsor, plans: :stages])}
        )

        {:ok, updated}

      error ->
        error
    end
  end

  defp stringify_phase_attrs(attrs) do
    Map.new(attrs, fn
      {phase, nil} ->
        {to_string(phase), %{}}

      {phase, %{} = inner} ->
        {to_string(phase),
         Map.new(inner, fn
           {k, nil} -> {to_string(k), nil}
           {k, v} -> {to_string(k), v}
         end)}
    end)
  end

  @doc """
  Returns `:ok` if `task` has an approved plan, otherwise
  `{:error, :no_approved_plan}`. Used to gate transitions into execution
  phases (`in_progress`, `in_review`, `deploying`, `done`).
  """
  def require_approved_plan_for(%Task{} = task, new_status) do
    cond do
      new_status not in @execution_phase_statuses ->
        :ok

      task.status in @execution_phase_statuses ->
        # Already in execution; the gate was checked at entry. Don't
        # re-check on intra-execution transitions (e.g. in_progress →
        # in_review) since the approved plan may already be `executing`
        # or `completed`.
        :ok

      current_plan(task.id) ->
        :ok

      true ->
        {:error, :no_approved_plan}
    end
  end

  @doc """
  Transition a task's status and broadcast the change to the board topic.

  When `new_status` is `"in_progress"`, the status flip and the Policy 2
  freeze of any messages in the task's execution space happen inside a
  single `Repo.transaction/1` — see
  `apps/platform/audit/2026-05-13-policy-2-freeze-trigger/design.md` for
  the atomicity rationale. If any freeze fails (changeset error), the
  whole transaction rolls back: the task stays in its original status and
  no messages get partially frozen.

  After the transaction commits successfully, two broadcasts fire on the
  affected space's chat topic:

    * `{:messages_frozen, message_ids, %{reason: :task_in_progress, task_id: id}}`
      — consumed by `PlatformWeb.Live.Chat.MessagesHooks` to refresh
      per-row `(edited)`-affordance state without a full reload.

  Non-`in_progress` transitions skip the freeze path entirely and behave
  exactly as before.
  """
  def transition_task(%Task{} = task, new_status) do
    with :ok <- require_approved_plan_for(task, new_status),
         :ok <- maybe_prepare_transition(task, new_status),
         {:ok, %{updated: updated, frozen: frozen}} <-
           transition_with_policy2_freeze(task, new_status) do
      updated = Repo.preload(updated, [:project, :epic, :sponsor, plans: :stages])
      broadcast_board({:task_updated, updated})
      maybe_finalize_transition(task, updated, new_status)

      Platform.Chat.FreezePolicy.broadcast_frozen(frozen, %{
        reason: :task_in_progress,
        task_id: updated.id
      })

      {:ok, updated}
    else
      error ->
        error
    end
  end

  # Atomic status flip + Policy 2 task-scoped freeze when entering :in_progress.
  # Delegates the actual freeze to `Platform.Chat.FreezePolicy` so the Tasks
  # domain doesn't reach into Chat schemas directly. Both writes share one
  # `Repo.transaction` so a freeze failure rolls back the status update —
  # no silent partial freeze, no half-flipped state.
  defp transition_with_policy2_freeze(%Task{} = task, "in_progress") do
    Repo.transaction(fn ->
      case transition_task_status(task, "in_progress") do
        {:ok, updated} ->
          case Platform.Chat.FreezePolicy.freeze_messages_for_task(updated) do
            {:ok, frozen_messages} ->
              %{updated: updated, frozen: frozen_messages}

            {:error, reason} ->
              Repo.rollback(reason)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp transition_with_policy2_freeze(%Task{} = task, new_status) do
    case transition_task_status(task, new_status) do
      {:ok, updated} -> {:ok, %{updated: updated, frozen: []}}
      error -> error
    end
  end

  # ── Manual drag-and-drop transitions (permissive) ─────────────────────

  # Permissive transitions for manual drag-and-drop on the kanban board.
  # Unlike @valid_task_transitions (used by the automated pipeline), this
  # allows humans to override status from the UI — e.g. reopening a done
  # task, skipping straight to in_progress, etc.
  @valid_drop_transitions %{
    "backlog" => ~w(in_progress in_review deploying done),
    "planning" => ~w(backlog in_progress in_review deploying done),
    "blocked" => ~w(backlog in_progress in_review deploying done),
    "in_progress" => ~w(backlog in_review deploying done),
    "in_review" => ~w(backlog in_progress deploying done),
    "deploying" => ~w(backlog in_progress in_review done),
    "done" => ~w(backlog in_progress)
  }

  @drop_target_status %{
    "backlog" => "backlog",
    "in_progress" => "in_progress",
    "in_review" => "in_review",
    "deploying" => "deploying",
    "done" => "done"
  }

  @doc """
  Move a task to a kanban column via manual drag-and-drop.

  Uses permissive transition rules (broader than the automated pipeline)
  since this represents an intentional human override from the board UI.

  Returns `{:ok, task}` or `{:error, :invalid_drop | :unknown_column | changeset}`.
  """
  def drop_task_to_column(%Task{} = task, column) do
    case Map.get(@drop_target_status, column) do
      nil ->
        {:error, :unknown_column}

      target_status when target_status == task.status ->
        # Same column — no-op, return task as-is
        {:ok, task}

      target_status ->
        allowed = Map.get(@valid_drop_transitions, task.status, [])

        cond do
          target_status not in allowed ->
            {:error, :invalid_drop}

          require_approved_plan_for(task, target_status) == {:error, :no_approved_plan} ->
            {:error, :no_approved_plan}

          true ->
            case task |> Task.changeset(%{status: target_status}) |> Repo.update() do
              {:ok, updated} ->
                updated = Repo.preload(updated, [:project, :epic, :sponsor, plans: :stages])
                broadcast_board({:task_updated, updated})
                {:ok, updated}

              {:error, changeset} ->
                {:error, changeset}
            end
        end
    end
  end

  defp maybe_prepare_transition(%Task{status: "in_progress"} = task, "in_review") do
    case failed_manual_approval_validation(task.id) do
      nil ->
        :ok

      validation ->
        case PlanEngine.reopen_manual_approval(validation.id) do
          {:ok, _validation} -> :ok
          {:error, :already_passed} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp maybe_prepare_transition(_task, _new_status), do: :ok

  defp maybe_finalize_transition(
         %Task{status: "in_progress"} = previous,
         %Task{} = task,
         "in_review"
       ) do
    RuntimeSupervision.abandon_current_lease_for_task(task.id, "execution")
    TaskRouterWatcher.force_dispatch(task.id)
    maybe_apply_phase_assignee(task)
    maybe_recompute_stack(task)
    maybe_handle_regression(previous, task, "in_review")
    maybe_merge_into_rollup(task, "in_review")
    :ok
  end

  defp maybe_finalize_transition(%Task{} = previous, %Task{} = task, "done") do
    if current_phase(previous) != current_phase(task) do
      maybe_apply_phase_assignee(task)
    end

    sweep_unblocked_dependents(task)
    maybe_recompute_stack(task)
    maybe_handle_regression(previous, task, "done")
    :ok
  end

  # Stage 4: cancellation is terminal (see @valid_task_transitions —
  # `cancelled` has no outbound edges). The router + lease teardown is
  # centralized in `transition_task_status/2 → maybe_dispatch_teardown/2`
  # so it fires for both `transition_task/2` (which lands here via
  # `transition_with_policy2_freeze`) and the MCP `task_update` path
  # (which calls `transition_task_status/2` directly). This head still
  # runs phase/stack/regression housekeeping like any other transition.
  defp maybe_finalize_transition(%Task{} = previous, %Task{} = task, "cancelled") do
    if current_phase(previous) != current_phase(task) do
      maybe_apply_phase_assignee(task)
    end

    maybe_recompute_stack(task)
    maybe_handle_regression(previous, task, "cancelled")
    :ok
  end

  defp maybe_finalize_transition(%Task{} = previous, %Task{} = task, new_status) do
    if current_phase(previous) != current_phase(task) do
      maybe_apply_phase_assignee(task)
    end

    maybe_recompute_stack(task)
    maybe_handle_regression(previous, task, new_status)
    :ok
  end

  defp maybe_finalize_transition(_previous_task, _task, _new_status), do: :ok

  # ADR 0041 §"Status divergence handling": any member status change
  # triggers a stack-level rollup-status recompute. Short-circuits when
  # the task is not a stack member.
  defp maybe_recompute_stack(%Task{stack_id: nil}), do: :ok

  defp maybe_recompute_stack(%Task{stack_id: stack_id}) when is_binary(stack_id) do
    Platform.Tasks.Stacks.recompute_stack_status(stack_id)
    :ok
  end

  # ADR 0041 §"Rollup-branch merge" — when a stack member transitions
  # into a state where its branch can join the rollup (currently
  # `in_review`), fire the deployer's per-member merge. The deployer
  # itself enforces the precise readiness gate (review-stage
  # validations all `passed`) and idempotency, so this seam is
  # intentionally permissive: we always invoke when the trigger
  # condition fires and let the deployer decide whether to act.
  defp maybe_merge_into_rollup(%Task{stack_id: nil}, _to), do: :ok

  defp maybe_merge_into_rollup(%Task{stack_id: stack_id} = task, to)
       when is_binary(stack_id) do
    _ = Platform.Tasks.StackDeployer.handle_member_transition(task, :transitioned, to)
    :ok
  end

  # ADR 0041 §"Status divergence handling": when a stack member regresses
  # (backward lifecycle step), re-evaluate downstream stack members.
  # Cross-stack regressions short-circuit inside the handler.
  defp maybe_handle_regression(%Task{} = previous, %Task{} = updated, new_status) do
    if Platform.Tasks.Stacks.regression?(previous.status, new_status) do
      Platform.Tasks.Stacks.handle_member_regression(updated, previous.status)
    end

    :ok
  end

  # When a task reaches `done`, find every `blocked` task that listed it as
  # a dependency and re-evaluate whether their other deps are also satisfied.
  # Any whose remaining deps are all `done` transition back to `in_progress`
  # and have `metadata["unmet_dependencies"]` cleared. The transition runs
  # through `transition_task/2`, so chained completions cascade naturally
  # without an explicit recursion loop.
  defp sweep_unblocked_dependents(%Task{} = done_task) do
    # The match list is a literal Elixir list (not a Jason-encoded string).
    # Postgrex binds binary params as already-jsonb (a string scalar) when
    # the column is jsonb, which breaks `$1::jsonb` casts of pre-encoded
    # JSON. Passing the term lets Postgrex serialize it as a jsonb array.
    match = [%{"task_id" => done_task.id}]

    candidates =
      Repo.all(
        from(t in Task,
          where:
            t.status == "blocked" and
              fragment("? @> ?", t.dependencies, ^match) and
              is_nil(t.deleted_at)
        )
      )

    Enum.each(candidates, fn blocked_task ->
      case unmet_dependencies(blocked_task) do
        [] -> unblock_task(blocked_task)
        still_unmet -> refresh_unmet_metadata(blocked_task, still_unmet)
      end
    end)

    :ok
  end

  # Sibling case: a dep just finished but other deps remain. Stay blocked
  # but rewrite metadata["unmet_dependencies"] so dashboards reflect only
  # the deps still gating the task instead of carrying the stale set.
  defp refresh_unmet_metadata(%Task{} = blocked_task, still_unmet) do
    new_ids = Enum.map(still_unmet, & &1.id)
    metadata = blocked_task.metadata || %{}
    current = Map.get(metadata, "unmet_dependencies", [])

    if Enum.sort(new_ids) == Enum.sort(current) do
      :ok
    else
      merged = Map.put(metadata, "unmet_dependencies", new_ids)
      {:ok, _} = update_task(blocked_task, %{metadata: merged})
      :ok
    end
  end

  defp unblock_task(%Task{} = blocked_task) do
    case transition_task(blocked_task, "in_progress") do
      {:ok, unblocked} ->
        metadata = unblocked.metadata || %{}

        if Map.has_key?(metadata, "unmet_dependencies") do
          cleared = Map.delete(metadata, "unmet_dependencies")
          {:ok, _} = update_task(unblocked, %{metadata: cleared})
        end

        :ok

      _ ->
        :ok
    end
  end

  # When a task crosses a phase boundary, re-derive the top-level
  # `assignee_id` / `assignee_type` from `phase_assignees[new_phase]`. This
  # is what makes the per-phase modal actually take effect: the runtime
  # router and every read path consults `task.assignee_id`, so it has to
  # match the new phase's configured agent.
  defp maybe_apply_phase_assignee(%Task{} = task) do
    new_phase = current_phase(task)
    {phase_id, phase_type} = assignee_for_phase(task, new_phase)

    cond do
      is_nil(phase_id) ->
        :ok

      phase_id == task.assignee_id and phase_type == task.assignee_type ->
        :ok

      true ->
        task
        |> Task.changeset(%{assignee_id: phase_id, assignee_type: phase_type})
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            broadcast_board(
              {:task_updated, Repo.preload(updated, [:project, :epic, :sponsor, plans: :stages])}
            )

            :ok

          _error ->
            :ok
        end
    end
  end

  defp failed_manual_approval_validation(task_id) do
    case current_plan(task_id) do
      %{stages: stages} ->
        stages
        |> Enum.sort_by(& &1.position)
        |> Enum.find_value(fn stage ->
          if stage.status == "failed" do
            Enum.find(
              stage.validations,
              &(&1.kind == "manual_approval" and &1.status == "failed")
            )
          else
            nil
          end
        end)

      _ ->
        nil
    end
  end

  @doc "Subscribe to the kanban board topic for real-time updates."
  def subscribe_board do
    Phoenix.PubSub.subscribe(Platform.PubSub, @board_topic)
  end

  @doc "Broadcast a board event."
  def broadcast_board(message) do
    Phoenix.PubSub.broadcast(Platform.PubSub, @board_topic, message)
  end

  # ── Legacy ETS-based read-side (backward compat) ─────────────────────────

  @spec list_tasks() :: [summary()]
  def list_tasks do
    active_runs = active_runs()
    artifacts = Artifacts.list_artifacts()
    task_ids = known_task_ids(active_runs, artifacts)

    task_ids
    |> Enum.map(&build_summary(&1, active_runs, artifacts))
    |> Enum.sort_by(&sort_tuple/1, :desc)
  end

  @spec get_task(String.t()) :: {:ok, detail()} | {:error, :not_found}
  def get_task(task_id) when is_binary(task_id) do
    active_runs = active_runs()
    artifacts = Artifacts.list_artifacts(task_id: task_id)
    summary = build_summary(task_id, active_runs, artifacts)

    if empty_summary?(summary) do
      {:error, :not_found}
    else
      {context_session, context_items, recent_deltas} = context_detail(task_id)

      {:ok,
       %Detail{
         summary: summary,
         runs: runs_for_task(active_runs, task_id),
         artifacts: artifacts,
         context_session: context_session,
         context_items: context_items,
         recent_deltas: recent_deltas
       }}
    end
  end

  # ── Proof-of-life delegates ──────────────────────────────────────────────

  alias Platform.Tasks.ProofOfLife

  @doc """
  Legacy proof-run entrypoint.

  This now delegates to the real docker/agent-backed proof-of-life launcher so
  older callers do not silently take the old synchronous local-repo path.
  """
  @spec launch_proof_run(String.t(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def launch_proof_run(task_id, opts \\ []) when is_binary(task_id) do
    with {:ok, _task_id} <- bootstrap_proof_of_life_task(task_id: task_id),
         {:ok, _version} <- approve_proof_of_life_plan(task_id) do
      launch_proof_of_life(task_id, opts)
    end
  end

  @spec request_stop(String.t()) :: {:ok, Run.t()} | {:error, term()}
  def request_stop(run_id), do: Execution.request_stop(run_id)

  @spec force_stop(String.t()) :: {:ok, Run.t()} | {:error, term()}
  def force_stop(run_id), do: Execution.force_stop(run_id)

  @spec bootstrap_proof_of_life_task(keyword()) :: {:ok, String.t()} | {:error, term()}
  def bootstrap_proof_of_life_task(opts \\ []), do: ProofOfLife.bootstrap_task(opts)

  @spec approve_proof_of_life_plan(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def approve_proof_of_life_plan(task_id), do: ProofOfLife.approve_plan(task_id)

  @spec launch_proof_of_life(String.t(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def launch_proof_of_life(task_id, opts \\ []), do: ProofOfLife.launch(task_id, opts)

  # ── PubSub ───────────────────────────────────────────────────────────────

  @spec subscribe(String.t()) :: :ok
  def subscribe(task_id) do
    _ = Phoenix.PubSub.subscribe(Platform.PubSub, "execution:runs:#{task_id}")
    _ = Artifacts.subscribe_task(task_id)
    _ = Phoenix.PubSub.subscribe(Platform.PubSub, "ctx:#{task_id}")
    :ok
  end

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(task_id) do
    _ = Phoenix.PubSub.unsubscribe(Platform.PubSub, "execution:runs:#{task_id}")
    _ = Phoenix.PubSub.unsubscribe(Platform.PubSub, Artifacts.task_topic(task_id))
    _ = Phoenix.PubSub.unsubscribe(Platform.PubSub, "ctx:#{task_id}")
    :ok
  end

  # ── Private helpers (legacy ETS read-side) ───────────────────────────────

  defp build_summary(task_id, active_runs, artifacts) do
    runs = runs_for_task(active_runs, task_id)
    task_artifacts = Enum.filter(artifacts, &(&1.task_id == task_id))
    {context_session, items, _deltas} = context_detail(task_id)

    latest_run = List.first(Enum.sort_by(runs, &run_sort_key/1, :desc))

    latest_activity_at =
      [
        latest_run && run_activity_at(latest_run),
        latest_artifact_at(task_artifacts),
        context_session && context_session.updated_at
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.max(DateTime, fn -> nil end)

    proof_state = extract_proof_state(items)

    %Summary{
      task_id: task_id,
      run_count: length(runs),
      active_run_count: Enum.count(runs, &(not Run.terminal?(&1))),
      artifact_count: length(task_artifacts),
      latest_run: latest_run,
      latest_activity_at: latest_activity_at,
      context_version: context_session && context_session.version,
      context_status: context_status(context_session),
      proof_branch: proof_state.branch,
      proof_verification: proof_state.verification,
      proof_pushed: proof_state.pushed
    }
  end

  defp extract_proof_state(items) do
    item_map =
      Map.new(items, fn item -> {item.key, item.value} end)

    %{
      branch: Map.get(item_map, "proof_run.branch"),
      verification: Map.get(item_map, "proof_run.verification_output"),
      pushed: Map.get(item_map, "proof_run.pushed") == "true"
    }
  end

  defp empty_summary?(%Summary{} = summary) do
    summary.run_count == 0 and summary.artifact_count == 0 and is_nil(summary.context_version)
  end

  defp known_task_ids(active_runs, artifacts) do
    run_ids = Enum.map(active_runs, & &1.task_id)
    artifact_ids = Enum.map(artifacts, & &1.task_id)
    context_ids = task_ids_from_context_sessions()

    (run_ids ++ artifact_ids ++ context_ids)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp task_ids_from_context_sessions do
    if :ets.whereis(:ctx_sessions) == :undefined do
      []
    else
      :ctx_sessions
      |> :ets.tab2list()
      |> Enum.map(fn {_scope_key, session} -> session.scope.task_id end)
      |> Enum.reject(&is_nil/1)
    end
  end

  defp context_detail(task_id) do
    scope = %{task_id: task_id}

    with {:ok, session} <- Context.get_session(scope),
         {:ok, snapshot} <- Context.snapshot(scope),
         {:ok, deltas} <- Context.latest_delta(scope, max(session.version - 5, 0)) do
      {session, snapshot.items, deltas}
    else
      _ -> {nil, [], []}
    end
  end

  defp context_status(nil), do: :empty
  defp context_status(%Session{required_version: version, version: version}), do: :current
  defp context_status(_session), do: :pending

  defp active_runs do
    Platform.Execution.RunSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
    |> Enum.filter(&is_pid/1)
    |> Enum.map(&safe_get_run/1)
    |> Enum.reject(&is_nil/1)
  end

  defp safe_get_run(pid) do
    try do
      case GenServer.call(pid, :get_run, 1_000) do
        {:ok, %Run{} = run} -> run
        _ -> nil
      end
    catch
      :exit, _ -> nil
    end
  end

  defp runs_for_task(runs, task_id) do
    runs
    |> Enum.filter(&(&1.task_id == task_id))
    |> Enum.sort_by(&run_sort_key/1, :desc)
  end

  defp run_sort_key(%Run{} = run) do
    run_activity_at(run) || run.inserted_at || DateTime.from_unix!(0)
  end

  defp run_activity_at(%Run{} = run) do
    run.finished_at || run.started_at || run.inserted_at
  end

  defp latest_artifact_at([]), do: nil

  defp latest_artifact_at(artifacts) do
    artifacts
    |> Enum.map(&(&1.updated_at || &1.inserted_at))
    |> max_datetime()
  end

  defp max_datetime(values) do
    values
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      items -> Enum.max_by(items, &DateTime.to_unix(&1, :microsecond))
    end
  end

  defp sort_tuple(%Summary{} = summary) do
    {summary.latest_activity_at || DateTime.from_unix!(0), summary.task_id}
  end

  # ── Private helpers (plan version) ───────────────────────────────────────

  defp maybe_set_plan_version(%{version: _} = attrs), do: attrs
  defp maybe_set_plan_version(%{"version" => _} = attrs), do: attrs

  defp maybe_set_plan_version(%{task_id: task_id} = attrs) do
    Map.put(attrs, :version, next_plan_version(task_id))
  end

  defp maybe_set_plan_version(%{"task_id" => task_id} = attrs) do
    Map.put(attrs, "version", next_plan_version(task_id))
  end

  defp maybe_set_plan_version(attrs), do: attrs

  defp next_plan_version(task_id) do
    query =
      from(p in Plan,
        where: p.task_id == ^task_id,
        select: max(p.version)
      )

    case Repo.one(query) do
      nil -> 1
      max -> max + 1
    end
  end
end
