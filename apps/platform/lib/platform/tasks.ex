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

  alias Platform.{Artifacts, Context, Execution, Memory}
  alias Platform.Accounts
  alias Platform.Agents.Agent
  alias Platform.Context.Session
  alias Platform.Execution.Run

  alias Platform.Orchestration.{
    ExecutionSpace,
    RuntimeSupervision,
    TaskRouterSupervisor,
    TaskRouterWatcher
  }

  alias Platform.Repo
  alias Platform.Tenancy.Lifecycle

  alias Platform.Tasks.{
    Epic,
    Indexer,
    Plan,
    PlanEngine,
    Project,
    References,
    RepoRef,
    ReviewRequest,
    Stack,
    Stage,
    Task,
    TaskReference,
    Validation
  }

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
    # ADR 0042 Decision 4: `planning → stack_pending` lands when
    # `apply_dispatch_gate/1` fires on a stack member whose commencement
    # gate is still closed. Rather than surface `:stack_plans_pending` (which
    # would roll back the plan-approval transaction), the member is parked
    # in `stack_pending` and the in-stack sweep promotes it once every
    # sibling plan is approved.
    "planning" => ~w(in_progress blocked backlog stack_pending cancelled),
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
         |> Platform.Tenancy.Lifecycle.guard_org_active()
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

  @doc """
  Update a project's own attributes (name, repo_url, default_branch,
  deploy_config). Frozen while the project is archived.

  Safe to guard: this is NOT the archive path. `Lifecycle` stamps
  `archived_at` through its own private writer, so archiving stays reversible
  even with this locked.
  """
  def update_project(%Project{} = project, attrs) do
    with :ok <- Lifecycle.ensure_project_writable(project.id) do
      project
      |> Project.changeset(attrs)
      |> Repo.update()
    end
  end

  # ── Project lifecycle (archive / schedule-deletion / restore) ─────────
  #
  # Task 019f4eaa stage 3. Implemented in `Platform.Tenancy.Lifecycle`
  # (single-row — projects have no cascade of their own); delegated here
  # so callers use the natural context API. All four require a Fabrikam admin
  # actor.

  @doc "See `Platform.Tenancy.Lifecycle.archive_project/2`."
  defdelegate archive_project(actor, project), to: Platform.Tenancy.Lifecycle

  @doc "See `Platform.Tenancy.Lifecycle.unarchive_project/2`."
  defdelegate unarchive_project(actor, project), to: Platform.Tenancy.Lifecycle

  @doc "See `Platform.Tenancy.Lifecycle.schedule_project_deletion/2`."
  defdelegate schedule_project_deletion(actor, project), to: Platform.Tenancy.Lifecycle

  @doc "See `Platform.Tenancy.Lifecycle.cancel_project_deletion/2`."
  defdelegate cancel_project_deletion(actor, project), to: Platform.Tenancy.Lifecycle

  def get_project(id), do: Repo.get(Project, id)

  def get_project_by_slug(slug) do
    Repo.get_by(Project, slug: slug)
  end

  @doc """
  **WARNING: applies NO viewer scoping.** Returns every project in every
  org, regardless of who is asking.

  It exists solely for system callers that run with no viewer at all —
  boot-time PubSub subscription inside a `GenServer.init/1`, where there
  is no user to scope against:

    * `Platform.Meetings.MeetingNotifier` — subscribes to every project's
      meetings topic at boot.
    * `Platform.Agents.MeetingHistorianHandler` — same pattern.

  **Any surface that renders to a human must call
  `list_projects_for_user/2` instead.** Filters, pickers, sidebars and
  LiveViews reaching for this function is exactly the defect ADR-0042
  scoping fixed: foreign-org project names leaked into every one of
  them. The explicit `_unscoped` suffix is deliberate — a future caller
  has to say out loud that it wants the unscoped list.

  ## Options

    * `:org_id` — only return projects belonging to this org (ADR-0042).
      Omit / `nil` → returns every project.
    * `:preload` — Ecto preload spec (atom or list) applied to the result.
      Stage 5 of ADR-0042 uses `preload: :org` so the sidebar group-by-org
      template can read `project.org.slug` without a per-row Repo hit.
  """
  def list_projects_unscoped(opts \\ []) do
    org_id = Keyword.get(opts, :org_id)
    preload = Keyword.get(opts, :preload, [])

    Project
    |> maybe_filter_projects_org(org_id)
    |> order_by([p], asc: p.name)
    |> Repo.all()
    |> Repo.preload(preload)
  end

  @doc """
  List the projects a viewer is allowed to see (ADR-0042).

  The viewer-scoped counterpart to `list_projects_unscoped/1`, which is unscoped
  and returns every project in every org. Any surface that renders
  project names to a user — filters, pickers, sidebars — must read
  through this function, or foreign-org project names leak.

  ## Semantics

    * The viewer scope is resolved once by `Platform.Tenancy.visibility/1`
      and applied **in the query** by `Platform.Tenancy.scope/3` — the
      single choke point every viewer-scoped read goes through. Filtering
      happens in the database, not after the fetch, so there is no window
      in which an unauthorized row exists in memory.
    * A `nil` user — or anything without a binary `:id` — returns `[]`,
      as does a user with zero memberships (`:none` fails closed). An
      unidentified caller is never authorized. Mirrors
      `Platform.Meetings.fetch_meeting_for_user/2`.
    * A member of the **root** org at ANY role sees every project
      (`:root_all`), not just root admins. Rowan's 2026-08-05 ruling:
      sub-orgs are filtering mechanisms, so a root member sees every
      tenant's content. This is deliberately wider than the previous
      `fabrikam_admin?/1`-only bypass. Membership is read from the preloaded
      `:org_memberships` when loaded (zero queries — the live path, since
      `Accounts.get_user/1` preloads), else from the `Repo`.
    * Results stay ordered alphabetically by name, which
      `Platform.Projects.group_by_org/1` documents that it relies on.

  ## Options

  Same as `list_projects_unscoped/1`:

    * `:org_id` — narrow *further* to a single org. It never widens: a
      non-admin asking for an org they do not belong to gets `[]`.
    * `:preload` — Ecto preload spec applied to the result.
  """
  @spec list_projects_for_user(map() | nil, keyword()) :: [Project.t()]
  def list_projects_for_user(user, opts \\ [])

  def list_projects_for_user(%{id: user_id} = user, opts) when is_binary(user_id) do
    org_id = Keyword.get(opts, :org_id)
    preload = Keyword.get(opts, :preload, [])

    visibility = Platform.Tenancy.visibility(user)

    Project
    |> Platform.Tenancy.scope(visibility)
    |> maybe_filter_projects_org(org_id)
    |> order_by([p], asc: p.name)
    |> Repo.all()
    |> Repo.preload(preload)
  end

  def list_projects_for_user(_user, _opts), do: []

  # NOT viewer scoping — a CALLER-supplied narrowing opt, which is why it is
  # a plain `where` and not `Tenancy.scope/3`. It composes AFTER the choke
  # point, so it can only ever intersect with what the viewer may already
  # see; it can never widen. Do not "consolidate" it into `scope/3`.
  defp maybe_filter_projects_org(query, nil), do: query

  defp maybe_filter_projects_org(query, org_id) when is_binary(org_id) do
    where(query, [p], p.org_id == ^org_id)
  end

  @doc """
  List the **independently** archived projects for the recovery surface —
  projects with `archived_at` set whose `archived_cascade_org_id` is NULL
  (i.e. archived on their own, not swept up by an org archive/deletion
  cascade). Cascade-hidden children are intentionally excluded: they come
  back automatically when their org is restored, so listing them as
  separately-restorable rows would be misleading.

  Returns both the purely-archived and the deletion-scheduled states
  (scheduling also stamps `archived_at`), with `:org` preloaded and
  ordered deletion-scheduled-first (soonest deadline first) so the
  recovery LiveView's split into "scheduled" / "archived" buckets keeps
  each bucket in the right order. Read-only companion to
  `list_projects_unscoped/1`; the lifecycle mutators live in
  `Platform.Tenancy.Lifecycle`.
  """
  @spec list_archived_projects() :: [Project.t()]
  def list_archived_projects do
    Project
    |> where([p], not is_nil(p.archived_at) and is_nil(p.archived_cascade_org_id))
    |> Repo.all()
    |> Repo.preload(:org)
    |> Enum.sort_by(fn p ->
      {p.deletion_scheduled_at || ~U[9999-01-01 00:00:00.000000Z], p.name}
    end)
  end

  @doc """
  List EVERY recoverable project for the recovery surface — every project
  with `archived_at` set, **both** the independently-archived ones AND the
  cascade-hidden children of an archived/deletion-scheduled org (no
  `archived_cascade_org_id` filter, unlike `list_archived_projects/0`).

  The unified read `Platform.Tenancy.Lifecycle.list_recoverable/0` consumes
  this: it needs the cascade children as rows in their own right (each
  carrying `archived_cascade_org_id`) so the recovery hub can group them
  under their org instead of hiding them. `list_archived_projects/0` — which
  excludes cascade children — stays as the sidebar's independent-only read.

  Returns both the purely-archived and the deletion-scheduled states with
  `:org` preloaded, ordered deletion-scheduled-first (soonest deadline first)
  then by name. Read-only; the lifecycle mutators live in
  `Platform.Tenancy.Lifecycle`.
  """
  @spec list_recoverable_projects() :: [Project.t()]
  def list_recoverable_projects do
    Project
    |> where([p], not is_nil(p.archived_at))
    |> Repo.all()
    |> Repo.preload(:org)
    |> Enum.sort_by(fn p ->
      {p.deletion_scheduled_at || ~U[9999-01-01 00:00:00.000000Z], p.name}
    end)
  end

  # ── Epics ────────────────────────────────────────────────────────────────

  def create_epic(attrs) do
    with :ok <- Lifecycle.ensure_project_writable(project_id_from(attrs)) do
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
  end

  def update_epic(%Epic{} = epic, attrs) do
    with :ok <- Lifecycle.ensure_project_writable(epic.project_id) do
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

  def create_task(attrs, opts \\ []) do
    with :ok <- Lifecycle.ensure_project_writable(project_id_from(attrs)) do
      do_create_task(attrs, opts)
    end
  end

  defp do_create_task(attrs, opts) do
    %Task{}
    |> Task.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, task} = ok ->
        # Stage 2 (019f3dbb): synchronously refresh task_references from
        # the description (cheap — single INSERT ... ON CONFLICT per
        # match), then fire-and-forget the semantic ingest. Both are
        # advisory to the write path — see Platform.Tasks.References
        # and Platform.Tasks.Indexer for the failure model.
        _ = References.upsert_from_description(task)
        _ = Memory.ingest_async([Indexer.build_entry(task)])
        # M4 (019f9251): sponsor-assigned inbox + push. The before-state is
        # nil (fresh insert), so emit whenever the new task already carries
        # a sponsor. Side-effect only — `ok` is preserved verbatim.
        _ = maybe_emit_sponsor_assigned(nil, task, opts)
        ok

      error ->
        error
    end
  end

  @doc """
  Auto-transition a freshly-created task from `backlog → planning` when it
  carries an agent-typed planning-phase assignee. No-op otherwise.

  Called by `Platform.Federation.ToolSurface :task_create` after
  `create_task/1` + `set_phase_assignees/2` land. Without this hop, a task
  created with `phase_assignees["planning"] = %{"assignee_type" => "agent",
  "assignee_id" => id}` would sit at `backlog` forever —
  `Platform.Orchestration.TaskRouterWatcher.should_run?/1` only spawns a
  router when the task's status is in
  `[\"planning\", \"in_progress\", \"in_review\", \"deploying\"]`, so no
  planner ever dispatches for a `backlog` task.

  Stack members (`stack_id != nil`) are intentionally excluded — the
  stack's own `Stacks.start_planning/1` wave cascade owns backlog →
  planning for its members, and firing this hop would race the wave
  gating.

  Failure model: `transition_task/2` refusals (invalid transition, stack
  gates, deploy gates) are logged at `:warning` and swallowed — the
  caller keeps the un-transitioned task. Auto-planning is advisory to
  the create write; a task created without its planner dispatch is
  recoverable via a subsequent manual transition or an operator
  `task_update`. A hard-fail here would surface a confusing "task
  created but rejected" envelope to MCP callers.

  ## Returns

    * `{:ok, transitioned_task}` when the transition fired and succeeded.
    * `{:ok, task}` when no transition was warranted (wrong status,
      missing/non-agent planning assignee, stack member, blank id).
    * `{:ok, task}` when the transition writer refused; a warning is
      logged with the reason.
  """
  @spec maybe_start_planning_on_create(Task.t()) :: {:ok, Task.t()}
  def maybe_start_planning_on_create(
        %Task{
          status: "backlog",
          stack_id: nil,
          phase_assignees: %{
            "planning" => %{"assignee_id" => id, "assignee_type" => "agent"}
          }
        } = task
      )
      when is_binary(id) and id != "" do
    case transition_task(task, "planning") do
      {:ok, transitioned} ->
        {:ok, transitioned}

      {:error, reason} ->
        Logger.warning(
          "[Tasks] maybe_start_planning_on_create: transition_task refused task_id=#{task.id} reason=#{inspect(reason)} — task stays at backlog"
        )

        {:ok, task}

      {:error, reason, details} ->
        Logger.warning(
          "[Tasks] maybe_start_planning_on_create: transition_task refused task_id=#{task.id} reason=#{inspect(reason)} details=#{inspect(details)} — task stays at backlog"
        )

        {:ok, task}
    end
  end

  def maybe_start_planning_on_create(%Task{} = task), do: {:ok, task}

  @doc """
  Clear the `needs_promotion` flag on `task`, atomically transitioning
  `backlog → planning` when applicable.

  Meeting-triage flow (task 019f5e2b-8d29 stage 2): filed-under-cap tasks
  land with `needs_promotion: true` and render a "Needs promotion" badge
  on the kanban card. Clicking the badge dispatches `promote_task` on
  `PlatformWeb.TasksLive`, which routes here.

  M5b (task 019f6e2c) extends this: when the task is still in `backlog`,
  the single `update_task/2` call also flips `status: "planning"` so the
  planner router dispatches without a second write / second broadcast.
  If the task's status is anything else (already `planning`, `in_progress`,
  etc.), only the flag clears — we never downgrade or re-transition.

  Idempotent by construction:

    * `needs_promotion == false` → no-op, no broadcast (returns `{:ok, task}`).
    * `needs_promotion == true, status == "backlog"` → sets both fields;
      one `:task_updated` broadcast.
    * `needs_promotion == true, status != "backlog"` → clears flag only;
      one `:task_updated` broadcast.
  """
  @spec promote(Task.t()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def promote(%Task{needs_promotion: false} = task), do: {:ok, task}

  def promote(%Task{needs_promotion: true, status: "backlog"} = task) do
    update_task(task, %{needs_promotion: false, status: "planning"})
  end

  def promote(%Task{needs_promotion: true} = task) do
    update_task(task, %{needs_promotion: false})
  end

  def update_task(%Task{} = task, attrs, opts \\ []) do
    task
    |> Task.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        preloaded = Repo.preload(updated, [:project, :epic, :sponsor, plans: :stages])
        broadcast_board({:task_updated, preloaded})
        maybe_sweep_stack_after_update(task, updated)
        maybe_refresh_references(task, updated)
        maybe_reingest_task(task, updated)
        # M4 (019f9251): sponsor-assigned inbox + push. `task` is the
        # before struct, `updated` the after — emit only on a genuine
        # change to a NEW user. Side-effect only — {:ok, updated} preserved.
        _ = maybe_emit_sponsor_assigned(task.sponsor_user_id, updated, opts)
        {:ok, updated}

      error ->
        error
    end
  end

  # ── ADR-0046 planning sub-phase writers (member 4, stage 2) ─────────────
  #
  # These are the ONLY writers for `planning_step` / `planning_step_outcomes`.
  # Both go through `Task.planning_step_changeset/2`, which casts exactly
  # those two fields — deliberately NOT through `Task.changeset/2`, which
  # casts `:status` and therefore makes `update_task/3` an unguarded status
  # writer (see the comment above `Task.changeset/2`).
  #
  # HARD RULE (ADR-0046 member 1): the fire-result → outcome mapping lives in
  # `Platform.Responsibilities.outcome/1` and nowhere else. Do not add a
  # `case` over `{:ok, :dispatched}` / `{:ok, :unfilled}` /
  # `{:ok, :unknown_responsibility}` here — if every consumer derives the
  # mapping, one of them eventually collapses `not_applicable` into `failed`
  # and re-opens the bug closed by
  # `0046-design-and-architecture-phases-in-planning.md § Per-step outcome`.

  @doc """
  Record the outcome of a planning sub-step against a task.

  `fire_result` is a raw `Platform.Responsibilities.fire/2` result. It is
  translated by `Platform.Responsibilities.outcome/1` — the single shared
  mapping — and merged into `planning_step_outcomes` under
  `to_string(step)` as:

      %{"outcome" => "complete" | "not_applicable" | "failed",
        "recorded_at" => <ISO8601 UTC>,
        "detail" => <inspect(reason), truncated to 500 chars> | nil}

  `detail` is populated only for the `{:error, reason}` shape; for the
  three `{:ok, _}` shapes it is `nil`. Recording a second step MERGES —
  an earlier step's entry is preserved.

  Accepts a `%Task{}` or a task id. Either way the row is re-read from the
  database before merging, so a caller holding a stale struct cannot clobber
  a step another writer recorded in between. Unknown id → `{:error, :task_not_found}`.

  ## Transaction semantics

  The write participates in any ambient `Repo.transaction/1`: if the
  surrounding work rolls back, the step genuinely did not happen. That is
  the correct Ecto semantic, and it is proved by a test
  (`planning_step_test.exs`, "transaction semantics") rather than asserted
  here in prose. This function never calls `Repo.rollback/1` itself and
  returns `{:error, changeset}` instead of raising on a validation failure,
  so it cannot abort a parent transaction it did not open.

  The one thing that CAN raise is `Responsibilities.outcome/1`, which has no
  catch-all clause on purpose (an unrecognised fire-result shape is a loud
  `FunctionClauseError`, not a silent mis-map). It is called BEFORE any
  write is attempted, and callers inside a transaction must keep the same
  `try/rescue` envelope the responsibility hooks already use for `fire/2` —
  see the "Consequence for transaction call sites" note on `outcome/1`.

  ## Callers

  `:architecture` is written by `submit_plan_for_review/1` (stage 3).

  `:design` is written by `Platform.Design.PreplanStep` (ADR-0046 member 7),
  which has since landed: `preplan_step.ex:509` on the settle path and
  `:557` on the expiry path. This block used to say `:design` had NO
  production caller and that an absent design outcome was therefore
  expected — that is now false in both halves, and it was being cited
  downstream as a reason to discount empty design results. Production, read
  during task `019fa510` stage 2: four tasks carry a `"design"` outcome, all
  four written on 2026-07-27, all four `outcome: "failed"` with
  `reason: "design_timeout"` exactly 30 minutes after the matching
  `design.task_direction` dispatch. An empty or failed design outcome is a
  measurement, not a placeholder.
  """
  @spec record_planning_step(Task.t() | binary(), :design | :architecture, term()) ::
          {:ok, Task.t()} | {:error, term()}
  def record_planning_step(task_or_id, step, fire_result)
      when step in [:design, :architecture] do
    case resolve_task_for_planning_step(task_or_id) do
      nil ->
        {:error, :task_not_found}

      %Task{} = task ->
        outcome = Platform.Responsibilities.outcome(fire_result)

        entry = %{
          "outcome" => to_string(outcome),
          "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "detail" => planning_step_detail(fire_result)
        }

        merged = Map.put(task.planning_step_outcomes || %{}, to_string(step), entry)

        write_planning_step(task, %{planning_step_outcomes: merged})
    end
  end

  @doc """
  Move a task's planning sub-phase cursor.

  Cursor-only write: the same narrow changeset, the same board broadcast,
  and no other field can ride along. A value outside `Task.planning_steps/0`
  is REJECTED as `{:error, changeset}` rather than raised, so a caller inside
  a transaction cannot be aborted by a bad cursor.

  Note this is a sub-phase of `status == "planning"`, not a status: the task
  stays in whatever status it was in. `Task.statuses/0` is untouched by
  ADR-0046.
  """
  @spec set_planning_step(Task.t() | binary(), :designing | :planning | :architecting) ::
          {:ok, Task.t()} | {:error, term()}
  def set_planning_step(task_or_id, step) do
    case resolve_task_for_planning_step(task_or_id) do
      nil -> {:error, :task_not_found}
      %Task{} = task -> write_planning_step(task, %{planning_step: planning_step_value(step)})
    end
  end

  @doc """
  The planning steps whose recorded outcome is `"failed"`.

  Returns `[%{step: String.t(), detail: String.t() | nil, recorded_at: String.t() | nil}]`,
  ordered by `Task.planning_step_keys/0` so the output is deterministic
  regardless of JSONB key order (Postgres does not preserve insertion order
  for `jsonb`).

  Only `"failed"` is reported. `"not_applicable"` is the progressive-
  enhancement path — nobody holds the responsibility — and must never be
  surfaced as a failure
  (`0046-design-and-architecture-phases-in-planning.md § Per-step outcome`).
  """
  @spec failed_planning_steps(Task.t()) :: [
          %{step: String.t(), detail: String.t() | nil, recorded_at: String.t() | nil}
        ]
  def failed_planning_steps(%Task{} = task) do
    outcomes = task.planning_step_outcomes || %{}

    Task.planning_step_keys()
    |> Enum.flat_map(fn key ->
      case Map.get(outcomes, key) do
        %{"outcome" => "failed"} = entry ->
          [
            %{
              step: key,
              detail: Map.get(entry, "detail"),
              recorded_at: Map.get(entry, "recorded_at")
            }
          ]

        _other ->
          []
      end
    end)
  end

  @doc """
  True when any planning gate was expected to run and did not.

  The single definition of "a gate did not run" — stage 4's two merge-time
  writers (`StackDeployer.build_pr_body/3` and `AutoMerger.execute_merge/4`)
  both call this rather than re-reading the JSONB, so there is exactly one
  place the predicate can drift.
  """
  @spec planning_gate_failed?(Task.t()) :: boolean()
  def planning_gate_failed?(%Task{} = task), do: failed_planning_steps(task) != []

  # Always re-read from the DB: `record_planning_step/3` merges into the
  # stored map, so a stale in-memory struct would silently drop a sibling
  # step's entry.
  defp resolve_task_for_planning_step(%Task{id: id}), do: Repo.get(Task, id)
  defp resolve_task_for_planning_step(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task_for_planning_step(_other), do: nil

  # `detail` carries the failure reason so the merge-time surface can say
  # WHY, not just THAT. Truncated because `reason` can be an arbitrary term
  # (an exception struct, a full HTTP response) and this lands in a JSONB
  # column read by a PR body.
  defp planning_step_detail({:error, reason}), do: reason |> inspect() |> String.slice(0, 500)
  defp planning_step_detail(_other), do: nil

  # Not `to_string/1`: a caller passing a term with no String.Chars impl
  # would raise, and these writers must return errors rather than raise.
  # An unstringifiable value becomes a string that fails validate_inclusion.
  defp planning_step_value(step) when is_atom(step) or is_binary(step), do: to_string(step)
  defp planning_step_value(step), do: inspect(step)

  defp write_planning_step(%Task{} = task, attrs) do
    task
    |> Task.planning_step_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        # Member 8 renders the cursor and the per-step outcomes on the
        # kanban card; the broadcast is what makes that live-refresh
        # without polling. Same topic and payload shape as `update_task/3`.
        preloaded = Repo.preload(updated, [:project, :epic, :sponsor, plans: :stages])
        broadcast_board({:task_updated, preloaded})
        {:ok, updated}

      error ->
        error
    end
  end

  # Stage 2 (019f3dbb) reference-scan refresh. Only re-run the scanner
  # when `description` actually changed — statuses/priorities/assignees
  # don't affect the derived `task_references` set. Advisory failure:
  # the scanner logs at :warning on its own; we don't propagate.
  defp maybe_refresh_references(%Task{description: same}, %Task{description: same}), do: :ok

  defp maybe_refresh_references(_before, %Task{} = after_task) do
    _ = References.upsert_from_description(after_task)
    :ok
  end

  # Stage 2 (019f3dbb) semantic re-ingest. Only re-embed when the corpus
  # inputs (title, description, or metadata["feature_area"]) actually
  # changed — status/priority updates are stored in the payload metadata
  # but don't affect the embedding vector, so re-embedding on every
  # status transition would burn quota for no recall gain.
  defp maybe_reingest_task(%Task{} = before, %Task{} = after_task) do
    title_changed = before.title != after_task.title
    desc_changed = before.description != after_task.description

    feature_changed =
      feature_area_from(before.metadata) != feature_area_from(after_task.metadata)

    if title_changed or desc_changed or feature_changed do
      _ = Memory.ingest_async([Indexer.build_entry(after_task)])
    end

    :ok
  end

  defp feature_area_from(nil), do: nil
  defp feature_area_from(%{} = metadata), do: Map.get(metadata, "feature_area")
  defp feature_area_from(_), do: nil

  # M4 (task 019f9251): emit a `task_sponsor_assigned` inbox row — and a
  # VAPID push — to a user the moment they become a task's ADR-0042 sponsor.
  # Mirrors the M3 analog `maybe_emit_plan_review_inbox/1`: private,
  # side-effect-only (the caller's write result is preserved verbatim),
  # fired POST-COMMIT and wrapped in rescue/catch :exit so an Inbox/PubSub/
  # push failure can NEVER stall the task write or its board broadcast.
  #
  # `before_sponsor_id` is the prior `sponsor_user_id` (nil on create); the
  # `%Task{}` is the post-write struct. Both write seams
  # (`do_create_task/2`, `update_task/3`) funnel here — and both MCP
  # `task_update` and the web board route through `update_task/3` — so this
  # single producer covers every sponsor-write path.
  #
  # PUSH-GAP NOTE (task 019f9251 finding): `Platform.Inbox.emit/1` does NOT
  # push — it only inserts one row and broadcasts `{:inbox_item_added, item}`.
  # NO existing inbox producer pushes either: chat mentions (chat.ex),
  # `maybe_emit_plan_review_inbox/1` (above), and review_requests
  # (tasks/review_requests.ex) all call `Inbox.emit` with no VAPID fan-out.
  # This producer wires push for `task_sponsor_assigned` ONLY; the shared
  # no-push gap on the other producers is a FLAGGED FOLLOW-UP, deliberately
  # not fixed here.
  defp maybe_emit_sponsor_assigned(before_sponsor_id, %Task{} = task, opts) do
    new_sponsor_id = task.sponsor_user_id

    if sponsor_assigned_emit?(before_sponsor_id, new_sponsor_id, opts) do
      title = "You're now sponsoring: #{task.title}"
      body = task.description && String.slice(task.description, 0, 200)
      url = "/tasks/#{task.id}"

      with {:ok, _item} <-
             Platform.Inbox.emit(%{
               user_id: new_sponsor_id,
               kind: "task_sponsor_assigned",
               source_type: "task",
               source_id: task.id,
               title: title,
               body: body,
               url: url
             }) do
        push_sponsor_assigned(new_sponsor_id, %{title: title, body: body, url: url})
      end

      :ok
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("[Inbox] task_sponsor_assigned emit crashed: #{Exception.message(e)}")

      {:error, :inbox_emit_failed}
  catch
    :exit, reason ->
      Logger.warning("[Inbox] task_sponsor_assigned emit exited: #{inspect(reason)}")

      {:error, :inbox_emit_failed}
  end

  # Gate the sponsor-assigned emit. Emit ONLY when the new sponsor is a real
  # user AND it differs from the prior sponsor (nil→user OR userA→userB).
  # This inherently suppresses: clear (new value nil), no-op (unchanged),
  # and unrelated-field updates (sponsor unchanged). SELF-SPONSOR SKIP: when
  # the acting user IS the new sponsor (a human assigning themselves via the
  # web board), suppress — the actor is threaded as `opts[:actor]` and
  # normalized to a user id; agent/system/absent actors never collide.
  defp sponsor_assigned_emit?(before_sponsor_id, new_sponsor_id, opts) do
    is_binary(new_sponsor_id) and
      new_sponsor_id != before_sponsor_id and
      actor_user_id(opts) != new_sponsor_id
  end

  defp actor_user_id(opts) do
    case Keyword.get(opts, :actor) do
      {:user, id} -> id
      _ -> nil
    end
  end

  # Push fan-out for the sponsor-assigned item. The sponsor is a *user*, not a
  # single participant row — and a user has one `chat_participants` row per
  # space. The old path resolved every such row and fanned out per row, which
  # meant the same physical device (endpoint), subscribed under many rows, got
  # pinged once per space: the duplicate-push storm (task 019f9251 follow-up).
  # `fan_out_to_user/3` delegates to `Push.send_to_user/2`, which deduplicates
  # by endpoint and delivers exactly once per device. Routed through the
  # `notifications_module()` indirection (mirroring meeting_notifier) so tests
  # can swap in a Recorder double, and because the real `fan_out_to_user/3`
  # short-circuits push in :test env. Payload keys are `title`/`body`/`url` (the
  # shape both the notifier and the inbox row use). The self-sponsor gate
  # already guarantees the sponsor is not the actor.
  defp push_sponsor_assigned(user_id, %{title: _, body: _, url: _} = payload) do
    notifications_module().fan_out_to_user(user_id, payload)
  end

  defp notifications_module do
    Application.get_env(:platform, :notifications_module, Platform.Notifications)
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
    with :ok <- Lifecycle.ensure_project_writable(task.project_id) do
      do_soft_delete_task(task)
    end
  end

  defp do_soft_delete_task(%Task{} = task) do
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
  def get_task_record(nil), do: nil

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

  # ── Meeting-triage dedup helper ────────────────────────────────────────
  #
  # Statuses considered "open" for dedup purposes. Explicitly excludes
  # `done`, `deploying`, `cancelled` — a terminal or shipping task should
  # NOT block a fresh filing of the same title. `in_review` stays in the
  # set: two agents shouldn't be filing the same review-pending work.
  @dedup_open_statuses ~w(backlog planning blocked in_progress in_review)

  # Minimum candidate title length — shorter titles skip the fuzzy compare
  # entirely to avoid false positives like `String.jaro_distance("fix", "foo")`
  # which sits at 0.777, tolerably below 0.85 but still noisy under variants.
  @dedup_min_candidate_length 6

  @doc """
  Return non-deleted tasks in the same project whose titles are similar to
  `candidate_title` above a Jaro-Winkler-style threshold.

  Used by `Platform.Meetings.Triage.file_tasks_from_canvas/2` as a cheap
  dedup gate — when a fuzzy match exists the caller skips the insert and
  notes the canvas rather than piling a near-duplicate onto the backlog.

  ## Semantics

    * Scope: `t.project_id == project_id AND is_nil(t.deleted_at) AND
      t.status IN #{inspect(@dedup_open_statuses)}`. Done, deploying, and
      cancelled tasks are excluded — a terminal task should not block a
      fresh filing of the same-titled work.
    * Similarity metric: `String.jaro_distance/2` between the normalized
      candidate title and each existing normalized title. Normalization
      lowercases + collapses whitespace so `"Provision Fabrikam Account"` and
      `"provision  fabrikam  account"` compare equal.
    * Threshold: `opts[:threshold]` (float) or the application env
      `:meetings_triage_dedup_threshold` (default `0.85`). Matches at
      exactly the threshold are included (`>=`).
    * Candidates whose normalized title is shorter than
      `#{@dedup_min_candidate_length}` characters short-circuit to `[]`
      without hitting the DB — avoids `"fix"`-class false positives.

  Returns a (potentially empty) list of `%Task{}` structs ordered by
  descending similarity so the caller can take the top match.
  """
  @spec similar_open_titles(binary(), binary(), keyword()) :: [Task.t()]
  def similar_open_titles(project_id, candidate_title, opts \\ [])

  def similar_open_titles(_project_id, title, _opts) when not is_binary(title), do: []

  def similar_open_titles(project_id, candidate_title, opts) when is_binary(project_id) do
    normalized = normalize_title_for_dedup(candidate_title)

    if String.length(normalized) < @dedup_min_candidate_length do
      []
    else
      threshold = dedup_threshold(opts)

      Task
      |> where([t], t.project_id == ^project_id)
      |> where([t], is_nil(t.deleted_at))
      |> where([t], t.status in @dedup_open_statuses)
      |> Repo.all()
      |> Enum.map(fn task ->
        score = String.jaro_distance(normalize_title_for_dedup(task.title), normalized)
        {task, score}
      end)
      |> Enum.filter(fn {_task, score} -> score >= threshold end)
      |> Enum.sort_by(fn {_task, score} -> score end, :desc)
      |> Enum.map(fn {task, _score} -> task end)
    end
  end

  defp normalize_title_for_dedup(nil), do: ""

  defp normalize_title_for_dedup(title) when is_binary(title) do
    title
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp dedup_threshold(opts) do
    Keyword.get(
      opts,
      :threshold,
      Application.get_env(:platform, :meetings_triage_dedup_threshold, 0.85)
    )
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
  Return non-deleted tasks whose `metadata[key] == value`.

  The comparison is a JSONB `->>` string-extract equality on the top-level
  key — nested paths (`metadata.foo.bar`) are NOT supported here (add a
  sibling helper if you need one). The `FindingFiler` dedup gate uses this
  to look up existing tasks by `metadata["security_fingerprint"]` without
  N+1-loading every task in the DB (task 019f3e8e-4406 stage 5).

  Non-string values coerce to string via `to_string/1` at the caller — the
  underlying `->>` operator always yields text so the query stays a single
  index lookup.
  """
  @spec list_tasks_by_metadata_key(String.t(), String.t()) :: [Task.t()]
  def list_tasks_by_metadata_key(key, value) when is_binary(key) and is_binary(value) do
    from(t in Task,
      where:
        fragment("?->>? = ?", t.metadata, ^key, ^value) and
          is_nil(t.deleted_at),
      order_by: [desc: t.inserted_at]
    )
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
  Returns `true` when transitioning `task` to `new_status` is permitted by
  the automated-pipeline transition table (`@valid_task_transitions`).
  Same rules `transition_task_status/2` enforces internally — surfaced as
  a pure predicate so callers can pre-check without triggering a write.

  Used by the MCP `task_update` execute path (task 019f6380 stage 2) to
  skip the plan-approval gate on transitions that would fail as
  `:invalid_transition` anyway — otherwise the gate would mask the
  more-specific transition-table error (e.g. `cancelled → in_progress`,
  where `cancelled` is a terminal state, would surface as
  `:no_approved_plan` instead of the transition-table refusal).
  """
  @spec transition_valid?(Task.t(), String.t()) :: boolean()
  def transition_valid?(%Task{status: current}, new_status) do
    new_status in Map.get(@valid_task_transitions, current, [])
  end

  @doc """
  Transition a task's status, enforcing valid transitions per ADR 0018 §7.
  """
  def transition_task_status(%Task{} = task, new_status) do
    with :ok <- require_deploy_target_for(task, new_status),
         :ok <- require_stack_commencement_for(task, new_status) do
      allowed = Map.get(@valid_task_transitions, task.status, [])

      if new_status in allowed do
        # Task 019fb977 stage 4: the flat pointer is derived BEFORE the
        # write, against the NEW status, and folded into the SAME
        # changeset. It used to be a second `Repo.update` fired after the
        # status commit (`maybe_apply_phase_assignee_and_reload/1`), which
        # left a window in which any reader — `TaskRouterWatcher`'s
        # `list_should_run_tasks/0` and `redispatch_for_runtime/1` are
        # exactly such readers — saw the new status paired with the
        # PREVIOUS phase's assignee.
        pointer_attrs = phase_pointer_attrs(task, new_status)

        task
        |> Task.changeset(Map.put(pointer_attrs, :status, new_status))
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            maybe_dispatch_teardown(updated, new_status)
            # `maybe_apply_phase_assignee/1` is what used to broadcast on a
            # pointer change; folding its write into the status changeset
            # removes that broadcast, so it is re-emitted here with the
            # SAME preloads (`tasks.ex:4978`). A `{:task_updated, ...}`
            # carrying a different association set is a silent break for
            # every `tasks:board` subscriber, the watcher included.
            maybe_broadcast_pointer_move(updated, pointer_attrs)
            maybe_append_timeline(updated, new_status)
            {:ok, updated}

          error ->
            error
        end
      else
        {:error, :invalid_transition}
      end
    end
  end

  # ADR-0044 stage 5: append a line to `docs/architecture/timeline.md` when
  # a task with `metadata.adr_flag` transitions to `done`. Wrapped through
  # `TimelineAppender.maybe_append/1` which itself is `try/rescue`-guarded
  # so a filesystem hiccup never stalls the status change.
  defp maybe_append_timeline(%Task{} = task, "done") do
    Platform.Responsibilities.TimelineAppender.maybe_append(task)
    :ok
  rescue
    error ->
      Logger.warning("[TimelineAppender] transition-hook raised: #{Exception.message(error)}")

      :ok
  catch
    :exit, reason ->
      Logger.warning("[TimelineAppender] transition-hook exited: #{inspect(reason)}")
      :ok
  end

  defp maybe_append_timeline(_task, _new_status), do: :ok

  # Changeset attrs re-deriving the flat `assignee_id` / `assignee_type`
  # pointer from `phase_assignees[current_phase(new_status)]`, for folding
  # into the same write as `status`. Empty map = leave the pointer alone.
  #
  # Resolved against the POST-transition struct so `current_phase/1` and
  # `assignee_for_phase/2` answer for the phase the task is moving INTO,
  # which is the whole point: the MCP `task_update({status: ...})` path
  # calls `transition_task_status/2` directly, bypassing
  # `transition_task/2` + `maybe_finalize_transition/3`, and would
  # otherwise leave the pointer stuck on the previous phase's agent (task
  # 019f42fd: `phase_assignees` intact, `current_phase == "execution"`,
  # flat pointer still at the planning agent).
  #
  # The `Platform.UUID.valid?/1` guard is load-bearing now that this write
  # shares a changeset with `status`. `Task.validate_phase_assignees/1`
  # (`tasks/task.ex:348`) checks only the phase KEYS, so an MCP
  # `task_update` can persist `phase_assignees["execution"]["assignee_id"]
  # == "higgins"`. MEASURED on the pre-fold code, not assumed: the second
  # `Repo.update` did not fail softly into that function's `_error -> :ok`
  # arm — `:binary_id` is a DUMP-time type error, so it RAISED
  # `Ecto.ChangeError` straight out of `transition_task_status/2` (and, on
  # the `in_progress` path, rolled the just-committed status back out of
  # `transition_with_policy2_freeze/2`'s transaction). Folded into one
  # changeset it would raise even more directly. Skipping the pointer is
  # therefore a repair, not just preservation: a malformed phase payload
  # can no longer take a legitimate status transition down with it.
  defp phase_pointer_attrs(%Task{} = task, new_status) do
    next = %{task | status: new_status}
    {phase_id, phase_type} = assignee_for_phase(next, current_phase(new_status))

    cond do
      is_nil(phase_id) ->
        %{}

      phase_id == task.assignee_id and phase_type == task.assignee_type ->
        %{}

      not Platform.UUID.valid?(phase_id) ->
        Logger.warning(
          "[Tasks] task #{task.id}: phase_assignees[#{current_phase(new_status)}] carries a " <>
            "malformed assignee_id #{inspect(phase_id)}; leaving the flat pointer unchanged"
        )

        %{}

      true ->
        %{assignee_id: phase_id, assignee_type: phase_type}
    end
  end

  defp maybe_broadcast_pointer_move(%Task{}, attrs) when map_size(attrs) == 0, do: :ok

  defp maybe_broadcast_pointer_move(%Task{} = updated, _attrs) do
    broadcast_board(
      {:task_updated, Repo.preload(updated, [:project, :epic, :sponsor, plans: :stages])}
    )

    :ok
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

  # Stage 3 of task 019f62a1 (Pin-to-Chat): task-done cascade. Removes
  # every `task_chat_pins` row so the space stops surfacing in each
  # pinner's sidebar rail. Placed in the shared teardown path (not
  # just `maybe_finalize_transition/3 → "done"`) so the MCP
  # `task_complete` / `task_update({status: "done"})` route — which
  # calls `transition_task_status/2` directly — also cascades. Does
  # NOT archive the execution space: plan-engine artifacts, canvases,
  # and message history persist for post-mortem access.
  defp maybe_dispatch_teardown(%Task{} = task, "done") do
    Platform.Tasks.ChatPins.unpin_all_for_task(task.id)
    :ok
  end

  defp maybe_dispatch_teardown(%Task{} = task, "cancelled") do
    TaskRouterSupervisor.stop_assignment(task.id)
    RuntimeSupervision.abandon_current_lease_for_task(task.id, "execution")
    # Stage 3 of task 019f62a1 (Pin-to-Chat): cancelled mirrors done —
    # cascade removes every pin row so cancelled tasks stop bubbling
    # in sidebar rails. Also pin-only, space preserved.
    Platform.Tasks.ChatPins.unpin_all_for_task(task.id)
    :ok
  end

  defp maybe_dispatch_teardown(_task, _new_status), do: :ok

  @doc """
  Central guard: may this task's per-task deploy path (auto-merge shell-out,
  PR-open dispatch, `Deploy: PR merge` stage injection) fire?

  Returns:

    * `:ok` — the task is NOT a stack member; the caller may proceed.
    * `{:error, :stack_ships_atomically}` — the task carries `stack_id`
      and the caller MUST NOT dispatch a per-member deploy. The stack
      rollup PR (T6 / ADR 0041) carries the deploy for every member
      atomically. Emits telemetry
      `[:platform, :tasks, :deploy_dispatch, :rejected_stack_member]`
      with `%{task_id, stack_id}` metadata each time the guard fires,
      making the recurring per-member ship regression cheap to alert on.

  This is the single seam every deploy-dispatch call site must consult so
  the "stacks ship as ONE rollup PR" invariant survives future refactors.
  Callers previously each inlined `is_binary(task.stack_id)` in
  `PlanEngine.maybe_inject_deploy_or_complete/2`,
  `AutoMerger.execute_merge/4`, and `GithubWebhookController`; any new
  path that skips the check silently ships a stack member alone — the
  exact recurring bug ORG_MEMORY `feedback_stack_rollup_ship` warns about.

  Accepts a `%Task{}`, a task id (binary), or `nil`. A `nil` task or a
  task id that doesn't resolve returns `:ok` because there's no stack
  context to violate — the eventual downstream call will fail on its own
  merits.
  """
  @spec dispatch_deploy_for_task(Task.t() | binary() | nil) ::
          :ok | {:error, :stack_ships_atomically}
  def dispatch_deploy_for_task(%Task{stack_id: stack_id} = task) when is_binary(stack_id) do
    Logger.info(
      "[Tasks] dispatch_deploy_for_task rejecting task #{task.id} — stack #{stack_id} " <>
        "ships atomically via rollup PR (stacks ship as ONE rollup PR)"
    )

    :telemetry.execute(
      [:platform, :tasks, :deploy_dispatch, :rejected_stack_member],
      %{count: 1},
      %{task_id: task.id, stack_id: stack_id}
    )

    {:error, :stack_ships_atomically}
  end

  def dispatch_deploy_for_task(%Task{}), do: :ok

  def dispatch_deploy_for_task(task_id) when is_binary(task_id) do
    case get_task_record(task_id) do
      %Task{} = task -> dispatch_deploy_for_task(task)
      nil -> :ok
    end
  end

  def dispatch_deploy_for_task(nil), do: :ok

  @doc """
  Resolve the effective deploy strategy for a task.

  Resolution order:
  1. `task.deploy_strategy` (task-level override) — always wins.
  2. Stack member with a live `rollup_branch` → `%{"type" => "no_op_wait_for_rollup"}`.
     Bug #5 (task 019f708f): the per-member deploy stage MUST NOT open a
     `pr_merge` PR for a stack member, because the stack ships as ONE
     rollup PR via `StackDeployer.maybe_open_stack_pr/1`. A per-member
     PR here would shatter the rollup discipline.
  3. `project.deploy_config["default_strategy"]` (project default).
  4. `%{"type" => "manual"}` (system fallback).

  The task must have `:project` preloaded, or be loaded with project.
  """
  def resolve_deploy_strategy(%Task{} = task) do
    task =
      task
      |> ensure_project_loaded()
      |> Repo.preload(:stack)

    cond do
      task.deploy_strategy ->
        task.deploy_strategy

      stack_member_with_rollup?(task) ->
        %{"type" => "no_op_wait_for_rollup"}

      default = get_in(task.project && task.project.deploy_config, ["default_strategy"]) ->
        default

      true ->
        %{"type" => "manual"}
    end
  end

  # Bug #5 (task 019f708f): a task is a "stack member with a live
  # rollup branch" iff its stack association is loaded, the stack row
  # exists, and its `rollup_branch` is a non-empty binary. That's the
  # only condition under which the stack-level rollup PR path is the
  # source of truth for the deploy.
  defp stack_member_with_rollup?(%Task{stack: %Platform.Tasks.Stack{rollup_branch: rb}})
       when is_binary(rb) and rb != "",
       do: true

  defp stack_member_with_rollup?(_), do: false

  @doc """
  Resolve the ORDERED set of repositories a task's deploy covers.

  Nothing in the schema records which repository a diff landed in: a task
  carries a `project_id`, and the project carries exactly one `repo_url`.
  A task whose work spans two repos — or whose work lives in a repo that
  is not its project's — is therefore indistinguishable from a
  single-repo task, and its deploy gate passes on the first PR that
  merges anywhere. The repo set has to be DECLARED before anything can
  gate on it, and it is declared inside the existing
  `task.deploy_strategy` map (which already wins over the project default
  in `resolve_deploy_strategy/1`), so this costs no migration:

      %{"type" => "pr_merge",
        "config" => %{"auto_merge" => false},
        "repos" => [
          %{"repo_url" => "https://github.com/Startup-Suite/core", "ci" => "required"},
          %{"repo_url" => "Startup-Suite/claude-code-suite-channel", "ci" => "none"}
        ]}

  Returns a list of entries, in declaration order:

      %{repo_url: String.t(), slug: String.t() | nil, config: map(),
        ci: "required" | "none", role: :primary | :secondary}

  Resolution order:

    1. `strategy["repos"]` is a non-empty list → one entry per element.
       The entry's own `"config"` overrides the strategy-level
       `"config"`; `"ci"` defaults to `"required"`; index 0 is
       `:primary`.
    2. otherwise → a single entry from `project.repo_url`, carrying
       `strategy["config"]`, `ci: "required"`, `role: :primary`. This is
       exactly today's behavior for every task that declares nothing.
    3. no resolvable repository → `[]`.

  `[]` means "no git deploy", NOT an error — a project with a blank or
  non-GitHub `repo_url` (`example.invalid` in fixtures) has no PR to
  merge. Callers must treat it that way; `real_repo_url?/1` in
  `HeartbeatScheduler` already draws the same line.

  A DECLARED entry whose `repo_url` will not normalize is KEPT, with
  `slug: nil`, and logged. `DeployStageBuilder.validate_strategy/1`
  refuses those at write time, so one can only arrive by a raw write —
  and dropping it would silently shrink the repo set back to the bug this
  exists to fix. A gate that can never match is a task that hangs; a
  dropped repo is a task that reports success it did not earn.
  """
  @spec resolve_deploy_repos(Task.t()) :: [
          %{
            repo_url: String.t(),
            slug: String.t() | nil,
            config: map(),
            ci: String.t(),
            role: :primary | :secondary
          }
        ]
  def resolve_deploy_repos(%Task{} = task) do
    task = ensure_project_loaded(task)

    repos_from_strategy(resolve_deploy_strategy(task), task.project && task.project.repo_url)
  end

  @doc """
  The pure core of `resolve_deploy_repos/1`: strategy map + project
  `repo_url` in, ordered repo entries out. No `Repo` access, no `%Task{}`.

  `resolve_deploy_repos/1` is the entry point whenever you hold a real
  `%Task{}` — it preloads the project for you and is what
  `DeployStageBuilder` and the webhook path resolve through. This arity
  exists for the ONE caller that cannot use it: `HeartbeatScheduler`
  renders dispatch prompts for plain maps as well as structs (its whole
  test file is `async: true` with no database checked out), and
  `ensure_project_loaded/1` would both `FunctionClauseError` on a map and
  hit the `Repo` from an unsandboxed process.

  Extracting the core rather than duplicating it is the point: prompt text
  and deploy gates must never disagree about which repositories a task
  covers, and a second `Map.get(strategy, "repos")` walk in
  `HeartbeatScheduler` is exactly the independently-drifting derivation
  `RepoRef`'s moduledoc argues against.
  """
  @spec repos_from_strategy(map(), String.t() | nil) :: [
          %{
            repo_url: String.t(),
            slug: String.t() | nil,
            config: map(),
            ci: String.t(),
            role: :primary | :secondary
          }
        ]
  def repos_from_strategy(strategy, project_repo_url) when is_map(strategy) do
    strategy_config = Map.get(strategy, "config", %{})

    case Map.get(strategy, "repos") do
      repos when is_list(repos) and repos != [] ->
        repos
        |> Enum.with_index()
        |> Enum.map(&declared_repo_entry(&1, strategy_config))

      _ ->
        project_repo_entry(project_repo_url, strategy_config)
    end
  end

  defp declared_repo_entry({entry, index}, strategy_config) when is_map(entry) do
    repo_url = Map.get(entry, "repo_url")
    slug = RepoRef.slug(repo_url)

    if is_nil(slug) do
      Logger.warning(
        "[Tasks] declared deploy repo #{inspect(repo_url)} is not a recognizable GitHub " <>
          "repository — keeping it with a nil slug so its gate cannot be matched by accident"
      )
    end

    %{
      repo_url: if(is_binary(repo_url), do: repo_url, else: ""),
      slug: slug,
      config: Map.merge(strategy_config, Map.get(entry, "config", %{})),
      ci: normalize_repo_ci(Map.get(entry, "ci", "required"), repo_url),
      role: if(index == 0, do: :primary, else: :secondary)
    }
  end

  defp declared_repo_entry({other, index}, strategy_config) do
    declared_repo_entry({%{"repo_url" => other}, index}, strategy_config)
  end

  defp project_repo_entry(repo_url, strategy_config) do
    case RepoRef.normalize(repo_url) do
      {:ok, slug} ->
        [
          %{
            repo_url: repo_url,
            slug: slug,
            config: strategy_config,
            ci: "required",
            role: :primary
          }
        ]

      # Blank, missing, `example.invalid`, or any non-GitHub URL: there is
      # no PR to merge, so there is no repo to gate.
      :error ->
        []
    end
  end

  defp normalize_repo_ci(ci, _repo_url) when ci in ["required", "none"], do: ci

  defp normalize_repo_ci(other, repo_url) do
    Logger.warning(
      "[Tasks] declared deploy repo #{inspect(repo_url)} has invalid ci #{inspect(other)} — " <>
        "treating as \"required\" (gating is the safe default)"
    )

    "required"
  end

  @doc """
  `resolve_deploy_strategy/1` with the resolved repository set attached.

  This is what deploy-stage construction consumes, so
  `DeployStageBuilder.build_stage/3` stays a pure map → map function with no
  `Repo` access. Its third argument, the recorded branch, is resolved by the
  CALLER (`PlanEngine`, via `StackDeployer.member_branch_for/1`) and handed in
  already-computed, so the builder still touches no `Repo`.

  The `"repos"` key is written back in the NORMALIZED shape — one
  string-keyed map per repository, carrying `"repo_url"`, `"slug"`,
  `"config"`, `"ci"` and `"role"` — so a consumer never has to redo the
  merge of strategy-level and per-entry config.

  When the repo set resolves EMPTY (no declared repos and no usable
  `project.repo_url`) the key is left ABSENT rather than written as `[]`.
  An empty list would read downstream as "build one gate per repo, of
  which there are none" — a deploy stage with zero validations, which
  auto-passes. Absent means "nothing was declared", which is the state
  every pre-existing task is in and which resolves to today's single
  unscoped gate.
  """
  @spec resolve_deploy_strategy_with_repos(Task.t()) :: map()
  def resolve_deploy_strategy_with_repos(%Task{} = task) do
    task = ensure_project_loaded(task)
    strategy = resolve_deploy_strategy(task)

    case resolve_deploy_repos(task) do
      [] -> Map.delete(strategy, "repos")
      repos -> Map.put(strategy, "repos", Enum.map(repos, &repo_entry_to_map/1))
    end
  end

  defp repo_entry_to_map(entry) do
    %{
      "repo_url" => entry.repo_url,
      "slug" => entry.slug,
      "config" => entry.config,
      "ci" => entry.ci,
      "role" => Atom.to_string(entry.role)
    }
  end

  @doc """
  Resolve the effective deploy target for a task.

  Resolution order:
  1. `task.deploy_target` (task-level override) → `{:explicit, target}`
  2. `project.deploy_config["default_deploy_target"]` (project default) → `{:inherited, target}`
  3. `project.deploy_config["deploy_targets"]` is a SOLE-entry list of one
     binary → `{:inherited, sole_entry}` (implicit-default inference)
  4. Nothing set (or multi-entry list without an explicit default) → `:none`

  Empty strings are treated as unset. Mirrors `resolve_deploy_strategy/1` and
  the existing `deploy_config["default_strategy"]` convention. No schema
  change: `deploy_config` is already `field(:deploy_config, :map, default: %{})`.

  The sole-entry inference addresses the v1 gap: real-world projects
  (including the Suite dogfood project) configure the enumerated
  `deploy_targets` list rather than the explicit `default_deploy_target`
  key. When the list has exactly one entry there is no ambiguity to
  resolve, so inheritance is safe. Multi-entry lists still fall through to
  `:none` unless the user picks a specific default — implicit inference on
  ambiguous input would silently ship to the wrong target.

  The task must have `:project` preloaded, or be loaded with project.
  """
  @spec resolve_deploy_target(Task.t()) ::
          {:explicit, String.t()} | {:inherited, String.t()} | :none
  def resolve_deploy_target(%Task{} = task) do
    task = ensure_project_loaded(task)

    deploy_config = (task.project && task.project.deploy_config) || %{}
    project_default = Map.get(deploy_config, "default_deploy_target")
    deploy_targets = Map.get(deploy_config, "deploy_targets")

    cond do
      is_binary(task.deploy_target) and task.deploy_target != "" ->
        {:explicit, task.deploy_target}

      is_binary(project_default) and project_default != "" ->
        {:inherited, project_default}

      match?([entry] when is_binary(entry) and entry != "", deploy_targets) ->
        [sole_entry] = deploy_targets
        {:inherited, sole_entry}

      true ->
        :none
    end
  end

  @doc """
  True when the task has a resolvable deploy target (explicit or inherited).

  Used by the `:deploying` transition guard to refuse deploys when neither the
  task nor its project has a target configured.
  """
  @spec has_deploy_target?(Task.t()) :: boolean()
  def has_deploy_target?(%Task{} = task), do: resolve_deploy_target(task) != :none

  @doc "Ensures the task has its project association loaded."
  def ensure_project_loaded(%Task{project: %Project{}} = task), do: task
  def ensure_project_loaded(%Task{} = task), do: Repo.preload(task, :project)

  # ── Plans ────────────────────────────────────────────────────────────────

  @doc """
  Create a plan for a task.

  The project write-freeze keystone: a plan is how new work *starts*, and it
  is reachable without ever calling `create_task/1` (an agent can plan a
  pre-existing backlog task). Guarding only task creation would leave that
  door open, so an archived project is rejected here too — one hop, on a
  lookup this function already pays for.

  Stages and validations underneath are deliberately NOT guarded: blocking
  the chain at its head means the tail only ever contains plans created
  before the archive, which is exactly the in-flight work that should drain.
  """
  def create_plan(attrs) do
    case task_id_from(attrs) do
      nil ->
        do_create_plan(attrs)

      task_id ->
        with :ok <- Lifecycle.ensure_task_project_writable(task_id) do
          case latest_plan(task_id) do
            %Plan{status: status} when status in ["draft", "pending_review"] ->
              {:error, :plan_pending_review}

            _ ->
              do_create_plan(attrs)
          end
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

  # Attrs reach the context with either atom or string keys depending on the
  # caller (LiveView forms vs MCP tools). A missing project_id falls through
  # to nil, which the guard treats as :ok so `validate_required` reports it.
  defp project_id_from(%{project_id: id}) when is_binary(id), do: id
  defp project_id_from(%{"project_id" => id}) when is_binary(id), do: id
  defp project_id_from(_), do: nil

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

  # The responsibility the plan-time architect holds. Named once so the
  # dispatch (`fire_architecture_review_plan/1`) and the assignee lookup
  # (`architect_agent_id/0`) can never drift onto different keys — they
  # are two reads of the same question and a typo in one would open a
  # gate crediting nobody.
  @architecture_responsibility_key "architecture.review_plan"

  def submit_plan_for_review(%Plan{status: "draft"} = plan) do
    case plan |> Plan.changeset(%{status: "pending_review"}) |> Repo.update() do
      {:ok, updated} ->
        # ADR-0044 stage 2: architect plan-time review hook.
        # Progressive enhancement — no-ops when no architect is
        # assigned. Wrapped in try/rescue/catch :exit so a handler
        # crash cannot stall the plan_submit → pending_review
        # transition (memory ref: `[Suite engine quirks]` cascade-fix
        # 019f3440). The Router internally swallows dispatch crashes
        # too; this belt-and-braces wrap protects against future
        # Router-shape changes.
        #
        # ADR-0046 member 4 stage 3: the fire result is no longer thrown
        # away. The cursor moves to `:architecting` for the duration of the
        # dispatch (what the task genuinely IS while the architect is being
        # asked), the outcome is persisted, and the cursor returns to
        # `:planning`. Everything here is side-effect only — the
        # `{:ok, plan}` return of this function is preserved verbatim,
        # matching `maybe_emit_plan_review_inbox/1` below.
        #
        # SCOPE BOUNDARY vs the sibling ADR-0046 stack members:
        #   * Member 5 owns the architecture GATE — blocking approval on the
        #     recorded outcome and redefining `auto_approve_plan`. This code
        #     only RECORDS; `maybe_auto_approve/1` below is untouched and no
        #     approval behaviour changes. Member 5's seam is the second
        #     cursor move: it stops returning the cursor to `:planning`
        #     until the gate resolves.
        #   * Member 7 owns the DESIGN step. `record_planning_step/3`
        #     accepts `:design` and is tested, but has no production caller
        #     yet — deliberate, not an oversight (see its `@doc`).
        #   * Member 8 owns card rendering. Nothing here touches a `.heex`,
        #     `assets/`, or a LiveView; the `{:task_updated, _}` broadcast
        #     that `set_planning_step/2` and `record_planning_step/3` emit
        #     is the whole of member 8's dependency on this stage.
        _ = move_planning_cursor(updated.task_id, :architecting)

        fire_result = fire_architecture_review_plan(updated)

        _ = record_architecture_planning_step(updated.task_id, fire_result)

        broadcast_board({:plan_updated, updated})

        case architecture_fire_outcome(fire_result) do
          :complete ->
            open_architecture_gate_at_submit(updated)

          outcome when outcome in [:not_applicable, :failed] ->
            # PROGRESSIVE ENHANCEMENT, and it is load-bearing rather than
            # a nicety: these two branches execute the BYTE-IDENTICAL tail
            # that ran before the gate existed, in the same order. A repo
            # with no architect assigned behaves exactly as it does today
            # (`0044-architect-responsibility.md § Decision`, ADR-0046
            # decision 3). `:failed` FALLS OPEN
            # (ADR-0046 decision 7) — the gate never opens and nothing is
            # blocked. Its visibility is already solved and must not be
            # re-solved here: `record_architecture_planning_step/2` above
            # wrote `planning_step_outcomes["architecture"]["outcome"] =
            # "failed"`, which member 4's merge-time writers surface.
            settle_ungated_plan_submission(updated)

          other ->
            # `Platform.Responsibilities.outcome/1` deliberately has no
            # catch-all, so this arm is only reachable if a future value
            # is ADDED to its union. Fall open and be loud: an outcome
            # this function has never seen is not evidence the architect
            # took the slot, and a `CaseClauseError` here would abort a
            # transition whose row is already committed.
            Logger.error(
              "[Tasks] architecture.review_plan unmapped outcome #{inspect(other)} " <>
                "plan=#{updated.id} task=#{updated.task_id} — gate not opened"
            )

            settle_ungated_plan_submission(updated)
        end

      error ->
        error
    end
  end

  def submit_plan_for_review(_plan), do: {:error, :invalid_transition}

  # ── ADR-0046 member 5 stage 2: the gate branch ─────────────────────────
  #
  # `:complete` from `Platform.Responsibilities.outcome/1` means THE
  # ARCHITECT NOW HOLDS THE SLOT. It does NOT mean "the architect
  # answered", and a reader who assumes otherwise will write a bug.
  #
  # Verified against production: `Platform.Roles.assignee_for/1` resolves
  # `architecture.review_plan` to a `kind: "native"` agent, so the Router
  # branches into `dispatch_native/4`, which is a HANDOFF —
  # `AgentResponder.maybe_dispatch/1` wraps the work in `Task.start/1` and
  # returns `:ok` unconditionally. `handle_output/3` is only reachable from
  # `run_external_dispatch/5`. THERE IS NO SYNCHRONOUS VERDICT for the
  # configuration actually deployed.
  #
  # Hence the gate is ASYNCHRONOUS: it opens here, on dispatch, and closes
  # on a later verdict (stage 4) or a deadline (stage 5). The alternative —
  # making `fire_trigger/3` hand back the parsed output so the gate could
  # resolve inline — was rejected because it widens member 1's return union
  # for one caller AND puts a full LLM round-trip inside a function the MCP
  # `plan_submit` tool calls synchronously.
  #
  # The cursor deliberately STAYS at `:architecting`: that is what the task
  # genuinely IS while the gate holds, and it is the seam member 4's plan
  # predicted ("member 5 will simply stop returning the cursor to
  # `:planning` until the gate resolves").
  defp open_architecture_gate_at_submit(%Plan{} = updated) do
    case open_architecture_gate(updated, architect_agent_id()) do
      {:ok, gated} ->
        emit_architecture_gate_opened(gated)
        broadcast_board({:plan_updated, gated})
        {:ok, gated}

      {:error, reason} ->
        # The gate could not be persisted. FALL OPEN, same rule as
        # `:failed` — a bookkeeping fault must not be able to strand a
        # plan, and a gate nobody can read is not a gate.
        Logger.error(
          "[Tasks] architecture gate failed to open plan=#{updated.id} " <>
            "task=#{updated.task_id} reason=#{inspect(reason)} — falling open"
        )

        settle_ungated_plan_submission(updated)
    end
  rescue
    e ->
      Logger.error(
        "[Tasks] architecture gate open crashed plan=#{updated.id} " <>
          "task=#{updated.task_id} error=#{Exception.message(e)} — falling open"
      )

      settle_ungated_plan_submission(updated)
  catch
    :exit, reason ->
      Logger.error(
        "[Tasks] architecture gate open exited plan=#{updated.id} " <>
          "task=#{updated.task_id} exit=#{inspect(reason)} — falling open"
      )

      settle_ungated_plan_submission(updated)
  end

  # ── Task 019fa605 stage 4: make the unrouted-gate class visible AT OPEN ──
  #
  # THE OPERATOR QUESTION THIS ANSWERS: "how do I find out that a gate just
  # opened on a task nothing will ever settle?" Stages 1-3 heal that stall,
  # but only after the deadline, and only as a counter on a reconcile line
  # that names no task. This is the one place in the system that knows —
  # synchronously, at the moment the gate is persisted — both that a gate is
  # now holding a plan and whether anything exists that will arm its
  # deadline. `routed` records that fact once, keyed to the plan.
  #
  # `TaskRouterWatcher.should_run?/1` is pure struct reads and
  # `Platform.Orchestration.TaskRouterWatcher` is already in this module's
  # alias block, so this adds no dependency edge and no query beyond the
  # `Repo.get/2` it needs.
  #
  # THE ENVELOPE IS LOAD-BEARING AND ITS OWN, NOT THE CALLER'S. This runs
  # inside a committed `draft -> pending_review` transition, and
  # `open_architecture_gate_at_submit/1`'s function-level rescue FALLS OPEN
  # by calling `settle_ungated_plan_submission/1` — which, on a gate that
  # HAS ALREADY PERSISTED, is wrong twice over. MEASURED, not assumed: with
  # this envelope removed and a fault injected here, an armed task's submit
  # returns `{:error, :architecture_gate_open}` — `approve_plan/3` correctly
  # refuses the open gate, so the plan is not auto-approved, but the MCP
  # `plan_submit` caller is told a committed, correctly-gated submit FAILED
  # and will retry or report a stall. The same path also moves the planning
  # cursor back to `:planning` while the gate is genuinely holding, and runs
  # the ungated sponsor-Inbox tail. An observer never gets to change the
  # outcome it observes — the rule stated at `fire_architecture_review_plan/1`.
  #
  # (`:telemetry.execute/3` catches and detaches a failing handler itself,
  # so a third-party observer cannot reach here. The faults this guards are
  # the ones on OUR side of the emit — the `Repo.get/2` exiting during
  # sandbox teardown, in the shape documented at `resolve_runtime_for_task/1`
  # and `boot_reconcile/0`.)
  defp emit_architecture_gate_opened(%Plan{} = gated) do
    task = Repo.get(Task, gated.task_id)
    routed = TaskRouterWatcher.should_run?(task)
    deadline_at = gated.architecture_verdict["deadline_at"]

    :telemetry.execute(
      [:platform, :plan, :architecture_gate_opened],
      %{count: 1},
      %{
        plan_id: gated.id,
        task_id: gated.task_id,
        routed: routed,
        deadline_at: deadline_at,
        resource_type: "plan",
        resource_id: gated.id,
        action: "architecture_gate_opened",
        actor_type: "system"
      }
    )

    unless routed do
      # ONE line, at open time, naming the task and the settler. Not a
      # warning: this configuration is SUPPORTED — it is merely the
      # arrangement whose settlement comes from the sweep rather than from a
      # router timer. Logging it at :warning would train operators to ignore
      # a line that describes a healthy system. The ruling is recorded at
      # `0046-design-and-architecture-phases-in-planning.md § Addendum (2026-07-28, task 019fa605): a user planning assignee under auto-approval is supported`
      # (kept contiguous on one line so the ADR-citation audit can resolve it).
      Logger.info(
        "[Tasks] architecture gate opened with no router: task=#{gated.task_id} " <>
          "plan=#{gated.id} deadline=#{deadline_at} — nothing will arm " <>
          "{:architecture_gate_deadline, _}; the settler is " <>
          "TaskRouterWatcher.sweep_expired_architecture_gates/0, within one " <>
          "reconcile tick after the deadline."
      )
    end

    :ok
  rescue
    e ->
      Logger.error(
        "[Tasks] architecture gate open telemetry crashed plan=#{gated.id} " <>
          "task=#{gated.task_id} error=#{Exception.message(e)} — gate stands"
      )

      :ok
  catch
    :exit, reason ->
      Logger.error(
        "[Tasks] architecture gate open telemetry exited plan=#{gated.id} " <>
          "task=#{gated.task_id} exit=#{inspect(reason)} — gate stands"
      )

      :ok
  end

  # Return the cursor to `:planning` and run the deferred tail. Every
  # non-gated exit from `submit_plan_for_review/1` funnels through here so
  # "the gate did not hold this plan" is one statement, not four.
  defp settle_ungated_plan_submission(%Plan{} = updated) do
    _ = move_planning_cursor(updated.task_id, :planning)
    settle_plan_submission(updated)
  end

  # THE TAIL. Extracted verbatim from `submit_plan_for_review/1` because
  # stage 3's `resolve_architecture_gate/2` calls this SAME function when
  # the gate resolves — the gated and ungated paths must not be able to
  # drift. Two copies of "what happens after plan review finishes" is how
  # the gated path silently stops emitting the sponsor row a year from now.
  defp settle_plan_submission(%Plan{} = updated) do
    case maybe_auto_approve(updated) do
      {:ok, settled} = result ->
        # M3 (task 019f904c): notify the task sponsor that a plan is
        # awaiting human review. Fires against the SETTLED plan so an
        # auto-approved plan (no human gate) skips the notification.
        # Side-effect only — the return value is preserved verbatim.
        #
        # ADR-0046 member 5: on the GATED path this does not run at submit
        # — the human's turn has not arrived while the architect is still
        # looking. It runs when the gate resolves, which is the correct
        # order, not a lost notification.
        _ = maybe_emit_plan_review_inbox(settled)
        result

      other ->
        other
    end
  end

  # The gate's read of the fire result.
  #
  # HARD RULE (ADR-0046 member 1): `Platform.Responsibilities.outcome/1` is
  # the ONLY translation from a fire result to an outcome, so this wrapper
  # adds an envelope and nothing else — no local mapping, no second `case`
  # over router return shapes.
  #
  # The envelope exists because `outcome/1` deliberately has no catch-all
  # clause and therefore RAISES on a shape it has never seen, while this
  # call site sits after a committed `draft -> pending_review` update and is
  # reached synchronously from the MCP `plan_submit` tool. An unrecognised
  # shape must not turn into a failed plan submission.
  #
  # `:unmapped` is deliberately NOT `:failed`: the caller falls open on
  # both, but only `:failed` is an architect that was asked and did not
  # answer. Collapsing them is the conflation forbidden by
  # `0046-design-and-architecture-phases-in-planning.md § Per-step outcome`, and
  # `record_architecture_planning_step/2` already refuses to make it.
  defp architecture_fire_outcome(fire_result) do
    Platform.Responsibilities.outcome(fire_result)
  rescue
    _ -> :unmapped
  catch
    :exit, _ -> :unmapped
  end

  # Who the gate is waiting on, recorded on the verdict so a reader can
  # tell WHICH architect holds the slot.
  #
  # Yes, this resolves the assignee a second time — the Router already did
  # it inside `fire_trigger/3`. The alternative is threading the assignee
  # back out through member 1's `{:ok, :dispatched} | ...` return union,
  # which three other stack members depend on, for one caller's
  # convenience. Two cheap reads beat a contract change.
  #
  # `nil` on any miss: an unattributed gate is still a gate, and a lookup
  # fault must not be able to stall the submission.
  defp architect_agent_id do
    case Platform.Roles.assignee_for(@architecture_responsibility_key) do
      %Agent{id: id} -> id
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # ADR-0044 stage 2 helper. Kept private so `submit_plan_for_review/1`
  # reads as a linear transition and the hook is the only public
  # surface the plan-approval flow depends on.
  #
  # ADR-0046 member 1 stage 4: the fire result is now INSPECTED rather
  # than discarded. Before stages 1-2 gave `Responsibilities.fire/2` a
  # real return contract, an architect endpoint that was down looked
  # exactly like "no architect assigned" here — the plan silently went
  # to review unreviewed, with nothing in the log to say so.
  #
  # LOAD-BEARING (verified, do not weaken): this helper MUST NOT raise.
  # It runs inside the `draft → pending_review` transition documented at
  # `submit_plan_for_review/1`, and a raise would abort that transition.
  # The branches below only log and return — no `raise`, no `!`-suffixed
  # call, and `plan` is a `%Plan{}` by the function head so `plan.id` /
  # `plan.task_id` cannot blow up on nil. Errors are RETURNED, never
  # raised. The value is returned on every branch so a future ADR-0046
  # consumer can lift it (the call site at `submit_plan_for_review/1`
  # still discards it via `_ =`).
  defp fire_architecture_review_plan(%Plan{} = plan) do
    case Platform.Responsibilities.fire(@architecture_responsibility_key, %{
           plan_id: plan.id,
           task_id: plan.task_id,
           plan: plan
         }) do
      {:error, reason} = result ->
        Logger.warning(
          "[Responsibilities] architecture.review_plan dispatch failed " <>
            "plan=#{plan.id} task=#{plan.task_id} reason=#{inspect(reason)}"
        )

        result

      {:ok, state} = result when state in [:unfilled, :unknown_responsibility] ->
        # Progressive enhancement, not a problem: no architect holds the
        # responsibility (or the key was never seeded). Info, not warning
        # — this is the steady state on a suite with no architect.
        Logger.info(
          "[Responsibilities] architecture.review_plan #{state} " <>
            "plan=#{plan.id} task=#{plan.task_id}"
        )

        result

      # {:ok, :dispatched} — the Router already logged the dispatch.
      result ->
        result
    end
  rescue
    e ->
      Logger.warning(
        "[Responsibilities] architecture.review_plan crashed: #{Exception.message(e)}"
      )

      {:error, :architect_crashed}
  catch
    :exit, reason ->
      Logger.warning("[Responsibilities] architecture.review_plan exited: #{inspect(reason)}")

      {:error, :architect_crashed}
  end

  # ADR-0046 member 4 stage 3. Persists the architecture step's outcome.
  #
  # Runs OUTSIDE `fire_architecture_review_plan/1`'s rescue, on purpose: the
  # fire result is captured first and recorded second, so a crash in the
  # RECORDER can never be logged as "the architect crashed" and can never be
  # mapped onto `"failed"` for the architecture step. A persistence bug must
  # not be attributed to the architect.
  #
  # It carries its OWN envelope for a different reason.
  # `Platform.Responsibilities.outcome/1` deliberately has no catch-all
  # clause, so a fire-result shape it has never seen raises
  # `FunctionClauseError` — and its `@doc` instructs call sites that cannot
  # afford a raise to wrap it in the same envelope the hooks already use for
  # `fire/2`. This is such a call site twice over: `submit_plan_for_review/1`
  # is fire-and-forget by the ADR-0044 contract, and `plan_submit` in
  # `Platform.Federation.ToolSurface` is a live agent-facing caller, so an
  # unrecognised Router return value must not turn into a failed plan
  # submission. (`submit_plan_for_review/1` is not itself transaction-nested
  # — checked: no caller wraps it in `Repo.transaction/1`. This envelope is
  # what keeps that true for a future one.)
  #
  # An unmapped shape is loud but harmless: logged at :error with the shape
  # verbatim, and NOTHING is written. The `"architecture"` key stays absent,
  # which is distinguishable from all three of complete / not_applicable /
  # failed. It is specifically NOT recorded as `"failed"` — that silent
  # mis-map is the exact thing member 1's missing catch-all exists to
  # prevent
  # (`0046-design-and-architecture-phases-in-planning.md § Per-step outcome`).
  defp record_architecture_planning_step(task_id, fire_result) do
    record_planning_step(task_id, :architecture, fire_result)
  rescue
    e ->
      Logger.error(
        "[Responsibilities] architecture.review_plan outcome unrecorded " <>
          "task=#{inspect(task_id)} fire_result=#{inspect(fire_result)} " <>
          "error=#{Exception.message(e)}"
      )

      {:error, :planning_step_unrecorded}
  catch
    :exit, reason ->
      Logger.error(
        "[Responsibilities] architecture.review_plan outcome unrecorded " <>
          "task=#{inspect(task_id)} fire_result=#{inspect(fire_result)} " <>
          "exit=#{inspect(reason)}"
      )

      {:error, :planning_step_unrecorded}
  end

  # ADR-0046 member 4 stage 3. Cursor-only sibling of the above, same
  # non-raising contract for the same reason: a cursor move is bookkeeping
  # and must never be able to stall the `draft → pending_review` transition.
  # `set_planning_step/2` already RETURNS `{:error, changeset}` for an
  # out-of-domain value and `{:error, :task_not_found}` for a missing row;
  # the envelope covers what it cannot (a PubSub or DB fault under the
  # broadcast).
  defp move_planning_cursor(task_id, step) do
    set_planning_step(task_id, step)
  rescue
    e ->
      Logger.warning(
        "[Tasks] planning cursor move failed task=#{inspect(task_id)} " <>
          "step=#{inspect(step)} error=#{Exception.message(e)}"
      )

      {:error, :planning_cursor_unmoved}
  catch
    :exit, reason ->
      Logger.warning(
        "[Tasks] planning cursor move exited task=#{inspect(task_id)} " <>
          "step=#{inspect(step)} exit=#{inspect(reason)}"
      )

      {:error, :planning_cursor_unmoved}
  end

  # M3 (task 019f904c): emit a `task_plan_review` inbox row to the task
  # SPONSOR when a plan lands in `pending_review` for human review.
  #
  # Fires against the SETTLED plan (post `maybe_auto_approve/1`): an
  # auto-approved plan has no human gate, so the `status == "pending_review"`
  # check alone suppresses the row. Wrapped in try/rescue/catch :exit
  # (mirroring `fire_architecture_review_plan/1`) so an Inbox/PubSub failure
  # can never stall the plan_submit → pending_review transition or the board
  # broadcast. No dedup — a v2 plan superseding a rejected v1 travels this
  # same path and simply emits another row (M1 "dismiss = gone" model).
  defp maybe_emit_plan_review_inbox(%Plan{} = settled) do
    case Repo.get(Task, settled.task_id) do
      nil ->
        :ok

      %Task{} = task ->
        {planner_id, planner_type} = assignee_for_phase(task, "planning")

        if plan_review_inbox_emit?(settled, task, planner_id, planner_type) do
          plan = Repo.preload(settled, stages: :validations)
          stage_count = length(plan.stages)

          validation_count =
            Enum.reduce(plan.stages, 0, fn s, acc -> acc + length(s.validations) end)

          Platform.Inbox.emit(%{
            user_id: task.sponsor_user_id,
            kind: "task_plan_review",
            source_type: "task",
            source_id: task.id,
            title: "Plan ready for review: #{task.title}",
            body:
              "Planner: #{planner_display_name(task)} · Stages: #{stage_count} · Validations: #{validation_count}",
            url: "/tasks/#{task.id}"
          })

          :ok
        else
          :ok
        end
    end
  rescue
    e ->
      Logger.warning("[Inbox] task_plan_review emit crashed: #{Exception.message(e)}")

      {:error, :inbox_emit_failed}
  catch
    :exit, reason ->
      Logger.warning("[Inbox] task_plan_review emit exited: #{inspect(reason)}")

      {:error, :inbox_emit_failed}
  end

  # Gate for the sponsor plan-review inbox row. Emit ONLY when the plan is
  # still awaiting a human gate, the task opted into review (not auto-approve),
  # a sponsor exists, the task is not terminal, and the sponsor did not author
  # the plan themselves (self-notify guard).
  defp plan_review_inbox_emit?(%Plan{} = settled, %Task{} = task, planner_id, planner_type) do
    settled.status == "pending_review" and
      task.auto_approve_plan == false and
      is_binary(task.sponsor_user_id) and
      task.status not in ~w(done cancelled) and
      not (planner_type == "user" and planner_id == task.sponsor_user_id)
  end

  # Resolve a human-readable name for the task's planning-phase assignee, for
  # the inbox row body. Falls back to "the planner" when the assignee is
  # unset or the referenced row is missing.
  defp planner_display_name(%Task{} = task) do
    case assignee_for_phase(task, "planning") do
      {id, "agent"} when is_binary(id) ->
        case Repo.get(Agent, id) do
          %Agent{name: name} when is_binary(name) -> name
          _ -> "the planner"
        end

      {id, "user"} when is_binary(id) ->
        case Accounts.get_user(id) do
          %Accounts.User{name: name} when is_binary(name) -> name
          _ -> "the planner"
        end

      _ ->
        "the planner"
    end
  end

  # Auto-approve branch (task 019f25f2 stage 2 + Stack v2 stage 4): fire when
  # EITHER the parent task carries the opt-in `auto_approve_plan` flag OR
  # the parent task's stack carries `auto_accept_plan: true`. Both signals
  # short-circuit the freshly-submitted plan through `approve_plan/3` with
  # `auto: true` so it lands `approved` with `auto_approved_at` stamped —
  # provided the precondition passes (plan has stages, task has execution +
  # review assignees). On skip we leave the plan in `pending_review` and
  # log which precondition failed so operators can diagnose flag-on tasks
  # that didn't auto-approve.
  #
  # Reading the stack flag at submit-time (rather than mutating each
  # member's `auto_approve_plan` at `Stacks.start_planning/1`) keeps the
  # boolean authoritative on the stack itself: toggling `auto_accept_plan`
  # mid-flight instantly changes behavior for the next plan submission
  # without a mutation storm across member tasks.
  defp maybe_auto_approve(%Plan{} = plan) do
    task = plan.task_id |> then(&Repo.get!(Task, &1)) |> Repo.preload(:stack)
    via = auto_approve_via(task)

    if via do
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
                  via: via,
                  resource_type: "plan",
                  resource_id: approved_plan.id,
                  action: "auto_approved",
                  actor_type: "system"
                }
              )

              {:ok, approved_plan}

            {:error, reason} = err ->
              Logger.warning(
                "auto_approve_plan: approve_plan failed task_id=#{task.id} plan_id=#{plan.id} via=#{via} reason=#{inspect(reason)}"
              )

              err
          end

        {:skip, reason} ->
          Logger.warning(
            "auto_approve_plan skipped task_id=#{task.id} plan_id=#{plan.id} via=#{via} reason=#{reason}"
          )

          :telemetry.execute(
            [:platform, :plan, :auto_approve_skipped],
            %{count: 1},
            %{
              task_id: task.id,
              plan_id: plan.id,
              via: via,
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

  # WHICH FLAG ARMS THE AUTO PATH, as ONE statement. Extracted from
  # `maybe_auto_approve/1` in task 019fa605 stage 3 because
  # `retry_auto_approval/1` must ask the identical question: an arm that
  # re-derived "armed" locally could retry a task the tail itself would
  # decline, and would log a skip on every reconcile tick forever.
  #
  # `task` must arrive with `:stack` preloaded — both callers do it.
  @spec auto_approve_via(%Task{}) :: :task | :stack | nil
  defp auto_approve_via(%Task{} = task) do
    cond do
      task.auto_approve_plan -> :task
      task.stack && task.stack.auto_accept_plan -> :stack
      true -> nil
    end
  end

  # ── ADR-0046 member 5: the architecture gate ────────────────────────
  #
  # STATE ONLY at this stage. Nothing here is called from the plan
  # lifecycle yet; `submit_plan_for_review/1` opens the gate in stage 2,
  # the MCP verdict tool closes it in stage 4, and the deadline timer
  # lands in stage 5. These functions are the whole vocabulary those
  # stages speak — no other module reads `plans.architecture_verdict`
  # directly.

  # 15 minutes. Long enough for an architect agent to actually read a
  # multi-stage plan and the ADRs it cites (member 3's context resolvers
  # push a real reading load onto that dispatch); short enough that one
  # silent architect does not hold an org's entire planning queue for a
  # working day. Overridable per-environment because the test suite
  # needs it to be ~0 and a human-in-the-loop override wants it longer.
  @architecture_gate_default_timeout_ms 15 * 60 * 1_000

  @doc """
  How long an open architecture gate has before it is considered expired.

  Configure with `config :platform, architecture_gate_timeout_ms: <ms>`.
  """
  @spec architecture_gate_timeout_ms() :: pos_integer()
  def architecture_gate_timeout_ms do
    Application.get_env(
      :platform,
      :architecture_gate_timeout_ms,
      @architecture_gate_default_timeout_ms
    )
  end

  @doc """
  Open the architecture gate on a plan version.

  Writes `state: "pending"`, `opened_at`, `deadline_at` (now +
  `architecture_gate_timeout_ms/0`) and `architect_agent_id`. The
  remaining keys are written as `nil` / `[]` so every reader sees the
  full shape and never has to distinguish "key absent" from "key nil".

  Goes through `Plan.architecture_verdict_changeset/2`, so this cannot
  move the plan's `status` even by accident.
  """
  @spec open_architecture_gate(Plan.t(), String.t() | nil) :: {:ok, Plan.t()} | {:error, term()}
  def open_architecture_gate(%Plan{} = plan, architect_agent_id \\ nil) do
    now = DateTime.utc_now()
    deadline = DateTime.add(now, architecture_gate_timeout_ms(), :millisecond)

    verdict = %{
      "state" => "pending",
      "opened_at" => DateTime.to_iso8601(now),
      "deadline_at" => DateTime.to_iso8601(deadline),
      "resolved_at" => nil,
      "resolved_by" => nil,
      "architect_agent_id" => architect_agent_id,
      "source" => nil,
      "summary" => nil,
      "findings" => []
    }

    plan
    |> Plan.architecture_verdict_changeset(%{architecture_verdict: verdict})
    |> Repo.update()
  end

  @doc """
  Read the gate's state. **Level-triggered, and it never writes.**

  Returns `:none` when the gate never opened for this plan version,
  `{:open, verdict}` while it is genuinely pending, and
  `{:resolved, verdict}` once it carries a terminal state.

  A `"pending"` verdict whose `deadline_at` has passed is reported as
  `{:resolved, %{"state" => "expired", "source" => "deadline"}}`
  WITHOUT persisting anything. That projection is the correctness
  guarantee that a gate can never block forever; stage 5's timer is only
  the eager path that also writes the row and resumes the deferred work.

  The rationale is a live production incident recorded in the
  2026-07-26 journal: `deploying -> done` lived solely in an
  edge-triggered PubSub handler with no level re-check, and a container
  restart between the broadcast and the handler stranded a completed
  task at `deploying` indefinitely while re-dispatching it every 90
  minutes. Same shape here. Build the level check first and treat the
  edge as an optimisation.

  A `"pending"` verdict with a missing or unparseable `deadline_at` is
  ALSO reported as expired. Deliberate, and it is the same argument: the
  alternative is a gate with no falsifiable end, which is the exact
  failure this function exists to rule out. Failing toward "not blocked"
  restores today's behaviour (a plan approves without architect review);
  failing toward "blocked" strands the task and needs a human.

  Accepts a `%Plan{}` or a plan id; **either way the row is re-read from
  the database.** A caller holding a struct loaded before the gate moved
  would otherwise get a stale answer, and this is the function every
  other module asks the question through. (Member 4's reviewer found the
  mirror-image bug in `AutoMerger.execute_merge/4`, which reads
  `planning_step_outcomes` off a struct loaded in a different process.)
  """
  @spec architecture_gate(Plan.t() | binary()) :: :none | {:open, map()} | {:resolved, map()}
  def architecture_gate(plan_or_id) do
    case resolve_plan_for_gate(plan_or_id) do
      nil -> :none
      %Plan{architecture_verdict: nil} -> :none
      %Plan{architecture_verdict: verdict} -> classify_architecture_verdict(verdict)
    end
  end

  @doc """
  True while the architecture gate is genuinely holding this plan.

  The single question every other module asks. Defined in terms of
  `architecture_gate/1` so the expiry projection can never be skipped by
  a caller that pattern-matches the raw column itself.
  """
  @spec architecture_gate_open?(Plan.t() | binary()) :: boolean()
  def architecture_gate_open?(plan_or_id), do: match?({:open, _}, architecture_gate(plan_or_id))

  @doc """
  Close the gate with a terminal verdict. One-shot.

  `verdict` is merged over the open verdict, so `opened_at`,
  `deadline_at` and `architect_agent_id` survive; `resolved_at` is
  stamped, and `:resolved_by` / `:source` may be supplied in `opts` (a
  non-nil value already present in `verdict` wins).

  Errors:

    * `{:error, :plan_not_found}`
    * `{:error, :gate_not_open}` — the gate never opened for this version
    * `{:error, :gate_already_resolved}` — somebody already closed it
    * `{:error, :verdict_state_not_terminal}` — `"state" => "pending"`;
      re-opening is `open_architecture_gate/2`'s job
    * `{:error, %Ecto.Changeset{}}` — the verdict failed validation

  ## Why one-shot, and how "first writer wins" is decided

  A duplicate MCP call must be harmless, and a late verdict racing an
  expired deadline must be deterministic. Both fall out of arbitrating
  on the PERSISTED state rather than on `architecture_gate/1`'s
  projection: an overdue-but-unwritten gate still reads `"pending"` in
  the row, so an architect whose answer beats stage 5's timer to the
  write genuinely wins, and once the timer has written `"expired"` the
  late answer is refused. Note this is the one place the level
  projection is deliberately NOT consulted — readers deciding whether to
  block want the projection; the writer arbitrating a race wants the row.

  The check and the write are one statement: the `UPDATE` carries its
  own `state = 'pending'` predicate, so two concurrent writers cannot
  both observe an open gate and both write. Zero rows affected IS the
  already-resolved answer.
  """
  @spec record_architecture_verdict(Plan.t() | binary(), map(), keyword()) ::
          {:ok, Plan.t()} | {:error, term()}
  def record_architecture_verdict(plan_or_id, verdict, opts \\ []) when is_map(verdict) do
    case resolve_plan_for_gate(plan_or_id) do
      nil ->
        {:error, :plan_not_found}

      %Plan{architecture_verdict: nil} ->
        {:error, :gate_not_open}

      %Plan{architecture_verdict: %{"state" => "pending"} = current} = plan ->
        if Map.get(verdict, "state") == "pending" do
          {:error, :verdict_state_not_terminal}
        else
          write_architecture_verdict(plan, current, verdict, opts)
        end

      %Plan{} ->
        {:error, :gate_already_resolved}
    end
  end

  defp write_architecture_verdict(%Plan{} = plan, current, attrs, opts) do
    now = DateTime.utc_now()

    merged =
      current
      |> Map.merge(attrs)
      |> put_verdict_default("resolved_at", DateTime.to_iso8601(now))
      |> put_verdict_default("resolved_by", Keyword.get(opts, :resolved_by))
      |> put_verdict_default("source", Keyword.get(opts, :source))

    changeset = Plan.architecture_verdict_changeset(plan, %{architecture_verdict: merged})

    case Ecto.Changeset.apply_action(changeset, :update) do
      {:error, %Ecto.Changeset{} = invalid} ->
        {:error, invalid}

      {:ok, _applied} ->
        {count, _} =
          Plan
          |> where([p], p.id == ^plan.id)
          |> where([p], fragment("?->>'state' = 'pending'", p.architecture_verdict))
          |> Repo.update_all(set: [architecture_verdict: merged, updated_at: now])

        case count do
          1 -> {:ok, Repo.get(Plan, plan.id)}
          0 -> {:error, :gate_already_resolved}
        end
    end
  end

  # Only fills a key that is absent or nil — an explicit value in the
  # caller's verdict always wins over the `opts` fallback.
  defp put_verdict_default(map, key, fallback) do
    case Map.get(map, key) do
      nil -> Map.put(map, key, fallback)
      _present -> map
    end
  end

  defp classify_architecture_verdict(%{"state" => "pending"} = verdict) do
    if architecture_gate_overdue?(verdict) do
      {:resolved, Map.merge(verdict, %{"state" => "expired", "source" => "deadline"})}
    else
      {:open, verdict}
    end
  end

  defp classify_architecture_verdict(%{"state" => state} = verdict) when is_binary(state) do
    {:resolved, verdict}
  end

  defp classify_architecture_verdict(_other), do: :none

  defp architecture_gate_overdue?(%{"deadline_at" => deadline}) when is_binary(deadline) do
    case DateTime.from_iso8601(deadline) do
      {:ok, at, _offset} -> DateTime.compare(DateTime.utc_now(), at) != :lt
      {:error, _reason} -> true
    end
  end

  defp architecture_gate_overdue?(_verdict), do: true

  # Always re-read: see the `architecture_gate/1` @doc. A gate answer
  # derived from a struct somebody loaded earlier is the class of bug
  # this whole stack is undoing.
  defp resolve_plan_for_gate(%Plan{id: id}), do: Repo.get(Plan, id)
  defp resolve_plan_for_gate(id) when is_binary(id), do: Repo.get(Plan, id)
  defp resolve_plan_for_gate(_other), do: nil

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

  # ── ADR-0046 member 5 stage 3: the single exit from the gate ──────────

  @doc """
  Close an open architecture gate and run the tail `submit_plan_for_review/1`
  deferred. **This is the only exit from the gate.**

  Every resolver goes through here and calls nothing else: stage 4's two
  verdict surfaces, stage 5's deadline, and `approve_plan/3`'s human
  override. One function so the four ways a gate can end cannot each grow
  their own idea of what "the gate finished" means.

  Steps, in this order:

    1. `record_architecture_verdict/3` writes the terminal verdict. It is
       one-shot and arbitrates on the persisted row, so a verdict racing a
       deadline is deterministic and a duplicate call is `{:error,
       :gate_already_resolved}` rather than a second settlement.
    2. The planning cursor returns to `:planning` — the gate is what parked
       it at `:architecting`.
    3. The resolution decides the tail.

  ## Resolutions

    * `:pass` — run `settle_plan_submission/1`: `maybe_auto_approve/1` then
      `maybe_emit_plan_review_inbox/1`, the deferred tail run late instead
      of never.
    * `:expired` / `:dispatch_failed` — identical to `:pass` (FALL OPEN,
      ADR-0046 decision 7), PLUS `record_planning_step(task, :architecture,
      {:error, reason})`. Falling open without recording is the exact
      conflation forbidden by
      `0046-design-and-architecture-phases-in-planning.md § Per-step outcome`,
      so the two live in one code path and
      are asserted in one test.
    * `:reject` — write the verdict, return the cursor, and hand off to
      `Platform.Tasks.ArchitectureRejection.handle/1` (ADR-0046 member 6).
      No auto-approval and no sponsor row: what happens after a rejection
      is bounded iteration, and it is owned by that module rather than by
      this one.
    * `:human_override` — write the verdict, return the cursor, and STOP.
      Used by `approve_plan/3` when a human approves past an open gate; the
      caller IS the settlement, so this resolution must not settle again.

  `:human_override` widens the arity-2 signature this stage was specified
  with. It is here rather than inline in `approve_plan/3` precisely because
  of the paragraph above: an override that wrote its own verdict and moved
  its own cursor would be a fifth exit from the gate, which is the thing
  this function exists to prevent.

  ## What a `:reject` now does, and where it stops

  Member 6 (`019f9b29-251e`) closed the interim stall this section used to
  describe. `Platform.Tasks.ArchitectureRejection.handle/1` has three
  outcomes, and this function chooses none of them:

    * BELOW the bound — `reject_plan/3` persists `status: "rejected"` with
      the architect's findings as the `rejection_reason`, and the identical
      body is posted to the execution space. The post is what wakes the
      planner; the persisted reason is what survives a restart that eats the
      wake-up. The planner is asked for the version AFTER the one just
      rejected — derived from `plan.version`, never a literal, because a
      second rejection must ask for a v3 rather than re-ask for the v2 the
      architect has already turned down.
    * AT the bound (`ArchitectureRejection.reject_limit/0`) — it escalates
      instead. The plan is left UNTOUCHED in `pending_review`, a digest of
      every round is posted and a sponsor inbox row is emitted, and no
      further version is asked for. The bound is what stops the loop; the
      notification is best-effort on top of it.
    * IN FLIGHT — refused outright with `{:error, :plan_in_flight}`, so a
      plan whose stages have already started is never retro-rejected.

  This function must not grow any of them: it hands the resolved plan to
  `ArchitectureRejection.handle/1` and swallows its errors, because the
  verdict is already written and the gate must still report that it
  resolved. Note also that THIS path never authors a new plan version — the
  planner does, in response to the chat message — which is asserted in
  `ArchitectureGateApprovalTest`.

  `opts` accepts `:resolved_by`, `:source`, `:summary` and `:findings`,
  which are merged into the verdict. `:source` must be one of
  `Plan.architecture_verdict_sources/0` or `nil`; it defaults to
  `"deadline"` for `:expired` and `"human"` for `:human_override`, and to
  `nil` otherwise — a caller reached through a channel is expected to
  name it (`"mcp"`, `"handle_output"`), because that distinction is the
  whole reason the field exists.
  """
  @spec resolve_architecture_gate(
          Plan.t() | binary(),
          :pass | :reject | :expired | :dispatch_failed | :human_override,
          keyword()
        ) :: {:ok, Plan.t()} | {:error, term()}
  def resolve_architecture_gate(plan_or_id, resolution, opts \\ [])
      when resolution in [:pass, :reject, :expired, :dispatch_failed, :human_override] do
    verdict =
      %{"state" => architecture_verdict_state(resolution)}
      |> put_verdict_present("summary", Keyword.get(opts, :summary))
      |> put_verdict_present("findings", Keyword.get(opts, :findings))

    record_opts = [
      resolved_by: Keyword.get(opts, :resolved_by),
      source: Keyword.get(opts, :source, architecture_verdict_source(resolution))
    ]

    case record_architecture_verdict(plan_or_id, verdict, record_opts) do
      {:ok, resolved} ->
        _ = move_planning_cursor(resolved.task_id, :planning)
        settle_resolved_architecture_gate(resolved, resolution)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp architecture_verdict_state(:pass), do: "passed"
  defp architecture_verdict_state(:reject), do: "rejected"
  defp architecture_verdict_state(:expired), do: "expired"
  defp architecture_verdict_state(:dispatch_failed), do: "dispatch_failed"
  defp architecture_verdict_state(:human_override), do: "human_override"

  # `"source"` names the CHANNEL the verdict arrived through, and this
  # function only knows the two channels that ARE a resolution: stage 5's
  # timer and an operator override. The other three resolutions can come
  # in either of two ways — the MCP tool or an external text parse — and
  # only the caller knows which, so each names itself (`source: "mcp"` in
  # `ToolSurface.resolve_architecture_verdict/5`, `source: "handle_output"`
  # in `Handlers.ArchitectureReviewPlan.apply_gate_resolution/3`).
  #
  # The default for those is `nil`, "no channel answered" — NOT
  # `"architect"` / `"dispatch"`, which is what this function emitted
  # before and which is what a source value looks like when it has given
  # up and restated `"state"`. `"architect"` was true of every verdict
  # and so distinguished nothing; `"dispatch"` said only what
  # `state == "dispatch_failed"` already said, one field over. A verdict
  # written by a caller that names no channel genuinely has no channel,
  # and `nil` is the honest way to say so — see `Plan`'s moduledoc.
  defp architecture_verdict_source(:expired), do: "deadline"
  defp architecture_verdict_source(:human_override), do: "human"
  defp architecture_verdict_source(_caller_names_its_own_channel), do: nil

  defp put_verdict_present(verdict, _key, nil), do: verdict
  defp put_verdict_present(verdict, key, value), do: Map.put(verdict, key, value)

  # `:human_override` STOPS, because `approve_plan/3` is mid-flight and
  # settling here would approve the plan twice.
  defp settle_resolved_architecture_gate(%Plan{} = resolved, :human_override) do
    broadcast_board({:plan_updated, resolved})
    {:ok, resolved}
  end

  # ADR-0046 member 6 (`019f9b29-251e`) stage 3: the seam member 5 left
  # open. Everything downstream of a rejection — the iteration counter,
  # the feedback body, the bound and the escalation — lives in
  # `ArchitectureRejection`, not here. A failure there is swallowed: the
  # verdict is already written and the gate must still report that it
  # resolved.
  defp settle_resolved_architecture_gate(%Plan{} = resolved, :reject) do
    broadcast_board({:plan_updated, resolved})

    case Platform.Tasks.ArchitectureRejection.handle(resolved) do
      {:ok, _outcome, final_plan} -> {:ok, final_plan}
      {:error, _reason} -> {:ok, resolved}
    end
  end

  defp settle_resolved_architecture_gate(%Plan{} = resolved, :pass) do
    broadcast_board({:plan_updated, resolved})
    settle_plan_submission(resolved)
  end

  # FALL OPEN AND SAY SO. Recorded BEFORE the settlement so a merge-time
  # reader (member 4's `planning_gate_failed?/1`) sees "the gate did not
  # complete" even if the settlement itself goes wrong.
  defp settle_resolved_architecture_gate(%Plan{} = resolved, fell_open)
       when fell_open in [:expired, :dispatch_failed] do
    _ = record_architecture_planning_step(resolved.task_id, {:error, fell_open})
    broadcast_board({:plan_updated, resolved})
    settle_plan_submission(resolved)
  end

  # ── task 019fa605 stage 3: the lost deferred tail ─────────────────────

  # THE RETRY SET, and it is deliberately two states rather than the three
  # this stage was specified with. See `retry_auto_approval/1`'s @doc for
  # why `"passed"` is a REFUSAL.
  @retry_auto_approval_states ["expired", "dispatch_failed"]

  @doc """
  The verdict states `retry_auto_approval/1` will re-run the deferred tail for.

  Public so `TaskRouterWatcher.sweep_unsettled_auto_approvals/0` can build its
  candidate query from the SAME list this module refuses on. The sweep holds no
  policy of its own; a second copy of this list is how the query and the
  refusal drift apart and the sweep starts scanning rows it can never act on.
  """
  @spec retryable_auto_approval_states() :: [String.t()]
  def retryable_auto_approval_states, do: @retry_auto_approval_states

  @doc """
  Re-run the deferred auto-approval tail for a plan whose gate already
  resolved terminally but which never left `pending_review`.

  Stage 1's `sweep_expired_architecture_gates/0` heals the shape where the
  verdict ROW still reads `"pending"`. This heals the shape AFTER that: a
  verdict committed terminal on a plan still sitting at `pending_review`
  with the auto flag armed — the deferred `settle_plan_submission/1` tail
  was lost between the verdict write and the approval.

  **This function heals deferred tails only.** It calls the private
  `maybe_auto_approve/1` and NOTHING else — specifically NOT
  `settle_plan_submission/1`, which also calls `maybe_emit_plan_review_inbox/1`.
  A recurring sweep re-entering that would emit a duplicate sponsor Inbox row
  every five minutes forever.

  Returns `{:ok, :approved}` | `{:ok, :noop, reason}` | `{:error, term()}`.

  ## That the tail can be lost at all is a property of this repo, not a theory

  `record_architecture_verdict/3`'s write is a committed `Repo.update_all`
  (see `write_architecture_verdict/4`) that PRECEDES the tail;
  `resolve_architecture_gate/3` then calls `settle_resolved_architecture_gate/2`
  outside any transaction. So any raise in the tail leaves the verdict
  written and the approval un-run. Both writers of `:expired` sit exactly
  where such a raise is swallowed and never retried:

    * `TaskRouterWatcher.settle_expired_gate/2` runs inside an `Enum.reduce`
      under the reconcile tick's `rescue`/`catch :exit` envelope, which
      degrades the whole sweep to zeros and moves on. The row it half-settled
      can never be seen again, because that sweep's candidate query filters
      `->>'state' = 'pending'` and the state is now `"expired"`.
    * `TaskRouter`'s `{:architecture_gate_deadline, plan_id}` handler runs in
      a GenServer `handle_info`, where a raise kills the router and the
      timer is never re-armed.

  `"dispatch_failed"` is written from `Handlers.ArchitectureReviewPlan`'s
  fire-and-forget output path, which has the same exposure.

  ## THE REFUSAL SET IS THE DELIVERABLE

    * `"rejected"` — GOVERNANCE, and the reason this function has an
      allow-list rather than "any terminal verdict".
      `Platform.Tasks.ArchitectureRejection.handle/1` leaves a plan
      UNTOUCHED at `pending_review` when it reaches `reject_limit/0` and
      escalates to a human (`escalate/2` returns the plan verbatim — no
      reject, no new lifecycle state). That row is BYTE-IDENTICAL in
      `plans.status` to the stall this function exists to heal. An arm keyed
      on "pending_review + terminal verdict" would auto-approve a plan an
      architect explicitly rejected and a human was summoned to look at —
      strictly worse than the stall.
    * `"human_override"` — that state only exists on a plan a human already
      approved, written by `approve_plan/3` mid-flight.
    * `"passed"` — REFUSED, and this stage was specified to retry it. The
      specification is wrong. Two independent grounds:

      1. NO WRITER CAN LOSE THIS TAIL. `:pass` reaches
         `resolve_architecture_gate/3` from exactly two places —
         `Federation.ToolSurface`'s MCP verdict tool and
         `Handlers.ArchitectureReviewPlan` — and the MCP path is a
         synchronous request whose raise surfaces to the calling agent as an
         error it retries. There is no timer, no capped sweep and no
         swallow-everything reconcile envelope on the `:pass` path, so the
         shape this function heals is not reachable through it. What a
         `"passed"` plan at `pending_review` on an ARMED task actually means
         is that the tail RAN and `auto_approve_precondition/2` declined.
      2. NO CONTAINMENT IF THE RETRY IS WRONG. `:expired` and
         `:dispatch_failed` run `record_architecture_planning_step(task,
         {:error, fell_open})` before settling, so `planning_gate_failed?/1`
         stays true and `AutoMerger.execute_merge/4` still refuses the
         merge — a mistaken retry approves a plan that a human still has to
         unblock. A `"passed"` plan has no such record, so a mistaken retry
         runs unattended all the way to merge.

      Note the argument that `:pass` "already calls `settle_plan_submission/1`"
      is true but does NOT discriminate: `settle_resolved_architecture_gate/2`'s
      `:expired`/`:dispatch_failed` clause calls it identically. Taken alone
      that argument would empty the retry set. The discriminator is which
      writers can lose the tail, above.
    * `:none` — a principled boundary, not caution: a plan whose gate never
      opened ran its tail INLINE at submit inside
      `settle_ungated_plan_submission/1`. There is no deferred tail to have
      lost.
    * `{:open, _}` — the gate is genuinely still holding the plan. That is
      stage 1's business, not this function's.
    * NOT ARMED — asked through `auto_approve_via/1`, the same statement
      `maybe_auto_approve/1` uses, so the two cannot disagree.
    * PRECONDITION FAILURE (`auto_approve_precondition/2`: empty plan, no
      execution assignee, no review assignee) — refused HERE, terminally,
      rather than being discovered inside `maybe_auto_approve/1`. That
      matters because this runs on a 5-minute tick: letting the tail
      discover it would log a `Logger.warning` and emit
      `[:platform, :plan, :auto_approve_skipped]` 288 times a day per plan,
      forever, for a condition no retry can change.
  """
  @spec retry_auto_approval(Plan.t() | binary()) ::
          {:ok, :approved} | {:ok, :noop, atom()} | {:error, term()}
  def retry_auto_approval(plan_or_id) do
    # Never trust a caller's struct — `architecture_gate/1`'s @doc argues
    # why, and this arm is reached from a sweep holding rows read before
    # the classification.
    case resolve_plan_for_gate(plan_or_id) do
      nil -> {:error, :plan_not_found}
      %Plan{status: "pending_review"} = plan -> retry_lost_deferred_tail(plan)
      %Plan{} -> {:ok, :noop, :not_pending_review}
    end
  end

  defp retry_lost_deferred_tail(%Plan{} = plan) do
    with {:gate, {:resolved, %{"state" => state}}} <- {:gate, architecture_gate(plan.id)},
         {:retryable, true, _state} <- {:retryable, state in @retry_auto_approval_states, state},
         task = plan.task_id |> then(&Repo.get!(Task, &1)) |> Repo.preload(:stack),
         {:armed, via} when not is_nil(via) <- {:armed, auto_approve_via(task)},
         {:precondition, :ok} <- {:precondition, auto_approve_precondition(task, plan)} do
      run_lost_deferred_tail(plan)
    else
      {:gate, :none} -> {:ok, :noop, :no_gate}
      {:gate, {:open, _verdict}} -> {:ok, :noop, :gate_open}
      {:retryable, false, state} -> {:ok, :noop, retry_refusal_for_state(state)}
      {:armed, nil} -> {:ok, :noop, :not_armed}
      {:precondition, {:skip, reason}} -> {:ok, :noop, reason}
    end
  end

  defp run_lost_deferred_tail(%Plan{} = plan) do
    case maybe_auto_approve(plan) do
      {:ok, %Plan{status: "approved"}} ->
        {:ok, :approved}

      # Defensive: the precondition and the arming were both checked above,
      # so the tail should not decline. If it does, say so rather than
      # reporting an approval that did not happen.
      {:ok, %Plan{}} ->
        {:ok, :noop, :auto_approve_declined}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Named refusals, so the sweep's telemetry says WHICH governance rule
  # declined rather than a single opaque atom.
  defp retry_refusal_for_state("rejected"), do: :architect_rejected
  defp retry_refusal_for_state("human_override"), do: :human_override
  defp retry_refusal_for_state("passed"), do: :gate_passed
  defp retry_refusal_for_state(_unknown), do: :verdict_not_retryable

  def approve_plan(plan, approved_by, opts \\ [])

  # ── ADR-0046 member 5 stage 3: the architecture gate's choke point ────
  #
  # ONE guard, EVERY approval writer. Stage 2's deferral only holds the
  # auto path; there are two other production writers and one of them is
  # agent-reachable — the MCP `plan_approve` tool, which lives in the
  # `plan` capability bundle, defaults `approved_by` to the literal
  # `"system"`, and calls this function directly. Guarding the submit path
  # alone would ship a gate with a documented bypass and an agent standing
  # next to it. Same argument commit `70fc30fe` makes for guarding the
  # router's `:dispatch` handler rather than its ~13 injectors: per-caller
  # guards do not cover the callers you have not met yet.
  #
  # WHO MAY PASS AN OPEN GATE: an approval whose `approved_by` resolves to
  # an existing `Accounts.User`. The LiveView button already sends a user
  # UUID, so the human path needs ZERO UI change; `"system:auto"`,
  # `plan_approve`'s `"system"` default and any agent slug are refused.
  #
  # ADR-0046 decision 4 redefines `auto_approve_plan` as "no HUMAN gate" —
  # the machine gate SUBSTITUTES for the human, it does not OUTRANK one. A
  # human looking at the plan is the superior authority and the architect's
  # findings are advisory to them. Blocking a human behind a model's
  # verdict inverts the authority order, and that inversion is the concrete
  # mechanism by which an architect that blocks a one-line fix gets
  # switched off within a week — leaving a gate that still looks present.
  #
  # The bypass is NOT silent: it writes `state: "human_override"` through
  # the one gate exit and emits
  # `[:platform, :plan, :architecture_gate_overridden]`.
  def approve_plan(%Plan{status: "pending_review"} = plan, approved_by, opts) do
    case architecture_gate_admission(plan, approved_by) do
      :inert ->
        do_approve_plan(plan, approved_by, opts)

      {:override, %Accounts.User{} = user} ->
        # Closed FIRST, approved second. If the approval then fails, the
        # gate reads `"human_override"` and the plan is still
        # `pending_review` — a retry works because the guard is now inert.
        # The other order would leave an APPROVED plan behind a still-open
        # gate, which stage 5's deadline would later try to settle again.
        _ = record_architecture_human_override(plan, user)
        do_approve_plan(plan, approved_by, opts)

      :refuse ->
        {:error, :architecture_gate_open}
    end
  end

  def approve_plan(_plan, _approved_by, _opts), do: {:error, :invalid_transition}

  # ── Task 019fa510 stage 5: the admission is also a WRITER ─────────────
  #
  # This used to ask `architecture_gate_open?/1`, a boolean. It now branches
  # on `architecture_gate/1`'s full return, because the boolean throws away
  # the one distinction that matters here: an overdue `"pending"` gate is
  # reported as `{:resolved, %{"state" => "expired"}}` by a projection that
  # DOES NOT WRITE. The old code read `false`, returned `:inert`, and
  # `do_approve_plan/3` approved while recording nothing about the gate —
  # leaving the row at `"pending"` and the task's `"architecture"` outcome
  # at the `"complete"` written at submit from `{:ok, :dispatched}`. An
  # unanswered gate was then BYTE-IDENTICAL to an architect pass, and
  # `AutoMerger.execute_merge/4` merged it.
  #
  # WHY THIS IS THE RIGHT PLACE, and not somewhere earlier. The projection
  # is the correctness guarantee (nothing blocks forever) and must stay a
  # pure read — `architecture_gate/1` is called from LiveView renders and
  # from the router's occupancy check, neither of which may write. The
  # deadline timer is the eager writer, but
  # `TaskRouterWatcher.should_run?/1` requires `assignee_type == "agent"`,
  # so a task whose PLANNING assignee is a USER never has a router, never
  # arms the timer, and never gets the `:overdue` occupancy re-fire either.
  # For those tasks THIS is the first and only moment the system both
  # observes the expiry and is already committed to a write, so it is the
  # last honest place to record it. (There is a narrower second window on
  # the same code: an agent-assigned task whose human clicks Approve after
  # the deadline but before any router observes it.)
  defp architecture_gate_admission(%Plan{} = plan, approved_by) do
    # `architecture_gate/1` re-reads the row. Load-bearing: this function is
    # reached from `AutoMerger`-style async paths and from a LiveView
    # holding a struct assigned on mount, and a gate answer derived from a
    # stale struct is the class of bug this stack undoes.
    case architecture_gate(plan) do
      {:open, _verdict} ->
        case human_approver(approved_by) do
          %Accounts.User{} = user -> {:override, user}
          nil -> :refuse
        end

      {:resolved, %{"state" => "expired"}} ->
        # Either the projection (row still `"pending"`) or a verdict a
        # router already wrote. The settler cannot tell them apart from
        # here and deliberately does not try — `record_architecture_verdict/3`
        # arbitrates on the persisted row inside a guarded `UPDATE`, so the
        # already-written case is a swallowed `{:error, :gate_already_resolved}`.
        _ = settle_projected_architecture_expiry(plan)
        :inert

      _resolved_or_none ->
        :inert
    end
  end

  # Write down an expiry that only ever existed as a projection.
  #
  # DOES NOT CALL `resolve_architecture_gate/3`, AND THAT IS THE WHOLE
  # DESIGN. That function's `:expired` clause ends in
  # `settle_resolved_architecture_gate/2`, which calls
  # `settle_plan_submission/1 -> maybe_auto_approve/1 -> approve_plan/3` —
  # and we are being called FROM `approve_plan/3`. The plan would be
  # approved twice with two different `approved_by` values, the human's
  # click landing under `"system:auto"`. The precedent is three functions
  # up: `settle_resolved_architecture_gate(plan, :human_override)` stops
  # for exactly this reason, on exactly this call path.
  #
  # So this is `resolve_architecture_gate/3`'s body minus the settlement:
  # the guarded verdict write, the cursor move back to `:planning` (the
  # architecture step is over however it ended), the planning-step outcome
  # that both `AutoMerger.execute_merge/4` and
  # `StackDeployer.planning_gate_section/1` read through
  # `planning_gate_failed?/1`, and the board broadcast.
  #
  # RECORDED IN THAT ORDER on purpose, mirroring the `:expired` clause of
  # `settle_resolved_architecture_gate/2`: the outcome is written before
  # the broadcast so a merge-time reader sees "the gate did not complete"
  # even if the broadcast goes wrong.
  #
  # EVERY FAILURE IS SWALLOWED and the approval proceeds regardless — same
  # rule as `record_architecture_human_override/2`. Refusing the human's
  # approval over a bookkeeping fault would strand a plan, which is the
  # failure mode the expiry projection exists to rule out in the first
  # place.
  defp settle_projected_architecture_expiry(%Plan{} = plan) do
    case record_architecture_verdict(plan, %{"state" => "expired"}, source: "deadline") do
      {:ok, resolved} ->
        _ = move_planning_cursor(resolved.task_id, :planning)
        _ = record_architecture_planning_step(resolved.task_id, {:error, :expired})
        broadcast_board({:plan_updated, resolved})
        {:ok, resolved}

      {:error, reason} = err ->
        # `:gate_already_resolved` is the COMMON case and is not an error:
        # a router (or a late architect) beat us to the write and their
        # verdict wins. Anything else is a genuine fault worth a line.
        Logger.debug(
          "[Tasks] projected architecture expiry not written plan=#{plan.id} " <>
            "task=#{plan.task_id} reason=#{inspect(reason)}"
        )

        err
    end
  end

  # `Accounts.get_user/1` is now TOTAL — it returns nil for `"system"`,
  # `"system:auto"` and every agent slug, which are the common case here — so
  # the lookup is both the admission test and the totality mechanism.
  #
  # This used to carry an `Ecto.UUID.cast/1` pre-filter, written on this
  # branch when `Accounts.get_user/1` still raised `Ecto.Query.CastError` on a
  # non-UUID binary. Main's 9b0d74d8 pushed that guard down into
  # `Accounts.get_user/1` itself (via `Platform.UUID.valid?/1`), making the
  # pre-filter redundant. `repo_lookup_boundary_test.exs`'s moduledoc names
  # this exact function as the one collapse it deliberately left to whoever
  # merged this stack.
  #
  # Behaviour is unchanged in every case. A canonical UUID resolved then and
  # resolves now. A malformed id returned nil then — the cast rejected it —
  # and returns nil now. A raw 16-byte binary is the only input whose PATH
  # differs: the bare cast used to hex-encode it into a well-formed UUID that
  # then missed, where `Platform.UUID.valid?/1` rejects it on the length check
  # first. Both roads end at nil.
  defp human_approver(approved_by) when is_binary(approved_by) do
    Accounts.get_user(approved_by)
  end

  defp human_approver(_other), do: nil

  defp record_architecture_human_override(%Plan{} = plan, %Accounts.User{} = user) do
    case resolve_architecture_gate(plan, :human_override, resolved_by: user.id) do
      {:ok, resolved} ->
        :telemetry.execute(
          [:platform, :plan, :architecture_gate_overridden],
          %{count: 1},
          %{
            task_id: resolved.task_id,
            plan_id: resolved.id,
            resolved_by: user.id,
            resource_type: "plan",
            resource_id: resolved.id,
            action: "architecture_gate_overridden",
            actor_type: "user"
          }
        )

        {:ok, resolved}

      {:error, reason} = err ->
        # Lost a race to another resolver, or the write failed. Either way
        # the gate is no longer this human's to close and the approval
        # proceeds — refusing here would strand a plan on a bookkeeping
        # fault, which is the failure mode `architecture_gate/1`'s expiry
        # projection exists to rule out.
        Logger.warning(
          "[Tasks] architecture gate human override unrecorded plan=#{plan.id} " <>
            "task=#{plan.task_id} user=#{user.id} reason=#{inspect(reason)}"
        )

        err
    end
  end

  defp do_approve_plan(%Plan{status: "pending_review"} = plan, approved_by, opts) do
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

      # Task 019f7b7e stage 2: reserve per-stack Ecto migration timestamps for
      # any stage whose description says it will author a migration. Runs
      # INSIDE this transaction so approval + reservation are atomic — a
      # failed allocation rolls the approval back rather than shipping a plan
      # whose executor is guaranteed to collide with a sibling.
      task = reserve_migration_slots_for_plan(updated_plan, task)

      previous_task = task

      {finalized_task, frozen_messages} =
        case task.status do
          status when status in ["planning", "backlog"] ->
            apply_dispatch_gate(task)

          _ ->
            {nil, []}
        end

      # ADR 0042 Decision 4: if this approval was the last-plan approval
      # for a stack, detect the closed→open gate transition here so we can
      # fire `stack_gate_opened` post-commit. `plan` is the pre-write plan
      # (status: "pending_review" per this clause head), which the helper
      # needs to know whether this task was already counted as approved
      # before the write.
      gate_transition = Platform.Tasks.Stacks.detect_gate_open_transition(task, plan)

      {updated_plan, previous_task, finalized_task, frozen_messages, superseded_siblings,
       gate_transition}
    end)
    |> case do
      {:ok,
       {updated, previous_task, finalized_task, frozen_messages, superseded_siblings,
        gate_transition}} ->
        # Broadcast supersedee transitions FIRST so observers fold v1 before
        # expanding v2 — preserves the "newer plan replaces older" UX order.
        Enum.each(superseded_siblings, fn sibling ->
          broadcast_board({:plan_updated, sibling})
        end)

        broadcast_board({:plan_updated, updated})

        # Stack-v2 gate broadcast. Signal only — no member is
        # auto-transitioned here. Subscribers (LiveViews, TaskRouter)
        # can react by re-checking `Stacks.executable_members/1` and
        # calling `Tasks.transition_task/2` per-member in dep order.
        case gate_transition do
          {:opened, stack, executable_ids} ->
            # Gap 3 self-heal (task 019f921d): the moment the last member
            # plan is approved, drive a `forming`-but-ready stack open so
            # the commencement gate is actually open by the time
            # subscribers react to `:stack_gate_opened` and transition
            # members to `in_progress`. Idempotent + log-and-swallow: a
            # stack already `in_progress` is a no-op, and a cascade failure
            # never rolls back the (already-committed) approval.
            _ = Platform.Tasks.Stacks.commence_if_ready(stack)

            broadcast_board({:stack_gate_opened, stack.id, executable_ids})

            Logger.info(
              "[Stacks] gate opened for stack=#{stack.id} executable=#{inspect(executable_ids)}"
            )

          :noop ->
            :ok
        end

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

        # Stack v2 (task 019f487e stage 3): if this task belongs to a
        # manual-mode stack (`stack.auto_plan == false`), the wave-gated
        # planning cascade may need to advance now that another
        # member's plan has been approved. Never let a cascade failure
        # roll back the approval itself — the operator already committed
        # to this plan, and we log-and-swallow any downstream error.
        _ = maybe_advance_stack_planning(updated)

        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Migration-slot reservation (task 019f7b7e stage 2) ────────────────────
  #
  # Stack members run concurrently on sibling branches. Two members that each
  # run `mix ecto.gen.migration` within the same second produce identical
  # filenames, and the rollup merge silently keeps one — the M1/M4 incident
  # (2026-07-17, commit `fe302787`). We pre-assign each migration-authoring
  # stage a timestamp from the per-stack allocator at approval time and stash
  # it on the member task's metadata, where it survives dispatch and
  # re-dispatch (stage 3 renders it into the executor's prompt).
  #
  # Deliberately greedy: a description that merely quotes `create table(` in
  # passing burns an unused timestamp, which costs nothing. A missed
  # migration-authoring stage is the collision this task exists to prevent.
  @migration_marker_regex ~r/priv\/repo\/migrations|mix ecto\.gen\.migration|use Ecto\.Migration|create table\(|alter table\(/i

  # Solo tasks have no sibling to collide with — short-circuit before touching
  # the allocator so single-task migration flows are completely unchanged.
  defp reserve_migration_slots_for_plan(%Plan{}, %Task{stack_id: nil} = task), do: task

  defp reserve_migration_slots_for_plan(%Plan{} = plan, %Task{} = task) do
    stages = plan |> Repo.preload(:stages) |> Map.get(:stages) |> List.wrap()
    stage_ids = MapSet.new(stages, & &1.id)

    # Idempotency across re-approval (v2 after v1 was rejected): keep only the
    # reservations whose stage still exists in the current plan, then allocate
    # solely for migration stages that don't already hold one. Without the
    # first filter a rejected-and-revised plan leaks a slot per iteration;
    # without the second, re-approving the same plan double-reserves.
    kept =
      task.metadata
      |> Kernel.||(%{})
      |> Map.get("reserved_migration_slots", [])
      |> List.wrap()
      |> Enum.filter(fn
        %{"stage_id" => stage_id} -> MapSet.member?(stage_ids, stage_id)
        _ -> false
      end)

    already_reserved = MapSet.new(kept, & &1["stage_id"])

    pending =
      stages
      |> Enum.filter(&migration_authoring_stage?/1)
      |> Enum.reject(&MapSet.member?(already_reserved, &1.id))
      |> Enum.sort_by(& &1.position)

    fresh = Enum.map(pending, &allocate_slot_for_stage!(&1, task))

    reservations = kept ++ fresh

    if reservations == List.wrap(Map.get(task.metadata || %{}, "reserved_migration_slots", [])) do
      task
    else
      metadata = Map.put(task.metadata || %{}, "reserved_migration_slots", reservations)

      # Raw `Repo.update!` rather than `update_task/2`: we are mid-transaction,
      # and `update_task/2` broadcasts + fires sweep/reingest side effects that
      # must not escape before commit. The post-commit `{:task_updated, ...}`
      # broadcast further down `approve_plan/3` covers observers.
      task
      |> Task.changeset(%{metadata: metadata})
      |> Repo.update!()
    end
  end

  defp migration_authoring_stage?(%{description: description}) when is_binary(description),
    do: Regex.match?(@migration_marker_regex, description)

  defp migration_authoring_stage?(_), do: false

  # Raises/rolls back on allocator failure — by design. `Repo.rollback/1`
  # inside the enclosing `approve_plan/3` transaction aborts the approval, so
  # an unallocatable slot bounces the approval instead of letting the executor
  # pick its own colliding timestamp.
  defp allocate_slot_for_stage!(stage, %Task{} = task) do
    case Platform.Tasks.Stacks.allocate_migration_slot(task.stack_id) do
      {:ok, timestamp} ->
        %{
          "stage_id" => stage.id,
          "stage_name" => stage.name,
          "timestamp" => timestamp,
          "allocated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

      {:error, reason} ->
        Logger.error(
          "[Tasks] migration slot allocation failed for task=#{task.id} " <>
            "stack=#{task.stack_id} stage=#{stage.id}: #{inspect(reason)}"
        )

        Repo.rollback({:migration_slot_allocation_failed, reason})
    end
  end

  # Stack v2 (task 019f487e stage 3) — manual-mode planning cascade hook.
  #
  # Called from `approve_plan/3` after the transaction commits. Loads
  # the task by the just-approved plan's `task_id`, preloads its parent
  # stack, and forwards to `Platform.Tasks.Stacks.advance_planning_waves/1`
  # only if the stack has `auto_plan == false` (the manual-mode default —
  # auto mode dispatches every wave up front in `start_planning/1`, so no
  # per-approval advance is required).
  #
  # Wrapped in try/rescue/catch so a cascade failure NEVER bubbles into
  # the approval flow — a stale DAG, a raced concurrent transition, or
  # any other downstream error is logged and swallowed.
  defp maybe_advance_stack_planning(%Plan{task_id: task_id}) when is_binary(task_id) do
    try do
      case Repo.get(Task, task_id) do
        nil ->
          :ok

        %Task{stack_id: nil} ->
          :ok

        %Task{} = task ->
          task = Repo.preload(task, :stack)

          case task.stack do
            %Platform.Tasks.Stack{auto_plan: false} = stack ->
              Platform.Tasks.Stacks.advance_planning_waves(stack)

            _ ->
              :ok
          end
      end
    rescue
      e ->
        Logger.warning(
          "[Tasks.approve_plan] maybe_advance_stack_planning raised for task_id=#{task_id}: #{Exception.message(e)}"
        )

        :ok
    catch
      :exit, reason ->
        Logger.warning(
          "[Tasks.approve_plan] maybe_advance_stack_planning exited for task_id=#{task_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp maybe_advance_stack_planning(_), do: :ok

  # Decide whether the just-approved task can move into execution or has to
  # park in `blocked` until its dependencies finish. Returns `{task, frozen}`
  # where `task` is the post-write struct and `frozen` is the list of
  # messages frozen by Policy 2 (empty unless the task moved into
  # `:in_progress`). Broadcasting `frozen` is the caller's responsibility
  # — it should fire post-commit to avoid stale events on rollback.
  defp apply_dispatch_gate(%Task{} = task) do
    # ADR 0042 Decision 4: for stack members whose commencement gate is
    # still closed (some sibling plan hasn't landed yet), park in
    # `stack_pending` rather than surfacing `{:error, :stack_plans_pending}`
    # from `transition_task_status/2` — that error would roll back the
    # enclosing `approve_plan` transaction. Non-stack tasks are vacuously
    # open per `CommencementGate.open?/1` and fall through to the existing
    # unmet-dependencies branch.
    case Platform.Tasks.Stacks.CommencementGate.open?(task) do
      false ->
        {:ok, pending} = transition_task_status(task, "stack_pending")
        {pending, []}

      true ->
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

  # In-flight statuses eligible for return-to-planning. A task in one of
  # these statuses has (or had) an active plan the executor is running
  # against — supersede_current_plan/3 kills that plan and drops the task
  # back to `planning` so the planner can produce a fresh one.
  @in_flight_supersede_statuses ~w(in_progress in_review deploying)

  @doc """
  Return an in-flight task to `planning` by superseding its current
  approved/executing plan. Companion to `reopen_with_feedback/3`, but
  targets `in_progress` / `in_review` / `deploying` instead of `done`.

  Atomic: marks the currently-active plan (`approved` or `executing`) as
  `superseded` with `reason` persisted to its `rejection_reason` column,
  then transitions the task to `planning` via a direct changeset (which
  bypasses `@valid_task_transitions` — reverse edges from in-flight
  statuses to `planning` are intentionally absent from the automated
  pipeline; supersession is the operator-driven exception, mirroring the
  same bypass `reopen_with_feedback/3` uses out of `done`). Both updates
  ride a single `Repo.transaction/1`; if either fails the whole call
  aborts and the task/plan retain their prior state.

  Post-commit side effects (best-effort, do not roll back the transaction):

    * `broadcast_board({:task_updated, task})` — planning column update
    * `broadcast_board({:plan_updated, plan})` — plan row update
    * `ExecutionSpace.post_log/2` — system log message in the task's
      execution space noting the supersession + reason (log-only, so the
      attention router does not re-engage a stopped executor). Skipped
      gracefully if no execution space exists for the task.

  Refusal cases:
    * `{:error, :reason_required}` — `reason` is nil or blank/whitespace
    * `{:error, :not_in_flight}` — task status is not one of
      `in_progress` / `in_review` / `deploying`
    * `{:error, :no_active_plan}` — task has no plan currently in
      `approved` or `executing` status (defensive: an in-flight task
      should always have one, but if the plan history is somehow lost
      we abort rather than transition the task with nothing to supersede)

  The `by_actor_id` argument is reserved for audit provenance. It is not
  written into the plan or task rows today — the transition is captured
  via `plan.rejection_reason` (the reason string) and the system log
  message. Callers should still pass it so future audit-log integrations
  have the actor available without an API change.
  """
  @spec supersede_current_plan(String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, Task.t()}
          | {:error, :not_in_flight | :reason_required | :no_active_plan | term()}
  def supersede_current_plan(task_id, reason, by_actor_id) when is_binary(task_id) do
    cond do
      is_nil(reason) or String.trim(reason) == "" ->
        {:error, :reason_required}

      true ->
        Repo.transaction(fn ->
          case Repo.get(Task, task_id) do
            nil ->
              Repo.rollback(:not_found)

            %Task{status: status} when status not in @in_flight_supersede_statuses ->
              Repo.rollback(:not_in_flight)

            %Task{} = task ->
              case latest_executing_plan(task.id) do
                nil ->
                  Repo.rollback(:no_active_plan)

                %Plan{} = plan ->
                  with {:ok, superseded_plan} <-
                         plan
                         |> Plan.changeset(%{
                           status: "superseded",
                           rejection_reason: reason
                         })
                         |> Repo.update(),
                       {:ok, updated_task} <-
                         task
                         |> Task.changeset(%{status: "planning"})
                         |> Repo.update() do
                    {updated_task, superseded_plan}
                  else
                    {:error, changeset} -> Repo.rollback(changeset)
                  end
              end
          end
        end)
        |> case do
          {:ok, {task, plan}} ->
            preloaded = Repo.preload(task, [:project, :epic, :sponsor, plans: :stages])
            broadcast_board({:task_updated, preloaded})
            broadcast_board({:plan_updated, plan})
            post_supersede_log(task.id, plan, reason, by_actor_id)
            {:ok, preloaded}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Post a log-only system message noting the supersession. Best-effort:
  # if the execution space does not exist yet, skip; if the post fails,
  # warn but do not surface — the task/plan transitions have already
  # committed and re-planning does not depend on the log entry.
  defp post_supersede_log(task_id, %Plan{} = plan, reason, by_actor_id) do
    case ExecutionSpace.find_by_task_id(task_id) do
      nil ->
        :ok

      %{id: space_id} ->
        actor_suffix =
          case by_actor_id do
            id when is_binary(id) and id != "" -> " (by #{id})"
            _ -> ""
          end

        content =
          "Plan v#{plan.version} superseded#{actor_suffix}. Task returned to planning. Reason: #{reason}"

        case ExecutionSpace.post_log(space_id, content) do
          {:ok, _msg} ->
            :ok

          {:error, err} ->
            Logger.warning(
              "supersede_current_plan: post_log failed task_id=#{task_id} plan_id=#{plan.id} error=#{inspect(err)}"
            )

            :ok
        end
    end
  end

  # Most-recent plan the executor is running (or was queued to run)
  # against — `approved` (planner just approved, executor may not have
  # picked it up yet) or `executing` (executor has picked it up and is
  # in the middle of a stage). Used by supersede_current_plan/3 to find
  # the plan we need to mark superseded. Note: this DOES NOT match
  # `completed` — a completed plan corresponds to a task in `done`,
  # which is handled by `reopen_with_feedback/3` instead.
  defp latest_executing_plan(task_id) do
    Plan
    |> where([p], p.task_id == ^task_id and p.status in ["approved", "executing"])
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

  # Kanban `@board_topic` event shapes (subscribe with `subscribe_board/0`,
  # broadcast via `broadcast_board/1`):
  #
  #   * `{:task_updated, %Task{}}` — single-row create/update path
  #     (via `update_task/2`). Preloaded with project/epic/sponsor/plans.
  #   * `{:task_deleted, %Task{}}` — single-row soft-delete via
  #     `soft_delete_task/1`.
  #   * `{:tasks_batch_deleted, [task_id], %{canvas_id, count,
  #     soft_deleted_at}}` — batch soft-delete (M5b/019f6e2c stage 5).
  #     Emitted by `Platform.Meetings.Triage.junk_batch/2` after a
  #     `Repo.update_all/2` transaction. Board LiveViews handle by
  #     re-running `refresh_board/1` once, dropping every listed row in
  #     a single reflow (cheaper than N sequential :task_deleted refreshes
  #     at any batch size ≥ 2). No sibling `:task_deleted` broadcasts fire
  #     for the same ids — batch is the SOLE signal for that path.
  #
  # Scope-narrowed topics (additive, see `topic_for_scope/1`): every event
  # above is ALSO broadcast to zero or more narrower topics derived from ids
  # already present on the payload (no database access). A subscriber that
  # only cares about one task/project/plan/stack can subscribe to just that
  # topic and stop receiving the firehose — which is what keeps `async: true`
  # test modules from observing each other's board traffic. The global topic
  # keeps receiving everything, so no production subscriber has to change.
  #
  #   * `{_evt, %Task{}}`               → `{:task, id}`, `{:project, project_id}`
  #   * `{_evt, %Plan{}}`               → `{:task, task_id}`
  #   * `{_evt, %Epic{}}`               → `{:project, project_id}`
  #   * `{:stage_transitioned, %Stage{}}` → `{:plan, plan_id}` — `Stage` has
  #     only `belongs_to(:plan, ...)`, and this fires on the plan-engine hot
  #     path, so no `Repo` lookup is done to reach the task.
  #   * `{:stack_gate_opened, stack_id, _ids}` → `{:stack, stack_id}`
  #   * `{_evt, %Stack{}}`              → `{:stack, id}`
  #   * `{:runtime_event, %{task_id: id}}` → `{:task, id}`
  #   * anything else                   → no scopes, global only. This
  #     deliberately includes `{:tasks_batch_deleted, ids, meta}`, which is a
  #     board-level reflow signal rather than a per-row event.
  #
  # Broadcast order is global-topic-first, then one broadcast per derived
  # scope; a process holding both subscriptions sees the global copy first.
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

  @typedoc """
  Actor initiating a task-state mutation. Mirrors `Platform.Audit.Event`'s
  actor triple so we don't invent a parallel taxonomy — see
  `sponsor_bypasses_plan_gate?/2` for why the predicate needs to know
  who's moving the task.
  """
  @type actor :: {:user, String.t()} | {:agent, String.t()} | :system

  @doc """
  Predicate: does the sponsor-bypass rule apply for this `task` + `actor`?

  Returns `true` when ALL of the following hold:

    * `task.sponsor_user_id` is set — a human sponsor exists.
    * There is no agent involvement in the current phase — the task has
      no top-level assignee, OR the top-level assignee is a user, OR the
      resolved per-phase assignee for the current phase is a user (or
      unset).
    * `actor` is a human user (`{:user, _uuid}`). `{:agent, _}` and
      `:system` never trigger the bypass — the whole point of the
      exemption is that a human is initiating the move.

  Rationale (task 019f6380): the `require_approved_plan_for/3` gate
  exists to prevent agents from marking their own work complete
  prematurely — an observed pathology in Suite's predecessor. That
  protection is meaningless when there's no agent in the loop and a
  human sponsor is confirming completion; forcing a plan in that case
  wastes tokens on a process the sponsor already knows is done.

  Public because downstream UI (`tasks_live.ex` etc.) may want to hide
  the "requires plan" affordance for the current viewer when the bypass
  would apply.
  """
  @spec sponsor_bypasses_plan_gate?(Task.t(), actor()) :: boolean()
  def sponsor_bypasses_plan_gate?(%Task{} = task, actor) do
    has_sponsor?(task) and human_actor?(actor) and non_agent_assignment?(task)
  end

  def sponsor_bypasses_plan_gate?(_task, _actor), do: false

  defp has_sponsor?(%Task{sponsor_user_id: id}) when is_binary(id), do: true
  defp has_sponsor?(_), do: false

  defp human_actor?({:user, uuid}) when is_binary(uuid), do: true
  defp human_actor?(_), do: false

  # A task has "no agent involvement" for gate-bypass purposes when there
  # is no agent scheduled for either the `execution` or `review` phase
  # AND the coarse `assignee_id`/`assignee_type` is either unset or a
  # user. `phase_has_agent?/1` runs FIRST because a per-phase agent
  # override can coexist with a nil top-level `assignee_id`
  # (task.assignee_id may not yet be derived if the task hasn't
  # transitioned into that phase) — the previous `is_nil(assignee_id) or …`
  # ordering short-circuited and granted bypass in that case even though
  # an agent was queued to execute the work (task 019f6380 stage 4
  # review finding).
  defp non_agent_assignment?(%Task{} = task) do
    cond do
      phase_has_agent?(task) -> false
      is_nil(task.assignee_id) -> true
      task.assignee_type == "user" -> true
      true -> false
    end
  end

  # True when `phase_assignees` schedules an agent for the execution or
  # review phase. Planning-phase agents don't count: the whole point of
  # a planner agent is to produce a plan, at which point the normal
  # `current_plan/1` gate opens and the bypass is moot.
  defp phase_has_agent?(%Task{phase_assignees: pa}) when is_map(pa) do
    phase_pair_agent?(Map.get(pa, "execution")) or
      phase_pair_agent?(Map.get(pa, "review"))
  end

  defp phase_has_agent?(_), do: false

  defp phase_pair_agent?(%{"assignee_type" => "agent"}), do: true
  defp phase_pair_agent?(%{"assignee_type" => "user"}), do: false
  # `per_phase_assignee/2` treats a bare `%{"assignee_id" => id}` (no
  # explicit type) as an agent — mirror that here so both resolvers agree.
  defp phase_pair_agent?(%{"assignee_id" => id}) when is_binary(id), do: true
  defp phase_pair_agent?(_), do: false

  @doc """
  Returns `:ok` if `task` has an approved plan, otherwise
  `{:error, :no_approved_plan}`. Used to gate transitions into execution
  phases (`in_progress`, `in_review`, `deploying`, `done`).

  Two-arity form preserves the pre-actor-threading behavior by
  defaulting `actor` to `:system` — every internal orchestration caller
  (task router, stack manager, webhook controller) stays on the same
  gate they had before task 019f6380 landed.

  Three-arity form consults `sponsor_bypasses_plan_gate?/2`: when the
  bypass fires (human sponsor, no agent, human actor) the gate opens
  even without an approved plan.
  """
  def require_approved_plan_for(%Task{} = task, new_status),
    do: require_approved_plan_for(task, new_status, :system)

  def require_approved_plan_for(%Task{} = task, new_status, actor) do
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

      sponsor_bypasses_plan_gate?(task, actor) ->
        :ok

      true ->
        {:error, :no_approved_plan}
    end
  end

  @doc """
  Returns `:ok` unless the task is transitioning into `:deploying` without a
  resolvable deploy target, in which case `{:error, :no_deploy_target_resolved}`.

  Mirrors `require_approved_plan_for/2`. Both entry paths (LiveView
  `transition_task/2` and MCP-facing `transition_task_status/2`) call this
  guard so the deploying gate holds regardless of caller — see the comment on
  `transition_task_status/2` about MCP `task_update` bypassing the LiveView
  path.

  Non-`:deploying` transitions are always permitted (`:ok`).
  """
  @spec require_deploy_target_for(Task.t(), String.t()) ::
          :ok | {:error, :no_deploy_target_resolved}
  def require_deploy_target_for(%Task{} = task, "deploying") do
    if has_deploy_target?(task), do: :ok, else: {:error, :no_deploy_target_resolved}
  end

  def require_deploy_target_for(_task, _new_status), do: :ok

  @doc """
  Returns `:ok` unless a stack member is transitioning into `in_progress`
  before every sibling has an approved plan (ADR 0042 Decision 4).

  Non-stack tasks (`stack_id: nil`) always return `:ok` — this guard is a
  no-op for plain tasks. Transitions to statuses other than `"in_progress"`
  also return `:ok`; the gate exists specifically to hold members in
  `pending`/`backlog`/`planning`/`stack_pending` until the whole stack's
  plans have landed.

  When the gate is closed for a stack member, returns
  `{:error, :stack_plans_pending, %{stack_id, waiting_on}}` where
  `waiting_on` is the ordered list of sibling task ids that are still
  missing an approved plan (see `Stacks.CommencementGate.waiting_on/1`).

  Mirrors the surface of `require_deploy_target_for/2` and
  `require_approved_plan_for/2`. Wired into `transition_task_status/2` so
  every entry path — LiveView, MCP `task_update`, `drop_task_to_column/2`,
  `apply_dispatch_gate/1` — is covered by the single base primitive.
  """
  @spec require_stack_commencement_for(Task.t(), String.t()) ::
          :ok
          | {:error, :stack_plans_pending, %{stack_id: String.t(), waiting_on: [String.t()]}}
  def require_stack_commencement_for(%Task{stack_id: nil}, _new_status), do: :ok

  def require_stack_commencement_for(%Task{} = task, "in_progress") do
    cond do
      # Already in an execution phase — the gate was checked at entry.
      # Re-checking on intra-execution transitions (e.g. a regression
      # `in_review → in_progress` or a demote `deploying → in_progress`)
      # would spuriously refuse work the operator is intentionally
      # rewinding. Mirrors `require_approved_plan_for/2`.
      task.status in @execution_phase_statuses ->
        :ok

      Platform.Tasks.Stacks.CommencementGate.open?(task) ->
        :ok

      true ->
        {:error, :stack_plans_pending,
         %{
           stack_id: task.stack_id,
           waiting_on: Platform.Tasks.Stacks.CommencementGate.waiting_on(task.stack_id)
         }}
    end
  end

  def require_stack_commencement_for(_task, _new_status), do: :ok

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
  def transition_task(%Task{} = task, new_status),
    do: transition_task(task, new_status, :system)

  @doc """
  Actor-aware variant of `transition_task/2`. `actor` is threaded into
  `require_approved_plan_for/3` so the sponsor-bypass rule can fire when
  a human user is moving a sponsor-only task with no agent involvement
  (see `sponsor_bypasses_plan_gate?/2`). Every other guard behaves
  identically to `transition_task/2`.
  """
  def transition_task(%Task{} = task, new_status, actor) do
    with :ok <- require_deploy_target_for(task, new_status),
         :ok <- require_approved_plan_for(task, new_status, actor),
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
  #
  # ADR 0042 Decision 4: `transition_task_status/2` may now return a
  # 3-tuple `{:error, :stack_plans_pending, %{stack_id, waiting_on}}` when
  # the commencement gate is closed. We stash the whole tuple in the
  # transaction rollback value so the LiveView / MCP caller sees the
  # structured payload, not just the reason atom.
  defp transition_with_policy2_freeze(%Task{} = task, "in_progress") do
    result =
      Repo.transaction(fn ->
        case transition_task_status(task, "in_progress") do
          {:ok, updated} ->
            case Platform.Chat.FreezePolicy.freeze_messages_for_task(updated) do
              {:ok, frozen_messages} ->
                %{updated: updated, frozen: frozen_messages}

              {:error, reason} ->
                Repo.rollback({:error, reason})
            end

          {:error, _reason} = error ->
            Repo.rollback(error)

          {:error, _reason, _details} = error ->
            Repo.rollback(error)
        end
      end)

    case result do
      {:ok, payload} -> {:ok, payload}
      {:error, %{} = _stashed} = err -> err
      {:error, {:error, reason}} -> {:error, reason}
      {:error, {:error, reason, details}} -> {:error, reason, details}
      {:error, other} -> {:error, other}
    end
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
  def drop_task_to_column(%Task{} = task, column),
    do: drop_task_to_column(task, column, :system)

  @doc """
  Actor-aware variant of `drop_task_to_column/2`. `actor` is threaded
  into `require_approved_plan_for/3` so a human user dropping a
  sponsor-only task (no agent involvement) can move it across execution
  columns without an approved plan — see
  `sponsor_bypasses_plan_gate?/2` for the full rule. Every other guard
  and the underlying changeset write are unchanged from
  `drop_task_to_column/2`.
  """
  def drop_task_to_column(%Task{} = task, column, actor) do
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

          require_approved_plan_for(task, target_status, actor) ==
              {:error, :no_approved_plan} ->
            {:error, :no_approved_plan}

          # ADR 0042 Decision 4: manual drops also honour the stack
          # commencement gate. `drop_task_to_column` writes the changeset
          # directly rather than funnelling through `transition_task_status/2`,
          # so we check the guard inline here.
          match?(
            {:error, :stack_plans_pending, _},
            require_stack_commencement_for(task, target_status)
          ) ->
            require_stack_commencement_for(task, target_status)

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

  # TAIL-stall fix (2026-07-22): a stack member that reaches `deploying`
  # AFTER its rollup PR already merged must self-complete to `done` — the
  # rollup-merge webhook already fired and won't be re-delivered, so nothing
  # else would move it. Runs the same generic housekeeping as the fallback
  # head PLUS the per-member deploy-tail trigger. The helper self-guards
  # (`:noop` unless the member is a `no_op_wait_for_rollup` member whose
  # stack rollup PR is stamped merged) and log-and-swallows, so a member
  # legitimately awaiting the merge simply stays at `deploying` and the
  # rollup-merge sweep remains the backstop.
  defp maybe_finalize_transition(%Task{} = previous, %Task{} = task, "deploying") do
    if current_phase(previous) != current_phase(task) do
      maybe_apply_phase_assignee(task)
    end

    maybe_recompute_stack(task)
    maybe_handle_regression(previous, task, "deploying")
    _ = Platform.Tasks.Stacks.complete_no_op_member_if_rollup_merged(task)
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
  # `assignee_id` / `assignee_type` from `phase_assignees[new_phase]`.
  #
  # CORRECTED, task 019fb977 stage 5. This comment used to end "the runtime
  # router and every read path consults `task.assignee_id`, so it has to match
  # the new phase's configured agent". That was FALSE for the router, and its
  # falseness is why 019f42fd's pointer repair looked sufficient for two
  # months while every post-planning dispatch went to the planning agent.
  #
  # `TaskRouter` does NOT consult `task.assignee_id`. It calls
  # `Platform.Orchestration.PhaseRuntime.resolve/1`, which reads
  # `phase_assignees[current_phase(task)]` and only falls back to the flat
  # pointer through `assignee_for_phase/2`'s own resolution order. Repairing
  # the pointer therefore never repaired the dispatch: a phase-BLIND reader
  # was the defect, and a phase-AWARE reader is the fix.
  #
  # What the flat pointer is still for: `TaskRouterWatcher`'s eligibility
  # queries, the board/UI read paths, and `PhaseRuntime`'s own fallback when a
  # task carries no entry for its current phase. Keeping it fresh is worth
  # doing — it is just not what makes dispatch correct.
  #
  # Measured, not asserted (stage 5 control M1): with the phase-aware reader
  # mutated back to `{task.assignee_id, task.assignee_type}` and this
  # ticket's single-write fold still in place, the flat pointer is fresh
  # enough to satisfy two of the three dispatch cases — and case 3 of
  # `task_router_phase_assignee_test.exs`, which forces the pointer stale at
  # READ time, still fails. That is the whole difference between the writer
  # fix and the reader fix, in one test.
  #
  # Task 019fb977 stage 4: for STATUS-DRIVEN transitions this is now a
  # no-op — `transition_task_status/2` folds the same derivation into the
  # status write (`phase_pointer_attrs/2`), so by the time the five
  # `maybe_finalize_transition/3` call sites reach here the `phase_id ==
  # task.assignee_id` arm below short-circuits. Deliberately kept: it is
  # still the correct pointer-repair for any caller that changes
  # `phase_assignees` without changing `status`, and its broadcast is the
  # one `transition_task_status/2` now re-emits itself.
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

  @doc "The global kanban board topic — receives every board event."
  @spec board_topic() :: String.t()
  def board_topic, do: @board_topic

  @doc """
  Build a scope-narrowed board topic.

  Named to mirror `Platform.Tasks.ReviewRequests.topic_for_task/1`. Accepts
  `{:task, id}` / `{:project, id}` / `{:plan, id}` / `{:stack, id}`.
  """
  @spec topic_for_scope({:task | :project | :plan | :stack, String.t()}) :: String.t()
  def topic_for_scope({kind, id}) when kind in [:task, :project, :plan, :stack] do
    @board_topic <> ":" <> Atom.to_string(kind) <> ":" <> to_string(id)
  end

  @doc """
  Subscribe the calling process to a scope-narrowed board topic.

  `subscribe_board(task: id)`, `subscribe_board(project: id)`,
  `subscribe_board(plan: id)` or `subscribe_board(stack: id)`. Unlike
  `subscribe_board/0` this delivers only the events whose payload carries
  that id.
  """
  @spec subscribe_board(keyword()) :: :ok | {:error, term()}
  def subscribe_board([{kind, id}]) when kind in [:task, :project, :plan, :stack] do
    Phoenix.PubSub.subscribe(Platform.PubSub, topic_for_scope({kind, id}))
  end

  @doc "Unsubscribe the calling process from a scope-narrowed board topic."
  @spec unsubscribe_board(keyword()) :: :ok
  def unsubscribe_board([{kind, id}]) when kind in [:task, :project, :plan, :stack] do
    Phoenix.PubSub.unsubscribe(Platform.PubSub, topic_for_scope({kind, id}))
  end

  @doc """
  Broadcast a board event.

  Goes to the global `@board_topic` first, then once per scope derived from
  the payload (see the `@board_topic` comment above). Order matters to a
  process holding both subscriptions and is asserted in
  `test/platform/tasks/board_topic_scope_test.exs`.
  """
  def broadcast_board(message) do
    :ok = Phoenix.PubSub.broadcast(Platform.PubSub, @board_topic, message)

    Enum.each(board_scopes(message), fn scope ->
      Phoenix.PubSub.broadcast(Platform.PubSub, topic_for_scope(scope), message)
    end)
  end

  # Derive narrower topics from ids ALREADY on the payload. Zero database
  # access — this runs on the plan-engine hot path.
  defp board_scopes({_evt, %Task{} = task}) do
    Enum.reject([{:task, task.id}, {:project, task.project_id}], &is_nil(elem(&1, 1)))
  end

  defp board_scopes({_evt, %Plan{} = plan}), do: scope_or_none(:task, plan.task_id)
  defp board_scopes({_evt, %Epic{} = epic}), do: scope_or_none(:project, epic.project_id)
  defp board_scopes({_evt, %Stack{} = stack}), do: scope_or_none(:stack, stack.id)

  defp board_scopes({:stage_transitioned, %Stage{} = stage}),
    do: scope_or_none(:plan, stage.plan_id)

  defp board_scopes({:stack_gate_opened, stack_id, _ids}), do: scope_or_none(:stack, stack_id)

  defp board_scopes({:runtime_event, %{task_id: task_id}}) when is_binary(task_id),
    do: [{:task, task_id}]

  defp board_scopes(_other), do: []

  defp scope_or_none(_kind, nil), do: []
  defp scope_or_none(kind, id), do: [{kind, id}]

  # ── memory_search hit hydration helpers (stage 3, 019f3dbb) ─────────────
  #
  # The two helpers below (`merged_pr_url/1` + `follow_up_task_ids/1`) power
  # the advisory task-hit fields on `Platform.Org.Wiki.Search`. Kept here
  # rather than inside `Search` because they operate purely on the Tasks
  # domain (plans, stages, validations, stack rollup metadata,
  # task_references) and are useful to any caller that already has a
  # `%Task{}` in hand — MCP `task_get`, the follow-up rollup on the
  # kanban card, and future callers that want to know "did this task
  # actually ship?"

  # A follow-up in ANY non-cancelled, non-soft-deleted status signals
  # "someone filed a task to fix/rework this one". `cancelled` is
  # explicitly excluded because a cancelled follow-up is a retracted
  # claim — the agent decided the fix wasn't needed after all.
  @follow_up_source_statuses ~w(backlog planning blocked in_progress in_review deploying done stack_pending)

  @doc """
  Return the merged-PR URL for a task's shipped work, or `nil` when nothing
  landed.

  Resolution order:

    1. **Per-task `pr_merged` validation.** Walks the task's latest plan
       (approved > completed > any) and looks for a `pr_merged` validation
       with `status = "passed"` and `evidence["merge_sha"]`. Combines with
       `project.repo_url` to produce `<repo_url>/commit/<merge_sha>`. This
       is the solo-task path that `Platform.Tasks.AutoMerger.record_merge_result/2`
       populates at `apps/platform/lib/platform/tasks/auto_merger.ex:186`.

    2. **Stack rollup URL fallback.** For stack members whose per-task
       `pr_merged` validation is intentionally deferred (see
       `AutoMerger.record_merge_result/2:180`, the `{:ok, :deferred}` head),
       reach into `stack.metadata["rollup_pr"]["url"]` — populated by
       `Platform.Tasks.StackDeployer` at `stack_deployer.ex:1182` /
       `:1287`. This is the URL agents actually click through to see the
       shipped code for the stack member.

    3. **`nil`.** No pr_merged evidence and no stack rollup URL — the task
       hasn't landed yet (still in-flight, cancelled, or done via a manual
       path with no auto-merger stamp).

  Accepts a `%Task{}` struct or a task id. When passed a struct, missing
  preloads (`:project`, `:stack`, `plans: [stages: :validations]`) are
  fetched lazily so callers don't have to remember the preload chain — the
  cost is one round-trip per invocation, which is fine for the memory_search
  hydration flow (bulk-loaded then hydrated one at a time).
  """
  @spec merged_pr_url(Task.t() | String.t()) :: String.t() | nil
  def merged_pr_url(id) when is_binary(id) do
    case Repo.get(Task, id) do
      %Task{} = task -> merged_pr_url(task)
      nil -> nil
    end
  end

  def merged_pr_url(%Task{} = task) do
    task = ensure_merged_pr_preloads(task)

    case extract_pr_merged_sha(task) do
      {:ok, sha, %Project{repo_url: repo_url}} when is_binary(repo_url) and repo_url != "" ->
        String.trim_trailing(repo_url, "/") <> "/commit/" <> sha

      _ ->
        stack_rollup_url(task)
    end
  end

  defp ensure_merged_pr_preloads(%Task{} = task) do
    preloads =
      []
      |> maybe_add_preload(task, :project)
      |> maybe_add_preload(task, :stack)
      |> maybe_add_plans_preload(task)

    case preloads do
      [] -> task
      list -> Repo.preload(task, list)
    end
  end

  defp maybe_add_preload(preloads, task, key) do
    case Map.get(task, key) do
      %Ecto.Association.NotLoaded{} -> [key | preloads]
      _ -> preloads
    end
  end

  defp maybe_add_plans_preload(preloads, %Task{plans: %Ecto.Association.NotLoaded{}}) do
    [{:plans, [stages: :validations]} | preloads]
  end

  defp maybe_add_plans_preload(preloads, %Task{plans: plans}) when is_list(plans) do
    # Plans loaded — check whether stages/validations are loaded through them.
    needs_stages? =
      Enum.any?(plans, fn plan ->
        case Map.get(plan, :stages) do
          %Ecto.Association.NotLoaded{} -> true
          stages when is_list(stages) -> stages_missing_validations?(stages)
          _ -> true
        end
      end)

    if needs_stages? do
      [{:plans, [stages: :validations]} | preloads]
    else
      preloads
    end
  end

  defp maybe_add_plans_preload(preloads, _), do: preloads

  defp stages_missing_validations?(stages) do
    Enum.any?(stages, fn stage ->
      case Map.get(stage, :validations) do
        %Ecto.Association.NotLoaded{} -> true
        _ -> false
      end
    end)
  end

  # Prefer the newest approved plan, then the newest completed plan, then
  # the newest anything. Mirrors `current_plan/1`'s preference order but
  # doesn't crash when no approved plan exists.
  defp extract_pr_merged_sha(%Task{plans: plans, project: %Project{} = project})
       when is_list(plans) do
    plans
    |> pick_plan_for_pr_lookup()
    |> find_pr_merged_sha()
    |> case do
      nil -> nil
      sha -> {:ok, sha, project}
    end
  end

  defp extract_pr_merged_sha(_), do: nil

  defp pick_plan_for_pr_lookup(plans) do
    approved = plans |> Enum.filter(&(&1.status == "approved")) |> newest_by_version()
    completed = plans |> Enum.filter(&(&1.status == "completed")) |> newest_by_version()
    any = plans |> newest_by_version()

    approved || completed || any
  end

  defp newest_by_version([]), do: nil

  defp newest_by_version(plans) do
    Enum.max_by(plans, &(&1.version || 0), fn -> nil end)
  end

  defp find_pr_merged_sha(nil), do: nil

  defp find_pr_merged_sha(%Plan{stages: stages}) when is_list(stages) do
    stages
    |> Enum.flat_map(fn stage ->
      case Map.get(stage, :validations) do
        list when is_list(list) -> list
        _ -> []
      end
    end)
    |> Enum.find_value(fn validation ->
      if validation.kind == "pr_merged" and validation.status == "passed" do
        Map.get(validation.evidence || %{}, "merge_sha")
      end
    end)
  end

  defp find_pr_merged_sha(_), do: nil

  defp stack_rollup_url(%Task{stack: %Stack{metadata: %{"rollup_pr" => %{"url" => url}}}})
       when is_binary(url) and url != "",
       do: url

  defp stack_rollup_url(_), do: nil

  @doc """
  Return the ids of "follow-up" tasks that reference this target task's
  UUID in their description AND were filed AFTER the target (temporal
  invariant) AND are not `cancelled` (a cancelled follow-up is a retracted
  claim, not a "was supposed to work but didn't" signal).

  The set is derived from the `task_references` table (populated by
  `Platform.Tasks.References` on task write) joined against `tasks`:

      SELECT source_task.id
      FROM task_references r
      JOIN tasks source_task ON source_task.id = r.source_task_id
      WHERE r.target_task_id = <task.id>
        AND source_task.inserted_at > <task.inserted_at>
        AND source_task.status IN ("backlog", "planning", "in_progress",
                                    "in_review", "deploying", "done",
                                    "blocked", "stack_pending")

  Callers use this to distinguish a task that shipped clean (no follow-ups)
  from one that shipped but was later re-opened via a new task (had
  follow-ups). The temporal cut ensures a task filed BEFORE the target
  can't be counted as a follow-up — the reference-scanner picks up any
  UUID mention, so a task that predates the target and coincidentally
  contains the UUID (unlikely but possible during renames/copies) would
  otherwise pollute the set.

  Accepts a `%Task{}` struct or a task id.
  """
  @spec follow_up_task_ids(Task.t() | String.t()) :: [String.t()]
  def follow_up_task_ids(id) when is_binary(id) do
    case Repo.get(Task, id) do
      %Task{} = task -> follow_up_task_ids(task)
      nil -> []
    end
  end

  def follow_up_task_ids(%Task{} = task) do
    from(r in TaskReference,
      join: source in Task,
      on: source.id == r.source_task_id,
      where:
        r.target_task_id == ^task.id and
          source.inserted_at > ^task.inserted_at and
          source.status in ^@follow_up_source_statuses and
          is_nil(source.deleted_at),
      select: source.id
    )
    |> Repo.all()
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
