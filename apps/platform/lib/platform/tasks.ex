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

  alias Platform.{Artifacts, Context, Execution}
  alias Platform.Context.Session
  alias Platform.Execution.Run
  alias Platform.Repo

  alias Platform.Tasks.{Epic, Plan, Project, Stage, Task, Validation}

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

  # ── Valid status transitions (ADR 0018 §7) ───────────────────────────────

  @valid_task_transitions %{
    "backlog" => ~w(planning blocked),
    "planning" => ~w(ready blocked backlog),
    "ready" => ~w(in_progress blocked planning),
    "in_progress" => ~w(in_review blocked done),
    "in_review" => ~w(done in_progress blocked),
    "blocked" => ~w(backlog planning ready in_progress),
    "done" => []
  }

  # ── Projects ─────────────────────────────────────────────────────────────

  def create_project(attrs) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
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

  def list_projects do
    Project
    |> order_by([p], asc: p.name)
    |> Repo.all()
  end

  # ── Epics ────────────────────────────────────────────────────────────────

  def create_epic(attrs) do
    %Epic{}
    |> Epic.changeset(attrs)
    |> Repo.insert()
  end

  def update_epic(%Epic{} = epic, attrs) do
    epic
    |> Epic.changeset(attrs)
    |> Repo.update()
  end

  def get_epic(id), do: Repo.get(Epic, id)

  def list_epics(project_id) do
    Epic
    |> where([e], e.project_id == ^project_id)
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
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
  end

  @doc "Get a task record from Postgres (no ETS merge)."
  def get_task_record(id), do: Repo.get(Task, id)

  def list_tasks_by_project(project_id) do
    Task
    |> where([t], t.project_id == ^project_id)
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
  end

  def list_tasks_by_epic(epic_id) do
    Task
    |> where([t], t.epic_id == ^epic_id)
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
  end

  def list_tasks_by_status(status) do
    Task
    |> where([t], t.status == ^status)
    |> order_by([t], desc: t.inserted_at)
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
    else
      {:error, :invalid_transition}
    end
  end

  # ── Plans ────────────────────────────────────────────────────────────────

  def create_plan(attrs) do
    attrs = maybe_set_plan_version(attrs)

    %Plan{}
    |> Plan.changeset(attrs)
    |> Repo.insert()
  end

  def get_plan(id) do
    Plan
    |> Repo.get(id)
    |> Repo.preload(:stages)
  end

  @doc "Get the latest approved plan for a task."
  def current_plan(task_id) do
    Plan
    |> where([p], p.task_id == ^task_id and p.status == "approved")
    |> order_by([p], desc: p.version)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> nil
      plan -> Repo.preload(plan, :stages)
    end
  end

  def list_plans(task_id) do
    Plan
    |> where([p], p.task_id == ^task_id)
    |> order_by([p], asc: p.version)
    |> Repo.all()
  end

  def submit_plan_for_review(%Plan{status: "draft"} = plan) do
    plan
    |> Plan.changeset(%{status: "pending_review"})
    |> Repo.update()
  end

  def submit_plan_for_review(_plan), do: {:error, :invalid_transition}

  def approve_plan(%Plan{status: "pending_review"} = plan, approved_by) do
    now = DateTime.utc_now()

    plan
    |> Plan.changeset(%{status: "approved", approved_by: approved_by, approved_at: now})
    |> Repo.update()
  end

  def approve_plan(_plan, _approved_by), do: {:error, :invalid_transition}

  def reject_plan(%Plan{status: "pending_review"} = plan, _rejected_by) do
    plan
    |> Plan.changeset(%{status: "rejected"})
    |> Repo.update()
  end

  def reject_plan(_plan, _rejected_by), do: {:error, :invalid_transition}

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

    Task
    |> maybe_filter_project(project_id)
    |> order_by([t], desc: t.inserted_at)
    |> preload([:project, :epic, plans: :stages])
    |> Repo.all()
  end

  defp maybe_filter_project(query, nil), do: query
  defp maybe_filter_project(query, id), do: where(query, [t], t.project_id == ^id)

  @doc "Get a task with full detail: project, epic, plans with stages and validations."
  def get_task_detail(task_id) do
    Task
    |> where([t], t.id == ^task_id)
    |> preload([:project, :epic, plans: [stages: :validations]])
    |> Repo.one()
  end

  @doc """
  Transition a task's status and broadcast the change to the board topic.
  """
  def transition_task(%Task{} = task, new_status) do
    case transition_task_status(task, new_status) do
      {:ok, updated} ->
        updated = Repo.preload(updated, [:project, :epic, plans: :stages])
        broadcast_board({:task_updated, updated})
        {:ok, updated}

      error ->
        error
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
